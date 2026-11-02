import { spawn } from "node:child_process";

import type { Logger } from "./logger.js";

export const SLOPZOOKA_BONJOUR_TYPE = "slopzooka";

type BonjourAdvertiserOptions = {
  logger: Logger;
  name: string;
  port: number;
  hostId: string;
};

export type BonjourAdvertiser = {
  stop: () => Promise<void>;
};

// Register through mDNSResponder, which owns the Mac's hostname and per-interface
// address records. The private stdin pipe is also a lifeline: EOF unregisters the
// service even if the companion crashes or is killed without running shutdown.
const registration = `
exec 3<&0
/usr/bin/dns-sd "$@" 3<&- &
registrar=$!
lifeline=
cleanup() {
  trap - EXIT
  kill "$registrar" \${lifeline:+"$lifeline"} 2>/dev/null || :
  wait "$registrar" \${lifeline:+"$lifeline"} 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
(read -r unused <&3; kill "$registrar" 2>/dev/null) &
lifeline=$!
exec 3<&-
wait "$registrar"
`;

export function startBonjourAdvertiser(
  options: BonjourAdvertiserOptions,
): BonjourAdvertiser {
  const fields = {
    serviceType: `_${SLOPZOOKA_BONJOUR_TYPE}._tcp`,
    serviceName: options.name,
    port: options.port,
  };
  const child = spawn(
    "/bin/sh",
    [
      "-c",
      registration,
      "slopzooka-bonjour",
      "-R",
      options.name,
      fields.serviceType,
      "local.",
      String(options.port),
      "name=SlopZooka",
      "version=0.2.0",
      `hostId=${options.hostId}`,
    ],
    { stdio: ["pipe", "pipe", "pipe"] },
  );
  let stopping = false;
  let advertised = false;
  let output = "";
  let errors = "";
  let stop: Promise<void> | undefined;
  child.stdout.setEncoding("utf8").on("data", (chunk: string) => {
    output = (output + chunk).slice(-4096);
    if (
      !stopping &&
      !advertised &&
      output.includes("Name now registered and active")
    ) {
      advertised = true;
      options.logger.info("Bonjour service advertised", fields);
    }
  });
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => {
    errors = (errors + chunk).slice(-4096);
  });
  // Ending the lifeline after an early registration failure can encounter EPIPE.
  child.stdin.on("error", () => {});
  child.on("error", (error) => {
    options.logger.error("Bonjour service error", {
      ...fields,
      error: error.message,
    });
  });
  const closed = new Promise<void>((resolve) => {
    child.once("close", (code, signal) => {
      if (!stopping)
        options.logger.error("Bonjour service stopped unexpectedly", {
          ...fields,
          code,
          signal,
          error: errors.trim(),
        });
      resolve();
    });
  });

  return {
    stop: () => {
      if (stop) return stop;
      stopping = true;
      stop = (async () => {
        child.stdin.end();
        await closed;
        options.logger.info("Bonjour service stopped", fields);
      })();
      return stop;
    },
  };
}
