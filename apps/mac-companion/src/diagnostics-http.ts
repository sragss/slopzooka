import { randomUUID } from "node:crypto";
import type { Express, RequestHandler } from "express";
import {
  isLogEvent,
  isLogClock,
  MAX_LOG_BATCH,
  MAX_LOG_EVENT_BYTES,
  validLogId,
  type LogEvent,
  validTimestamp,
} from "../../../packages/protocol/src/diagnostics.js";
import { captureLogs } from "./log-store.js";
import path from "node:path";
import { logContext, type Diagnostics } from "./logger.js";

/** Install before parsing/authentication; never record headers, queries, or bodies. */
export function logRequests(diagnostics: Diagnostics): RequestHandler {
  const log = diagnostics.logger("http");
  return (req, res, next) => {
    const requested = req.header("X-SlopZooka-Action-ID");
    const actionId = validLogId(requested) ? requested : randomUUID();
    const requestId = randomUUID(),
      started = performance.now();
    const context = { actionId, requestId };
    res.setHeader("X-SlopZooka-Request-ID", requestId);
    res.setHeader("X-SlopZooka-Time", new Date().toISOString());
    const diagnosticsRequest = req.path.startsWith("/api/diagnostics");
    if (diagnosticsRequest) {
      next();
      return;
    }
    let finished = false;
    const complete = () => {
      if (finished) return;
      finished = true;
      const fields = {
        ...context,
        method: req.method,
        route: req.route?.path ?? "unmatched",
        status: res.statusCode,
        durationMs: performance.now() - started,
        ...Object.fromEntries(
          Object.entries(req.params ?? {}).filter(([key]) =>
            /^(sessionId|workspaceId|id)$/.test(key),
          ),
        ),
        aborted: !res.writableFinished,
      };
      if (res.statusCode >= 500 || fields.aborted)
        log.error("http.completed", fields);
      else if (res.statusCode >= 400) log.warn("http.completed", fields);
      else if (!["GET", "HEAD", "OPTIONS"].includes(req.method))
        log.info("http.completed", fields);
      else log.debug("http.completed", fields);
    };
    res.once("finish", complete);
    res.once("close", complete);
    logContext.run(context, next);
  };
}

/** Paired clients only: install after Pairing.install. No new listener or credentials. */
export function installDiagnosticsRoutes(
  app: Express,
  diagnostics: Diagnostics,
  hostId: string,
  flushService: () => Promise<boolean>,
) {
  // Host-wide, bounded admission. Client-provided IDs cannot bypass the budget.
  let budget = 512 * 1024,
    resetAt = Date.now() + 1000;
  let ingesting = 0;
  app.post("/api/diagnostics/events", async (req, res) => {
    const expectedHost = req.header("X-SlopZooka-Host-ID");
    if (expectedHost && expectedHost !== hostId) {
      res.status(409).json({ error: "Diagnostics belong to a different Mac" });
      return;
    }
    const events: unknown = req.body?.events;
    if (
      req.body?.version !== 1 ||
      !Array.isArray(events) ||
      events.length < 1 ||
      events.length > MAX_LOG_BATCH
    ) {
      res.status(400).json({ error: "Invalid diagnostics batch" });
      return;
    }
    if (Date.now() >= resetAt) {
      budget = 512 * 1024;
      resetAt = Date.now() + 1000;
    }
    const bytes = Buffer.byteLength(JSON.stringify(events));
    if (bytes > budget) {
      res.setHeader("Retry-After", "1");
      res.status(429).json({ error: "Diagnostics busy" });
      return;
    }
    budget -= bytes;
    if (ingesting >= 4) {
      res.status(503).json({ error: "Diagnostics busy" });
      return;
    }
    ingesting++;
    try {
      const clientId = req.header("X-SlopZooka-Client-ID");
      const receivedAt = new Date().toISOString();
      const rawClock = req.body.clock;
      const clock = isLogClock(rawClock)
        ? {
            observedAt: rawClock.observedAt,
            offsetMs: rawClock.offsetMs,
            uncertaintyMs: rawClock.uncertaintyMs,
          }
        : undefined;
      let accepted = true,
        rejected = 0;
      for (const raw of events) {
        if (
          !isLogEvent(raw) ||
          !["vision-client", "browser"].includes(raw.source) ||
          Buffer.byteLength(JSON.stringify(raw)) > MAX_LOG_EVENT_BYTES
        ) {
          rejected++;
          continue;
        }
        const event: LogEvent = {
          ...raw,
          receivedAt,
          clock,
          fields: {
            ...raw.fields,
            hostId,
            clientId: validLogId(clientId) ? clientId : "browser",
          },
        };
        if (!diagnostics.store.append(event)) accepted = false;
      }
      if (rejected)
        diagnostics
          .logger("diagnostics")
          .warn("logs.rejected", { hostId, clientId, count: rejected });
      // Acknowledgement means appended to the OS, not merely queued. A forced power
      // loss can still lose a recent batch; this is diagnostics, not an audit journal.
      if (!(await diagnostics.store.flush())) accepted = false;
      res
        .status(accepted ? 200 : 503)
        .json(
          accepted
            ? { ok: true, receivedAt, rejected }
            : { error: "Diagnostics unavailable" },
        );
    } finally {
      ingesting--;
    }
  });

  let capturing = false;
  app.post("/api/diagnostics/capture", async (req, res) => {
    if (capturing) {
      res.status(429).json({ error: "A capture is already running" });
      return;
    }
    const around = req.body?.around ?? new Date().toISOString();
    if (!validTimestamp(around)) {
      res.status(400).json({ error: "Expected a valid incident timestamp" });
      return;
    }
    capturing = true;
    try {
      const flushes = await Promise.allSettled([
        diagnostics.store.flush(),
        flushService(),
      ]);
      const report = await captureLogs(diagnostics.store.directory, around, {
        hostId,
        storage: diagnostics.store.status,
        flushIncomplete: flushes.some(
          (result) => result.status === "rejected" || result.value === false,
        ),
      });
      res.json({
        ...report,
        download: `/api/diagnostics/reports/${report.reportId}`,
      });
    } catch {
      res.status(503).json({ error: "Diagnostics capture unavailable" });
    } finally {
      capturing = false;
    }
  });
  app.get("/api/diagnostics/reports/:id", (req, res) => {
    if (
      !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(
        req.params.id,
      )
    ) {
      res.status(400).json({ error: "Invalid report ID" });
      return;
    }
    res.download(
      path.join(
        diagnostics.store.directory,
        "reports",
        `${req.params.id}.json`,
      ),
      (error) => {
        if (error && !res.headersSent)
          res.status(404).json({ error: "Report unavailable" });
      },
    );
  });
}
