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
};
export type SessionLaunch = {
  workspaceId: string;
  cwd: string;
  profile: TuiProfile | null;
  id: string;
  environment: Record<string, string>;
};
