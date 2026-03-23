export type SurfaceKind = "tui" | "terminal";
export type TuiProfile = "codex" | "claude" | "opencode";

export type ClientMessage =
  | HelloMessage
  | CreateSurfaceMessage
  | TerminalInputMessage
  | TerminalResizeMessage
  | CloseSurfaceMessage;

export type ServerMessage =
  | HelloAckMessage
  | ClusterSnapshotMessage
  | SurfaceCreatedMessage
  | TerminalOutputMessage
  | SurfaceClosedMessage
  | ErrorMessage;

export type HelloMessage = {
  type: "hello";
  clientName?: string;
};

export type CreateSurfaceMessage = {
  type: "create_surface";
  kind: SurfaceKind;
  profile?: TuiProfile;
  cwd?: string;
  cols?: number;
  rows?: number;
};

export type TerminalInputMessage = {
  type: "terminal_input";
  surfaceId: string;
  data: string;
};

export type TerminalResizeMessage = {
  type: "terminal_resize";
  surfaceId: string;
  cols: number;
  rows: number;
};

export type CloseSurfaceMessage = {
  type: "close_surface";
  surfaceId: string;
};

export type HelloAckMessage = {
  type: "hello_ack";
  serverVersion: string;
  hostname: string;
  controlOrigin: string;
};

export type ClusterSnapshotMessage = {
  type: "cluster_snapshot";
  clusterId: string;
  surfaces: SurfaceSummary[];
};

export type SurfaceCreatedMessage = {
  type: "surface_created";
  clusterId: string;
  surface: SurfaceSummary;
};

export type TerminalOutputMessage = {
  type: "terminal_output";
  surfaceId: string;
  data: string;
};

export type SurfaceClosedMessage = {
  type: "surface_closed";
  surfaceId: string;
  exitCode: number | null;
  signal?: number;
  reason: "client_closed" | "process_exit" | "socket_closed";
};

export type ErrorMessage = {
  type: "error";
  message: string;
};

export type SurfaceSummary = {
  id: string;
  kind: SurfaceKind;
  profile?: TuiProfile;
  title: string;
  cwd: string;
  cols: number;
  rows: number;
};

const messageTypes = new Set<string>([
  "hello",
  "create_surface",
  "terminal_input",
  "terminal_resize",
  "close_surface"
]);

export function isClientMessage(value: unknown): value is ClientMessage {
  if (typeof value !== "object" || value === null) {
    return false;
  }

  const candidate = value as { type?: unknown };
  return typeof candidate.type === "string" && messageTypes.has(candidate.type);
}
