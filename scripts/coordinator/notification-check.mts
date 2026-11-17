// Controlled bell source for the next headset gate. Only a prepared isolated rig.
import fs from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { PreviewControl } from "../../apps/mac-companion/src/preview-control.js";
const [action, directory, clientId] = process.argv.slice(2);
if (!directory || !["prepare", "open", "bell"].includes(action))
  throw new Error(
    "Usage: notification-check.mts prepare|open|bell <rig-directory> [headset-client-id]",
  );
const run = path.resolve(directory);
const rig = JSON.parse(await fs.readFile(path.join(run, "rig.json"), "utf8"));
if (rig.home !== path.join(run, "home")) throw new Error("Not an isolated rig");
const config = JSON.parse(
  await fs.readFile(path.join(run, "operator.json"), "utf8"),
);
if (config.origin !== `http://127.0.0.1:${rig.port}`)
  throw new Error("Wrong rig endpoint");
const health = (await fetch(config.origin + "/health").then((r) =>
  r.json(),
)) as any;
if (health.hostId !== config.hostId) throw new Error("Wrong rig host");
async function request(route: string, method: string, body: unknown) {
  const response = await fetch(config.origin + route, {
    method,
    headers: {
      Authorization: "Bearer " + config.token,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`Test request failed: ${response.status}`);
  return response.json();
}
const file = path.join(run, "notification-session.json");
let saved = await fs
  .readFile(file, "utf8")
  .then(JSON.parse)
  .catch((error) => {
    if (error.code !== "ENOENT") throw error;
    return undefined;
  });
if (action === "prepare") {
  if (!saved) {
    saved = { sessionId: randomUUID() };
    // Record intent before the POST so retry cannot create another PTY.
    await fs.writeFile(file, JSON.stringify(saved), { mode: 0o600 });
  }
  await request("/api/workspaces/coordinator-fixture/sessions", "POST", {
    sessionId: saved.sessionId,
    profile: null,
  });
  await request(`/api/sessions/${saved.sessionId}`, "PATCH", {
    name: "Notification check",
  });
  console.log("Prepared isolated Notification check terminal");
} else {
  if (!saved) throw new Error("Prepare the notification terminal first");
  if (action === "open") {
    if (!clientId) throw new Error("Explicit headset client ID required");
    await new PreviewControl({ ...config, clientId }).showTerminal(
      saved.sessionId,
    );
    console.log("Requested Notification check on the selected headset");
  } else {
    await request(`/api/sessions/${saved.sessionId}/input`, "POST", {
      commandId: randomUUID(),
      text: "printf '\\a'",
      sendReturn: true,
    });
    console.log("Sent one bell to the isolated test terminal");
  }
}
