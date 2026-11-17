// Start/check/stop only this explicitly selected test rig. No headset installation here.
import fs from "node:fs/promises";
import path from "node:path";
import net from "node:net";
import { spawn } from "node:child_process";
import { SessionServiceClient } from "../../apps/mac-companion/src/session-service-client.js";
const [action, directory] = process.argv.slice(2);
if (!directory || !["start", "check", "stop"].includes(action))
  throw new Error("Usage: rig.mts start|check|stop <prepared-rig-directory>");
const run = path.resolve(directory),
  rig = JSON.parse(await fs.readFile(path.join(run, "rig.json"), "utf8"));
if (rig.home !== path.join(run, "home")) throw new Error("Rig home mismatch");
const origin = `http://127.0.0.1:${rig.port}`;
const pidFile = path.join(run, "processes.json");
if (action === "start") {
  // Fail rather than attach to an unrelated companion occupying this port.
  const listener = net.createServer();
  await new Promise<void>((resolve, reject) => {
    listener.once("error", reject);
    listener.listen(rig.port, "0.0.0.0", resolve);
  });
  await new Promise<void>((resolve) => listener.close(() => resolve()));
  const log = await fs.open(path.join(run, "console.log"), "a", 0o600);
  const child = spawn(
    path.join(rig.companion, "Contents/Resources/runtime/node"),
    [path.join(rig.companion, "Contents/Resources/host/src/server.mjs")],
    {
      cwd: run,
      detached: true,
      stdio: ["ignore", log.fd, log.fd],
      env: {
        ...process.env,
        SLOPZOOKA_HOME: rig.home,
        SLOPZOOKA_PORT: String(rig.port),
        SLOPZOOKA_HOST: "0.0.0.0",
        SLOPZOOKA_PORTLESS: "0",
        SLOPZOOKA_DIRECT: "1",
        SLOPZOOKA_WINDOW_PREVIEWS: "1",
        SLOPZOOKA_BONJOUR_NAME: "Slz Coordinator Test",
        SLOPZOOKA_COORDINATOR_CONFIG: rig.config,
      },
    },
  );
  await new Promise<void>((resolve, reject) => {
    child.once("spawn", resolve);
    child.once("error", reject);
  });
  child.unref();
  await log.close();
  await fs.writeFile(pidFile, JSON.stringify({ companion: child.pid }), {
    mode: 0o600,
  });
  console.log("Started isolated companion", child.pid, "on", rig.port);
} else if (action === "stop") {
  const stored = JSON.parse(
    await fs.readFile(path.join(rig.home, "pairing.json"), "utf8"),
  );
  const health = (await fetch(origin + "/health")
    .then((r) => r.json())
    .catch(() => undefined)) as any;
  if (health && health.hostId !== stored.hostId)
    throw new Error("Port belongs to another host; refusing cleanup");
  const service = await SessionServiceClient.forHome(rig.home);
  // Shutdown via authenticated private session-service socket, never a production PID.
  await service.stop().catch(() => {});
  const pids = JSON.parse(await fs.readFile(pidFile, "utf8"));
  const { execFileSync } = await import("node:child_process");
  const command = execFileSync(
    "ps",
    ["-p", String(pids.companion), "-o", "command="],
    { encoding: "utf8" },
  ).trim();
  if (
    !command.startsWith(
      path.join(rig.companion, "Contents/Resources/runtime/node") + " ",
    )
  )
    throw new Error("Companion PID changed; refusing signal");
  process.kill(pids.companion, "SIGTERM");
  console.log("Stopped isolated rig; source fixture may be closed separately.");
} else {
  const health = (await fetch(origin + "/health").then((r) => r.json())) as any;
  const stored = JSON.parse(
    await fs.readFile(path.join(rig.home, "pairing.json"), "utf8"),
  );
  if (health.hostId !== stored.hostId)
    throw new Error("Unexpected host identity");
  const code = (
    await fs.readFile(path.join(run, "console.log"), "utf8")
  ).matchAll(/pairing code: (\d{6})/g);
  console.log(
    JSON.stringify({
      hostId: health.hostId,
      port: rig.port,
      code: [...code].at(-1)?.[1],
      companion: "Slz Coordinator Test",
    }),
  );
}
