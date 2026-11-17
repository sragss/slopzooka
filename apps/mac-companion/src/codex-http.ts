import { createHash } from "node:crypto";
import { realpath } from "node:fs/promises";
import type { Express } from "express";
import { validId } from "../../../packages/protocol/src/index.js";
import { CodexThreads } from "./codex-threads.js";
import { ServiceError } from "./errors.js";
import type { SessionServiceClient } from "./session-service-client.js";
import type { WorkspaceService } from "./workspace.js";

export function installCodexThreadRoutes(
  app: Express,
  codex: CodexThreads,
  sessions: SessionServiceClient,
  workspaces: WorkspaceService,
): void {
  app.get("/api/codex/threads", async (_req, res, next) => {
    try {
      res.json({ threads: await codex.list() });
    } catch (error) {
      next(error);
    }
  });
  app.post("/api/codex/threads/:threadId/resume", async (req, res, next) => {
    try {
      if (!validId(req.body?.sessionId))
        throw new ServiceError("Valid sessionId required", 400);
      const thread = await codex.read(req.params.threadId!);
      const cwd = await realpath(thread.cwd);
      const workspace = await workspaces.workspaceForDirectory(cwd);
      // Local folders need an identity, not a fabricated Git repository/index entry.
      const workspaceId =
        workspace?.workspaceId ??
        `codex-${createHash("sha256").update(cwd).digest("hex").slice(0, 24)}`;
      const session = await sessions.create({
        id: req.body.sessionId,
        workspaceId,
        cwd,
        profile: "codex",
        codexResume: { threadId: thread.id, title: thread.title },
        environment: Object.fromEntries(
          Object.entries(process.env).filter(
            (entry): entry is [string, string] => entry[1] !== undefined,
          ),
        ),
      });
      const [described] = await workspaces.describeSessions([session]);
      res.status(201).json({ session: described });
    } catch (error) {
      next(error);
    }
  });
}
