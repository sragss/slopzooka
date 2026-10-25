export const PROTOCOL_VERSION = 1;
export type TuiProfile = "codex" | "claude" | "opencode";
export type SessionSummary = {
  id: string;
  workspaceId: string;
  profile: TuiProfile | null;
  title: string;
  cwd: string;
  cols: number;
  rows: number;
  status: "running" | "exited";
  exitCode: number | null;
};
export type ClientMessage =
  | { type: "hello"; version: number }
  | { type: "attach"; sessionId: string; cursor?: number }
  | { type: "detach"; sessionId: string }
  | { type: "input"; sessionId: string; data: string }
  | { type: "resize"; sessionId: string; cols: number; rows: number }
  | { type: "ack"; sessionId: string; cursor: number };
export type ServerMessage =
  | { type: "ownership"; sessionId: string; writable: boolean }
  | {
      type: "hello";
      version: number;
      hostId: string;
      sessions: SessionSummary[];
    }
  | {
      type: "attached";
      session: SessionSummary;
      cursor: number;
      snapshot?: string;
      writable: boolean;
    }
  | { type: "output"; sessionId: string; cursor: number; data: string }
  | { type: "exited"; sessionId: string; exitCode: number | null }
  | { type: "error"; message: string; code: string };
export const validId = (value: unknown): value is string =>
  typeof value === "string" && /^[a-zA-Z0-9._:-]{1,120}$/.test(value);
export const validDimension = (value: unknown): value is number =>
  Number.isInteger(value) && Number(value) >= 2 && Number(value) <= 500;
export const validProfile = (value: unknown): value is TuiProfile | null =>
  value === null ||
  value === "codex" ||
  value === "claude" ||
  value === "opencode";
export function isClientMessage(value: unknown): value is ClientMessage {
  if (!value || typeof value !== "object") return false;
  const m = value as Record<string, unknown>;
  if (m.type === "hello") return m.version === PROTOCOL_VERSION;
  if (!validId(m.sessionId)) return false;
  const cursor = (v: unknown) => Number.isSafeInteger(v) && Number(v) >= 0;
  switch (m.type) {
    case "attach":
      return m.cursor === undefined || cursor(m.cursor);
    case "detach":
      return true;
    case "ack":
      return cursor(m.cursor);
    case "input":
      return typeof m.data === "string" && m.data.length <= 64 * 1024;
    case "resize":
      return validDimension(m.cols) && validDimension(m.rows);
    default:
      return false;
  }
}
