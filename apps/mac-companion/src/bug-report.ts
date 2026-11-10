import "./bug-report.css";
import {
  bugReportBody,
  bugReportURL,
  type BugReportCapture,
} from "./bug-report-draft.js";
import { browserLog, flushBrowserLogs } from "./browser-logger.js";

const log = browserLog("bug-report");
const $ = <T extends HTMLElement = HTMLElement>(id: string) =>
  document.getElementById(id) as T;
const form = $<HTMLFormElement>("report-form");
const description = $<HTMLTextAreaElement>("description");
const title = $<HTMLInputElement>("title");
const download = $<HTMLAnchorElement>("download-report");
const body = document.createElement("input");
body.type = "hidden";
body.name = "body";
description.removeAttribute("name");
form.append(body);
const status = $("capture-status");
const retry = $<HTMLButtonElement>("retry-capture");
const ticket = new URLSearchParams(location.hash.slice(1)).get("connect");
const requestedTime = new URLSearchParams(location.search).get("around");
const around =
  requestedTime && Number.isFinite(Date.parse(requestedTime))
    ? new Date(requestedTime).toISOString()
    : new Date().toISOString();
// A one-use companion ticket must never reach GitHub, browser history or referrers.
history.replaceState(null, "", location.pathname);
let capture: BugReportCapture | undefined;
let capturing = false;

function updatePreview() {
  $("public-preview").textContent = bugReportBody(
    description.value,
    around,
    capture,
  );
}
form.oninput = updatePreview;
// A normal GET form opens GitHub's composer; it never creates an issue itself.
form.onsubmit = (event) => {
  try {
    const draft = bugReportBody(description.value, around, capture);
    bugReportURL(title.value, draft); // Bound the encoded URL before navigation.
    body.value = draft;
    $("report-error").hidden = true;
    log.info("bug-report.review.requested");
  } catch (error) {
    event.preventDefault();
    $("report-error").textContent =
      error instanceof Error ? error.message : "Could not prepare the draft.";
    $("report-error").hidden = false;
  }
};

async function saveCapture() {
  if (capturing) return;
  capturing = true;
  retry.hidden = true;
  status.textContent =
    "Saving a diagnostic snapshot on your Mac… You can report the bug while this finishes.";
  try {
    await flushBrowserLogs();
    const response = await fetch("/api/diagnostics/capture", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ around }),
      signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok)
      throw new Error(
        response.status === 401
          ? "Connect this browser in the dashboard, then retry. You can still report the bug without a snapshot."
          : "The Mac could not save a snapshot. You can still report the bug, or retry.",
      );
    const result = (await response.json()) as BugReportCapture;
    if (!/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(result.reportId))
      throw new Error("The Mac returned an invalid report. Try again.");
    capture = result;
    download.href = `/api/diagnostics/reports/${capture.reportId}`;
    download.hidden = false;
    status.textContent =
      "Snapshot saved on your Mac. Download it to inspect locally; it is not attached to the issue.";
    log.info("bug-report.snapshot.saved", { reportId: capture.reportId });
  } catch (error) {
    status.textContent =
      error instanceof Error
        ? error.message
        : "Snapshot unavailable. You can still report the bug.";
    retry.hidden = false;
  } finally {
    capturing = false;
    updatePreview();
  }
}
retry.onclick = () => {
  void saveCapture();
};
updatePreview();
async function start() {
  if (ticket) {
    try {
      const response = await fetch("/api/pair/dashboard", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ticket }),
        signal: AbortSignal.timeout(10_000),
      });
      if (!response.ok)
        throw new Error(
          "Open Report a Bug again from SlopZooka to connect this browser.",
        );
    } catch (error) {
      status.textContent =
        error instanceof Error
          ? error.message
          : "Connect this browser in the dashboard to save diagnostics.";
      retry.hidden = false;
      return;
    }
  }
  log.info("bug-report.opened");
  await saveCapture();
}
void start();
