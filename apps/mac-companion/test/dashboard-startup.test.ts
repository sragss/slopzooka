import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

// Exercise the independent inline fallback, which must work when harness.js
// cannot be downloaded or throws during initialization.
const html = fs.readFileSync(
  new URL("../public/index.html", import.meta.url),
  "utf8",
);
const bootstrap = html.match(
  /<script id="dashboard-startup">([\s\S]*?)<\/script>/,
)![1]!;
function fixture() {
  const window = new EventTarget();
  const script = new EventTarget();
  const loading = { hidden: false };
  const error = { hidden: true };
  const label = { textContent: "Connecting…" };
  const retry = { onclick: () => {} };
  const elements = new Map<string, unknown>([
    ["loading", loading],
    ["startup-error", error],
    ["connection-label", label],
    ["dashboard-script", script],
    ["retry-startup", retry],
  ]);
  let timeout: () => void;
  let cancelled = false;
  let reloads = 0;
  vm.runInNewContext(bootstrap, {
    window,
    document: { getElementById: (id: string) => elements.get(id) },
    location: { reload: () => reloads++ },
    setTimeout: (run: () => void) => {
      timeout = run;
      return 1;
    },
    clearTimeout: () => {
      cancelled = true;
    },
  });
  return {
    window,
    script,
    loading,
    error,
    label,
    retry,
    expire: () => {
      if (!cancelled) timeout();
    },
    reloads: () => reloads,
  };
}

test("dashboard startup failures show Retry instead of leaving Connecting forever", () => {
  for (const trigger of [
    (f: ReturnType<typeof fixture>) =>
      f.script.dispatchEvent(new Event("error")),
    (f: ReturnType<typeof fixture>) =>
      f.window.dispatchEvent(new Event("error")),
    (f: ReturnType<typeof fixture>) => f.expire(),
  ]) {
    const f = fixture();
    trigger(f);
    assert.equal(f.loading.hidden, true);
    assert.equal(f.error.hidden, false);
    assert.equal(f.label.textContent, "Dashboard unavailable");
    f.retry.onclick();
    assert.equal(f.reloads(), 1);
  }
});

test("successful and late dashboard initialization dismiss startup failures and cancel the watchdog", () => {
  for (const late of [false, true]) {
    const f = fixture();
    if (late) f.expire();
    f.window.dispatchEvent(new Event("slz-dashboard-ready"));
    assert.equal(f.error.hidden, true);
    assert.equal(f.loading.hidden, false);
    assert.equal(f.label.textContent, "Connecting…");
    f.expire();
    f.window.dispatchEvent(new Event("error"));
    f.script.dispatchEvent(new Event("error"));
    assert.equal(
      f.error.hidden,
      true,
      "startup handlers do not overwrite the running dashboard",
    );
  }
});
