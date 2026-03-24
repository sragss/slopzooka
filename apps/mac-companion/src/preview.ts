import http from "node:http";
import https from "node:https";
import { URL } from "node:url";

import httpProxy, { type ErrorCallback } from "http-proxy";

import type { Logger } from "./logger.js";

const DEFAULT_SCAN_PORTS = [3000, 3001, 3002, 4173, 4174, 5173, 5174, 8000, 8080, 4321, 4200, 4000];
const PREVIEW_PORT_START = Number(process.env.SLOPZOOKA_PREVIEW_PORT_START ?? "7801");
const PREVIEW_PORT_END = Number(process.env.SLOPZOOKA_PREVIEW_PORT_END ?? "7899");
const LOOPBACK_HOST = "127.0.0.1";

export type PreviewCandidate = {
  port: number;
  statusCode: number;
  title: string | null;
  frameworkHint: string | null;
};

export type OpenPreviewResult = {
  clusterId: string;
  targetPort: number;
  exposedPort: number;
  title: string;
  frameworkHint: string | null;
};

type PreviewProxyRecord = {
  clusterId: string;
  targetPort: number;
  exposedPort: number;
  server: http.Server;
  proxy: httpProxy;
};

export class PreviewManager {
  private readonly proxies = new Map<string, PreviewProxyRecord>();

  constructor(private readonly logger: Logger) {}

  async scanCandidates(): Promise<PreviewCandidate[]> {
    const probeResults = await Promise.all(
      DEFAULT_SCAN_PORTS.map(async (port) => probeDevServer(port))
    );

    const candidates = probeResults
      .filter((candidate): candidate is PreviewCandidate => candidate !== null)
      .sort((lhs, rhs) => compareCandidates(lhs, rhs));

    this.logger.info("Preview scan completed", {
      candidateCount: candidates.length,
      ports: candidates.map((candidate) => candidate.port)
    });

    return candidates;
  }

  async openPreview(clusterId: string, requestedPort?: number): Promise<OpenPreviewResult> {
    const candidates = await this.scanCandidates();
    const selected = selectCandidate(candidates, requestedPort);
    if (!selected) {
      throw new Error("No reachable localhost previews found.");
    }

    const key = previewKey(clusterId, selected.port);
    const existing = this.proxies.get(key);
    if (existing) {
      return {
        clusterId,
        targetPort: existing.targetPort,
        exposedPort: existing.exposedPort,
        title: selected.title ?? defaultPreviewTitle(selected.port, selected.frameworkHint),
        frameworkHint: selected.frameworkHint
      };
    }

    const exposedPort = await this.reserveExposedPort();
    const target = new URL(`http://${LOOPBACK_HOST}:${selected.port}`);
    const proxy = httpProxy.createProxyServer({
      target,
      changeOrigin: true,
      ws: true,
      xfwd: true
    });

    proxy.on("error", ((error, _req, res) => {
      this.logger.error("Preview proxy error", {
        clusterId,
        targetPort: selected.port,
        exposedPort,
        error: error instanceof Error ? error.message : String(error)
      });

      if (res && "writeHead" in res && "end" in res) {
        if (!res.headersSent) {
          res.writeHead(502, { "Content-Type": "text/plain; charset=utf-8" });
        }
        res.end("SlopZooka preview proxy could not reach the local dev server.");
      }
    }) as ErrorCallback);

    const server = http.createServer((req, res) => {
      proxy.web(req, res);
    });

    server.on("upgrade", (req, socket, head) => {
      proxy.ws(req, socket, head);
    });

    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(
        {
          port: exposedPort,
          host: "::",
          ipv6Only: false
        },
        () => {
          server.off("error", reject);
          resolve();
        }
      );
    });

    const record: PreviewProxyRecord = {
      clusterId,
      targetPort: selected.port,
      exposedPort,
      server,
      proxy
    };
    this.proxies.set(key, record);

    this.logger.info("Preview proxy opened", {
      clusterId,
      targetPort: selected.port,
      exposedPort
    });

    return {
      clusterId,
      targetPort: selected.port,
      exposedPort,
      title: selected.title ?? defaultPreviewTitle(selected.port, selected.frameworkHint),
      frameworkHint: selected.frameworkHint
    };
  }

  async stop(): Promise<void> {
    const records = Array.from(this.proxies.values());
    this.proxies.clear();

    await Promise.all(
      records.map(
        (record) =>
          new Promise<void>((resolve) => {
            record.proxy.close?.();
            record.server.close(() => resolve());
          })
      )
    );
  }

  private async reserveExposedPort(): Promise<number> {
    for (let port = PREVIEW_PORT_START; port <= PREVIEW_PORT_END; port += 1) {
      if (Array.from(this.proxies.values()).some((record) => record.exposedPort == port)) {
        continue;
      }

      const available = await canListenOnPort(port);
      if (available) {
        return port;
      }
    }

    throw new Error("No preview proxy ports are available.");
  }
}

