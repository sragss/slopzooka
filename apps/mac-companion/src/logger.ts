import fs from "node:fs";
import os from "node:os";
import path from "node:path";

type LogLevel = "info" | "warn" | "error";
type LogFields = Record<string, unknown>;

export type Logger = {
  readonly logDir: string;
  readonly logFilePath: string;
  info(message: string, fields?: LogFields): void;
  warn(message: string, fields?: LogFields): void;
  error(message: string, fields?: LogFields): void;
};

export function createLogger(appName: string, fileName: string): Logger {
  const logDir = resolveLogDir(appName);
  fs.mkdirSync(logDir, { recursive: true });

  const logFilePath = path.join(logDir, fileName);
  const stream = fs.createWriteStream(logFilePath, {
    flags: "a",
    encoding: "utf8",
  });

  const logger: Logger = {
    logDir,
    logFilePath,
    info(message, fields) {
      write("info", message, fields);
    },
    warn(message, fields) {
      write("warn", message, fields);
    },
    error(message, fields) {
      write("error", message, fields);
    },
  };

  return logger;

  function write(
    level: LogLevel,
    message: string,
    fields: LogFields = {},
  ): void {
    const entry = {
      ts: new Date().toISOString(),
      level,
      message,
      ...fields,
    };

    const line = `${JSON.stringify(entry)}\n`;
    stream.write(line);

    const consoleMethod =
      level === "error"
        ? console.error
        : level === "warn"
          ? console.warn
          : console.log;
    consoleMethod(`[slopzooka] ${message}`, fields);
  }
}

function resolveLogDir(appName: string): string {
  const override = process.env.SLOPZOOKA_LOG_DIR?.trim();
  if (override) {
    return path.resolve(override);
  }

  return path.join(os.homedir(), "Library", "Logs", appName);
}
