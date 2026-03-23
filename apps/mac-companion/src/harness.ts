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

const hostInput = mustQuery<HTMLInputElement>("#host");
const cwdInput = mustQuery<HTMLInputElement>("#cwd");
const kindSelect = mustQuery<HTMLSelectElement>("#surface-kind");
const profileSelect = mustQuery<HTMLSelectElement>("#profile");
const connectButton = mustQuery<HTMLButtonElement>("#connect");
const disconnectButton = mustQuery<HTMLButtonElement>("#disconnect");
const spawnButton = mustQuery<HTMLButtonElement>("#spawn");
const closeSurfaceButton = mustQuery<HTMLButtonElement>("#close-surface");
const clearLogButton = mustQuery<HTMLButtonElement>("#clear-log");
const surfaceList = mustQuery<HTMLSelectElement>("#surface-list");
const surfaceMeta = mustQuery<HTMLElement>("#surface-meta");
const logEl = mustQuery<HTMLElement>("#log");
const terminalMount = mustQuery<HTMLElement>("#terminal");
const statusDot = mustQuery<HTMLElement>("#status-dot");
const statusText = mustQuery<HTMLElement>("#status-text");

const terminal = new Terminal({
  cursorBlink: true,
  fontSize: 14,
  lineHeight: 1.2,
  theme: {
    background: "#0c111a",
    foreground: "#e9edf4"
  }
});
const fitAddon = new FitAddon();
terminal.loadAddon(fitAddon);
terminal.open(terminalMount);
fitAddon.fit();

const currentHost = window.location.host || "Sams-MacBook-Pro-2.local:7777";
hostInput.value = currentHost;
cwdInput.value = "";

let socket: WebSocket | null = null;
let activeSurface: SurfaceSummary | null = null;
const surfaces = new Map<string, SurfaceSummary>();

function log(message: string): void {
  const stamp = new Date().toLocaleTimeString();
  logEl.textContent += `[${stamp}] ${message}\n`;
  logEl.scrollTop = logEl.scrollHeight;
}

function setConnected(connected: boolean): void {
  statusDot.classList.toggle("connected", connected);
  statusText.textContent = connected ? "Connected" : "Disconnected";
  connectButton.disabled = connected;
  disconnectButton.disabled = !connected;
  spawnButton.disabled = !connected;
  closeSurfaceButton.disabled = !connected || !activeSurface;
}

function renderSurfaceList(): void {
  const selectedSurfaceId = activeSurface?.id ?? "";
  surfaceList.replaceChildren();

  for (const surface of surfaces.values()) {
    const option = document.createElement("option");
    option.value = surface.id;
    option.textContent = `${surface.kind} | ${surface.title} | ${surface.id.slice(0, 8)}`;
    option.selected = surface.id === selectedSurfaceId;
    surfaceList.append(option);
  }

  if (!activeSurface) {
    surfaceMeta.textContent = "No active surface selected.";
    closeSurfaceButton.disabled = true;
    return;
  }

  surfaceMeta.textContent = `Active: ${activeSurface.id} | cwd: ${activeSurface.cwd} | size: ${activeSurface.cols}x${activeSurface.rows}`;
  closeSurfaceButton.disabled = false;
}

function setActiveSurface(surface: SurfaceSummary | null): void {
  activeSurface = surface;
  renderSurfaceList();
}

function wsUrlForHost(host: string): string {
  const scheme = window.location.protocol === "https:" ? "wss" : "ws";
  return `${scheme}://${host}/ws`;
}

function send(message: ClientMessage): void {
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    log(`Cannot send ${message.type}; socket is not open.`);
    return;
  }

  socket.send(JSON.stringify(message));
}

function handleServerMessage(message: ServerMessage): void {
  switch (message.type) {
    case "hello_ack":
      log(`Connected to ${message.controlOrigin} (${message.hostname})`);
      break;
    case "cluster_snapshot":
      log(`Cluster snapshot received with ${message.surfaces.length} surface(s).`);
      surfaces.clear();
      for (const surface of message.surfaces) {
        surfaces.set(surface.id, surface);
      }
      setActiveSurface(message.surfaces.at(-1) ?? null);
      break;
    case "surface_created":
      surfaces.set(message.surface.id, message.surface);
      setActiveSurface(message.surface);
      terminal.clear();
      log(`Surface ${message.surface.id} created in ${message.surface.cwd}`);
      queueResize();
      break;
    case "terminal_output":
      if (message.surfaceId === activeSurface?.id) {
        terminal.write(message.data);
      }
      break;
    case "surface_closed":
      log(
        `Surface ${message.surfaceId} closed (${message.reason}, exitCode=${message.exitCode ?? "null"}).`
      );
      surfaces.delete(message.surfaceId);
      if (message.surfaceId === activeSurface?.id) {
        setActiveSurface(Array.from(surfaces.values()).at(-1) ?? null);
      } else {
        renderSurfaceList();
      }
      break;
    case "error":
      log(`Error: ${message.message}`);
      break;
  }
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

connectButton.addEventListener("click", () => {
  const host = hostInput.value.trim();
  if (!host) {
    log("Host is required.");
    return;
  }

  const ws = new WebSocket(wsUrlForHost(host));
  socket = ws;

  ws.addEventListener("open", () => {
    setConnected(true);
    log(`Socket opened to ${host}.`);
    send({ type: "hello", clientName: "browser-harness" });
  });

  ws.addEventListener("message", (event) => {
    try {
      const payload = JSON.parse(String(event.data)) as ServerMessage;
      handleServerMessage(payload);
    } catch (error) {
      log(`Failed to parse server message: ${String(error)}`);
    }
  });

  ws.addEventListener("close", () => {
    log("Socket closed.");
    setConnected(false);
    surfaces.clear();
    setActiveSurface(null);
  });

  ws.addEventListener("error", () => {
    log("WebSocket error.");
  });
});

disconnectButton.addEventListener("click", () => {
  socket?.close();
});

spawnButton.addEventListener("click", () => {
  const message: CreateSurfaceMessage = {
    type: "create_surface",
    kind: kindSelect.value as CreateSurfaceMessage["kind"],
    profile: kindSelect.value === "tui" ? (profileSelect.value as TuiProfile) : undefined,
    cwd: cwdInput.value.trim() || undefined,
    cols: terminal.cols,
    rows: terminal.rows
  };

  send(message);
});

clearLogButton.addEventListener("click", () => {
  logEl.textContent = "";
});

closeSurfaceButton.addEventListener("click", () => {
  if (!activeSurface) {
    return;
  }

  send({
    type: "close_surface",
    surfaceId: activeSurface.id
  });
});

surfaceList.addEventListener("change", () => {
  const nextId = surfaceList.value;
  if (!nextId) {
    setActiveSurface(null);
    return;
  }

  const nextSurface = surfaces.get(nextId) ?? null;
  setActiveSurface(nextSurface);
  terminal.clear();
  terminal.write(`\r\n[slopzooka] selected surface ${nextId}\r\n`);
  queueResize();
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

terminal.focus();
log(`Harness ready. Open this at http://${currentHost}/`);

function mustQuery<T extends Element>(selector: string): T {
  const element = document.querySelector<T>(selector);
  if (!element) {
    throw new Error(`Missing required element: ${selector}`);
  }

  return element;
}
