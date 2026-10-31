import https from "node:https";
import { X509Certificate } from "node:crypto";

export function tlsFetch(
  url: string,
  authority: string,
  options: https.RequestOptions = {},
): Promise<Response> {
  return new Promise((resolve, reject) => {
    const req = https.request(
      url,
      {
        ...options,
        ca: new X509Certificate(Buffer.from(authority, "base64")).toString(),
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("error", reject);
        res.on("end", () => {
          const headers = new Headers();
          for (const [name, value] of Object.entries(res.headers))
            for (const item of Array.isArray(value)
              ? value
              : value === undefined
                ? []
                : [value])
              headers.append(name, item);
          resolve(
            new Response(
              res.statusCode === 204 ? null : Buffer.concat(chunks),
              { status: res.statusCode, headers },
            ),
          );
        });
      },
    );
    req.setTimeout(5000, () =>
      req.destroy(new Error("HTTPS fixture timed out")),
    );
    req.on("error", reject);
    req.end();
  });
}
