// Opt-in live experiment, versioned separately from terminal/window persistence.
export type ProbeStream = {
  host: string;
  port: number;
  token: string;
  fingerprint: string;
  target: string;
};
export type ProbeSurface = {
  id: string;
  title: string;
  workspaceID: string;
  deviceID: string;
  stream: ProbeStream;
};
export type ProbeCommand = {
  id: string;
  action: "open" | "close" | "reload";
  surfaceID: string;
};
export const probeID = (value: unknown): value is string =>
  typeof value === "string" && /^[a-zA-Z0-9:_-]{1,180}$/.test(value);
export function probeSurface(value: unknown): ProbeSurface {
  const v = value as ProbeSurface;
  if (
    !v ||
    !probeID(v.id) ||
    !v.id.startsWith("probe:") ||
    !probeID(v.workspaceID) ||
    !probeID(v.deviceID) ||
    typeof v.title !== "string" ||
    v.title.length > 160 ||
    !v.stream ||
    !probeID(v.stream.target) ||
    typeof v.stream.host !== "string" ||
    !/^[a-zA-Z0-9.:-]+$/.test(v.stream.host) ||
    !Number.isInteger(v.stream.port) ||
    v.stream.port < 1 ||
    v.stream.port > 65535 ||
    !/^[a-f0-9]{64}$/i.test(v.stream.fingerprint) ||
    typeof v.stream.token !== "string" ||
    v.stream.token.length < 32 ||
    v.stream.token.length > 256
  )
    throw new Error("Invalid live-probe surface manifest");
  return {
    id: v.id,
    title: v.title,
    workspaceID: v.workspaceID,
    deviceID: v.deviceID,
    stream: { ...v.stream },
  };
}
