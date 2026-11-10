import { execFile, spawn, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import http, { type IncomingMessage } from "node:http";
import path from "node:path";
import os from "node:os";
import type { Duplex } from "node:stream";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import type { Express } from "express";
import type { Logger } from "./logger.js";
import { logError } from "../../../packages/protocol/src/diagnostics.js";
import { TransportHelperDecoder } from "./transport-helper.js";
import { PreviewTLS } from "./preview-tls.js";

export type Upgrade = (
  req: IncomingMessage,
  socket: Duplex,
  head: Buffer,
) => void;
const exec = promisify(execFile);
const peerRequests = new WeakSet<IncomingMessage>();
export function createPeerIngress(app: Express, upgrade: Upgrade): http.Server {
  const server = http.createServer((req, res) => {
    peerRequests.add(req);
    app(req, res);
  });
  server.on("upgrade", (req, socket, head) => {
    peerRequests.add(req);
    upgrade(req, socket, head);
  });
  return server;
}
export const connectionMethod = (req: IncomingMessage) =>
  peerRequests.has(req) ? "direct" : "localNetwork";

/** The native ingress forwards only to this private HTTP listener. Route facts
 * come from the accepting listener, never an agent/client-supplied header. */
export class CompanionTransport {
  private readonly ingress: http.Server;
  private child?: ChildProcess;
  private closed?: Promise<void>;
  private stopped = false;
  private authority?: string;
  private ready = false;
  private retry?: NodeJS.Timeout;
  private renewal?: NodeJS.Timeout;
  private starting?: Promise<void>;
  private retryDelay = 1000;

  constructor(
    app: Express,
    upgrade: Upgrade,
    private readonly home: string,
    private readonly hostId: string,
    private readonly logger: Logger,
  ) {
    this.ingress = createPeerIngress(app, upgrade);
  }

  get health() {
    return {
      version: 1,
      direct: this.ready,
      // Public trust material, adopted only over an already authenticated route.
      ...(this.authority ? { certificateAuthority: this.authority } : {}),
    };
  }

  start(): Promise<void> {
    if (this.starting) return this.starting;
    this.starting = this.startAttempt().finally(() => {
      this.starting = undefined;
    });
    return this.starting;
  }

  private scheduleRetry() {
    if (this.stopped || this.retry) return;
    this.logger.info("helper.retry.scheduled", { delayMs: this.retryDelay });
    this.retry = setTimeout(() => {
      this.retry = undefined;
      void this.start();
    }, this.retryDelay);
    this.retryDelay = Math.min(30_000, this.retryDelay * 2);
    this.retry.unref();
  }

  private async startAttempt(): Promise<void> {
    if (
      this.stopped ||
      this.ready ||
      this.child ||
      process.env.SLOPZOOKA_DIRECT === "0"
    )
      return;
    // Memory-only TLS identity import requires macOS 15 (Darwin 24).
    if (
      process.platform !== "darwin" ||
      Number(os.release().split(".")[0]) < 24
    )
      return;
    const started = performance.now();
    const helperId = randomUUID();
    this.logger.info("helper.starting", { helperId });
    const binary = fileURLToPath(
      new URL("../native/transport-host", import.meta.url),
    );
    try {
      await fs.access(binary);
      const directory = path.join(this.home, "transport");
      const identity = await new PreviewTLS(directory).certificate(
        "slopzooka.local",
      );
      this.authority = identity.certificateAuthority;
      // The TLS identity is independent of frontend gateways. Only its CA travels
      // in health; the private identity remains in the companion's private home.
      const temporary = await fs.mkdtemp(path.join(directory, "identity-"));
      const identityPath = path.join(temporary, "identity.p12");
      try {
        await fs.writeFile(path.join(temporary, "key.pem"), identity.key, {
          mode: 0o600,
        });
        await fs.writeFile(path.join(temporary, "cert.pem"), identity.cert);
        await exec(
          "/usr/bin/openssl",
          [
            "pkcs12",
            "-export",
            "-inkey",
            "key.pem",
            "-in",
            "cert.pem",
            "-out",
            "identity.p12",
            "-passout",
            "pass:slopzooka-local",
            "-keypbe",
            "PBE-SHA1-3DES",
            "-certpbe",
            "PBE-SHA1-3DES",
          ],
          { cwd: temporary, timeout: 10_000 },
        );
        await fs.chmod(identityPath, 0o600);
        if (this.stopped) return;
        if (!this.ingress.listening)
          await new Promise<void>((resolve, reject) => {
            this.ingress.once("error", reject);
            this.ingress.listen(0, "127.0.0.1", () => {
              this.ingress.removeListener("error", reject);
              resolve();
            });
          });
        if (this.stopped) {
          this.ingress.close();
          return;
        }
        const address = this.ingress.address();
        if (!address || typeof address === "string")
          throw new Error("Missing native ingress port");
        const child = spawn(
          binary,
          [identityPath, String(address.port), this.hostId],
          { stdio: ["pipe", "pipe", "pipe"] },
        );
        this.child = child;
        const context = { helperId, pid: child.pid };
        let renewing = false;
        // Rotate the leaf before expiry while retaining the paired CA. This uses
        // the same helper recovery path as an exit; PTYs remain in their service.
        clearTimeout(this.renewal);
        this.renewal = setTimeout(
          () => {
            renewing = true;
            this.logger.info("helper.renewing", context);
            child.stdin.end();
          },
          Math.max(
            1000,
            Math.min(
              2_000_000_000,
              identity.expiresAt - Date.now() - 7 * 24 * 60 * 60_000,
            ),
          ),
        );
        this.renewal.unref();
        this.closed = new Promise((resolve) =>
          child.once("close", (code, signal) => {
            clearTimeout(this.renewal);
            if (this.child === child) this.child = undefined;
            this.ready = false;
            this.logger[this.stopped || renewing ? "info" : "warn"](
              "helper.exited",
              {
                ...context,
                code,
                signal,
                expected: this.stopped || renewing,
                durationMs: Math.round(performance.now() - started),
              },
            );
            this.scheduleRetry();
            resolve();
          }),
        );
        child.stdin.on("error", () => {});
        child.stderr.on("data", () => {}); // Only typed stdout metadata enters application logs.
        await new Promise<void>((resolve, reject) => {
          let awaitingReady = true;
          const timer = setTimeout(() => {
            awaitingReady = false;
            child.stdin.end();
            reject(new Error("Direct ingress startup timed out"));
          }, 8_000);
          child.once("error", (error) => {
            awaitingReady = false;
            clearTimeout(timer);
            reject(error);
          });
          child.once("close", () => {
            awaitingReady = false;
            clearTimeout(timer);
            reject(new Error("Direct ingress unavailable"));
          });
          const decoder = new TransportHelperDecoder((message) => {
            if (message.type === "observation") {
              this.logger[message.event.endsWith("failed") ? "warn" : "info"](
                message.event,
                { ...context, ...message.fields },
              );
              return;
            }
            if (!awaitingReady || this.stopped) return;
            awaitingReady = false;
            clearTimeout(timer);
            this.ready = true;
            this.retryDelay = 1000;
            this.logger.info("helper.ready", {
              ...context,
              port: message.port,
              durationMs: Math.round(performance.now() - started),
            });
            resolve();
          });
          let invalid = false;
          child.stdout.on("data", (data: Buffer) => {
            if (invalid) return;
            try {
              decoder.push(data);
            } catch (error) {
              invalid = true;
              awaitingReady = false;
              this.ready = false;
              clearTimeout(timer);
              this.logger.warn("helper.protocol.failed", {
                ...context,
                error: logError(error),
              });
              child.stdin.end();
              reject(error);
            }
          });
        });
      } finally {
        await fs.rm(temporary, { recursive: true, force: true });
      }
    } catch (error) {
      this.logger.warn("helper.unavailable", {
        helperId,
        error: logError(error),
        durationMs: Math.round(performance.now() - started),
      });
    }
  }

  async stop(): Promise<void> {
    if (this.stopped) return;
    this.stopped = true;
    this.logger.info("transport.stopping");
    clearTimeout(this.retry);
    clearTimeout(this.renewal);
    this.ready = false;
    this.child?.stdin?.end();
    this.ingress.closeAllConnections();
    this.ingress.close();
    await this.starting;
    await this.closed;
  }
}
