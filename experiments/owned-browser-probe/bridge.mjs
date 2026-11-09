import { createServer, createConnection } from "node:net";
import { chmod } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { receive, send } from "./wire.mjs";

// Transport only: no workspace, process, window, or durable workflow registry.
export async function startBridge({ socketPath, token }) {
  const events = new EventEmitter();
  const peers = new Set();
  const pending = new Map();
  let extension;
  let extensionPid;
  let epoch = 0;
  function disconnectExtension(peer) {
    if (peer !== extension) return;
    extension = undefined;
    extensionPid = undefined;
    for (const { reject, timer } of pending.values()) {
      clearTimeout(timer);
      reject(
        new Error(
          "Bridge disconnected; effects may have occurred. Reclaim and observe; do not replay.",
        ),
      );
    }
    pending.clear();
    events.emit("disconnected", epoch);
  }
  function request(owner, tool, args = {}) {
    if (!extension) return Promise.reject(new Error("Extension unavailable"));
    return new Promise((resolve, reject) => {
      const id = randomUUID();
      const peer = extension;
      const timer = setTimeout(() => {
        // Quarantine the whole uncertain channel rather than let queued input run.
        peer.destroy();
        disconnectExtension(peer);
      }, 15_000);
      pending.set(id, { resolve, reject, timer });
      try {
        send(peer, { id, owner, tool, args });
      } catch (error) {
        peer.destroy();
        disconnectExtension(peer);
      }
    });
  }
  const server = createServer((peer) => {
    peers.add(peer);
    let role;
    const owner = randomUUID();
    const handshakeTimeout = setTimeout(() => peer.destroy(), 2000);
    peer.on("error", () => {});
    peer.on("close", () => {
      clearTimeout(handshakeTimeout);
      peers.delete(peer);
      disconnectExtension(peer);
      if (role === "client")
        void request(owner, "browser_stop").catch(() => {});
    });
    receive(
      peer,
      (message) => {
        if (!role) {
          clearTimeout(handshakeTimeout);
          if (
            message.role === "extension" &&
            message.token === token &&
            !extension
          ) {
            role = "extension";
            extension = peer;
            extensionPid = message.pid;
            epoch++;
            events.emit("connected", { epoch, pid: extensionPid });
          } else if (message.role === "client") {
            role = "client";
          } else peer.destroy();
          return;
        }
        if (role === "extension") {
          if (message.event) {
            events.emit("event", message);
            return;
          }
          const entry = pending.get(message.id);
          if (!entry) return;
          pending.delete(message.id);
          clearTimeout(entry.timer);
          if (message.error) entry.reject(new Error(message.error));
          else entry.resolve(message.result);
        } else {
          if (
            typeof message.id !== "string" ||
            typeof message.tool !== "string"
          ) {
            peer.destroy();
            return;
          }
          void request(owner, message.tool, message.args)
            .then(
              (result) => {
                if (!peer.destroyed)
                  send(peer, { id: message.id, result }, 8 * 1024 * 1024);
              },
              (error) => {
                if (!peer.destroyed)
                  send(peer, { id: message.id, error: error.message });
              },
            )
            .catch(() => peer.destroy());
        }
      },
      () => peer.destroy(),
    );
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  await chmod(socketPath, 0o600);
  return {
    events,
    get status() {
      return {
        connected: !!extension,
        epoch,
        pid: extensionPid,
        pending: pending.size,
      };
    },
    async close() {
      for (const peer of peers) peer.destroy();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

export async function connectBridge(socketPath) {
  const socket = createConnection(socketPath);
  const pending = new Map();
  socket.on("error", () => {});
  socket.on("close", () => {
    for (const entry of pending.values())
      entry.reject(
        new Error("Companion connection closed; effects may have occurred"),
      );
    pending.clear();
  });
  await new Promise((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("error", reject);
  });
  send(socket, { role: "client" });
  receive(
    socket,
    (message) => {
      const entry = pending.get(message.id);
      if (!entry) return;
      pending.delete(message.id);
      if (message.error) entry.reject(new Error(message.error));
      else entry.resolve(message.result);
    },
    () => socket.destroy(),
  );
  return {
    call(tool, args = {}) {
      return new Promise((resolve, reject) => {
        const id = randomUUID();
        pending.set(id, { resolve, reject });
        try {
          send(socket, { id, tool, args });
        } catch (error) {
          pending.delete(id);
          reject(error);
        }
      });
    },
    close() {
      socket.destroy();
    },
  };
}
