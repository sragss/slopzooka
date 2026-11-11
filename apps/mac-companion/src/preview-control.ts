import fs from "node:fs/promises";
import * as z from "zod/v4";
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

/** Stateless intent adapter. Layout persistence and lifecycle remain with their existing owners. */
export class PreviewControl {
  private readonly config: PreviewControlConfig;
  constructor(config: PreviewControlConfig) {
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
  ): Promise<unknown> {
    const response = await fetch(this.config.origin + path, {
      method,
      redirect: "error",
      signal: AbortSignal.timeout(10_000),
      headers: authenticated
        ? {
            Authorization: `Bearer ${this.config.token}`,
            "X-SlopZooka-Client-ID": this.config.clientId,
            "Content-Type": "application/json",
          }
        : {},
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
  private async verifyHost(): Promise<void> {
    const health = z
      .object({ hostId: z.string() })
      .parse(await this.request("/health", "GET", undefined, false));
    if (health.hostId !== this.config.hostId)
      throw new ServiceError(
        "Companion identity changed; reconnect the preview configuration before continuing.",
        409,
      );
  }
  private async catalog() {
    return catalogSchema.parse(await this.request("/api/frontends")).windows;
  }
  private async layout(): Promise<WindowLayout> {
    return layoutSchema.parse(await this.request("/api/window-layout"));
  }
  async list() {
    await this.verifyHost();
    const [catalog, layout] = await Promise.all([
      this.catalog(),
      this.layout(),
    ]);
    return {
      host_id: this.config.hostId,
      client_id: this.config.clientId,
      state: catalog?.state ?? "disabled",
      message: catalog?.message,
      sources: catalog?.sources ?? [],
      previews: layout.windows.filter((record) => this.native(record)),
    };
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
    return this.mutate((layout) => {
      const existing = layout.windows.find(
        (record) => this.native(record) && record.targetID === sourceId,
      );
      const id = existing?.id ?? `${this.config.hostId}:${sourceId}`;
      const record: WindowRecord = {
        ...(existing ?? { id, kind: "preview", targetID: sourceId }),
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
    });
  }
  async rename(id: string, name: string) {
    await this.verifyHost();
    const label = previewName.parse(name);
    return this.mutate((layout) => {
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
    });
  }
  async close(id: string) {
    await this.verifyHost();
    return this.mutate((layout) => {
      const record = layout.windows.find((window) => window.id === id);
      if (record && !this.native(record))
        throw new ServiceError("This tool only closes native previews.", 400);
      layout.windows = layout.windows.filter((window) => window.id !== id);
      return id;
    });
  }
  private async mutate(apply: (layout: WindowLayout) => string) {
    for (let attempt = 0; attempt < 4; attempt++) {
      const layout = await this.layout();
      const id = apply(layout);
      try {
        const saved = layoutSchema.parse(
          await this.request("/api/window-layout", "PUT", layout),
        );
        return {
          preview_id: id,
          revision: saved.revision,
          desired_open: saved.windows.some((record) => record.id === id),
          status: "desired_state_acknowledged",
          visibility: "not_observed",
        };
      } catch (error) {
        if (
          !(error instanceof ServiceError) ||
          error.statusCode !== 409 ||
          attempt === 3
        )
          throw error;
        // Re-read and apply only this intent, preserving intervening user/agent changes.
      }
    }
    throw new Error("Unreachable layout retry state");
  }
}
