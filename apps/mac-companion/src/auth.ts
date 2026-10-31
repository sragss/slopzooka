import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { IncomingMessage } from "node:http";
import type { Express } from "express";

const publicPaths = new Set([
  "/health",
  "/",
  "/index.html",
  "/dashboard",
  "/favicon.png",
  "/harness.js",
  "/harness.css",
  "/terminal.js",
  "/terminal.css",
]);

export class Pairing {
  readonly hostId: string;
  private currentCode = "";
  private codeExpires = 0;
  get code(): string {
    if (this.now() >= this.codeExpires) {
      const previous = this.currentCode;
      do {
        this.currentCode = crypto
          .randomInt(1_000_000)
          .toString()
          .padStart(6, "0");
      } while (this.currentCode === previous);
      this.codeExpires = this.now() + 5 * 60_000;
    }
    return this.currentCode;
  }
  private readonly tokens: Set<string>;
  private attempts = { count: 0, until: 0 };
  displayUntil = 0;
  private nextDisplay = 0;
  private displayRequester?: string;
  private readonly connectedClients = new Map<string, number>();
  private readonly file: string;
  constructor(
    home: string,
    private readonly proxyOrigin: () => string | undefined = () => undefined,
    private readonly now: () => number = Date.now,
  ) {
    fs.mkdirSync(home, { recursive: true, mode: 0o700 });
    this.file = path.join(home, "pairing.json");
    let saved: { hostId: string; tokens: string[] };
    try {
      saved = JSON.parse(fs.readFileSync(this.file, "utf8"));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      saved = { hostId: crypto.randomUUID(), tokens: [] };
    }
    if (typeof saved.hostId !== "string" || !Array.isArray(saved.tokens))
      throw new Error("Invalid pairing store");
    this.hostId = saved.hostId;
    this.tokens = new Set(saved.tokens);
    this.persist();
  }
  authorized(req: IncomingMessage): boolean {
    return this.tokens.has(this.digest(this.credential(req)));
  }
  sameOrigin(req: IncomingMessage): boolean {
    const origin = req.headers.origin;
    if (!origin) return true; // Native clients authenticate with a bearer token.
    try {
      const url = new URL(origin);
      return (
        url.host === req.headers.host &&
        (this.secureProxy(req)
          ? url.origin === this.proxyOrigin()
          : url.protocol === "http:")
      );
    } catch {
      return false;
    }
  }
  private secureProxy(req: IncomingMessage): boolean {
    const origin = this.proxyOrigin();
    const address = req.socket.remoteAddress;
    return (
      !!origin &&
      origin.startsWith("https:") &&
      new URL(origin).host === req.headers.host &&
      (address === "127.0.0.1" ||
        address === "::1" ||
        address === "::ffff:127.0.0.1") &&
      req.headers["x-forwarded-proto"] === "https"
    );
  }
  install(app: Express): void {
    app.use((req, res, next) => {
      if (!this.sameOrigin(req)) {
        res.status(403).json({ error: "Origin rejected" });
        return;
      }
      if (this.authorized(req)) this.noteConnection(req);
      next();
    });
    // Explicit pairing-screen request. Health checks never put a code on screen.
    // Only private desktop IPC carries the code; this response cannot reveal it.
    app.post("/api/pair/display", (req, res) => {
      const requester = this.clientKey(req);
      const connectedUntil = this.connectedClients.get(requester) ?? 0;
      if (
        !this.authorized(req) &&
        this.now() >= connectedUntil &&
        this.now() >= this.nextDisplay
      ) {
        this.displayRequester = requester;
        this.displayUntil = this.now() + 45_000;
        this.nextDisplay = this.now() + 60_000;
      }
      res.json({ ok: true });
    });
    app.post("/api/pair", (req, res) => {
      const now = this.now();
      if (now >= this.attempts.until)
        this.attempts = { count: 0, until: now + 60_000 };
      // A host-wide budget prevents bypassing the six-digit code limit via new addresses.
      if (++this.attempts.count > 10) {
        res.setHeader(
          "Retry-After",
          Math.ceil((this.attempts.until - now) / 1000),
        );
        res.status(429).json({ error: "Wait a minute before pairing again" });
        return;
      }
      if (typeof req.body?.code !== "string" || req.body.code !== this.code) {
        res
          .status(401)
          .json({ error: "Enter the pairing code shown on your Mac" });
        return;
      }
      const token = crypto.randomBytes(32).toString("hex");
      this.tokens.add(this.digest(token));
      // Bound credentials; pairing again eventually retires the oldest credentials.
      if (this.tokens.size > 32)
        this.tokens.delete(this.tokens.values().next().value!);
      this.persist();
      this.displayUntil = 0;
      this.displayRequester = undefined;
      this.noteConnection(req);
      this.cookie(req, res, token);
      res.json({ token, hostId: this.hostId });
    });
    app.use((req, res, next) => {
      if (
        (req.method === "GET" || req.method === "HEAD") &&
        publicPaths.has(req.path)
      ) {
        next();
        return;
      }
      if (!this.authorized(req)) {
        res
          .status(401)
          .json({ error: "Pair this device with the companion first" });
        return;
      }
      if (req.path === "/terminal") this.cookie(req, res, this.credential(req));
      next();
    });
  }
  private clientKey(req: IncomingMessage): string {
    // This is display attribution, never an authentication credential. Native
    // clients keep an ID across IPv4/IPv6 changes; older clients use their peer.
    const id = req.headers["x-slopzooka-client-id"];
    return typeof id === "string" &&
      /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id)
      ? `client:${id.toLowerCase()}`
      : `address:${req.socket.remoteAddress}`;
  }
  private noteConnection(req: IncomingMessage): void {
    const requester = this.clientKey(req);
    const now = this.now();
    for (const [client, until] of this.connectedClients) {
      if (until <= now) this.connectedClients.delete(client);
    }
    this.connectedClients.delete(requester);
    // A short lease covers an in-flight display request arriving after connect.
    this.connectedClients.set(requester, now + 15_000);
    if (this.connectedClients.size > 128)
      this.connectedClients.delete(this.connectedClients.keys().next().value!);
    if (this.displayRequester === requester) {
      this.displayUntil = 0;
      this.displayRequester = undefined;
    }
  }
  private credential(req: IncomingMessage): string {
    const bearer = req.headers.authorization;
    if (bearer?.startsWith("Bearer ")) return bearer.slice(7);
    return (
      req.headers.cookie
        ?.split(";")
        .map((x) => x.trim())
        .find((x) => x.startsWith("slz_session="))
        ?.slice(12) ?? ""
    );
  }
  private digest(token: string): string {
    return crypto.createHash("sha256").update(token).digest("hex");
  }
  private cookie(
    req: IncomingMessage,
    res: import("express").Response,
    token: string,
  ): void {
    res.cookie("slz_session", token, {
      httpOnly: true,
      secure: this.secureProxy(req),
      sameSite: "strict",
      path: "/",
      maxAge: 365 * 24 * 60 * 60 * 1000,
    });
  }
  private persist(): void {
    const temp = `${this.file}.${crypto.randomUUID()}.tmp`;
    fs.writeFileSync(
      temp,
      JSON.stringify({ hostId: this.hostId, tokens: [...this.tokens] }),
      { mode: 0o600 },
    );
    fs.renameSync(temp, this.file);
  }
}
