import fs from "node:fs/promises";
import { realpathSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import {
  boundedLogEvent,
  isLogEvent,
  type LogEvent,
} from "../../../packages/protocol/src/diagnostics.js";

export const LOG_RETENTION_MS = 24 * 60 * 60 * 1000;
export const LOG_ROLES = [
  "mac-companion",
  "session-service",
  "mac-menu",
] as const;
export type LogRole = (typeof LOG_ROLES)[number];
const MiB = 1024 * 1024;
const MAX_SEGMENT_BYTES = 4 * MiB;
const budgets: Record<LogRole, number> = {
  "mac-companion": 128 * MiB,
  "session-service": 112 * MiB,
  "mac-menu": 16 * MiB,
};

export function resolveLogDir(
  home = process.env.SLOPZOOKA_HOME ?? path.join(os.homedir(), ".slopzooka"),
): string {
  let canonical = path.resolve(home);
  try {
    canonical = realpathSync(canonical);
  } catch {
    /* First startup. */
  }
  return path.join(canonical, "logs");
}

export type LogStoreOptions = {
  directory?: string;
  home?: string;
  maxBytes?: number;
  segmentBytes?: number;
  queueBytes?: number;
  retentionMs?: number;
  now?: () => number;
};

/** One writer per role, matching the existing one-companion/service-per-home rule.
 * No open file descriptor crosses a rotation; other roles are never pruned here. */
export class LogStore {
  readonly directory: string;
  readonly file: string;
  private readonly roleDirectory: string;
  private readonly maxBytes: number;
  private readonly segmentBytes: number;
  private readonly queueLimit: number;
  private readonly retentionMs: number;
  private readonly now: () => number;
  private queue: string[] = [];
  private queuedBytes = 0;
  private writingBytes = 0;
  private task?: Promise<boolean>;
  private timer?: ReturnType<typeof setTimeout>;
  private gaps = 0;
  private gapSequence = 0;
  private readonly instanceId = randomUUID();
  private initialized = false;
  private totalDropped = 0;
  private writeFailures = 0;

  constructor(
    readonly role: LogRole,
    options: LogStoreOptions = {},
  ) {
    this.directory = options.directory ?? resolveLogDir(options.home);
    this.roleDirectory = path.join(this.directory, role);
    this.file = path.join(this.roleDirectory, "current.jsonl");
    this.maxBytes = options.maxBytes ?? budgets[role];
    this.segmentBytes = Math.min(
      options.segmentBytes ?? MAX_SEGMENT_BYTES,
      this.maxBytes,
      MAX_SEGMENT_BYTES,
    );
    this.queueLimit = options.queueBytes ?? MiB;
    this.retentionMs = options.retentionMs ?? LOG_RETENTION_MS;
    this.now = options.now ?? Date.now;
  }

  get status() {
    return { dropped: this.totalDropped, writeFailures: this.writeFailures };
  }

  append(event: LogEvent): boolean {
    const line = JSON.stringify(boundedLogEvent(event)) + "\n";
    const bytes = Buffer.byteLength(line);
    const limit =
      event.level === "error" || event.level === "warn"
        ? this.queueLimit
        : this.queueLimit * 0.75;
    if (
      bytes > this.segmentBytes ||
      this.queuedBytes + this.writingBytes + bytes > limit
    ) {
      this.gaps++;
      this.totalDropped++;
      return false;
    }
    this.queue.push(line);
    this.queuedBytes += bytes;
    if (!this.timer) {
      this.timer = setTimeout(() => {
        this.timer = undefined;
        void this.flush();
      }, 100);
      this.timer.unref();
    }
    return true;
  }

  async flush(): Promise<boolean> {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
    while (this.task || this.queue.length || this.gaps) {
      this.task ??= this.drain().finally(() => {
        this.task = undefined;
      });
      if (!(await this.task)) return false;
    }
    return true;
  }

  private async drain(): Promise<boolean> {
    let ok = true;
    while (this.queue.length || this.gaps) {
      const lines: string[] = [];
      let bytes = 0;
      let records = 0;
      const gaps = this.gaps;
      if (gaps) {
        const event: LogEvent = {
          version: 1,
          source: this.role,
          instanceId: this.instanceId,
          sequence: ++this.gapSequence,
          ts: new Date(this.now()).toISOString(),
          monotonicMs: performance.now(),
          level: "warn",
          component: "diagnostics",
          event: "logs.dropped",
          fields: { count: gaps },
        };
        const line = JSON.stringify(event) + "\n";
        lines.push(line);
        bytes += Buffer.byteLength(line);
        this.gaps = 0;
      }
      while (this.queue.length) {
        const line = this.queue[0]!,
          size = Buffer.byteLength(line);
        if (bytes + size > this.segmentBytes && lines.length) break;
        lines.push(this.queue.shift()!);
        records++;
        bytes += size;
        this.queuedBytes -= size;
      }
      this.writingBytes = bytes;
      try {
        await fs.mkdir(this.roleDirectory, { recursive: true, mode: 0o700 });
        const stat = await fs.stat(this.file).catch(() => undefined);
        const rotate =
          stat &&
          (!this.initialized ||
            stat.size + bytes > this.segmentBytes ||
            this.now() - stat.mtimeMs >= this.retentionMs ||
            this.now() - stat.birthtimeMs >= 15 * 60_000);
        if (rotate) {
          await fs.rename(
            this.file,
            path.join(
              this.roleDirectory,
              `${Math.floor(stat.mtimeMs)}-${randomUUID()}.jsonl`,
            ),
          );
        }
        if (!this.initialized || rotate) await this.prune();
        await fs.appendFile(this.file, lines.join(""), { mode: 0o600 });
        this.initialized = true;
      } catch {
        this.initialized = false;
        this.writeFailures++;
        this.gaps += gaps + records;
        this.totalDropped += records;
        ok = false;
        // Retry on the next flush, not in a hot loop on a full/unavailable disk.
        break;
      } finally {
        this.writingBytes = 0;
      }
    }
    return ok;
  }

  private async prune(): Promise<void> {
    const files = await segmentFiles(this.roleDirectory);
    // Every listed file is closed. Reserve a complete new segment so its
    // subsequent growth needs no pruning or cached disk accounting.
    let total = files.reduce((sum, file) => sum + file.size, this.segmentBytes);
    let count = files.length + 1;
    for (const file of files) {
      if (
        this.now() - file.modified <= this.retentionMs &&
        total <= this.maxBytes &&
        count <= 512
      )
        continue;
      await fs.rm(file.file, { force: true });
      total -= file.size;
      count--;
    }
  }
}

async function segmentFiles(directory: string) {
  const entries = await fs
    .readdir(directory, { withFileTypes: true })
    .catch((error) => {
      if (error.code === "ENOENT") return [];
      throw error;
    });
  const files = [];
  for (const entry of entries) {
    if (
      !entry.isFile() ||
      !/^(current|[0-9]+-[a-f0-9-]+)\.jsonl$/.test(entry.name)
    )
      continue;
    const file = path.join(directory, entry.name);
    const stat = await fs.stat(file).catch((error) => {
      if (error.code === "ENOENT") return undefined;
      throw error;
    });
    if (stat) files.push({ file, size: stat.size, modified: stat.mtimeMs });
  }
  return files.sort(
    (a, b) => a.modified - b.modified || a.file.localeCompare(b.file),
  );
}

// Read a snapshot of a managed segment, never an arbitrarily large/corrupt file.
async function readSegment(
  file: string,
): Promise<{ text: string; partial: boolean }> {
  const handle = await fs.open(file, "r");
  try {
    const { size } = await handle.stat();
    if (size > MAX_SEGMENT_BYTES) throw new Error("Oversized log segment");
    const buffer = Buffer.alloc(size);
    const { bytesRead } = await handle.read(buffer, 0, size, 0);
    if (bytesRead !== size) throw new Error("Incomplete log segment read");
    const end = buffer.lastIndexOf(10);
    return {
      text: end < 0 ? "" : buffer.subarray(0, end).toString("utf8"),
      partial: end !== size - 1,
    };
  } finally {
    await handle.close();
  }
}

/** Capture retained evidence without filtering on untrusted device clocks or
 * rewriting source order/identity. Timeline analysis belongs to the debugger. */
export async function captureLogs(
  directory: string,
  around = new Date().toISOString(),
  context: {
    hostId?: string;
    flushIncomplete?: boolean;
    storage?: { dropped: number; writeFailures: number };
  } = {},
) {
  const events: LogEvent[] = [];
  const producers = new Map<
    string,
    Pick<LogEvent, "source" | "instanceId" | "buildId" | "runtimeId">
  >();
  const unavailable: LogRole[] = [];
  const files = [];
  let truncated = false,
    partialSegments = 0,
    malformedRecords = 0,
    bytes = 0;
  for (const role of LOG_ROLES) {
    try {
      const segments = await segmentFiles(path.join(directory, role));
      // The fatal-error fallback is a single bounded record, independent of the
      // structured writer and its initialization/rotation.
      const bootstrap = path.join(directory, role, "bootstrap.jsonl");
      const stat = await fs.stat(bootstrap).catch(() => undefined);
      if (stat && Date.now() - stat.mtimeMs <= LOG_RETENTION_MS)
        segments.push({
          file: bootstrap,
          size: stat.size,
          modified: stat.mtimeMs,
        });
      if (!segments.length) unavailable.push(role);
      files.push(...segments.map((file) => ({ ...file, role })));
    } catch {
      unavailable.push(role);
    }
  }
  for (const file of files
    .sort((a, b) => b.modified - a.modified)
    .slice(0, 512)) {
    try {
      const segment = await readSegment(file.file);
      if (segment.partial) partialSegments++;
      for (const line of segment.text.split("\n")) {
        if (!line) continue;
        let event: unknown;
        try {
          event = JSON.parse(line);
        } catch {
          malformedRecords++;
          continue;
        }
        if (!isLogEvent(event)) {
          malformedRecords++;
          continue;
        }
        // Reserve space for the manifest. Newest files win when the capture cap
        // is reached; raw timestamps and duplicate retry identities survive.
        const size = Buffer.byteLength(line) + 1;
        if (bytes + size > 32 * MiB - 256 * 1024) {
          truncated = true;
          continue;
        }
        bytes += size;
        events.push(event);
        const key = `${event.source}:${event.instanceId}`;
        if (producers.size < 256 || producers.has(key))
          producers.set(key, {
            source: event.source,
            instanceId: event.instanceId,
            buildId: event.buildId,
            runtimeId: event.runtimeId,
          });
        else truncated = true;
      }
    } catch {
      if (!unavailable.includes(file.role)) unavailable.push(file.role);
    }
  }
  const reportId = randomUUID();
  const report = {
    version: 1,
    reportId,
    capturedAt: new Date().toISOString(),
    around,
    ...context,
    coverage: {
      retentionHours: 24,
      truncated: truncated || files.length > 512,
      unavailable,
      partialSegments,
      malformedRecords,
      missingBuilds: [...producers.values()]
        .filter((p) => !p.buildId || p.buildId === "unknown")
        .map((p) => p.instanceId),
      notes:
        "Best-effort retained evidence; offline client buffers, forced termination and capacity limits can leave gaps. Clock observations describe upload-time calibration; earlier clock changes are unknown. Events are unsorted and retries may repeat identities.",
    },
    producers: [...producers.values()],
    events,
  };
  const data = JSON.stringify(report);
  const reportDirectory = path.join(directory, "reports");
  await fs.mkdir(reportDirectory, { recursive: true, mode: 0o700 });
  const existing = [];
  for (const file of await fs.readdir(reportDirectory, {
    withFileTypes: true,
  })) {
    // A crash between writing and renaming a report must not leave temporary
    // exports outside the budget.
    if (!file.isFile() || !/^[a-f0-9-]+\.json(?:\.tmp)?$/.test(file.name))
      continue;
    const name = path.join(reportDirectory, file.name),
      stat = await fs.stat(name);
    existing.push({ file: name, modified: stat.mtimeMs, size: stat.size });
  }
  let total = existing.reduce(
      (sum, file) => sum + file.size,
      Buffer.byteLength(data),
    ),
    count = existing.length;
  for (const file of existing.sort((a, b) => a.modified - b.modified)) {
    if (
      Date.now() - file.modified <= 7 * LOG_RETENTION_MS &&
      total <= 64 * MiB &&
      count < 128
    )
      continue;
    await fs.rm(file.file, { force: true });
    total -= file.size;
    count--;
  }
  const file = path.join(reportDirectory, `${reportId}.json`),
    temporary = `${file}.tmp`;
  try {
    await fs.writeFile(temporary, data, { mode: 0o600 });
    await fs.rename(temporary, file);
  } finally {
    await fs.rm(temporary, { force: true });
  }
  const { events: _, ...manifest } = report;
  return manifest;
}
