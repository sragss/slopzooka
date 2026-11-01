import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import http from "node:http";
import { createHash } from "node:crypto";
import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { WebSocket } from "ws";
import { ServiceError } from "./errors.js";
import {
  SESSION_SERVICE_VERSION,
  type ServiceInfo,
  type SessionLaunch,
} from "./session-service-protocol.js";

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const absent = (error: unknown) =>
  ["ENOENT", "ECONNREFUSED"].includes(
    (error as NodeJS.ErrnoException).code ?? "",
  );

/** One local terminal-service client. No cached session registry or automatic mutation retries. */
export class SessionServiceClient {
  private constructor(
    readonly socketPath: string,
    private readonly home: string,
  ) {}
  static async forHome(home: string): Promise<SessionServiceClient> {
    await fs.mkdir(home, { recursive: true, mode: 0o700 });
    const canonical = await fs.realpath(home);
    // macOS has a short Unix-socket path limit; don't put the socket in a worktree.
    const key = createHash("sha256")
      .update(canonical)
      .digest("hex")
      .slice(0, 24);
    const directory = `/tmp/slz-sessions-${process.getuid!()}-${key}`;
    await fs.mkdir(directory, { mode: 0o700 }).catch((error) => {
      if (error.code !== "EEXIST") throw error;
    });
    const stat = await fs.lstat(directory);
    if (
      !stat.isDirectory() ||
      stat.isSymbolicLink() ||
      stat.uid !== process.getuid!() ||
      stat.mode & 0o077
    )
      throw new Error(
        "Session socket directory must be private and owned by this user",
      );
    return new SessionServiceClient(
      path.join(directory, "service.sock"),
      canonical,
    );
  }
  get logPath(): string {
    return path.join(this.home, "session-service.log");
  }
  async info(): Promise<ServiceInfo> {
    const info = await this.request<ServiceInfo>("/info");
    if (info.version !== SESSION_SERVICE_VERSION)
      throw new ServiceError(
        "The running session service needs an explicit update. End its sessions before restarting it.",
        503,
      );
    return info;
  }
  async connectOrStart(): Promise<ServiceInfo> {
    try {
      return await this.info();
    } catch (error) {
      if (!absent(error)) throw error;
    }
    const runtime = await this.installRuntime();
    const { id } = JSON.parse(
      await fs.readFile(path.join(runtime, "runtime.json"), "utf8"),
    );
    let launcherExit: number | undefined;
    const launch = async () => {
      launcherExit = undefined;
      const log = await fs.open(this.logPath, "a", 0o600);
      try {
        // lockf holds a kernel lock for the lifetime of its command. Competing
        // launchers exit immediately; stale sockets are handled only by the winner.
        const child = spawn(
          "/usr/bin/lockf",
          [
            "-ks",
            "-t",
            "0",
            path.join(path.dirname(this.socketPath), "service.lock"),
            path.join(runtime, "node"),
            path.join(runtime, "service.cjs"),
            this.socketPath,
            id,
          ],
          {
            detached: true,
            stdio: ["ignore", log.fd, log.fd],
            cwd: this.home,
            env: { PATH: process.env.PATH, HOME: process.env.HOME },
          },
        );
        await new Promise<void>((resolve, reject) => {
          child.once("spawn", resolve);
          child.once("error", reject);
        });
        child.once("exit", (code) => {
          launcherExit = code ?? -1;
        });
        child.unref();
      } finally {
        await log.close();
      }
    };
    await launch();
    const deadline = Date.now() + 8000;
    while (Date.now() < deadline) {
      try {
        return await this.info();
      } catch (error) {
        if (!absent(error)) throw error;
      }
      if (launcherExit !== undefined) {
        if (launcherExit !== 75)
          throw new ServiceError(
            "Session service failed to start. See session-service.log.",
            503,
          );
        // A previous lockf may still be reaping a crashed service. Retry only
        // immediate lock contention; never leave a queued launch after returning.
        await delay(200);
        await launch();
      }
      await delay(50);
    }
    throw new ServiceError(
      "Session service did not start. See session-service.log; existing sessions were not stopped.",
      503,
    );
  }
  create(launch: SessionLaunch) {
    return this.request<
      import("../../../packages/protocol/src/index.js").SessionSummary
    >("/sessions", "POST", launch);
  }
  end(id: string) {
    return this.request(`/sessions/${encodeURIComponent(id)}`, "DELETE");
  }
  async rename(id: string, name: unknown) {
    if (!(await this.info()).capabilities?.includes("rename-session"))
      throw new ServiceError(
        "The running session service needs an explicit update before renaming. End its sessions before restarting it.",
        503,
      );
    return this.request<
      import("../../../packages/protocol/src/index.js").SessionSummary
    >(`/sessions/${encodeURIComponent(id)}`, "PATCH", { name });
  }
  paste(id: string, commandId: string, text: string, sendReturn: boolean) {
    return this.request(`/sessions/${encodeURIComponent(id)}/input`, "POST", {
      commandId,
      text,
      sendReturn,
    });
  }
  async stop(): Promise<void> {
    await this.request("/stop", "POST");
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) {
      try {
        await this.info();
      } catch (error) {
        if (absent(error)) return;
      }
      await delay(50);
    }
    throw new ServiceError("Session service is still stopping", 503);
  }
  request<T = unknown>(
    route: string,
    method = "GET",
    body?: unknown,
  ): Promise<T> {
    return new Promise((resolve, reject) => {
      const data = body === undefined ? undefined : JSON.stringify(body);
      const request = http.request(
        {
          socketPath: this.socketPath,
          path: route,
          method,
          agent: false,
          headers: data
            ? {
                "Content-Type": "application/json",
                "Content-Length": Buffer.byteLength(data),
              }
            : {},
        },
        (response) => {
          const chunks: Buffer[] = [];
          let length = 0;
          response.on("data", (chunk: Buffer) => {
            length += chunk.length;
            if (length > 256 * 1024)
              request.destroy(new Error("Session service response too large"));
            else chunks.push(chunk);
          });
          response.on("error", reject);
          response.on("end", () => {
            try {
              const result = JSON.parse(Buffer.concat(chunks).toString());
              if (response.statusCode !== 200)
                throw new ServiceError(
                  result.error ?? "Session service request failed",
                  response.statusCode ?? 503,
                );
              resolve(result);
            } catch (error) {
              reject(error);
            }
          });
        },
      );
      const deadline = setTimeout(
        () =>
          request.destroy(
            new ServiceError(
              "Session service request timed out; its outcome may be unknown",
              503,
            ),
          ),
        5000,
      );
      request.once("close", () => clearTimeout(deadline));
      request.on("error", reject);
      request.end(data);
    });
  }
  /** Each viewer keeps its own attachment and writer identity in SessionManager. */
  async relay(viewer: WebSocket, hello: object): Promise<void> {
    // The service handshake and viewer hello come from the same live connection.
    if (viewer.readyState !== WebSocket.OPEN) return;
    const upstream = new WebSocket(`ws+unix://${this.socketPath}:/terminal`, {
      // A bounded xterm checkpoint can be larger than an ordinary output frame.
      maxPayload: 64 * 1024 * 1024,
      handshakeTimeout: 5000,
    });
    const close = () => {
      upstream.terminate();
      if (viewer.readyState === WebSocket.OPEN)
        viewer.close(1012, "Session connection interrupted; reconnect");
    };
    const handshake = setTimeout(close, 5000);
    upstream.once("close", () => clearTimeout(handshake));
    upstream.on("error", close);
    upstream.on("close", close);
    viewer.once("close", () => upstream.terminate());
    viewer.on("message", (raw) => {
      if (
        upstream.readyState !== WebSocket.OPEN ||
        upstream.bufferedAmount + raw.toString().length > 2 * 1024 * 1024
      ) {
        close();
        return;
      }
      upstream.send(raw, { binary: false });
    });
    let ready = false;
    upstream.on("message", (raw) => {
      if (!ready) {
        try {
          const info = JSON.parse(raw.toString());
          if (
            info.type !== "service-ready" ||
            info.version !== SESSION_SERVICE_VERSION
          )
            throw new Error("Incompatible session stream");
          ready = true;
          clearTimeout(handshake);
          if (viewer.readyState !== WebSocket.OPEN) {
            close();
            return;
          }
          viewer.send(
            JSON.stringify({
              ...hello,
              sessions: info.sessions,
              serviceInstanceId: info.instanceId,
            }),
          );
        } catch {
          close();
        }
        return;
      }
      if (
        viewer.readyState !== WebSocket.OPEN ||
        viewer.bufferedAmount > 2 * 1024 * 1024
      ) {
        close();
        return;
      }
      viewer.send(raw, { binary: false });
    });
  }

  private async installRuntime(): Promise<string> {
    const root = path.join(this.home, "session-runtimes");
    await fs.mkdir(root, { recursive: true, mode: 0o700 });
    const stage = await fs.mkdtemp(path.join(root, ".stage-"));
    try {
      if (import.meta.url.endsWith(".ts")) {
        // Development gets the same immutable runtime as a packaged build.
        await promisify(execFile)(
          process.execPath,
          [
            path.resolve(
              import.meta.dirname,
              "../scripts/build-session-runtime.mjs",
            ),
            stage,
          ],
          { timeout: 30000, maxBuffer: 1024 * 1024 },
        );
      } else {
        await fs.cp(
          path.resolve(import.meta.dirname, "../../session-runtime"),
          stage,
          {
            recursive: true,
            mode: constants.COPYFILE_FICLONE,
          },
        );
      }
      const { id } = JSON.parse(
        await fs.readFile(path.join(stage, "runtime.json"), "utf8"),
      );
      if (!/^[a-f0-9]{64}$/.test(id))
        throw new Error("Invalid session runtime identity");
      const destination = path.join(root, id);
      try {
        await fs.rename(stage, destination);
      } catch (error) {
        if (
          !["EEXIST", "ENOTEMPTY"].includes(
            (error as NodeJS.ErrnoException).code ?? "",
          )
        )
          throw error;
      }
      return destination;
    } finally {
      await fs.rm(stage, { recursive: true, force: true });
    }
  }
}
