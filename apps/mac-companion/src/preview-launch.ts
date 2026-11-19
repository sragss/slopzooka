import { writePreviewConfig } from "./preview-control.js";
import path from "node:path";
import type { Request } from "express";
import * as z from "zod/v4";
import { ServiceError } from "./errors.js";
import type { SessionLaunch } from "./session-service-protocol.js";
import type { Logger } from "./logger.js";

// The private file is shared by launches from this pairing. The owner session
// travels separately, so a concurrent resume cannot overwrite another owner.
export function headsetCodexLaunch(options: {
  home: string;
  hostId: string;
  origin: string;
  previewCommand: string;
  previewArgs: string[];
  logger: Logger;
}) {
  return async (
    req: Request,
    sessionId: string,
  ): Promise<SessionLaunch["previewMcp"]> => {
    const header = req.header("X-SlopZooka-Client-ID");
    if (header === undefined) return undefined;
    const client = z.uuid().safeParse(header);
    const token = req.header("Authorization")?.match(/^Bearer (.+)$/)?.[1];
    if (!client.success || !token)
      throw new ServiceError(
        "A paired headset client is required for this preview route.",
        400,
      );
    const clientId = client.data.toLowerCase();
    const file = path.join(
      options.home,
      "preview-routes",
      options.hostId + "-" + clientId + ".json",
    );
    await writePreviewConfig(file, {
      origin: options.origin,
      hostId: options.hostId,
      clientId,
      token,
    });
    options.logger.info("preview.route.requested", {
      hostId: options.hostId,
      clientId,
      sessionId,
    });
    return {
      command: options.previewCommand,
      args: [...options.previewArgs, file, sessionId],
    };
  };
}
