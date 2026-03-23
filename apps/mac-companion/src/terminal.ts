import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";

import type {
  ClientMessage,
  CreateSurfaceMessage,
  ServerMessage,
  SurfaceSummary,
  TerminalInputMessage,
  TerminalResizeMessage,
  TuiProfile
} from "../../../packages/protocol/src/index.js";

const mount = mustQuery<HTMLElement>("#terminal");
const titlePill = mustQuery<HTMLElement>("#title-pill");
const statusPill = mustQuery<HTMLElement>("#status-pill");

const terminal = new Terminal({
  cursorBlink: true,
  fontSize: 16,
  lineHeight: 1.22,
  theme: {
    background: "#05070b",
    foreground: "#e7edf7"
  }
});
const fitAddon = new FitAddon();
terminal.loadAddon(fitAddon);
terminal.open(mount);
fitAddon.fit();
terminal.focus();

const params = new URLSearchParams(window.location.search);
const profile = parseProfile(params.get("profile"));
const cwd = params.get("cwd")?.trim() || undefined;
const host = window.location.host;
const socket = new WebSocket(wsUrlForHost(host));

let activeSurface: SurfaceSummary | null = null;
let closedByClient = false;

window.slzFocusTerminal = focusTerminal;
window.slzSendTerminalInput = sendTerminalInput;

titlePill.innerHTML = `<strong>${displayName(profile)}</strong> waiting for companion...`;
setStatus("Connecting...");

socket.addEventListener("open", () => {
  send({ type: "hello", clientName: "terminal-page" });
});

socket.addEventListener("message", (event) => {
  try {
    const payload = JSON.parse(String(event.data)) as ServerMessage;
    handleServerMessage(payload);
  } catch (error) {
    setError(`Failed to parse server message: ${String(error)}`);
  }
});

socket.addEventListener("close", () => {
  if (!closedByClient) {
    setError("Connection closed.");
  }
});

socket.addEventListener("error", () => {
  setError("WebSocket error.");
});

terminal.onData((data) => {
  if (!activeSurface) {
    return;
  }

  const message: TerminalInputMessage = {
    type: "terminal_input",
    surfaceId: activeSurface.id,
    data
  };

  send(message);
});

window.addEventListener("resize", queueResize);
window.addEventListener("pagehide", teardownSurface);
window.addEventListener("focus", focusTerminal);
window.addEventListener("pageshow", focusTerminal);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) {
    focusTerminal();
  }
});
mount.addEventListener("pointerdown", () => {
  focusTerminal();
});

function handleServerMessage(message: ServerMessage): void {
  switch (message.type) {
    case "hello_ack": {
      const createMessage: CreateSurfaceMessage = {
        type: "create_surface",
        kind: profile ? "tui" : "terminal",
        profile: profile ?? undefined,
        cwd,
        cols: terminal.cols,
        rows: terminal.rows
      };

      titlePill.innerHTML = `<strong>${displayName(profile)}</strong> on ${message.hostname}`;
      setStatus("Launching...");
      send(createMessage);
      break;
    }
    case "cluster_snapshot":
      break;
    case "surface_created":
      activeSurface = message.surface;
      queueResize();
      setStatus(`Connected • ${message.surface.cwd}`);
      break;
    case "terminal_output":
      if (message.surfaceId === activeSurface?.id) {
        terminal.write(message.data);
      }
      break;
    case "surface_closed":
      if (message.surfaceId === activeSurface?.id) {
        setStatus(`Session ended (${message.reason})`, true);
        activeSurface = null;
      }
      break;
    case "error":
      setError(message.message);
      break;
  }
}

function send(message: ClientMessage): void {
  if (socket.readyState !== WebSocket.OPEN) {
    return;
  }

  socket.send(JSON.stringify(message));
}

function queueResize(): void {
  if (!activeSurface) {
    return;
  }

  fitAddon.fit();

  const message: TerminalResizeMessage = {
    type: "terminal_resize",
    surfaceId: activeSurface.id,
    cols: terminal.cols,
    rows: terminal.rows
  };

  send(message);
}

function teardownSurface(): void {
  if (!activeSurface) {
    return;
  }

  closedByClient = true;
  send({
    type: "close_surface",
    surfaceId: activeSurface.id
  });
}

function focusTerminal(): void {
  requestAnimationFrame(() => {
    terminal.focus();
  });
}

function sendTerminalInput(text: string): void {
  if (!activeSurface || !text) {
    return;
  }

  const message: TerminalInputMessage = {
    type: "terminal_input",
    surfaceId: activeSurface.id,
    data: text
  };

  send(message);
  focusTerminal();
}

function setStatus(message: string, isError = false): void {
  statusPill.textContent = message;
  statusPill.classList.toggle("error", isError);
}

function setError(message: string): void {
  setStatus(message, true);
}

function parseProfile(value: string | null): TuiProfile | null {
  if (value === "codex" || value === "claude" || value === "opencode") {
    return value;
  }

  return null;
}

function displayName(profile: TuiProfile | null): string {
  switch (profile) {
    case "codex":
      return "Codex";
    case "claude":
      return "Claude Code";
    case "opencode":
      return "OpenCode";
    case null:
      return "Terminal";
  }
}

function wsUrlForHost(currentHost: string): string {
  const scheme = window.location.protocol === "https:" ? "wss" : "ws";
  return `${scheme}://${currentHost}/ws`;
}

function mustQuery<T extends Element>(selector: string): T {
  const element = document.querySelector<T>(selector);
  if (!element) {
    throw new Error(`Missing required element: ${selector}`);
  }

  return element;
}

declare global {
  interface Window {
    slzFocusTerminal?: () => void;
    slzSendTerminalInput?: (text: string) => void;
  }
}
