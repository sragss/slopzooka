import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import https from "node:https";
import type { Logger } from "./logger.js";
import { readPortless, readPortlessProxy } from "./frontend-discovery.js";

const hostname = "slopzooka.localhost";
type Options = {
  stateDir?: string;
  enabled?: boolean;
  register?: (
    stateDir: string,
    port: number,
    signal: AbortSignal,
  ) => Promise<void>;
};

/** Optional address for the dashboard. Portless never owns or restarts the companion. */
export class DashboardAddress {
  readonly fallback: string;
  private origin?: string;
  private task?: Promise<void>;
  private timer?: NodeJS.Timeout;
  private readonly abort = new AbortController();
  private readonly stateDir: string;
  private readonly enabled: boolean;
  private lastWarning?: string;
  private readonly register: NonNullable<Options["register"]>;
  get proxyOrigin(): string | undefined {
    return this.origin;
  }

  constructor(
    private readonly port: number,
    private readonly hostId: string,
    private readonly logger: Logger,
    options: Options = {},
  ) {
    this.fallback = `http://localhost:${port}/`;
    this.stateDir =
      options.stateDir ??
      process.env.PORTLESS_STATE_DIR ??
      path.join(os.homedir(), ".portless");
    this.enabled = options.enabled ?? process.env.SLOPZOOKA_PORTLESS !== "0";
    this.register =
      options.register ??
      (async (stateDir, port, signal) => {
        const env: NodeJS.ProcessEnv = {
          ...process.env,
          PORTLESS_STATE_DIR: stateDir,
          PORTLESS_TLD: "localhost",
        };
        // We invoke an installed executable directly, even if the companion was launched with pnpm exec.
        delete env.npm_command;
        delete env.PNPM_SCRIPT_SRC_DIR;
        await promisify(execFile)(
          "portless",
          ["alias", hostname, String(port)],
          {
            env,
            timeout: 3000,
            maxBuffer: 128 * 1024,
            signal,
          },
        );
      });
  }

  start(): void {
    if (this.timer || this.abort.signal.aborted || !this.enabled) return;
    void this.refresh();
    this.timer = setInterval(() => void this.refresh(), 15_000);
    this.timer.unref();
  }

  refresh(): Promise<void> {
    if (!this.enabled || this.abort.signal.aborted) return Promise.resolve();
    this.task ??= this.update()
      .catch((error) => {
        this.origin = undefined;
        if (this.abort.signal.aborted) return;
        const detail = error instanceof Error ? error.message : String(error);
        if (detail !== this.lastWarning)
          this.logger.warn("Named dashboard unavailable; using localhost", {
            error: detail,
          });
        this.lastWarning = detail;
      })
      .finally(() => {
        this.task = undefined;
      });
    return this.task;
  }

  private async update(): Promise<void> {
    const proxy = await readPortlessProxy(this.stateDir);
    if (!proxy) {
      this.origin = undefined;
      return;
    }
    let routes = (await readPortless(this.stateDir)).routes;
    let route = routes.find((route) => route.frontend.hostname === hostname);
    if (route && route.frontend.port !== this.port)
      throw new Error(
        `${hostname} is already assigned to port ${route.frontend.port}; leaving that route unchanged.`,
      );
    if (!route) {
      await this.register(this.stateDir, this.port, this.abort.signal);
      routes = (await readPortless(this.stateDir)).routes;
      route = routes.find((route) => route.frontend.hostname === hostname);
    }
    if (!route || route.frontend.port !== this.port)
      throw new Error(
        `Portless did not register ${hostname} for port ${this.port}.`,
      );
    if (this.abort.signal.aborted) return;
    this.origin = new URL(route.frontend.url).origin;
    this.lastWarning = undefined;
  }

  /** Recheck the actual route on each menu click, so a dead/reassigned proxy falls back safely. */
  async destination(): Promise<string> {
    if (!this.enabled || this.abort.signal.aborted) return this.fallback;
    await this.refresh();
    const origin = this.origin;
    if (!origin) return this.fallback;
    try {
      const ca = origin.startsWith("https:")
        ? await fs.readFile(path.join(this.stateDir, "ca.pem"))
        : undefined;
      const healthy = await this.verify(origin, ca);
      return healthy && this.origin === origin && !this.abort.signal.aborted
        ? origin + "/"
        : this.fallback;
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      if (!this.abort.signal.aborted && detail !== this.lastWarning)
        this.logger.warn(
          "Named dashboard health check failed; using localhost",
          { origin, error: detail },
        );
      this.lastWarning = detail;
      return this.fallback;
    }
  }

  private verify(origin: string, ca?: Buffer): Promise<boolean> {
    const url = new URL(origin);
    return new Promise((resolve, reject) => {
      const request = (url.protocol === "https:" ? https : http).request(
        {
          hostname: "127.0.0.1",
          port: url.port || (url.protocol === "https:" ? 443 : 80),
          path: "/health",
          method: "GET",
          headers: { Host: url.host },
          servername: url.hostname,
          ca,
          agent: false,
          signal: this.abort.signal,
        },
        (response) => {
          let body = "";
          response.setEncoding("utf8");
          response.on("data", (chunk) => {
            body += chunk;
            if (body.length > 16 * 1024)
              request.destroy(
                new Error("Unexpected dashboard health response"),
              );
          });
          response.on("error", reject);
          response.on("end", () => {
            clearTimeout(deadline);
            try {
              resolve(
                response.statusCode === 200 &&
                  JSON.parse(body).hostId === this.hostId,
              );
            } catch {
              resolve(false);
            }
          });
        },
      );
      const deadline = setTimeout(
        () => request.destroy(new Error("Portless health check timed out")),
        1000,
      );
      request.on("error", (error) => {
        clearTimeout(deadline);
        reject(error);
      });
      request.end();
    });
  }

  async stop(): Promise<void> {
    clearInterval(this.timer);
    this.abort.abort();
    this.origin = undefined;
    await this.task;
    // The static alias is intentionally reusable across restarts; never stop the shared proxy.
  }
}
