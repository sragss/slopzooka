import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import { TerminalConnection } from "./terminal-connection.js";

const mount = document.querySelector<HTMLElement>("#terminal")!;
const title = document.querySelector<HTMLElement>("#title-pill")!;
const status = document.querySelector<HTMLElement>("#status-pill")!;
const terminal = new Terminal({
  cursorBlink: true,
  fontSize: 16,
  lineHeight: 1.22,
  theme: { background: "#05070b", foreground: "#e7edf7" },
});
const fit = new FitAddon();
terminal.loadAddon(fit);
terminal.open(mount);
fit.fit();
terminal.focus();
const sessionId = new URLSearchParams(location.search).get("sessionId");
const connection = sessionId
  ? new TerminalConnection(
      terminal,
      sessionId,
      (message, state) => {
        status.textContent = message;
        status.classList.toggle("error", state === "failed");
        window.webkit?.messageHandlers.terminalState?.postMessage({
          state,
          message,
        });
      },
      () => fit.fit(),
    )
  : undefined;
title.textContent = sessionId
  ? `Terminal • ${sessionId.slice(0, 8)}`
  : "Missing session";
connection?.connect();
let resizeFrame = 0;
const resizeObserver = new ResizeObserver(() => {
  cancelAnimationFrame(resizeFrame);
  resizeFrame = requestAnimationFrame(() => connection?.resize());
});
resizeObserver.observe(mount);
const reconnect = () => connection?.reconnect();
// Font zoom preserves the full viewport on visionOS. WKWebView.pageZoom scales
// the existing canvas without changing its measured viewport or firing resize.
window.slzSetTerminalZoom = (zoom) => {
  if (!Number.isFinite(zoom) || zoom < 0.1 || zoom > 2) return;
  const fontSize = 16 * zoom;
  if (terminal.options.fontSize === fontSize) return;
  terminal.options.fontSize = fontSize;
  cancelAnimationFrame(resizeFrame);
  resizeFrame = requestAnimationFrame(() => connection?.resize());
};
window.addEventListener("online", reconnect);
function detach() {
  resizeObserver.disconnect();
  cancelAnimationFrame(resizeFrame);
  window.removeEventListener("online", reconnect);
  connection?.detach();
}
window.addEventListener("pagehide", detach);
window.addEventListener("pageshow", (event) => {
  if (event.persisted) location.reload();
});
window.slzFocusTerminal = () => terminal.focus();
window.slzDetachTerminal = detach;
mount.addEventListener("pointerdown", () => terminal.focus());
declare global {
  interface Window {
    slzFocusTerminal?: () => void;
    slzDetachTerminal?: () => void;
    slzSetTerminalZoom?: (zoom: number) => void;
    webkit?: {
      messageHandlers: {
        terminalState?: { postMessage: (value: unknown) => void };
      };
    };
  }
}
