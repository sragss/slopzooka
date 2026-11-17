import type {
  SessionSummary,
  TuiProfile,
} from "../../../packages/protocol/src/index.js";

// Private local control API. Terminal streams use the existing public messages.
export const SESSION_SERVICE_VERSION = 1;
export type ServiceInfo = {
  version: number;
  instanceId: string;
  runtimeId: string;
  pid: number;
  sessions: SessionSummary[];
  capabilities?: string[];
  /** The retained process owns its writer, even after companion configuration changes. */
  logFilePath?: string;
};
export type SessionLaunch = {
  workspaceId: string;
  cwd: string;
  profile: TuiProfile | null;
  id: string;
  environment: Record<string, string>;
  codexResume?: { threadId: string; title: string };
};

export const CODEX_RESUME_CAPABILITY = "codex-resume-v1";
export const validCodexThreadId = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
