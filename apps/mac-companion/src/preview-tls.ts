import { execFile } from "node:child_process";
import {
  createPrivateKey,
  randomBytes,
  randomUUID,
  X509Certificate,
} from "node:crypto";
import fs from "node:fs/promises";
import { isIP } from "node:net";
import path from "node:path";
import { promisify } from "node:util";

const exec = promisify(execFile);
type Authority = { key: string; cert: string };

/** A private development CA. It is never installed in the system trust store. */
export class PreviewTLS {
  private authority?: Promise<Authority>;
  constructor(private readonly directory: string) {}

  async certificate(
    hostname: string,
  ): Promise<Authority & { certificateAuthority: string; expiresAt: number }> {
    const host = hostname.replace(/^\[|\]$/g, "").toLowerCase();
    if (
      !isIP(host) &&
      !/^(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(host)
    )
      throw new Error("Invalid preview hostname");
    this.authority ??= this.loadAuthority().catch((error) => {
      this.authority = undefined;
      throw error;
    });
    let authority = await this.authority;
    if (
      Date.parse(new X509Certificate(authority.cert).validTo) <=
      Date.now() + 31 * 24 * 60 * 60_000
    ) {
      this.authority = this.loadAuthority();
      authority = await this.authority;
    }
    const temporary = await fs.mkdtemp(path.join(this.directory, "leaf-"));
    try {
      await fs.writeFile(path.join(temporary, "ca-key.pem"), authority.key, {
        mode: 0o600,
      });
      await fs.writeFile(path.join(temporary, "ca.pem"), authority.cert);
      await fs.writeFile(
        path.join(temporary, "extensions"),
        [
          "basicConstraints=critical,CA:FALSE",
          "keyUsage=critical,digitalSignature,keyEncipherment",
          "extendedKeyUsage=serverAuth",
          `subjectAltName=${isIP(host) ? "IP" : "DNS"}:${host}`,
        ].join("\n"),
      );
      await this.openssl(temporary, [
        "req",
        "-new",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        "key.pem",
        "-out",
        "request.pem",
        "-subj",
        "/CN=SlopZooka Preview",
      ]);
      await this.openssl(temporary, [
        "x509",
        "-req",
        "-in",
        "request.pem",
        "-CA",
        "ca.pem",
        "-CAkey",
        "ca-key.pem",
        "-set_serial",
        `0x${randomBytes(16).toString("hex")}`,
        "-days",
        "30",
        "-sha256",
        "-extfile",
        "extensions",
        "-out",
        "cert.pem",
      ]);
      const cert = await fs.readFile(path.join(temporary, "cert.pem"), "utf8");
      return {
        key: await fs.readFile(path.join(temporary, "key.pem"), "utf8"),
        cert,
        expiresAt: Date.parse(new X509Certificate(cert).validTo),
        certificateAuthority: new X509Certificate(authority.cert).raw.toString(
          "base64",
        ),
      };
    } finally {
      await fs.rm(temporary, { recursive: true, force: true });
    }
  }

  private async loadAuthority(): Promise<Authority> {
    await fs.mkdir(this.directory, { recursive: true, mode: 0o700 });
    const file = path.join(this.directory, "authority.json");
    try {
      const saved: Authority = JSON.parse(await fs.readFile(file, "utf8"));
      const cert = new X509Certificate(saved.cert);
      if (!cert.ca || !cert.checkPrivateKey(createPrivateKey(saved.key)))
        throw new Error(`Invalid preview certificate authority: ${file}`);
      if (Date.parse(cert.validTo) > Date.now() + 31 * 24 * 60 * 60_000)
        return saved;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    const temporary = await fs.mkdtemp(path.join(this.directory, "ca-"));
    const pending = `${file}.${randomUUID()}.tmp`;
    try {
      await this.openssl(temporary, [
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-sha256",
        "-days",
        "3650",
        "-keyout",
        "key.pem",
        "-out",
        "cert.pem",
        "-subj",
        "/CN=SlopZooka Preview CA",
        "-addext",
        "basicConstraints=critical,CA:TRUE,pathlen:0",
        "-addext",
        "keyUsage=critical,keyCertSign,cRLSign",
      ]);
      const authority = {
        key: await fs.readFile(path.join(temporary, "key.pem"), "utf8"),
        cert: await fs.readFile(path.join(temporary, "cert.pem"), "utf8"),
      };
      await fs.writeFile(pending, JSON.stringify(authority), { mode: 0o600 });
      await fs.rename(pending, file);
      return authority;
    } finally {
      await fs.rm(pending, { force: true });
      await fs.rm(temporary, { recursive: true, force: true });
    }
  }
  private async openssl(cwd: string, args: string[]): Promise<void> {
    await exec("openssl", args, {
      cwd,
      timeout: 10_000,
      maxBuffer: 1024 * 1024,
    });
  }
}
