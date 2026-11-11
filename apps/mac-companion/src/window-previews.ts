import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { connect, type Socket } from "node:net";
import type { Duplex } from "node:stream";
import { fileURLToPath } from "node:url";
import type { IncomingMessage } from "node:http";
import type { PresentationAvailability } from "../../../packages/protocol/src/index.js";
import type { Logger } from "./logger.js";
import { ServiceError } from "./errors.js";
import { connectionMethod } from "./companion-transport.js";

export type WindowSource = {
  id: string;
  title: string;
  application: string;
  contentWidth: number;
  contentHeight: number;
};
export type WindowCatalog = {
  sources: WindowSource[];
  state: "ready" | "permissionRequired" | "locked" | "failed";
  message?: string;
};
type Reply = {
  version: number;
  type: string;
  id?: string;
  port?: number;
  error?: string;
  value?: unknown;
  event?: string;
  fields?: Record<string, unknown>;
};
type Pending = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
};

/** Optional native capture provider. Shared companion routes own authentication;
 * this adapter owns its child and fixed private byte bridge, never window intent. */
export class WindowPreviews {
  readonly enabled: boolean;
  private child?: ChildProcessWithoutNullStreams;
  private port?: number;
  private buffer = Buffer.alloc(0);
  private pending = new Map<string, Pending>();
  private channels = new Set<Duplex>();
  private stopped = false;
  private startTask?: Promise<void>;
  private catalogTask?: Promise<WindowCatalog>;
  constructor(
    private readonly log: Logger,
    private readonly binary = fileURLToPath(
      new URL("../native/window-host", import.meta.url),
    ),
    enabled = process.env.SLOPZOOKA_WINDOW_PREVIEWS === "1",
  ) {
    this.enabled = enabled;
  }

