import { randomUUID } from "node:crypto";
import path from "node:path";
import fs from "node:fs/promises";
import * as z from "zod/v4";
import { logContext, type Logger } from "./logger.js";
import {
  DIAGNOSTICS_VERSION,
  type LogEvent,
} from "../../../packages/protocol/src/diagnostics.js";
import { ServiceError } from "./errors.js";
import type { WindowLayout, WindowRecord } from "./window-layout.js";

const identifier = z.string().min(1).max(512);
export const previewName = z
  .string()
  .trim()
  .min(1)
  .max(120)
  .refine(
    (value) =>
      !Array.from(value).some((character) => character.charCodeAt(0) < 32),
    "Names cannot contain control characters",
  );
const configSchema = z.object({
  origin: z.url(),
  hostId: z.uuid(),
  clientId: z.uuid(),
  token: z.string().min(1),
  ownerSessionId: identifier.optional(),
});
export type PreviewControlConfig = z.infer<typeof configSchema>;
const layoutSchema = z.object({
  version: z.literal(1),
  revision: z.number().int().nonnegative(),
  windows: z
    .array(
      z.object({
        id: identifier,
        kind: z.enum(["terminal", "preview"]),
        targetID: identifier,
        name: previewName.optional(),
        ownerSessionIds: z.array(identifier).optional(),
      }),
    )
    .max(128),
});
const catalogSchema = z.object({
  windows: z
    .object({
      state: z.enum(["ready", "permissionRequired", "locked", "failed"]),
      message: z.string().optional(),
      sources: z.array(
        z.object({
          id: identifier,
          title: z.string(),
          application: z.string(),
          contentWidth: z.number(),
          contentHeight: z.number(),
        }),
      ),
    })
    .optional(),
});

/** Publish complete credentials even if two launches from the same client overlap. */
export async function writePreviewConfig(
  file: string,
  config: PreviewControlConfig,
): Promise<void> {
  await fs.mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = file + "." + randomUUID();
  try {
    await fs.writeFile(temporary, JSON.stringify(config), {
      mode: 0o600,
      flag: "wx",
    });
    await fs.rename(temporary, file);
  } finally {
    await fs.rm(temporary, { force: true });
  }
}

export async function readPreviewConfig(
  file: string,
): Promise<PreviewControlConfig> {
  const info = await fs.stat(file);
  if (
    !info.isFile() ||
    (info.mode & 0o077) !== 0 ||
    info.uid !== process.getuid?.()
  )
    throw new Error(
      "Preview configuration must be an owner-only file (chmod 600).",
    );
  return configSchema.parse(JSON.parse(await fs.readFile(file, "utf8")));
}

// Compare only the requested effects. An unrelated rename, a new co-owner,
// or a different window changing while the response was lost is independent.
function matchesIntent(
  expected: WindowRecord | undefined,
  actual: WindowRecord | undefined,
  name?: string,
  owner?: string,
): boolean {
  if (!expected || !actual) return expected === actual;
  return (
    actual.kind === expected.kind &&
    actual.targetID === expected.targetID &&
    (name === undefined || actual.name === name) &&
    (owner === undefined || actual.ownerSessionIds?.includes(owner) === true)
  );
}

/** Stateless intent adapter. Layout persistence and lifecycle remain with their existing owners. */
export class PreviewControl {
  private readonly config: PreviewControlConfig;
  constructor(
    config: PreviewControlConfig,
    private readonly logger?: Logger,
  ) {
    this.config = configSchema.parse(config);
    const origin = new URL(config.origin);
    if (
      origin.protocol !== "http:" ||
      !["127.0.0.1", "[::1]"].includes(origin.hostname) ||
      origin.username ||
      origin.password ||
      origin.pathname !== "/" ||
      origin.search ||
      origin.hash
    )
      throw new Error(
        "Preview control requires an explicit local companion HTTP origin.",
      );
    this.config.origin = origin.origin;
  }

