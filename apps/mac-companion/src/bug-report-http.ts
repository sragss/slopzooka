import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import type { Express } from "express";
import { validTimestamp } from "../../../packages/protocol/src/diagnostics.js";
import {
  bugReportBody,
  bugReportURL,
  type BugReportCapture,
} from "./bug-report-draft.js";
import type { GitHubClient } from "./github.js";

/** Paired native composition. A bounded, short-lived draft pins exactly what was reviewed. */
export function installBugReportRoutes(
  app: Express,
  directory: string,
  github: Pick<GitHubClient, "bugReportAccount" | "createBugReport">,
) {
  const drafts = new Map<
    string,
    {
      title: string;
      body: string;
      account: string | null;
      expires: number;
      submission?: Promise<string>;
    }
  >();
  let preparing = 0;
  app.post("/api/diagnostics/bug-report/prepare", async (req, res) => {
    const { title, description, around, reportId } = req.body ?? {};
    if (
      typeof title !== "string" ||
      !title.trim() ||
      title.length > 120 ||
      typeof description !== "string" ||
      !description.trim() ||
      description.length > 4000 ||
      !validTimestamp(around) ||
      (reportId !== undefined &&
        (typeof reportId !== "string" ||
          !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(reportId)))
    ) {
      res.status(400).json({
        error: "Expected a summary, description and incident timestamp",
      });
      return;
    }
    for (const [id, draft] of drafts)
      if (draft.expires < Date.now()) drafts.delete(id);
    if (drafts.size + preparing >= 32 || preparing >= 4) {
      res
        .status(429)
        .json({ error: "Too many report drafts. Try again later." });
      return;
    }
    preparing++;
    try {
      let capture: BugReportCapture | undefined;
      if (reportId) {
        const file = await fs.open(
          path.join(directory, "reports", `${reportId}.json`),
          "r",
        );
        try {
          if ((await file.stat()).size > 32 * 1024 * 1024)
            throw new Error("Report too large");
          capture = JSON.parse(await file.readFile("utf8")) as BugReportCapture;
        } finally {
          await file.close();
        }
        if (capture.reportId !== reportId || capture.around !== around)
          throw new Error("Report mismatch");
      }
      const body = bugReportBody(description, around, capture);
      let browserURL: string | null = null;
      try {
        browserURL = bugReportURL(title, body);
      } catch {
        /* Native publishing has no URL length limit. */
      }
      const account = await github.bugReportAccount().catch(() => null);
      const draftId = randomUUID();
      drafts.set(draftId, {
        title: title.trim(),
        body,
        account,
        expires: Date.now() + 30 * 60_000,
      });
      res.json({ draftId, body, account, browserURL });
    } catch {
      res.status(503).json({
        error: "Could not prepare this report. The snapshot may have expired.",
      });
    } finally {
      preparing--;
    }
  });
  app.post("/api/diagnostics/bug-report/submit", async (req, res) => {
    const draft =
      typeof req.body?.draftId === "string"
        ? drafts.get(req.body.draftId)
        : undefined;
    if (!draft || draft.expires < Date.now()) {
      res.status(410).json({
        error: "Report draft expired. Review it again before publishing.",
      });
      return;
    }
    try {
      if (
        !draft.account ||
        (await github.bugReportAccount()) !== draft.account
      ) {
        res.status(409).json({
          error:
            "GitHub account changed or is unavailable. Review before publishing.",
        });
        return;
      }
      // Cache both success and failure: a lost acknowledgement must not create a
      // second issue. No automatic retries after an uncertain GitHub response.
      draft.submission ??= github.createBugReport(draft.title, draft.body);
      res.json({ url: await draft.submission });
    } catch {
      res.status(502).json({
        error:
          "GitHub submission could not be confirmed. Check existing issues before trying again.",
      });
    }
  });
}
