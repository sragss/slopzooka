import {
  LOG_SOURCES,
  type LogSource,
} from "../../../packages/protocol/src/diagnostics.js";

export const BUG_ISSUES_URL = "https://github.com/sragss/slopzooka/issues/new";
export type BugReportCapture = {
  reportId: string;
  around: string;
  producers: { source: LogSource; buildId?: string; runtimeId?: string }[];
  coverage: {
    truncated: boolean;
    unavailable: string[];
    partialSegments: number;
    malformedRecords: number;
  };
  flushIncomplete?: boolean;
};

/** Explicit public allowlist. Raw events, paths, host/client IDs and errors stay local. */
export function bugReportBody(
  description: string,
  around: string,
  capture?: BugReportCapture,
): string {
  const builds = [
    ...new Set(
      (capture?.producers ?? [])
        .filter((p) => LOG_SOURCES.includes(p.source))
        .map((p) => {
          const build = /^[a-f0-9]{64}$/.test(p.buildId ?? "")
            ? p.buildId!
            : "unavailable";
          const runtime = /^(v|os-)\d+\.\d+\.\d+$/.test(p.runtimeId ?? "")
            ? ` (${p.runtimeId!})`
            : "";
          return `- ${p.source}: ${build}${runtime}`;
        }),
    ),
  ].slice(0, 8);
  const id =
    capture &&
    /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(capture.reportId)
      ? capture.reportId
      : undefined;
  const incomplete =
    capture &&
    (capture.flushIncomplete ||
      capture.coverage.truncated ||
      capture.coverage.unavailable.length > 0 ||
      capture.coverage.partialSegments > 0 ||
      capture.coverage.malformedRecords > 0);
  return [
    "## What happened",
    description.trim(),
    "## Incident",
    `Time: ${new Date(around).toISOString()}`,
    id
      ? `Local diagnostic report: ${id} (logs have not been uploaded).`
      : "No diagnostic snapshot is attached.",
    ...(incomplete ? ["The local snapshot has incomplete coverage."] : []),
    ...(builds.length ? ["## Builds", ...builds] : []),
  ].join("\n\n");
}

export function bugReportURL(title: string, body: string): string {
  if (!title.trim()) throw new Error("Enter a short summary.");
  const url = new URL(BUG_ISSUES_URL);
  url.searchParams.set("title", title.trim());
  url.searchParams.set("body", body);
  if (url.href.length > 7800)
    throw new Error(
      "Shorten the description to fit GitHub’s issue draft link. Your local snapshot is still saved.",
    );
  return url.href;
}