  private async request(
    path: string,
    method = "GET",
    body?: unknown,
    authenticated = true,
    timeoutMs = 10_000,
  ): Promise<unknown> {
    const response = await fetch(this.config.origin + path, {
      method,
      redirect: "error",
      signal: AbortSignal.timeout(timeoutMs),
      headers: {
        "X-SlopZooka-Action-ID": String(
          logContext.current().actionId ?? randomUUID(),
        ),
        ...(authenticated
          ? {
              "X-SlopZooka-Host-ID": this.config.hostId,
              Authorization: `Bearer ${this.config.token}`,
              "X-SlopZooka-Client-ID": this.config.clientId,
              "Content-Type": "application/json",
            }
          : {}),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    if (!response.ok) {
      await response.body?.cancel();
      // Do not relay arbitrary server responses, credentials or URLs to the model.
      throw new ServiceError(
        `Companion request failed (HTTP ${response.status}).`,
        response.status,
      );
    }
    return response.json();
  }
  private async verifyHost(timeoutMs?: number): Promise<void> {
    const health = z
      .object({ hostId: z.string() })
      .parse(await this.request("/health", "GET", undefined, false, timeoutMs));
    if (health.hostId !== this.config.hostId)
      throw new ServiceError(
        "Companion identity changed; reconnect the preview configuration before continuing.",
        409,
      );
  }
  // MCP processes share the companion's bounded diagnostics intake and file writer.
  async sendDiagnostic(event: LogEvent): Promise<void> {
    await this.verifyHost(750);
    await this.request(
      "/api/diagnostics/events",
      "POST",
      { version: DIAGNOSTICS_VERSION, events: [event] },
      true,
      750,
    );
  }
  private async catalog() {
    return catalogSchema.parse(await this.request("/api/frontends")).windows;
  }
  private async layout(): Promise<WindowLayout> {
    return layoutSchema.parse(await this.request("/api/window-layout"));
  }
  private async headsetAvailable(): Promise<boolean> {
    return z
      .object({ available: z.boolean() })
      .parse(await this.request("/api/window-layout/availability")).available;
  }
  async list() {
    await this.verifyHost();
    const fields = {
      hostId: this.config.hostId,
      clientId: this.config.clientId,
      sessionId: this.config.ownerSessionId,
    };
    if (!(await this.headsetAvailable())) {
      this.logger?.info("preview.list.completed", {
        ...fields,
        state: "not_available",
      });
      return {
        host_id: this.config.hostId,
        client_id: this.config.clientId,
        headset_available: false,
        state: "not_available",
        message:
          "Headset preview is not available right now. Open SlopZooka on your headset and try again when connected.",
        sources: [],
        previews: [],
      };
    }
    const [catalog, layout] = await Promise.all([
      this.catalog(),
      this.layout(),
    ]);
    this.logger?.info("preview.list.completed", {
      ...fields,
      state: catalog?.state ?? "disabled",
      sourceCount: catalog?.sources.length ?? 0,
    });
    return {
      host_id: this.config.hostId,
      client_id: this.config.clientId,
      headset_available: true,
      state: catalog?.state ?? "disabled",
      message: catalog?.message,
      sources: catalog?.sources ?? [],
      previews: layout.windows.filter((record) => this.native(record)),
    };
  }
  async showTerminal(sessionId: string) {
    await this.verifyHost();
    const sessions = z
      .object({ sessions: z.array(z.object({ id: z.string() })) })
      .parse(await this.request("/api/sessions"));
    if (!sessions.sessions.some((session) => session.id === sessionId))
      throw new ServiceError("Terminal is unavailable", 404);
    return this.mutate("show_terminal", (layout) => {
      const record = layout.windows.find((window) => window.id === sessionId);
      if (
        record &&
        (record.kind !== "terminal" || record.targetID !== sessionId)
      )
        throw new ServiceError("Window identity conflict", 409);
      if (!record)
        layout.windows.push({
          id: sessionId,
          kind: "terminal",
          targetID: sessionId,
        });
      return sessionId;
    });
  }
  private native(record: WindowRecord): boolean {
    return record.kind === "preview" && record.targetID.startsWith("window:");
  }
  async open(sourceId: string, name?: string) {
    await this.verifyHost();
    const catalog = await this.catalog();
    if (catalog?.state !== "ready")
      throw new ServiceError(
        `Mac capture is ${catalog?.state ?? "disabled"}. Check preview_list and resolve capture availability first.`,
        409,
      );
    if (
      !sourceId.startsWith("window:") ||
      !catalog.sources.some((source) => source.id === sourceId)
    )
      throw new ServiceError(
        "Source is unavailable. Refresh preview_list before opening it.",
        404,
      );
    const label = name === undefined ? undefined : previewName.parse(name);
    return this.mutate(
      "open",
      (layout) => {
        const existing = layout.windows.find(
          (record) => this.native(record) && record.targetID === sourceId,
        );
        const id = existing?.id ?? `${this.config.hostId}:${sourceId}`;
        const record: WindowRecord = {
          ...(existing ?? { id, kind: "preview", targetID: sourceId }),
          ...(this.config.ownerSessionId &&
          (!existing || existing.ownerSessionIds)
            ? {
                ownerSessionIds: [
                  ...new Set([
                    ...(existing?.ownerSessionIds ?? []),
                    this.config.ownerSessionId,
                  ]),
                ],
              }
            : {}),
          ...(label === undefined ? {} : { name: label }),
        };
        if (!existing && layout.windows.some((window) => window.id === id))
          throw new ServiceError(
            "Preview ID conflicts with another window.",
            409,
          );
        layout.windows = existing
          ? layout.windows.map((window) => (window.id === id ? record : window))
          : [...layout.windows, record];
        return id;
      },
      label,
    );
  }
  async rename(id: string, name: string) {
    await this.verifyHost();
    const label = previewName.parse(name);
    return this.mutate(
      "rename",
      (layout) => {
        const record = layout.windows.find(
          (window) => window.id === id && this.native(window),
        );
        if (!record)
          throw new ServiceError(
            "Native preview is not open on this headset.",
            404,
          );
        record.name = label;
        return id;
      },
      label,
    );
  }
  async close(id: string) {
    await this.verifyHost();
    return this.mutate("close", (layout) => {
      const record = layout.windows.find((window) => window.id === id);
      if (record && !this.native(record))
        throw new ServiceError("This tool only closes native previews.", 400);
      layout.windows = layout.windows.filter((window) => window.id !== id);
      return id;
    });
  }
  private async mutate(
    operation: "show_terminal" | "open" | "rename" | "close",
    apply: (layout: WindowLayout) => string,
    requestedName?: string,
  ) {
    const fields = {
      operation,
      hostId: this.config.hostId,
      clientId: this.config.clientId,
      sessionId: this.config.ownerSessionId,
    };
    const started = performance.now();
    for (let attempt = 1; attempt <= 4; attempt++) {
      const layout = await this.layout();
      const id = apply(layout);
      const expected = layout.windows.find((w) => w.id === id);
      if (!(await this.headsetAvailable())) {
        this.logger?.warn("preview.write.rejected", {
          ...fields,
          attempt,
          reason: "headset_unavailable",
        });
        throw new ServiceError(
          "Headset preview is not available right now. No preview change was saved. Open SlopZooka on your headset and try again when connected.",
          503,
        );
      }
      let saved: WindowLayout;
      let confirmation: "write_reply" | "layout_readback" = "write_reply";
      try {
        saved = layoutSchema.parse(
          await this.request("/api/window-layout", "PUT", layout),
        );
      } catch (error) {
        if (
          error instanceof ServiceError &&
          error.statusCode < 500 &&
          error.statusCode !== 408
        ) {
          if (error.statusCode === 409 && attempt < 4) continue;
          this.logger?.warn("preview.write.rejected", {
            ...fields,
            attempt,
            status: error.statusCode,
          });
          throw error;
        }
        // The PUT may have committed. Revalidate identity before a single read;
        // another user's concurrent changes are independent of this intent.
        let observed: WindowLayout | undefined;
        try {
          await this.verifyHost();
          observed = await this.layout();
        } catch {
          /* Unreachable or replaced companion. Keep the outcome uncertain. */
        }
        const actual = observed?.windows.find((w) => w.id === id);
        const requiredOwner =
          operation === "open" &&
          expected?.ownerSessionIds?.includes(this.config.ownerSessionId ?? "")
            ? this.config.ownerSessionId
            : undefined;
        if (
          !observed ||
          observed.revision < layout.revision ||
          !matchesIntent(expected, actual, requestedName, requiredOwner)
        ) {
          this.logger?.warn("preview.write.uncertain", {
            ...fields,
            attempt,
            durationMs: performance.now() - started,
            reason: observed ? "state_mismatch" : "readback_unavailable",
            baseRevision: layout.revision,
            observedRevision: observed?.revision,
          });
          throw new ServiceError(
            "Couldn’t confirm whether the preview change was saved. Check preview_list before taking any further action.",
            503,
          );
        }
        saved = observed;
        confirmation = "layout_readback";
      }
      const desiredOpen = saved.windows.some((w) => w.id === id);
      if (expected && !desiredOpen) {
        this.logger?.warn("preview.write.rejected", {
          ...fields,
          attempt,
          reason: "owner_ended",
        });
        throw new ServiceError(
          "The owning terminal has ended. The preview was not opened.",
          410,
        );
      }
      this.logger?.info("preview.write.confirmed", {
        ...fields,
        attempt,
        confirmation,
        revision: saved.revision,
        durationMs: performance.now() - started,
      });
      return {
        preview_id: id,
        revision: saved.revision,
        desired_open: desiredOpen,
        status: "desired_state_acknowledged",
        confirmation,
        visibility: "not_observed",
      };
    }
    throw new Error("Unreachable layout retry state");
  }
}
