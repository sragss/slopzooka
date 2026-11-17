import { execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import fs from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import express from "express";
import { WebSocketServer } from "ws";
import {
  isClientMessage,
  PROTOCOL_VERSION,
} from "../../../packages/protocol/src/index.js";
import { SessionManager, send } from "../src/sessions.js";

const exec = promisify(execFile);
const root = path.resolve(import.meta.dirname, "../../..");
const baselineIndex = process.argv.indexOf("--baseline");
const baseline =
  baselineIndex >= 0 ? process.argv[baselineIndex + 1] : undefined;
if (baselineIndex >= 0 && (!baseline || baseline.startsWith("--")))
  throw new Error("Supply a git revision: --baseline <git-ref>");
const home = await fs.mkdtemp(
  path.join(os.tmpdir(), "slz-notification-probe-"),
);
const interactive = process.argv.includes("--interactive");
const appBundle = path.join(
  root,
  ".build",
  "notification-probe",
  baseline ? "Baseline.app" : "Notifications.app",
);
const executable = path.join(appBundle, "Contents/MacOS/Notifications");
const manager = new SessionManager();
const app = express();
const server = http.createServer(app);
const sockets = new WebSocketServer({ server, path: "/ws" });
let attachments = 0;
try {
  await fs.mkdir(path.dirname(executable), { recursive: true });
  await fs.mkdir(path.join(appBundle, "Contents/Resources"), {
    recursive: true,
  });
  await fs.copyFile(
    path.join(
      root,
      "apps/vision-client/SlopZooka/SlopZooka/terminal-notification.wav",
    ),
    path.join(appBundle, "Contents/Resources/terminal-notification.wav"),
  );
  await fs.writeFile(
    path.join(appBundle, "Contents/Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Notifications</string><key>CFBundleIdentifier</key><string>dev.slopzooka.notification-probe${baseline ? ".baseline" : ""}</string><key>CFBundleName</key><string>Notifications</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>`,
  );
  let controller = path.join(
    root,
    "apps/vision-client/SlopZooka/SlopZooka/CompanionWebView.swift",
  );
  let browser = path.join(root, "apps/mac-companion/public/terminal.js");
  if (baseline) {
    const originalController = await exec(
      "git",
      [
        "show",
        `${baseline}:apps/vision-client/SlopZooka/SlopZooka/CompanionWebView.swift`,
      ],
      { cwd: root },
    );
    controller = path.join(home, "CompanionWebView.swift");
    await fs.writeFile(controller, originalController.stdout);
    const originalBrowser = await exec(
      "git",
      ["show", `${baseline}:apps/mac-companion/public/terminal.js`],
      { cwd: root, maxBuffer: 2 * 1024 * 1024 },
    );
    browser = path.join(home, "terminal.js");
    await fs.writeFile(browser, originalBrowser.stdout);
  }
  await exec(
    "xcrun",
    [
      "swiftc",
      "-swift-version",
      "5",
      "-parse-as-library",
      ...["Diagnostics", "NativeLogFile"].map((name) =>
        path.join(root, `apps/shared/${name}.swift`),
      ),
      ...[
        "CompanionModels",
        "CompanionTransport",
        "TerminalNavigation",
        "TerminalZoom",
        "TerminalNotifications",
      ].map((name) =>
        path.join(root, `apps/vision-client/SlopZooka/SlopZooka/${name}.swift`),
      ),
      controller,
      path.join(root, "packages/transport/NativeStream.swift"),
      path.join(
        root,
        "apps/vision-client/tests/TerminalNotificationProbe.swift",
      ),
      "-o",
      executable,
    ],
    { cwd: root },
  );
  await exec("codesign", ["--force", "--sign", "-", appBundle]);
  await fs.writeFile(
    path.join(home, "agent.py"),
    `import os, select, time, tty
tty.setraw(0)
focused = True
pending = None
buffer = b''
def emit(data):
 os.write(1, data)
emit(b'\\x1b[?1004hNotification probe ready\\r\\n')
open('ready', 'w').close()
while True:
 if not select.select([0], [], [], None if pending is None else max(0, pending - time.monotonic()))[0]:
  if not focused: emit(b'Background: needs input\\r\\n\\x07')
  pending = None
  continue
 buffer += os.read(0, 1024)
 while buffer:
  if buffer.startswith(b'\\x1b'):
   if len(buffer) < 3: break
   key, buffer = buffer[:3], buffer[3:]
   if key == b'\\x1b[O':
    with open('focus-outs', 'a') as events: events.write('out\\n')
    if focused: pending = time.monotonic() + 0.2
    focused = False
   elif key == b'\\x1b[I':
    focused = True
    pending = None
  else:
   key, buffer = buffer[:1], buffer[1:]
   if key == b'b': emit(b'Bell\\r\\n\\x07')
   elif key == b'o': emit(b'\\x1b]9;Finished\\x07')
   elif key == b'm': emit(b'\\x1b]777;notify;Probe;Needs input\\x1b\\\\')
`,
  );
  const session = manager.create("notification-probe", home, null, undefined, {
    PATH: process.env.PATH,
    SHELL: "/bin/sh",
  });
  manager.paste(
    session.id,
    "start-probe",
    "exec /usr/bin/python3 -u ./agent.py",
    true,
  );
  app.get("/terminal", (_req, res) =>
    res.sendFile(path.join(root, "apps/mac-companion/public/terminal.html"), {
      dotfiles: "allow",
    }),
  );
  app.get("/terminal.js", (_req, res) =>
    res.sendFile(browser, { dotfiles: "allow" }),
  );
  app.use(
    express.static(path.join(root, "apps/mac-companion/public"), {
      dotfiles: "allow",
    }),
  );
  app.get("/probe/state", async (_req, res) => {
    const events = await fs
      .readFile(path.join(home, "focus-outs"), "utf8")
      .catch(() => "");
    res.json({
      attachments,
      processes: manager.summaries().length,
      focusOuts: events.split("\n").length - 1,
    });
  });
  app.post("/probe/emit/:kind", (req, res) => {
    const key = req.params.kind;
    if (!["b", "o", "m"].includes(key)) {
      res.sendStatus(400);
      return;
    }
    manager.paste(session.id, randomUUID(), key, false);
    res.sendStatus(204);
  });
  app.post("/probe/offline", (_req, res) => {
    for (const socket of sockets.clients) socket.terminate();
    manager.paste(session.id, randomUUID(), "b", false);
    res.sendStatus(204);
  });
  sockets.on("connection", (socket) => {
    send(socket, {
      type: "hello",
      version: PROTOCOL_VERSION,
      hostId: "probe",
      serviceInstanceId: "notification-probe",
      sessions: manager.summaries(),
    });
    socket.on("error", () => {});
    socket.on("close", () => manager.detach(socket));
    socket.on("message", (raw) => {
      const message: unknown = JSON.parse(raw.toString());
      if (!isClientMessage(message))
        throw new Error("Invalid probe terminal message");
      switch (message.type) {
        case "hello":
          break;
        case "attach":
          attachments++;
          manager.attach(socket, message.sessionId, message.cursor);
          break;
        case "detach":
          manager.detach(socket, message.sessionId);
          break;
        case "take-control":
          manager.takeControl(socket, message.sessionId);
          break;
        case "input":
          manager.input(socket, message.sessionId, message.data);
          break;
        case "resize":
          manager.resize(socket, message.sessionId, message.cols, message.rows);
          break;
        case "ack":
          manager.acknowledge(socket, message.sessionId, message.cursor);
          break;
      }
    });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  if (!address || typeof address === "string")
    throw new Error("Probe did not listen");
  const deadline = Date.now() + 10000;
  while (!(await fs.stat(path.join(home, "ready")).catch(() => undefined))) {
    if (Date.now() > deadline) throw new Error("Probe agent did not start");
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  const url = `http://127.0.0.1:${address.port}/terminal?sessionId=${session.id}`;
  console.log(
    `Notification probe: ${baseline ? "original code" : "current code"}; isolated PTY; ${appBundle}`,
  );
  const resultPath = path.join(home, "result.txt");
  const child = spawn(
    "/usr/bin/open",
    [
      "-n",
      "-W",
      appBundle,
      "--args",
      url,
      resultPath,
      ...(interactive ? ["--interactive"] : []),
    ],
    { stdio: "inherit" },
  );
  const exited = once(child, "exit");
  const resultDeadline = Date.now() + 90000;
  let result: string | undefined;
  while (!result) {
    result = await fs.readFile(resultPath, "utf8").catch(() => undefined);
    if (Date.now() > resultDeadline)
      throw new Error("Notification probe did not report a result");
    if (!result) await new Promise((resolve) => setTimeout(resolve, 50));
  }
  console.log(result.trim());
  if (!result.startsWith("PASS") && !interactive)
    throw new Error("Notification probe failed");
  if (interactive)
    console.log(
      "Close the probe window to stop its isolated companion and PTY.",
    );
  await exited;
} finally {
  for (const socket of sockets.clients) socket.terminate();
  sockets.close();
  server.close();
  await manager.stop();
  await fs.rm(home, { recursive: true, force: true });
}
