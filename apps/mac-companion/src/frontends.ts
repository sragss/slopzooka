import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import https from "node:https";
import { lookup } from "node:dns/promises";
import type { Socket } from "node:net";
import httpProxy from "http-proxy";
import type { Logger } from "./logger.js";
import { ServiceError } from "./errors.js";
import {
  localListeners,
  probeHTTP,
  readPortless,
  type Frontend,
  type FrontendRoute,
  type LocalListener,
} from "./frontend-discovery.js";
export type { Frontend } from "./frontend-discovery.js";
type Catalog = { frontends: Frontend[]; warning: string | null };
type ProxyRecord = {
  server: http.Server;
  proxy: httpProxy;
  sockets: Set<Socket>;
  exposedPort: number;
  token: string;
  routeKey: string;
  agent?: https.Agent;
};
type Options = {
  listeners?: () => Promise<LocalListener[]>;
  home?: string;
  stateDir?: string;
};
type Bookmark = { url: string; target: string; local: boolean };

/** Discovery sources produce routes; all local routes share the same gateway lifecycle. */
export class FrontendService {
  private catalog: Catalog = { frontends: [], warning: null };
  private routes = new Map<string, FrontendRoute>();
  private portless: FrontendRoute[] = [];
  private portlessPorts = new Set<number>();
  private local = new Map<string, { route: FrontendRoute; lastSeen: number }>();
  private readonly proxies = new Map<string, ProxyRecord>();
  private operation: Promise<unknown> = Promise.resolve();
  private stopTask?: Promise<void>;
  private refreshTask?: Promise<Catalog>;
  private stopping = false;
  private readonly stateDir: string;
  private readonly bookmarksPath: string;
  private readonly listeners: () => Promise<LocalListener[]>;
  constructor(
    private readonly logger: Logger,
    options: Options = {},
  ) {
    this.stateDir =
      options.stateDir ??
      process.env.PORTLESS_STATE_DIR ??
      path.join(os.homedir(), ".portless");
    this.bookmarksPath = path.join(
      options.home ??
        process.env.SLOPZOOKA_HOME ??
        path.join(os.homedir(), ".slopzooka"),
      "frontends.json",
    );
    this.listeners = options.listeners ?? localListeners;
  }
  private enqueue<T>(work: () => Promise<T>): Promise<T> {
    const next = this.operation.then(work);
    this.operation = next.catch(() => undefined);
    return next;
  }
  getCatalog(): Promise<Catalog> {
    if (!this.refreshTask)
      this.refreshTask = this.enqueue(() =>
        this.stopping ? Promise.resolve(this.catalog) : this.refresh(),
      ).finally(() => {
        this.refreshTask = undefined;
      });
    return this.refreshTask;
  }
  private async bookmarks(): Promise<Bookmark[]> {
    try {
      const entries: unknown = JSON.parse(
        await fs.readFile(this.bookmarksPath, "utf8"),
      );
      if (
        !Array.isArray(entries) ||
        entries.length > 100 ||
        entries.some(
          (entry) =>
            !entry ||
            typeof entry.url !== "string" ||
            typeof entry.target !== "string" ||
            typeof entry.local !== "boolean" ||
            !this.validURL(entry.url) ||
            !this.validURL(entry.target),
        )
      )
        throw new Error("Invalid saved frontend URLs");
      return entries;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
      throw error;
    }
  }
  private validURL(value: string): URL | undefined {
    try {
      const url = new URL(value);
      if (
        value.length <= 2048 &&
        ["http:", "https:"].includes(url.protocol) &&
        !url.username &&
        !url.password
      )
        return url;
    } catch {
      /* Invalid user input. */
    }
    return undefined;
  }
  private manualRoute(bookmark: Bookmark): FrontendRoute {
    const url = new URL(bookmark.url);
    return {
      frontend: {
        id: `manual:${crypto.createHash("sha256").update(url.href).digest("hex").slice(0, 24)}`,
        hostname: url.hostname,
        title: url.host + (url.pathname === "/" ? "" : url.pathname),
        url: url.href,
        port: Number(url.port || (url.protocol === "https:" ? 443 : 80)),
        source: "manual",
        status: "registered",
        transport: bookmark.local ? "gateway" : "direct",
      },
      target: bookmark.target,
    };
  }
  private async saveBookmarks(entries: Bookmark[]): Promise<void> {
    this.requireRunning();
    await fs.mkdir(path.dirname(this.bookmarksPath), { recursive: true });
    const temporary = `${this.bookmarksPath}.${crypto.randomUUID()}.tmp`;
    try {
      await fs.writeFile(temporary, JSON.stringify(entries, null, 2), {
        mode: 0o600,
      });
      await fs.rename(temporary, this.bookmarksPath);
    } finally {
      await fs.rm(temporary, { force: true });
    }
  }
  addURL(value: string): Promise<Frontend> {
    return this.enqueue(async () => {
      this.requireRunning();
      const url = this.validURL(value.trim());
      if (!url)
        throw new ServiceError(
          "Enter an http:// or https:// URL without embedded credentials",
          400,
        );
      const host = url.hostname.replace(/^\[|\]$/g, "");
      const isLoopback =
        host === "localhost" ||
        host.endsWith(".localhost") ||
        host === "::1" ||
        /^127\./.test(host);
      let addresses: string[] = [];
      if (!isLoopback) {
        let timer: NodeJS.Timeout | undefined;
        try {
          const resolved = await Promise.race([
            lookup(host, { all: true }),
            new Promise<never>((_, reject) => {
              timer = setTimeout(
                () => reject(new Error("DNS lookup timed out")),
                1500,
              );
            }),
          ]);
          addresses = resolved.map((entry) => entry.address);
        } catch {
          /* Remote names may resolve only on the headset's network. */
        } finally {
          clearTimeout(timer);
        }
      }
      const localAddresses = new Set(
        Object.values(os.networkInterfaces()).flatMap(
          (items) => items?.map((item) => item.address) ?? [],
        ),
      );
      const local =
        isLoopback ||
        addresses.some(
          (address) =>
            localAddresses.has(address) ||
            address === "::1" ||
            /^127\./.test(address),
        );
      const target = new URL(url.origin);
      if (isLoopback && host !== "::1") target.hostname = "127.0.0.1";
      const port = Number(url.port || (url.protocol === "https:" ? 443 : 80));
      if (
        local &&
        (port === Number(process.env.SLOPZOOKA_PORT ?? 7777) ||
          [...this.proxies.values()].some(
            (record) => record.exposedPort === port,
          ))
      )
        throw new ServiceError(
          "Use an app URL, not a SlopZooka control or preview URL",
          400,
        );
      const entries = await this.bookmarks();
      const bookmark = { url: url.href, target: target.origin, local };
      if (!entries.some((entry) => entry.url === bookmark.url)) {
        if (entries.length >= 100)
          throw new ServiceError(
            "Remove a saved URL before adding another",
            409,
          );
        entries.push(bookmark);
        await this.saveBookmarks(entries);
      }
      await this.refresh();
      return this.manualRoute(bookmark).frontend;
    });
  }
  removeURL(id: string): Promise<void> {
    return this.enqueue(async () => {
      this.requireRunning();
      const entries = await this.bookmarks();
      await this.saveBookmarks(
        entries.filter((entry) => this.manualRoute(entry).frontend.id !== id),
      );
      await this.refresh();
    });
  }
  private async discoverLocal(): Promise<void> {
    const listeners = (await this.listeners()).filter(
      (listener) =>
        listener.pid !== process.pid &&
        !this.portlessPorts.has(listener.port) &&
        listener.port !== Number(process.env.SLOPZOOKA_PORT ?? 7777) &&
        ![...this.proxies.values()].some(
          (record) => record.exposedPort === listener.port,
        ),
    );
    if (listeners.length > 128)
      throw new Error(
        "Too many local listeners to discover automatically. Add the app URL instead.",
      );
    const now = Date.now();
    const found = new Set<string>();
    let index = 0;
    await Promise.all(
      Array.from({ length: Math.min(8, listeners.length) }, async () => {
        while (index < listeners.length) {
          const listener = listeners[index++]!;
          const host = listener.host.includes(":")
            ? `[${listener.host}]`
            : listener.host;
          const url = `http://${host}:${listener.port}/`;
          const id = `local:${host}:${listener.port}`;
          found.add(id);
          const ready = await probeHTTP(url);
          const previous = this.local.get(id);
          if (!ready && !previous) continue;
          this.local.set(id, {
            lastSeen: now,
            route: {
              frontend: {
                id,
                hostname: `${host}:${listener.port}`,
                title: `${listener.cwd ? path.basename(listener.cwd) || listener.command : listener.command} · ${listener.port}`,
                url,
                port: listener.port,
                source: "local",
                status: ready ? "ready" : "starting",
                transport: "gateway",
              },
              target: new URL(url).origin,
            },
          });
        }
      }),
    );
    for (const [id, entry] of this.local) {
      if (
        this.portlessPorts.has(entry.route.frontend.port) ||
        now - entry.lastSeen > 60_000
      )
        this.local.delete(id);
      else if (!found.has(id)) entry.route.frontend.status = "stopped";
    }
  }
  private routeKey(route: FrontendRoute): string {
    return JSON.stringify([
      route.target,
      route.caPath,
      new URL(route.frontend.url).origin,
      route.frontend.transport,
    ]);
  }
  private async refresh(): Promise<Catalog> {
    const warnings: string[] = [];
    try {
      const result = await readPortless(this.stateDir);
      this.portless = result.routes;
      this.portlessPorts = result.ports;
    } catch (error) {
      warnings.push(
        `Portless catalog unavailable: ${(error as Error).message}`,
      );
    }
    try {
      await this.discoverLocal();
    } catch (error) {
      warnings.push((error as Error).message);
    }
    let manual: FrontendRoute[];
    try {
      manual = (await this.bookmarks()).map((entry) => this.manualRoute(entry));
    } catch (error) {
      warnings.push(`Saved URLs unavailable: ${(error as Error).message}`);
      manual = [...this.routes.values()].filter(
        (route) => route.frontend.source === "manual",
      );
    }
    const routes = [...this.portless, ...manual];
    const origins = new Set(
      routes.flatMap((route) => [
        new URL(route.frontend.url).origin,
        route.target,
      ]),
    );
    routes.push(
      ...[...this.local.values()]
        .map((entry) => entry.route)
        .filter((route) => !origins.has(new URL(route.frontend.url).origin)),
    );
    this.routes = new Map(routes.map((route) => [route.frontend.id, route]));
    for (const [id, record] of this.proxies) {
      const route = this.routes.get(id);
      if (
        !route ||
        route.frontend.status === "stopped" ||
        this.routeKey(route) !== record.routeKey
      ) {
        this.proxies.delete(id);
        await this.close(record);
      }
    }
    this.catalog = {
      frontends: routes
        .map((route) => route.frontend)
        .sort((a, b) => a.title.localeCompare(b.title)),
      warning: warnings.join("\n") || null,
    };
    return this.catalog;
  }
  openFrontend(id: string): Promise<{
    frontend: Frontend;
    exposedPort?: number;
    accessToken?: string;
  }> {
    return this.enqueue(async () => {
      this.requireRunning();
      const catalog = await this.refresh();
      this.requireRunning();
      const frontend = catalog.frontends.find((f) => f.id === id);
      if (!frontend)
        throw new ServiceError("Frontend is no longer registered", 404);
      if (frontend.status === "stopped")
        throw new ServiceError(
          "Start this app on your Mac, then try again",
          503,
        );
      if (frontend.transport !== "gateway") return { frontend };
      let record = this.proxies.get(id);
      if (!record) {
        record = await this.createGateway(id);
        if (this.stopping) {
          await this.close(record);
          this.requireRunning();
        }
        this.proxies.set(id, record);
      }
      return {
        frontend,
        exposedPort: record.exposedPort,
        accessToken: record.token,
      };
    });
  }
  private requireRunning(): void {
    if (this.stopping)
      throw new ServiceError("Companion is shutting down", 503);
  }
  private async createGateway(id: string): Promise<ProxyRecord> {
    const token = crypto.randomBytes(32).toString("hex");
    const cookieName = `slz_preview_${crypto.createHash("sha256").update(id).digest("hex").slice(0, 16)}`;
    const sockets = new Set<Socket>();
    const proxy = httpProxy.createProxyServer({
      ws: true,
      xfwd: false,
    });
    // Bound a stalled upstream handshake, not the lifetime of SSE/streaming responses.
    proxy.on("proxyReq", (request) => {
      request.setTimeout(30_000, () =>
        request.destroy(new Error("Frontend response timed out")),
      );
      request.once("response", () => request.setTimeout(0));
    });
    const route = this.routes.get(id)!;
    const upstreamURL = new URL(route.frontend.url);
    const ca = route.caPath ? await fs.readFile(route.caPath) : undefined;
    const agent =
      upstreamURL.protocol === "https:"
        ? new https.Agent({ ca, servername: upstreamURL.hostname })
        : undefined;
    const target = route.target;
    const routeOrigin = upstreamURL.origin;
    const authorized = (req: http.IncomingMessage) =>
      req.headers.cookie
        ?.split(";")
        .some((c) => c.trim() === `${cookieName}=${token}`);
    const prepare = (req: http.IncomingMessage) => {
      const external = `http://${req.headers.host}`;
      // Present one coherent upstream origin. Next.js validates Server Actions
      // against X-Forwarded-Host, and Portless preserves these forwarded headers.
      const upstream = new URL(routeOrigin);
      req.headers.host = upstream.host;
      req.headers["x-forwarded-host"] = upstream.host;
      req.headers["x-forwarded-proto"] = upstream.protocol.slice(0, -1);
      req.headers["x-forwarded-port"] =
        upstream.port || (upstream.protocol === "https:" ? "443" : "80");
      if (req.headers.origin === external) req.headers.origin = routeOrigin;
      // Never pass companion or preview credentials to the dev server.
      if (req.headers.cookie)
        req.headers.cookie = req.headers.cookie
          .split(";")
          .filter((c) => !/^\s*slz_(session|preview_[a-f0-9]+)=/.test(c))
          .join(";");
    };
    proxy.on("error", (error, _req, res) => {
      this.logger.warn("Frontend gateway error", { id, error: error.message });
      if ("writeHead" in res) {
        if (!res.headersSent) res.writeHead(502);
        res.end(
          "The frontend is unavailable. Start it on your Mac, then reload.",
        );
      } else res.destroy();
    });
    const externalOrigins = new WeakMap<http.IncomingMessage, string>();
    proxy.on("proxyRes", (response, req) => {
      const external = externalOrigins.get(req);
      if (
        external &&
        response.headers["access-control-allow-origin"] === routeOrigin
      )
        response.headers["access-control-allow-origin"] = external;
      if (external && response.headers.location?.startsWith(routeOrigin + "/"))
        response.headers.location =
          external + response.headers.location.slice(routeOrigin.length);
    });
    const server = http.createServer((req, res) => {
      const url = new URL(req.url ?? "/", "http://preview.invalid");
      if (
        url.pathname === "/__slz_access" &&
        url.searchParams.get("token") === token
      ) {
        res.writeHead(303, {
          "Set-Cookie": `${cookieName}=${token}; HttpOnly; SameSite=Strict; Path=/`,
          Location:
            upstreamURL.pathname + upstreamURL.search + upstreamURL.hash,
          "Cache-Control": "no-store",
          "Referrer-Policy": "no-referrer",
        });
        res.end();
        return;
      }
      if (!authorized(req)) {
        res.writeHead(401);
        res.end("Open this frontend from SlopZooka to connect.");
        return;
      }
      if (!this.catalog.frontends.some((f) => f.id === id)) {
        res.writeHead(410);
        res.end("Frontend stopped");
        return;
      }
      externalOrigins.set(req, `http://${req.headers.host}`);
      prepare(req);
      proxy.web(req, res, {
        target,
        agent,
        headers: { host: new URL(routeOrigin).host },
        cookieDomainRewrite: "",
      });
    });
    server.on("connection", (socket) => {
      sockets.add(socket);
      socket.on("close", () => sockets.delete(socket));
    });
    server.on("upgrade", (req, socket, head) => {
      if (
        !authorized(req) ||
        (req.headers.origin &&
          req.headers.origin !== `http://${req.headers.host}`)
      ) {
        socket.destroy();
        return;
      }
      prepare(req);
      proxy.ws(req, socket, head, {
        target,
        agent,
        headers: { host: new URL(routeOrigin).host },
      });
    });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(
        { port: 0, host: process.env.SLOPZOOKA_HOST ?? "::", ipv6Only: false },
        () => {
          server.off("error", reject);
          resolve();
        },
      );
    });
    const address = server.address();
    if (!address || typeof address === "string")
      throw new Error("No gateway listener address");
    return {
      server,
      proxy,
      sockets,
      exposedPort: address.port,
      token,
      agent,
      routeKey: this.routeKey(route),
    };
  }
  private async close(record: ProxyRecord): Promise<void> {
    for (const socket of record.sockets) socket.destroy();
    record.proxy.close();
    record.agent?.destroy();
    await new Promise<void>((resolve) => record.server.close(() => resolve()));
  }
  stop(): Promise<void> {
    this.stopping = true;
    this.stopTask ??= this.enqueue(async () => {
      const records = [...this.proxies.values()];
      this.proxies.clear();
      await Promise.allSettled(records.map((record) => this.close(record)));
    });
    return this.stopTask;
  }
}
