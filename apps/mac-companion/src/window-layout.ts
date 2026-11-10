import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import type { Express, Request } from "express";
import { ServiceError } from "./errors.js";

// This is desired UI, not process ownership or a list of connected viewers.
// URLs, credentials, focus, and physical geometry never belong in this store.
export type WindowRecord = {
  id: string;
  kind: "terminal" | "preview";
  targetID: string;
};
export type WindowLayout = {
  version: 1;
  revision: number;
  windows: WindowRecord[];
};
type Store = { version: 1; clients: Record<string, WindowLayout> };
const empty = (): WindowLayout => ({ version: 1, revision: 0, windows: [] });
const validRevision = (value: unknown): value is number =>
  Number.isSafeInteger(value) && Number(value) >= 0;
const validClient = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);

function windows(value: unknown): WindowRecord[] {
  const text = (v: unknown): v is string =>
    typeof v === "string" &&
    v.length > 0 &&
    v.length <= 512 &&
    // eslint-disable-next-line no-control-regex -- Reject C0 control characters in window identifiers.
    !/[\x00-\x1f]/.test(v);
  if (!Array.isArray(value) || value.length > 128)
    throw new ServiceError("Expected at most 128 window records", 400);
  const ids = new Set<string>();
  return value.map((record) => {
    if (
      !record ||
      !text(record.id) ||
      !text(record.targetID) ||
      !["terminal", "preview"].includes(record.kind) ||
      ids.has(record.id)
    )
      throw new ServiceError("Invalid or duplicate window record", 400);
    ids.add(record.id);
    return { id: record.id, kind: record.kind, targetID: record.targetID };
  });
}

/** One serialized, atomic persistence boundary for every client window layout. */
export class WindowLayoutStore {
  private tail: Promise<unknown> = Promise.resolve();
  private readonly file: string;
  constructor(home: string) {
    this.file = path.join(home, "window-layouts.json");
  }

  private serialized<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.tail.then(operation, operation);
    this.tail = result.catch(() => undefined);
    return result;
  }
  private async read(): Promise<Store> {
    let data: Store;
    try {
      data = JSON.parse(await fs.readFile(this.file, "utf8"));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT")
        return { version: 1, clients: {} };
      throw error;
    }
    if (
      data?.version !== 1 ||
      !data.clients ||
      typeof data.clients !== "object" ||
      Array.isArray(data.clients)
    )
      throw new Error("Invalid window layout store; restore it before writing");
    for (const [client, layout] of Object.entries(data.clients)) {
      if (
        !validClient(client) ||
        layout?.version !== 1 ||
        !validRevision(layout.revision)
      )
        throw new Error(
          "Invalid window layout store; restore it before writing",
        );
      windows(layout.windows);
    }
    return data;
  }
  get(client: string): Promise<WindowLayout> {
    return this.serialized(
      async () => (await this.read()).clients[client] ?? empty(),
    );
  }
  put(
    client: string,
    revision: unknown,
    records: unknown,
  ): Promise<WindowLayout> {
    return this.serialized(async () => {
      if (!validClient(client) || !validRevision(revision))
        throw new ServiceError(
          "Valid client and layout revision required",
          400,
        );
      const nextWindows = windows(records);
      const store = await this.read();
      const current = store.clients[client] ?? empty();
      if (current.revision !== revision)
        throw new ServiceError(
          "Window layout changed; refresh before saving",
          409,
        );
      if (!store.clients[client] && Object.keys(store.clients).length >= 64)
        throw new ServiceError("Window layout client limit reached", 409);
      if (JSON.stringify(current.windows) === JSON.stringify(nextWindows))
        return current;
      const next: WindowLayout = {
        version: 1,
        revision: revision + 1,
        windows: nextWindows,
      };
      store.clients[client] = next;
      await fs.mkdir(path.dirname(this.file), { recursive: true, mode: 0o700 });
      const temporary = `${this.file}.${crypto.randomUUID()}.tmp`;
      try {
        await fs.writeFile(temporary, JSON.stringify(store), { mode: 0o600 });
        await fs.rename(temporary, this.file);
      } finally {
        await fs.rm(temporary, { force: true });
      }
      return next;
    });
  }
}

// Install after pairing middleware. The client ID partitions layouts; it is not authentication.
export function installWindowLayoutRoutes(
  app: Express,
  store: WindowLayoutStore,
): void {
  function client(req: Request): string {
    const id = req.header("X-SlopZooka-Client-ID");
    if (!validClient(id))
      throw new ServiceError(
        "A stable client ID is required for window layouts",
        400,
      );
    return id.toLowerCase();
  }
  app.get("/api/window-layout", async (req, res) => {
    try {
      res.json(await store.get(client(req)));
    } catch (error) {
      res
        .status(error instanceof ServiceError ? error.statusCode : 500)
        .json({ error: (error as Error).message });
    }
  });
  app.put("/api/window-layout", async (req, res) => {
    try {
      if (req.body?.version !== 1)
        throw new ServiceError("Unsupported window layout version", 400);
      res.json(
        await store.put(client(req), req.body?.revision, req.body?.windows),
      );
    } catch (error) {
      res
        .status(error instanceof ServiceError ? error.statusCode : 500)
        .json({ error: (error as Error).message });
    }
  });
}
