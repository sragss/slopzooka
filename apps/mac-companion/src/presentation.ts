import type { PresentationAvailability } from "../../../packages/protocol/src/index.js";
import type { IncomingMessage } from "node:http";
import type { Frontend } from "./frontends.js";
import { connectionMethod } from "./companion-transport.js";

/** Canonical result for the destination connection. Catalog and open enforcement
 * use this same resolver; future MCP callers must supply the destination route. */
export function webPresentation(
  req: IncomingMessage,
  frontend: Frontend,
): PresentationAvailability {
  if (frontend.status === "stopped")
    return {
      presentation: "web" as const,
      available: false,
      reasonCode: "source_stopped",
      message: "Start this app on your Mac first.",
      alternatives: [],
    };
  if (connectionMethod(req) === "direct")
    return {
      presentation: "web" as const,
      available: false,
      reasonCode: "presentation_unsupported_on_route",
      message:
        "Web previews are not supported on Direct to Mac yet. Choose Local Network in Settings.",
      alternatives: [],
    };
  return { presentation: "web" as const, available: true, alternatives: [] };
}
