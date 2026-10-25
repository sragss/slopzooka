import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import path from "node:path";
import http from "node:http";
import https from "node:https";

export type Frontend = {
  id: string;
  hostname: string;
  title: string;
  port: number;
  url: string;
  source: "portless" | "local" | "manual";
  status: "registered" | "ready" | "starting" | "stopped";
  transport: "lan" | "gateway" | "direct";
};
export type FrontendRoute = {
  frontend: Frontend;
  target: string;
  caPath?: string;
};
export type LocalListener = {
  pid: number;
  command: string;
  cwd?: string;
  host: string;
  port: number;
};
const exec = promisify(execFile);

/** Machine-readable lsof output; no shell parsing, common-port list, or privileged scan. */
export function parseListeners(output: string): LocalListener[] {
  const listeners = new Map<string, LocalListener>();
  let pid = 0,
    command = "App",
    family = "IPv4";
  for (const line of output.split("\n")) {
    if (line.startsWith("p")) pid = Number(line.slice(1));
    if (line.startsWith("c")) command = line.slice(1);
    if (line.startsWith("t")) family = line.slice(1);
    if (!line.startsWith("n")) continue;
    const address = line.slice(1);
    const colon = address.lastIndexOf(":");
    let host = address.slice(0, colon).replace(/^\[|\]$/g, "");
    const port = Number(address.slice(colon + 1));
    if (
      colon < 0 ||
      !pid ||
      !Number.isInteger(port) ||
      port < 1 ||
      port > 65535
    )
      continue;
    if (host === "*") host = family === "IPv6" ? "::1" : "127.0.0.1";
    if (host === "0.0.0.0") host = "127.0.0.1";
    if (host === "::") host = "::1";
    const key = `${pid}:${port}`;
    // Prefer IPv4 when one process listens on both families; keep IPv6-only servers.
    if (listeners.get(key)?.host !== "127.0.0.1")
      listeners.set(key, { pid, command, host, port });
  }
  return [...listeners.values()];
}
export async function localListeners(): Promise<LocalListener[]> {
  try {
    const { stdout } = await exec(
      "/usr/sbin/lsof",
      [
        "-nP",
        "-a",
        "-u",
        String(process.getuid!()),
        "-iTCP",
        "-sTCP:LISTEN",
        "-Fpcnt",
      ],
      { timeout: 3000, maxBuffer: 1024 * 1024 },
    );
    const listeners = parseListeners(stdout);
    const pids = [...new Set(listeners.map((listener) => listener.pid))].slice(
      0,
      128,
    );
    if (pids.length) {
      try {
        const { stdout: directories } = await exec(
          "/usr/sbin/lsof",
          ["-a", "-p", pids.join(","), "-d", "cwd", "-Fn"],
          { timeout: 1500, maxBuffer: 1024 * 1024 },
        );
        let pid = 0;
        const cwd = new Map<number, string>();
        for (const line of directories.split("\n")) {
          if (line.startsWith("p")) pid = Number(line.slice(1));
          if (line.startsWith("n/")) cwd.set(pid, line.slice(1));
        }
        for (const listener of listeners) listener.cwd = cwd.get(listener.pid);
      } catch {
        /* Process names are sufficient if a working directory is inaccessible. */
      }
    }
    return listeners;
  } catch (error) {
    const result = error as { code?: number; stdout?: string; stderr?: string };
    // lsof exits 1 when no descriptors match.
    if (result.code === 1 && !result.stderr?.trim())
      return parseListeners(result.stdout ?? "");
    throw new Error(
      "Could not discover local servers. You can still add a URL.",
    );
  }
}

/** HEAD only, no redirects/body buffering. Any HTTP response proves a web server is present. */
export function probeHTTP(url: string): Promise<boolean> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (ok: boolean) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      request.destroy();
      resolve(ok);
    };
    const request = (url.startsWith("https:") ? https : http).request(
      url,
      {
        method: "HEAD",
        agent: false,
        headers: { "User-Agent": "SlopZooka-Discovery" },
      },
      (response) => {
        response.destroy();
        finish(true);
      },
    );
    const timer = setTimeout(() => finish(false), 800);
    request.on("error", () => finish(false));
    request.end();
  });
}

export async function readPortless(
  stateDir: string,
): Promise<{ routes: FrontendRoute[]; ports: Set<number> }> {
  const optional = async (name: string) => {
    try {
      return (await fs.readFile(path.join(stateDir, name), "utf8")).trim();
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw error;
    }
  };
  const contents = await optional("routes.json");
  if (contents === undefined) return { routes: [], ports: new Set() };
  const raw: unknown = JSON.parse(contents);
  if (!Array.isArray(raw)) throw new Error("Unsupported Portless route schema");
  const port = Number(await optional("proxy.port"));
  if (!Number.isInteger(port) || port < 1 || port > 65535)
    throw new Error("Invalid Portless proxy port");
  const marker = await optional("proxy.tls");
  if (marker !== undefined && marker !== "0" && marker !== "1")
    throw new Error("Invalid Portless TLS marker");
  const tls = marker === "1";
  const lan = await optional("proxy.lan");
  if (lan === "") throw new Error("Invalid Portless LAN marker");
  const routes: FrontendRoute[] = [];
  const ports = new Set([port]);
  const names = new Set<string>();
  for (const route of raw) {
    if (
      !route ||
      typeof route.hostname !== "string" ||
      !/^[a-z0-9][a-z0-9.-]{0,252}$/.test(route.hostname) ||
      !Number.isInteger(route.port) ||
      route.port < 1 ||
      route.port > 65535 ||
      !Number.isInteger(route.pid) ||
      route.pid < 0
    )
      throw new Error("Unsupported Portless route record");
    if (names.has(route.hostname))
      throw new Error("Duplicate Portless hostname");
    names.add(route.hostname);
    if (route.pid !== 0) {
      try {
        process.kill(route.pid, 0);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ESRCH") continue;
      }
    }
    ports.add(route.port);
    const url = new URL(
      `${tls ? "https" : "http"}://${route.hostname}:${port}`,
    );
    routes.push({
      frontend: {
        id: route.hostname,
        hostname: route.hostname,
        title: route.hostname,
        port: route.port,
        url: url.href,
        source: "portless",
        status: "registered",
        transport:
          lan !== undefined && route.hostname.endsWith(".local")
            ? "lan"
            : "gateway",
      },
      target: `${url.protocol}//127.0.0.1:${port}`,
      caPath: tls ? path.join(stateDir, "ca.pem") : undefined,
    });
  }
  return { routes, ports };
}