  private start(): Promise<void> {
    if (this.stopped || !this.enabled)
      return Promise.reject(
        new ServiceError("Mac window previews are not enabled.", 503),
      );
    if (this.startTask) return this.startTask;
    this.startTask = new Promise<void>((resolve, reject) => {
      const child = spawn(this.binary, [], { stdio: "pipe" });
      this.child = child;
      const timer = setTimeout(() => {
        reject(new Error("Capture provider startup timed out"));
        child.kill();
      }, 5000);
      child.stderr.resume(); // No uncontrolled native stderr in centralized logs.
      child.stdout.on("data", (chunk: Buffer) => {
        this.buffer = Buffer.concat([this.buffer, chunk]);
        if (this.buffer.length > 512 * 1024) {
          child.kill();
          return;
        }
        for (;;) {
          const newline = this.buffer.indexOf(10);
          if (newline < 0) break;
          const line = this.buffer.subarray(0, newline);
          this.buffer = this.buffer.subarray(newline + 1);
          try {
            const message = JSON.parse(line.toString()) as Reply;
            if (message.version !== 1)
              throw new Error("Unknown capture protocol");
            if (
              message.type === "ready" &&
              Number.isInteger(message.port) &&
              message.port! > 0 &&
              message.port! <= 65535
            ) {
              this.port = message.port;
              clearTimeout(timer);
              resolve();
              this.log.info("provider.ready");
            } else if (message.type === "observation") {
              const allowed = new Set([
                "viewerId",
                "frames",
                "bytes",
                "dropped",
                "reason",
                "durationMs",
                "captured",
                "coalesced",
                "stage",
                "errorDomain",
                "errorCode",
              ]);
              if (
                message.event !== "stream.summary" ||
                !message.fields ||
                Object.entries(message.fields).some(
                  ([key, value]) =>
                    !allowed.has(key) ||
                    typeof value !== "string" ||
                    value.length > 128,
                )
              )
                throw new Error("Invalid capture observation");
              this.log.info(
                message.event,
                message.fields as Record<string, string>,
              );
            } else if (message.type === "reply" && message.id) {
              const item = this.pending.get(message.id.toLowerCase());
              if (item) {
                this.pending.delete(message.id.toLowerCase());
                clearTimeout(item.timer);
                if (message.error)
                  item.reject(new ServiceError(message.error, 409));
                else item.resolve(message.value);
              }
            } else if (message.type === "failed") {
              child.kill();
            }
          } catch {
            child.kill();
          }
        }
      });
      const ended = () => {
        if (this.child !== child) return;
        clearTimeout(timer);
        this.child = undefined;
        this.port = undefined;
        this.startTask = undefined;
        this.buffer = Buffer.alloc(0);
        const error = new ServiceError(
          "Mac capture provider is unavailable. Retry to select a window again.",
          503,
        );
        reject(error);
        for (const item of this.pending.values()) {
          clearTimeout(item.timer);
          item.reject(error);
        }
        this.pending.clear();
        for (const channel of this.channels) channel.destroy();
        this.channels.clear();
        this.log.info("provider.stopped");
      };
      child.once("error", ended);
      child.once("exit", ended);
      child.stdin.on("error", () => child.kill());
    });
    return this.startTask;
  }
  private async command(method: string, sourceID?: string): Promise<unknown> {
    await this.start();
    if (!this.child || this.pending.size >= 8)
      throw new ServiceError("Mac capture provider is busy.", 503);
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new ServiceError("Mac capture operation timed out.", 504));
      }, 5000);
      this.pending.set(id, { resolve, reject, timer });
      this.child!.stdin.write(JSON.stringify({ id, method, sourceID }) + "\n");
    });
  }
  async catalog(): Promise<WindowCatalog> {
    if (!this.catalogTask)
      this.catalogTask = this.command("catalog")
        .then((value) => {
          const catalog = value as WindowCatalog;
          if (
            !Array.isArray(catalog.sources) ||
            catalog.sources.length > 500 ||
            !["ready", "permissionRequired", "locked"].includes(catalog.state)
          )
            throw new Error("Invalid native window catalog");
          for (const source of catalog.sources)
            if (!validSource(source))
              throw new Error("Invalid native window source");
          return catalog;
        })
        .catch(
          (): WindowCatalog => ({
            sources: [],
            state: "failed",
            message:
              "Mac window sharing is unavailable. Check the companion on your Mac.",
          }),
        )
        .finally(() => {
          this.catalogTask = undefined;
        });
    return this.catalogTask;
  }
  async resolve(id: string, request: IncomingMessage): Promise<WindowSource> {
    const catalog = await this.catalog();
    const availability = windowPresentation(request, catalog);
    if (!availability.available)
      throw new ServiceError(
        availability.message ?? "Window sharing unavailable",
        409,
      );
    const source = catalog.sources.find((item) => item.id === id);
    if (!source)
      throw new ServiceError(
        "This Mac window is unavailable. Select its current window from the launcher.",
        404,
      );
    return source;
  }
  async permission(settings: boolean): Promise<void> {
    await this.command(settings ? "settings" : "permission");
  }

  async upgrade(
    request: IncomingMessage,
    socket: Duplex,
    head: Buffer,
  ): Promise<void> {
    let upstream: Socket | undefined;
    const close = () => {
      socket.destroy();
      upstream?.destroy();
      this.channels.delete(socket);
    };
    socket.once("error", close);
    socket.once("close", close);
    socket.pause();
    this.channels.add(socket);
    try {
      assertWindowRoute(request);
      if (
        head.length ||
        request.headers.upgrade !== "slz-window-v1" ||
        this.channels.size > 8
      )
        throw new ServiceError("Invalid native preview request", 400);
      const id = decodeURIComponent(
        request.url!.slice("/api/window-stream/".length),
      );
      await this.resolve(id, request);
      const opened = (await this.command("open", id)) as { ticket: string };
      if (
        !/^[a-f0-9-]{36}$/i.test(opened.ticket) ||
        !this.port ||
        socket.destroyed
      )
        throw new Error("Invalid capture admission");
      upstream = connect({ host: "127.0.0.1", port: this.port });
      upstream.on("error", close);
      upstream.on("close", close);
      const deadline = setTimeout(close, 5000);
      upstream.once("connect", () => {
        clearTimeout(deadline);
        if (socket.destroyed) {
          close();
          return;
        }
        upstream!.write(opened.ticket + "\n");
        socket.write(
          "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: slz-window-v1\r\n\r\n",
        );
        // stream.pipe applies bounded backpressure. Frames are never parsed here.
        socket.pipe(upstream!).pipe(socket);
        socket.resume();
      });
      upstream.once("close", () => clearTimeout(deadline));
    } catch (error) {
      this.log.warn("stream.rejected", {
        status: error instanceof ServiceError ? error.statusCode : 503,
      });
      if (!socket.destroyed)
        socket.end(
          `HTTP/1.1 ${error instanceof ServiceError ? error.statusCode : 503} Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`,
        );
    }
  }
  stop(): void {
    this.stopped = true;
    for (const channel of this.channels) channel.destroy();
    this.child?.stdin.end();
    this.child?.kill();
  }
}
function validSource(value: WindowSource): boolean {
  return (
    typeof value?.id === "string" &&
    /^window:[a-f0-9-]{36}:\d+:\d+$/.test(value.id) &&
    typeof value.title === "string" &&
    value.title.length <= 256 &&
    typeof value.application === "string" &&
    value.application.length <= 128 &&
    [value.contentWidth, value.contentHeight].every(
      (size) => Number.isFinite(size) && size >= 1 && size <= 16384,
    )
  );
}
export function assertWindowRoute(request: IncomingMessage): void {
  if (connectionMethod(request) === "direct")
    throw new ServiceError(
      "Mac window previews are not supported on Direct to Mac yet. Choose Local Network in Settings.",
      409,
    );
}

export function windowPresentation(
  request: IncomingMessage,
  catalog: WindowCatalog,
): PresentationAvailability {
  let reasonCode: PresentationAvailability["reasonCode"];
  let message: string | undefined;
  if (connectionMethod(request) === "direct") {
    reasonCode = "presentation_unsupported_on_route";
    message =
      "Mac window previews are not supported on Direct to Mac yet. Choose Local Network in Settings.";
  } else if (catalog.state === "permissionRequired") {
    reasonCode = "permission_required";
    message = "Allow Screen Recording on your Mac to share windows.";
  } else if (catalog.state === "locked") {
    reasonCode = "desktop_locked";
    message = "Unlock your Mac to share windows.";
  } else if (catalog.state !== "ready") {
    reasonCode = "provider_unavailable";
    message = catalog.message ?? "Mac window sharing is unavailable.";
  }
  return {
    presentation: "window",
    available: !reasonCode,
    reasonCode,
    message,
    alternatives: [],
  };
}
