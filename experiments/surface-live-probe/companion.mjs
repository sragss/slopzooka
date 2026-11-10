import { spawn } from "node:child_process";
import { readFile, writeFile, appendFile, mkdir } from "node:fs/promises";
import { createServer } from "node:net";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { networkInterfaces } from "node:os";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const manifestPath = resolve(process.argv[2] ?? "");
const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
if (!manifest.surfaces?.length)
  throw new Error("Pass the live simulator surfaces.json path");
const run = dirname(manifestPath),
  home = join(run, "companion-home");
await mkdir(home, { recursive: true, mode: 0o700 });
const reservation = createServer();
await new Promise((r) => reservation.listen(0, "127.0.0.1", r));
const port = reservation.address().port;
await new Promise((r) => reservation.close(r));
let output = "",
  code,
  exit,
  stopRequested = false;
const finished = new Promise((r) => {
  process.once("SIGINT", () => {
    stopRequested = true;
    r();
  });
  process.once("SIGTERM", () => {
    stopRequested = true;
    r();
  });
});
const child = spawn(
  process.execPath,
  [
    "--import",
    join(root, "apps/mac-companion/node_modules/tsx/dist/loader.mjs"),
    join(root, "apps/mac-companion/src/server.ts"),
  ],
  {
    cwd: root,
    env: {
      ...process.env,
      SLOPZOOKA_HOME: home,
      SLOPZOOKA_PORT: String(port),
      SLOPZOOKA_HOST: "0.0.0.0",
      SLOPZOOKA_PORTLESS: "0",
      SLOPZOOKA_DESKTOP: "1",
      SLOPZOOKA_SURFACE_PROBE_MANIFEST: manifestPath,
    },
    stdio: ["pipe", "pipe", "pipe"],
  },
);
exit = new Promise((r) => {
  child.once("exit", r);
  child.once("error", r);
});
child.stdout.on("data", (data) => {
  output = (output + data).slice(-100000);
  code = /SlopZooka pairing code: (\d{6})/.exec(output)?.[1] ?? code;
  void appendFile(join(run, "companion.log"), data);
});
child.stderr.on(
  "data",
  (data) => void appendFile(join(run, "companion.log"), data),
);
const base = `http://127.0.0.1:${port}`,
  pause = (ms) => new Promise((r) => setTimeout(r, ms));
try {
  let ready = false;
  for (let i = 0; i < 100 && !stopRequested; i++) {
    try {
      if (code && (await fetch(base + "/health")).ok) {
        ready = true;
        break;
      }
    } catch {}
    if (child.exitCode !== null) break;
    await pause(100);
  }
  if (!ready)
    throw new Error("Isolated companion not ready; see companion.log");
  const response = await fetch(base + "/api/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code }),
  });
  if (!response.ok) throw new Error("Local test pairing failed");
  const paired = await response.json();
  const configPath = join(run, "companion-connection.json");
  await writeFile(
    configPath,
    JSON.stringify({
      base,
      token: paired.token,
      hostID: paired.hostId,
      home,
      port,
    }),
    { mode: 0o600 },
  );
  await writeFile(
    join(run, "agent-config.json"),
    JSON.stringify({
      kind: "simulator",
      connection: join(run, "viewer-connection.json"),
      companion: configPath,
      surfaceID: manifest.surfaces[0].id,
    }),
    { mode: 0o600 },
  );
  const host = (networkInterfaces().en0 ?? []).find(
    (a) => a.family === "IPv4",
  )?.address;
  await writeFile(
    join(run, "headset-setup.json"),
    JSON.stringify({
      address: `${host ?? "MAC_LAN_ADDRESS"}:${port}`,
      pairingCode: code,
      at: new Date().toISOString(),
    }),
    { mode: 0o600 },
  );
  console.log(
    JSON.stringify({
      kind: "gateway-ready",
      run,
      headsetSetup: join(run, "headset-setup.json"),
      agentConfig: join(run, "agent-config.json"),
      note: "Open the real SlopZooka app, connect to this isolated companion. The model can then request presentation.",
    }),
  );
  await finished;
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  if (child.exitCode === null) {
    const requestId = randomUUID();
    child.stdin.write(
      JSON.stringify({ type: "stop-session-service", requestId }) + "\n",
    );
    for (
      let i = 0;
      i < 70 && !output.includes(`SLZ_SERVICE {\"requestId\":\"${requestId}\"`);
      i++
    )
      await pause(100);
    child.stdin.end();
    await Promise.race([exit, pause(3000)]);
    if (child.exitCode === null) child.kill("SIGTERM");
  }
}
