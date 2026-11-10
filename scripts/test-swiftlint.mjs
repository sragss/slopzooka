import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "slz-window-lint-"));
const vision = "apps/vision-client/SlopZooka/SlopZooka";
const cases = [
  [
    `${vision}/WindowScene.swift`,
    'func show() { openWindow(id: "launcher"); dismissWindow(id: "terminal") }',
    false,
  ],
  [
    `${vision}/ContentView.swift`,
    "struct Probe { @Environment(\\.openWindow) private var showWindow }",
    true,
  ],
  [
    `${vision}/TerminalWindowView.swift`,
    'func close() { dismissWindow(id: "terminal") }',
    true,
  ],
  [
    `${vision}/Nested/WindowScene.swift`,
    'func show() { openWindow(id: "launcher") }',
    true,
  ],
  [
    `${vision}/Help.swift`,
    '// openWindow(id: "launcher")\nlet help = "dismissWindow(id:)"',
    false,
  ],
  [
    "apps/mac-menu/Sources/Panel.swift",
    'func show() { openWindow(id: "pairing") }',
    false,
  ],
];

try {
  const files = [];
  for (const [name, source] of cases) {
    const file = path.join(temporary, name);
    await fs.mkdir(path.dirname(file), { recursive: true });
    await fs.writeFile(file, source);
    files.push(file);
  }
  const result = spawnSync(
    path.join(root, ".build/swiftlint/swiftlint"),
    [
      "lint",
      "--config",
      path.join(root, ".swiftlint.yml"),
      "--quiet",
      "--no-cache",
      "--reporter",
      "json",
      ...files,
    ],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 2, result.stderr || String(result.error));
  const findings = JSON.parse(result.stdout);
  assert(
    findings.every((finding) => finding.rule_id === "native_window_actions"),
    result.stdout,
  );
  assert.deepEqual(
    findings.map((finding) => path.relative(temporary, finding.file)).sort(),
    cases
      .filter(([, , rejected]) => rejected)
      .map(([name]) => name)
      .sort(),
  );
  console.log(
    "PASS: native window actions stay in the scene adapter; aliases, path scope, comments, and strings are checked",
  );
} finally {
  await fs.rm(temporary, { recursive: true, force: true });
}
