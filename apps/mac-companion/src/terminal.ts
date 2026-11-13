import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import { TerminalConnection } from "./terminal-connection.js";
import { bindTerminalTextInput } from "./terminal-text-input.js";
import { browserLog } from "./browser-logger.js";

const mount = document.querySelector<HTMLElement>("#terminal")!;
const overlay = document.querySelector<HTMLElement>("#connection-overlay")!;
const messageLabel = document.querySelector<HTMLElement>(
  "#connection-message",
)!;
const guidance = document.querySelector<HTMLElement>("#connection-guidance")!;
const readOnlyBadge = document.querySelector<HTMLElement>("#read-only")!;
const takeControlButton =
  document.querySelector<HTMLButtonElement>("#take-control")!;
const terminal = new Terminal({
  cursorBlink: true,
  fontSize: 16,
  lineHeight: 1.22,
  theme: { background: "#05070b", foreground: "#e7edf7" },
});
const fit = new FitAddon();
terminal.loadAddon(fit);
terminal.open(mount);
const detachTextInput = bindTerminalTextInput(terminal);
fit.fit();
// Keep hardware typing ready; the floating keyboard requires an explicit request.
focusTerminal();

function focusTerminal(showKeyboard = false) {
  const input = terminal.textarea;
  if (input) {
    const mode = showKeyboard ? "text" : "none";
    if (input.inputMode !== mode) {
      input.inputMode = mode;
      // WebKit needs a fresh focus session when changing keyboard presentation.
      if (document.activeElement === input) input.blur();
    }
  }
  terminal.focus();
}
const sessionId = new URLSearchParams(location.search).get("sessionId");
const log = browserLog("terminal", { sessionId });
const connection = sessionId
  ? new TerminalConnection(
      terminal,
      sessionId,
      (message, state, readOnly = false, canTakeControl = false) => {
        // Snapshot parsing can emit DEC focus reports before attachment accepts
        // input. Reestablish focus after attaching or regaining write ownership.
        if (state === "running" && !readOnly && terminal.modes.sendFocusMode)
          terminal.input(
            document.hasFocus() && document.activeElement === terminal.textarea
              ? "\x1b[I"
              : "\x1b[O",
            false,
          );
        overlay.hidden = state === "running";
        messageLabel.textContent = message;
        guidance.hidden = state !== "disconnected";
        overlay.classList.toggle("error", state === "failed");
        readOnlyBadge.hidden = !readOnly;
        takeControlButton.hidden = !canTakeControl;
        window.webkit?.messageHandlers?.terminalState?.postMessage({
          state,
          message,
        });
      },
      () => fit.fit(),
      (sequence, serviceInstanceId, audible) => {
        window.webkit?.messageHandlers?.terminalNotification?.postMessage({
          kind: "alert",
          sequence,
          serviceInstanceId,
          audible,
        });
      },
      log,
    )
  : undefined;
document.title = sessionId
  ? `Terminal • ${sessionId.slice(0, 8)}`
  : "Missing session";
if (!sessionId) messageLabel.textContent = "Missing terminal session";
connection?.connect();
takeControlButton.addEventListener("click", () => {
  connection?.takeControl();
  terminal.focus();
});
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
  log.info("zoom.changed", { zoom });
  terminal.options.fontSize = fontSize;
  cancelAnimationFrame(resizeFrame);
  resizeFrame = requestAnimationFrame(() => connection?.resize());
};
window.addEventListener("online", reconnect);
function detach() {
  detachTextInput();
  resizeObserver.disconnect();
  cancelAnimationFrame(resizeFrame);
  window.removeEventListener("online", reconnect);
  connection?.detach();
}
window.addEventListener("pagehide", detach);
window.addEventListener("pageshow", (event) => {
  if (event.persisted) location.reload();
});
window.slzFocusTerminal = focusTerminal;
// Native scene activity is independent of WebKit's retained DOM focus. Let
// xterm send DEC focus-out so agents can emit their background notifications.
window.slzBlurTerminal = () => terminal.blur();
// Synthetic keydowns make xterm focus its textarea, reopening the keyboard.
// Direct input uses the same onData/ownership path without changing focus.
window.slzInterruptTerminal = () => {
  log.info("interrupt.requested");
  terminal.input("\u001b", true);
};
window.slzDetachTerminal = detach;
mount.addEventListener("pointerdown", () => focusTerminal(true));
// Only user interaction acknowledges an alert; programmatic focus/reconnect does not.
const selectTerminal = () =>
  window.webkit?.messageHandlers?.terminalNotification?.postMessage({
    kind: "selected",
  });
mount.addEventListener("pointerdown", selectTerminal, true);
mount.addEventListener("keydown", selectTerminal, true);
mount.addEventListener("beforeinput", selectTerminal, true);
declare global {
  interface Window {
    slzFocusTerminal?: (showKeyboard?: boolean) => void;
    slzBlurTerminal?: () => void;
    slzInterruptTerminal?: () => void;
    slzDetachTerminal?: () => void;
    slzSetTerminalZoom?: (zoom: number) => void;
    webkit?: {
      messageHandlers?: {
        terminalState?: { postMessage: (value: unknown) => void };
        terminalNotification?: { postMessage: (value: unknown) => void };
        diagnostics?: { postMessage: (value: unknown) => void };
      };
    };
  }
}
