import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { IncomingMessage } from "node:http";
import type { Express } from "express";

const publicPaths = new Set([
  "/health",
  "/",
  "/index.html",
  "/harness.js",
  "/harness.css",
  "/terminal.js",
  "/terminal.css",
]);

export class Pairing {
  readonly hostId: string;
  readonly code = crypto.randomBytes(6).toString("hex");
  private readonly tokens: Set<string>;
  private readonly attempts = new Map<
    string,
    { count: number; until: number }
  >();
  private readonly file: string;
  constructor(home: string) {
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
      return url.host === req.headers.host && url.protocol === "http:";
    } catch {
      return false;
    }
  }
  install(app: Express): void {
    app.post("/api/pair", (req, res) => {
      if (!this.sameOrigin(req)) {
        res.status(403).json({ error: "Origin rejected" });
        return;
      }
      const ip = req.ip ?? "unknown",
        now = Date.now();
      const attempt = this.attempts.get(ip) ?? {
        count: 0,
        until: now + 60_000,
      };
      if (now > attempt.until) {
        attempt.count = 0;
        attempt.until = now + 60_000;
      }
      if (++attempt.count > 10) {
        res.status(429).json({ error: "Wait a minute before pairing again" });
        return;
      }
      if (this.attempts.size > 1000) this.attempts.clear();
      this.attempts.set(ip, attempt);
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
      this.cookie(res, token);
      res.json({ token, hostId: this.hostId });
    });
    app.use((req, res, next) => {
      if (!this.sameOrigin(req)) {
        res.status(403).json({ error: "Origin rejected" });
        return;
      }
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
      if (req.path === "/terminal") this.cookie(res, this.credential(req));
      next();
    });
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
  private cookie(res: import("express").Response, token: string): void {
    res.cookie("slz_session", token, {
      httpOnly: true,
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