function previewKey(clusterId: string, targetPort: number): string {
  return `${clusterId}:${targetPort}`;
}

function selectCandidate(candidates: PreviewCandidate[], requestedPort?: number): PreviewCandidate | null {
  if (requestedPort) {
    return candidates.find((candidate) => candidate.port === requestedPort) ?? null;
  }

  return candidates[0] ?? null;
}

function compareCandidates(lhs: PreviewCandidate, rhs: PreviewCandidate): number {
  const lhsRank = portRank(lhs.port);
  const rhsRank = portRank(rhs.port);
  if (lhsRank !== rhsRank) {
    return lhsRank - rhsRank;
  }

  if (lhs.frameworkHint !== rhs.frameworkHint) {
    return (lhs.frameworkHint ? 0 : 1) - (rhs.frameworkHint ? 0 : 1);
  }

  return lhs.port - rhs.port;
}

function portRank(port: number): number {
  const index = DEFAULT_SCAN_PORTS.indexOf(port);
  return index === -1 ? Number.MAX_SAFE_INTEGER : index;
}

function defaultPreviewTitle(port: number, frameworkHint: string | null): string {
  if (frameworkHint) {
    return `${frameworkHint} preview • :${port}`;
  }

  return `Preview • :${port}`;
}

async function probeDevServer(port: number): Promise<PreviewCandidate | null> {
  try {
    const result = await fetchText(`http://${LOOPBACK_HOST}:${port}/`);
    if (result.statusCode >= 500) {
      return null;
    }

    return {
      port,
      statusCode: result.statusCode,
      title: extractHTMLTitle(result.body),
      frameworkHint: detectFrameworkHint(result.headers, result.body)
    };
  } catch {
    return null;
  }
}

async function fetchText(url: string): Promise<{
  statusCode: number;
  headers: Record<string, string | string[] | undefined>;
  body: string;
}> {
  const parsed = new URL(url);
  const transport = parsed.protocol === "https:" ? https : http;

  return new Promise((resolve, reject) => {
    const request = transport.request(
      parsed,
      {
        method: "GET",
        headers: {
          "User-Agent": "SlopZooka/0.1.0",
          Accept: "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8"
        }
      },
      (response) => {
        const chunks: Buffer[] = [];
        response.on("data", (chunk) => {
          chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
        });
        response.on("end", () => {
          const body = Buffer.concat(chunks).toString("utf8");
          resolve({
            statusCode: response.statusCode ?? 0,
            headers: response.headers,
            body
          });
        });
      }
    );

    request.setTimeout(700, () => {
      request.destroy(new Error("Timed out"));
    });
    request.on("error", reject);
    request.end();
  });
}

function extractHTMLTitle(body: string): string | null {
  const match = body.match(/<title[^>]*>(.*?)<\/title>/is);
  return match?.[1]?.replace(/\s+/g, " ").trim() || null;
}

function detectFrameworkHint(
  headers: Record<string, string | string[] | undefined>,
  body: string
): string | null {
  const serverHeader = headerValue(headers.server);
  const poweredBy = headerValue(headers["x-powered-by"]);
  const lowerBody = body.toLowerCase();

  if (poweredBy.includes("next") || lowerBody.includes("__next")) {
    return "Next.js";
  }

  if (serverHeader.includes("vite") || lowerBody.includes("/@vite/client") || lowerBody.includes("vite/client")) {
    return "Vite";
  }

  if (lowerBody.includes("astro")) {
    return "Astro";
  }

  if (lowerBody.includes("webpack")) {
    return "Webpack";
  }

  return null;
}

function headerValue(value: string | string[] | undefined): string {
  if (Array.isArray(value)) {
    return value.join(",").toLowerCase();
  }

  return (value ?? "").toLowerCase();
}

async function canListenOnPort(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const server = http.createServer();
    server.once("error", () => {
      resolve(false);
    });
    server.listen(
      {
        port,
        host: "::",
        ipv6Only: false
      },
      () => {
        server.close(() => resolve(true));
      }
    );
  });
}
