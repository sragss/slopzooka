import https from "node:https";
import { readFile } from "node:fs/promises";
import { join, dirname } from "node:path";

export async function mediaRequest(connectionFile, command) {
  const c = JSON.parse(await readFile(connectionFile, "utf8"));
  const cert = await readFile(join(dirname(connectionFile), "media-cert.pem"));
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        host: c.host,
        port: c.port,
        path: "/command",
        method: "POST",
        ca: cert,
        checkServerIdentity: (_host, peer) =>
          peer.fingerprint256?.replaceAll(":", "").toLowerCase() ===
          c.fingerprint
            ? undefined
            : new Error("Media certificate mismatch"),
        headers: {
          Authorization: `Bearer ${c.token}`,
          "Content-Type": "application/json",
        },
        timeout: 20000,
      },
      (res) => {
        let bytes = "";
        res.on("data", (chunk) => {
          bytes += chunk;
          if (bytes.length > 16 * 1024 * 1024)
            req.destroy(new Error("Response exceeded"));
        });
        res.on("end", () => {
          try {
            const value = JSON.parse(bytes);
            if (res.statusCode !== 200)
              throw new Error(value.error ?? `HTTP ${res.statusCode}`);
            resolve(value);
          } catch (e) {
            reject(e);
          }
        });
      },
    );
    req.on("error", reject);
    req.on("timeout", () =>
      req.destroy(new Error("Uncertain media command timeout; do not replay")),
    );
    req.end(JSON.stringify(command));
  });
}
export async function companionRequest(file, path, body) {
  const c = JSON.parse(await readFile(file, "utf8"));
  const response = await fetch(c.base + path, {
    method: body === undefined ? "GET" : "POST",
    headers: {
      Authorization: `Bearer ${c.token}`,
      "Content-Type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(8000),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error ?? `HTTP ${response.status}`);
  return result;
}
