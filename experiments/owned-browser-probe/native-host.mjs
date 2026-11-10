import { readFile } from "node:fs/promises";
import { createConnection } from "node:net";
import { receive, send } from "./wire.mjs";

const config = JSON.parse(await readFile(process.argv[2], "utf8"));
if (process.argv[3] !== config.extensionOrigin)
  throw new Error("Unexpected extension origin");
const socket = createConnection(config.socketPath);
const stop = () => process.exit(0);
socket.on("error", stop);
socket.on("close", stop);
process.stdin.on("end", stop);
process.stdout.on("error", stop);
socket.on("connect", () => {
  send(socket, { role: "extension", token: config.token, pid: process.pid });
  receive(
    process.stdin,
    (message) => send(socket, message, 8 * 1024 * 1024),
    stop,
  );
  // Chrome enforces a 1 MB host-to-extension limit. Images go the other way.
  receive(socket, (message) => send(process.stdout, message), stop);
});
