// Operator controls for the prepared test only. No target discovery or model loop.
import { readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { parseArgs } from "node:util";
import { mediaRequest, companionRequest } from "./request.mjs";
const { values } = parseArgs({
  options: {
    config: { type: "string" },
    action: { type: "string" },
    client: { type: "string" },
  },
});
if (
  !values.config ||
  !["status", "open", "close", "reload", "stop", "resume"].includes(
    values.action,
  )
)
  throw new Error(
    "Use --config PRIVATE_AGENT_JSON --action status|open|close|reload|stop|resume [--client ID]",
  );
const c = JSON.parse(await readFile(values.config, "utf8"));
let result;
if (values.action === "stop" || values.action === "resume") {
  if (values.action === "resume" && c.kind === "browser")
    throw new Error("Browser Stop ends the lease; start a fresh owned run");
  result = await mediaRequest(c.connection, {
    slot: c.slot,
    tool: c.kind === "browser" ? "browser_stop" : `surface_${values.action}`,
  });
} else {
  if (!c.companion) throw new Error("Attach the isolated companion first");
  if (values.action === "status")
    result = await companionRequest(c.companion, "/api/surface-probe");
  else {
    if (!values.client)
      throw new Error(
        "Pass the exact active --client from status; do not guess a headset",
      );
    result = await companionRequest(
      c.companion,
      "/api/surface-probe/commands",
      {
        id: randomUUID(),
        clientID: values.client,
        surfaceID: c.surfaceID,
        action: values.action,
      },
    );
  }
}
console.log(JSON.stringify(result, null, 2));
