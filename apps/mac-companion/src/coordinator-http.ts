import type { Express, Request } from "express";
import * as z from "zod/v4";
import { Coordinator, coordinatorRequest } from "./coordinator.js";
import { ServiceError } from "./errors.js";
export function installCoordinatorRoutes(
  app: Express,
  coordinator: Coordinator,
  hostId: string,
  origin: string,
) {
  const client = (req: Request) =>
    z.uuid().parse(req.header("X-SlopZooka-Client-ID")).toLowerCase();
  app.get("/api/coordinator", async (req, res) =>
    res.json(await coordinator.status(client(req))),
  );
  app.post("/api/coordinator", async (req, res) => {
    const token = req.header("Authorization")?.match(/^Bearer (.+)$/)?.[1];
    if (!token)
      throw new ServiceError(
        "Coordinator requires the paired native client credential",
        401,
      );
    res.json(
      await coordinator.submit(
        { hostId, origin, clientId: client(req), token },
        coordinatorRequest.parse(req.body),
        z
          .array(z.string().max(256))
          .max(24)
          .optional()
          .parse(req.body?.launcherNames),
      ),
    );
  });
  app.post(
    ["/api/coordinator/stop", "/api/coordinator/stop-coordinator"],
    async (req, res) =>
      res.json(
        await coordinator.stop(
          client(req),
          z.object({ requestId: z.uuid() }).parse(req.body).requestId,
        ),
      ),
  );
  app.post("/api/coordinator/stop-agent", async (req, res) =>
    res.json(
      await coordinator.stopAgent(
        client(req),
        z.object({ requestId: z.uuid() }).parse(req.body).requestId,
      ),
    ),
  );
  app.post("/api/coordinator/answer", async (req, res) => {
    const answer = z
      .object({
        sessionId: z.string().min(1).max(128),
        questionId: z.string().min(1).max(128),
        accept: z.boolean(),
      })
      .parse(req.body);
    await coordinator.answer(
      client(req),
      answer.sessionId,
      answer.questionId,
      answer.accept,
    );
    res.json(await coordinator.status(client(req)));
  });
}
