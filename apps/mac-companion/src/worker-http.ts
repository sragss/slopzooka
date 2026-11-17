import type { Express } from "express";
import * as z from "zod/v4";
import type { CodexWorkers, WorkerLaunch } from "./codex-workers.js";
const id = z
  .string()
  .min(1)
  .max(128)
  .regex(/^[a-zA-Z0-9_-]+$/);
const absolute = z.string().startsWith("/").max(4096);
const launch = z.object({
  nativeControl: z.boolean().optional(),
  session: z.object({
    id,
    workspaceId: id,
    cwd: absolute,
    profile: z.literal("codex"),
    environment: z.record(z.string(), z.string()),
  }),
  clientId: z.uuid(),
  executable: absolute,
  model: z.string().max(100).optional(),
  task: z.string().min(1).max(32000),
  previewConfig: absolute,
  previewCommand: absolute,
  previewArgs: z.array(z.string()).max(8),
});
export function installWorkerRoutes(app: Express, workers: CodexWorkers) {
  app.get("/workers", async (req, res) =>
    res.json({
      workers: await workers.list(z.uuid().parse(req.query.clientId)),
    }),
  );
  app.post("/workers", async (req, res) =>
    res.json(await workers.start(launch.parse(req.body) as WorkerLaunch)),
  );
  app.post("/workers/:id/submit", async (req, res) =>
    res.json(
      await workers.submit(
        id.parse(req.params.id),
        z
          .object({
            requestId: id,
            text: z.string().min(1).max(32000),
            mode: z.enum(["queue", "steer"]),
            expectedTurnId: z.string().max(128).optional(),
          })
          .parse(req.body),
      ),
    ),
  );
  app.post("/workers/:id/stop", async (req, res) =>
    res.json(
      await workers.stop(
        id.parse(req.params.id),
        z
          .object({ requestIds: z.array(id).max(128).optional() })
          .parse(req.body).requestIds,
      ),
    ),
  );
  app.post("/workers/:id/answer", async (req, res) => {
    const answer = z
      .object({ questionId: z.string().max(128), accept: z.boolean() })
      .parse(req.body);
    res.json(
      await workers.answer(
        id.parse(req.params.id),
        answer.questionId,
        answer.accept,
      ),
    );
  });
}
