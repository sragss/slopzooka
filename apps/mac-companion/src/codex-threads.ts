import { spawn, type ChildProcess } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { stat } from "node:fs/promises";
import { ServiceError } from "./errors.js";
import type { Logger } from "./logger.js";
import { validCodexThreadId } from "./session-service-protocol.js";

export type CodexThread = {
  id: string;
  title: string;
  cwd: string;
  updatedAt: number;
  available: boolean;
};

// Resolve through the same interactive login shell as the terminal launcher.
// Only the configured command is shell code; every RPC/CLI argument stays quoted.
export const CODEX_EXEC = String.raw`slz_codex_command=$1; shift; eval "exec $slz_codex_command \"\$@\""`;

/** Metadata only. Codex owns its history format, indexing, and migrations. */
export class CodexThreads {
  private listing?: Promise<CodexThread[]>;
  private readonly children = new Map<ChildProcess, () => void>();
  private stopped = false;

  constructor(
    private readonly logger: Logger,
    private readonly environment: NodeJS.ProcessEnv = process.env,
    private readonly timeoutMs = 20_000,
  ) {}

  list(): Promise<CodexThread[]> {
    return (this.listing ??= this.request("thread/list", {
      limit: 25,
      sortKey: "updated_at",
      sortDirection: "desc",
      archived: false,
      modelProviders: [],
      sourceKinds: ["cli", "vscode", "appServer", "exec"],
    })
      .then(async (result) => {
        if (!Array.isArray(result.data)) throw this.unavailable();
        const threads = await Promise.all(
          result.data
            .slice(0, 25)
            .map((thread: unknown) => this.summary(thread)),
        );
        const unique = new Map(threads.map((thread) => [thread.id, thread]));
        this.logger.info("catalog.loaded", { count: unique.size });
        return [...unique.values()];
      })
      .finally(() => {
        this.listing = undefined;
      }));
  }

  async read(id: string): Promise<CodexThread> {
    if (!validCodexThreadId(id))
      throw new ServiceError("Invalid Codex thread ID", 400);
    const result = await this.request("thread/read", {
      threadId: id,
      includeTurns: false,
    });
    const thread = await this.summary(result.thread);
    if (thread.id !== id) throw this.unavailable();
    if (!thread.available)
      throw new ServiceError(
        "This thread’s folder is missing on the Mac.",
        409,
      );
    return thread;
  }

  stop(): void {
    this.stopped = true;
    for (const cancel of this.children.values()) cancel();
  }

  private unavailable(): ServiceError {
    return new ServiceError(
      "Codex threads are unavailable. Check the Codex installation and configuration on your Mac, then refresh.",
      503,
    );
  }

  private async summary(value: unknown): Promise<CodexThread> {
    const thread = value as
      | (Partial<CodexThread> & {
          name?: unknown;
          preview?: unknown;
          ephemeral?: unknown;
        })
      | null;
    if (
      !thread ||
      !validCodexThreadId(thread.id) ||
      typeof thread.cwd !== "string" ||
      !path.isAbsolute(thread.cwd) ||
      thread.cwd.includes("\0") ||
      typeof thread.updatedAt !== "number" ||
      !Number.isFinite(thread.updatedAt) ||
      thread.ephemeral === true
    )
      throw this.unavailable();
    const title = [thread.name, thread.preview].find(
      (text) => typeof text === "string" && text.trim(),
    ) as string | undefined;
    return {
      id: thread.id,
      title:
        Array.from(
          (title ?? "Codex thread")
            .split(/\r?\n/, 1)[0]!
            .replace(/\p{Cc}/gu, " ")
            .trim(),
        )
          .slice(0, 80)
          .join("") || "Codex thread",
      cwd: thread.cwd,
      updatedAt: thread.updatedAt,
      available: await stat(thread.cwd).then(
        (info) => info.isDirectory(),
        () => false,
      ),
    };
  }

  private request(
    method: string,
    params: Record<string, unknown>,
  ): Promise<Record<string, unknown>> {
    if (this.stopped) return Promise.reject(this.unavailable());
    if (this.children.size >= 4)
      return Promise.reject(
        new ServiceError("Codex is busy. Try again shortly.", 503),
      );
    return new Promise((resolve, reject) => {
      const child = spawn(
        this.environment.SHELL ?? os.userInfo().shell ?? "/bin/zsh",
        [
          "-lic",
          CODEX_EXEC,
          "slopzooka-codex",
          this.environment.SLOPZOOKA_CODEX_COMMAND ?? "codex",
          "app-server",
          "--listen",
          "stdio://",
        ],
        {
          cwd: os.homedir(),
          env: this.environment,
          stdio: ["pipe", "pipe", "ignore"],
        },
      );
      let buffer = "",
        bytes = 0,
        settled = false;
      const finish = (
        error?: ServiceError,
        result?: Record<string, unknown>,
      ) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        this.children.delete(child);
        child.stdin.end();
        // Closing stdin retires the reader normally; bound cleanup if Codex stalls.
        child.kill("SIGTERM");
        const kill = setTimeout(() => child.kill("SIGKILL"), 1000);
        kill.unref();
        child.once("exit", () => clearTimeout(kill));
        if (error) {
          this.logger.warn("catalog.failed", {
            method,
            status: error.statusCode,
          });
          reject(error);
        } else resolve(result!);
      };
      const timer = setTimeout(
        () => finish(this.unavailable()),
        this.timeoutMs,
      );
      this.children.set(child, () => finish(this.unavailable()));
      child.on("error", () => finish(this.unavailable()));
      child.stdin.on("error", () => finish(this.unavailable()));
      child.once("exit", () => finish(this.unavailable()));
      child.stdout.setEncoding("utf8");
      const send = (message: unknown) =>
        child.stdin.write(JSON.stringify(message) + "\n");
      child.stdout.on("data", (data: string) => {
        bytes += Buffer.byteLength(data);
        if (bytes > 4 * 1024 * 1024) return finish(this.unavailable());
        buffer += data;
        let newline: number;
        while (!settled && (newline = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, newline);
          buffer = buffer.slice(newline + 1);
          let message: {
            id?: number;
            error?: unknown;
            result?: Record<string, unknown>;
          };
          try {
            message = JSON.parse(line) as typeof message;
          } catch {
            continue;
          } // Shell startup chatter is not protocol traffic.
          if (!message || (message.id !== 1 && message.id !== 2)) continue;
          if (
            message.error ||
            !message.result ||
            typeof message.result !== "object"
          )
            return finish(this.unavailable());
          if (message.id === 1) {
            send({ method: "initialized", params: {} });
            send({ id: 2, method, params });
          } else finish(undefined, message.result);
        }
      });
      send({
        id: 1,
        method: "initialize",
        params: {
          clientInfo: {
            name: "slopzooka",
            title: "SlopZooka",
            version: "0.2.0",
          },
        },
      });
    });
  }
}
