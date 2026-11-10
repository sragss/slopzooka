import fs from "node:fs/promises";
import { randomUUID } from "node:crypto";
import type { Express } from "express";
import {
  probeID,
  probeSurface,
  type ProbeCommand,
  type ProbeSurface,
} from "../../../packages/protocol/src/surface-probe.js";
import { ServiceError } from "./errors.js";

type Result = { id: string; error?: string };
type Client = {
  receiverID: string;
  seen: number;
  available: boolean;
  presence: unknown;
};
type Pending = ProbeCommand & {
  clientID: string;
  receiverID: string;
  created: number;
  state: "pending" | "acknowledged" | "failed";
  error?: string;
};

// Only ephemeral command delivery. WindowGateway and WindowLayoutStore remain
// the sole intent/persistence owners. Restart deliberately loses this test queue.
export class SurfaceProbeCommands {
  readonly instanceID = randomUUID();
  readonly clients = new Map<string, Client>();
  readonly commands = new Map<string, Pending>();
  constructor(private now = () => Date.now()) {}
  poll(
    clientID: string,
    receiverID: string,
    available: boolean,
    results: Result[],
    presence: unknown,
  ) {
    if (!probeID(clientID) || !probeID(receiverID) || results.length > 256)
      throw new ServiceError("Invalid receiver", 400);
    if (!this.clients.has(clientID) && this.clients.size >= 16)
      throw new ServiceError("Probe client limit", 409);
    this.clients.set(clientID, {
      receiverID,
      seen: this.now(),
      available,
      presence,
    });
    for (const c of this.commands.values()) {
      if (c.state !== "pending") continue;
      if (
        this.now() - c.created > 30000 ||
        (c.clientID === clientID && c.receiverID !== receiverID)
      ) {
        c.state = "failed";
        c.error =
          "Receiver replaced or delivery expired; inspect state before issuing a fresh request";
      }
    }
    for (const result of results) {
      const c = this.commands.get(result.id);
      if (
        c?.clientID === clientID &&
        c.receiverID === receiverID &&
        c.state === "pending"
      ) {
        c.state = result.error ? "failed" : "acknowledged";
        c.error = result.error?.slice(0, 500);
      }
    }
    return {
      instanceID: this.instanceID,
      commands: available
        ? [...this.commands.values()]
            .filter(
              (c) =>
                c.clientID === clientID &&
                c.receiverID === receiverID &&
                c.state === "pending",
            )
            .map(({ id, action, surfaceID }) => ({ id, action, surfaceID }))
        : [],
    };
  }
  submit(clientID: string, command: ProbeCommand) {
    if (
      !probeID(command.id) ||
      !probeID(command.surfaceID) ||
      !["open", "close", "reload"].includes(command.action)
    )
      throw new ServiceError("Invalid probe command", 400);
    const old = this.commands.get(command.id);
    if (old) {
      if (
        old.clientID !== clientID ||
        old.surfaceID !== command.surfaceID ||
        old.action !== command.action
      )
        throw new ServiceError("Command ID reused with different intent", 409);
      return old;
    }
    const client = this.clients.get(clientID);
    if (!client?.available || this.now() - client.seen > 8000)
      throw new ServiceError(
        "No active paired Vision presenter; open the app first",
        409,
      );
    if (this.commands.size >= 256)
      throw new ServiceError(
        "Probe command budget reached; restart the isolated run",
        409,
      );
    const row: Pending = {
      ...command,
      clientID,
      receiverID: client.receiverID,
      created: this.now(),
      state: "pending",
    };
    this.commands.set(command.id, row);
    return row;
  }
}

// Installed only with an explicit local manifest, after normal pairing middleware.
export function installSurfaceProbe(app: Express, manifestPath: string) {
  const commands = new SurfaceProbeCommands();
  async function surfaces(): Promise<ProbeSurface[]> {
    const file = await fs.readFile(manifestPath, "utf8");
    if (file.length > 65536) throw new Error("Probe manifest too large");
    const value = JSON.parse(file);
    if (
      value.version !== 1 ||
      !Array.isArray(value.surfaces) ||
      value.surfaces.length > 8
    )
      throw new Error("Invalid probe manifest");
    return value.surfaces.map(probeSurface);
  }
  app.get("/api/surface-probe", async (_req, res) => {
    try {
      res.json({
        instanceID: commands.instanceID,
        surfaces: (await surfaces()).map(({ stream, ...s }) => s),
        clients: [...commands.clients].map(([id, c]) => ({ id, ...c })),
        commands: [...commands.commands.values()],
      });
    } catch (e) {
      res.status(500).json({ error: (e as Error).message });
    }
  });
  app.post("/api/surface-probe/poll", (req, res) => {
    try {
      if (
        typeof req.body?.available !== "boolean" ||
        !Array.isArray(req.body?.results) ||
        req.body.results.some(
          (r: Result) =>
            !r ||
            !probeID(r.id) ||
            (r.error !== undefined && typeof r.error !== "string"),
        )
      )
        throw new ServiceError("Invalid poll", 400);
      res.json(
        commands.poll(
          req.header("X-SlopZooka-Client-ID") ?? "",
          req.body.receiverID,
          req.body.available,
          req.body.results,
          req.body.presence,
        ),
      );
    } catch (e) {
      res
        .status(e instanceof ServiceError ? e.statusCode : 400)
        .json({ error: (e as Error).message });
    }
  });
  app.post("/api/surface-probe/commands", async (req, res) => {
    try {
      if (!(await surfaces()).some((s) => s.id === req.body?.surfaceID))
        throw new ServiceError("Unknown probe surface", 404);
      res.json(
        commands.submit(req.body.clientID, {
          id: req.body.id,
          action: req.body.action,
          surfaceID: req.body.surfaceID,
        }),
      );
    } catch (e) {
      res
        .status(e instanceof ServiceError ? e.statusCode : 400)
        .json({ error: (e as Error).message });
    }
  });
  app.post("/api/surface-probe/resolve", async (req, res) => {
    try {
      const surface = (await surfaces()).find((s) => s.id === req.body?.id);
      if (!surface)
        throw new ServiceError(
          "Probe surface unavailable; prepare it again",
          404,
        );
      res.json(surface);
    } catch (e) {
      res
        .status(e instanceof ServiceError ? e.statusCode : 400)
        .json({ error: (e as Error).message });
    }
  });
}
