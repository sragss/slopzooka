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
const nativeTerminal = Boolean(window.webkit?.messageHandlers?.terminalState);
const input = terminal.textarea;
if (nativeTerminal && input) {
  input.inputMode = "none";
  input.addEventListener("blur", () => {
    // The toolbar's keyboard request applies to the current focus session.
    input.inputMode = "none";
  });
}
const detachTextInput = bindTerminalTextInput(terminal);
let scrollbackRemainder = 0;
let scrollbackReady = false;
let dragScrollbackAvailable = false;
const canDragScrollback = () =>
  scrollbackReady &&
  terminal.buffer.active.type === "normal" &&
  terminal.buffer.active.baseY > 0 &&
  terminal.modes.mouseTrackingMode === "none";
const publishDragScrollback = () => {
  const available = canDragScrollback();
  if (available === dragScrollbackAvailable) return;
  dragScrollbackAvailable = available;
  window.webkit?.messageHandlers?.terminalScrollback?.postMessage(
    available ? "1" : "0",
  );
};
const resetScrollbackMotion = () => {
  scrollbackRemainder = 0;
};
const scrollbackSubscriptions = [
  terminal.buffer.onBufferChange(resetScrollbackMotion),
  terminal.onResize(resetScrollbackMotion),
  terminal.onResize(publishDragScrollback),
  terminal.onWriteParsed(publishDragScrollback),
];
// The native controls supply fractions of the viewport height. Scroll only the
// local normal buffer, including when another viewer owns PTY input.
window.slzScrollback = (pages, fromBody = false) => {
  if (!scrollbackReady || !Number.isFinite(pages) || Math.abs(pages) > 4)
    return;
  // Terminal mode can change before the native availability update arrives.
  if (fromBody && !canDragScrollback()) return;
  const { type, baseY, viewportY } = terminal.buffer.active;
  if (type !== "normal") return;
  const targetDelta = Math.max(
    -viewportY,
    Math.min(baseY - viewportY, scrollbackRemainder + pages * terminal.rows),
  );
  const lines = Math.trunc(targetDelta);
  scrollbackRemainder = targetDelta - lines;
  if (lines !== 0) terminal.scrollLines(lines);
};
fit.fit();
// Native scenes queue focus through TerminalSessionController when active and
// attached. Autofocusing here would briefly focus an inactive scene on reload.
// Standalone browser terminals still start ready for physical keyboard input.
if (!nativeTerminal) focusTerminal();

function focusTerminal(showKeyboard = false) {
  const input = terminal.textarea;
  if (input) {
    const mode = showKeyboard ? "text" : "none";
    if (input.inputMode !== mode || (nativeTerminal && showKeyboard)) {
      // A fresh focus session also reopens a system-dismissed keyboard.
      if (document.activeElement === input) input.blur();
      input.inputMode = mode;
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
        scrollbackReady = state === "running";
        if (!scrollbackReady) resetScrollbackMotion();
        publishDragScrollback();
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
          scrollback: "1",
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
  scrollbackReady = false;
  publishDragScrollback();
  for (const subscription of scrollbackSubscriptions) subscription.dispose();
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
// Native copy/select all use the emulator's selection, which WebKit cannot see.
window.slzSelectedTerminalText = () =>
  document.activeElement === terminal.textarea ? terminal.getSelection() : "";
window.slzSelectAllTerminalText = () => {
  if (document.activeElement === terminal.textarea) terminal.selectAll();
};
window.slzSetTerminalOptionAsMeta = (enabled) => {
  terminal.options.macOptionIsMeta = enabled;
  window.slzTerminalOptionAsMeta = enabled;
};
window.slzDetachTerminal = detach;
mount.addEventListener("pointerdown", () => {
  if (nativeTerminal) terminal.focus();
  else focusTerminal(true);
});
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
    slzSelectedTerminalText?: () => string;
    slzSelectAllTerminalText?: () => void;
    slzSetTerminalOptionAsMeta?: (enabled: boolean) => void;
    slzTerminalOptionAsMeta?: boolean;
    slzDetachTerminal?: () => void;
    slzSetTerminalZoom?: (zoom: number) => void;
    slzScrollback?: (pages: number, fromBody?: boolean) => void;
    webkit?: {
      messageHandlers?: {
        terminalState?: { postMessage: (value: unknown) => void };
        terminalScrollback?: { postMessage: (value: unknown) => void };
        terminalNotification?: { postMessage: (value: unknown) => void };
        diagnostics?: { postMessage: (value: unknown) => void };
      };
    };
  }
}
