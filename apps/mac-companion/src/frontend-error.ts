import type { ServerResponse } from "node:http";

const escape = (value: string) =>
  value.replace(
    /[&<>"']/g,
    (character) =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      })[character]!,
  );

/** An actionable error document, without injecting diagnostics into an already-started stream. */
export function frontendError(
  res: ServerResponse,
  status: number,
  message: string,
  detail: string,
): void {
  if (res.headersSent) {
    res.destroy();
    return;
  }
  res.writeHead(status, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><title>Frontend unavailable</title>
<style>body{font:14px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;max-width:520px;margin:12vh auto;padding:24px}h1{font-size:22px}button{font:inherit;padding:6px 16px;cursor:pointer}details{margin-top:24px}pre{white-space:pre-wrap;overflow-wrap:anywhere}</style>
<h1>Frontend unavailable</h1><p>${escape(message)}</p><button onclick="location.reload()">Reload</button><details><summary>Details</summary><pre>${escape(detail)}</pre></details></html>`);
}
