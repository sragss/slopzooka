import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "slz-keyboard-"));
const run = (command, args) =>
  execFileSync(command, args, { cwd: root, stdio: "inherit", timeout: 60_000 });
try {
  const entry = path.join(temporary, "fixture.js");
  await fs.writeFile(
    entry,
    `
import { Terminal } from ${JSON.stringify(path.join(root, "apps/mac-companion/node_modules/@xterm/xterm"))};
const terminal = new Terminal();
terminal.open(document.getElementById('terminal'));
const input = terminal.textarea;
let data = [];
terminal.onData(value => data.push(value));
window.runKeyboardChecks = () => {
  const check = (expected, label) => {
    if (JSON.stringify(data) !== JSON.stringify(expected)) throw Error(label + ': ' + JSON.stringify(data));
    data = [];
  };
  const edit = (type, target = input, composing = false) => target.dispatchEvent(new InputEvent('beforeinput', {
    inputType: type, bubbles: true, cancelable: true, isComposing: composing
  }));
  window.slzInterruptTerminal(); check(['\\x1b'], 'interrupt sends Escape');
  edit('insertLineBreak'); check(['\\r'], 'floating Return');
  edit('insertParagraph'); check(['\\r'], 'paragraph Return');
  const accepted = input.dispatchEvent(new KeyboardEvent('keydown', {
    key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true
  }));
  if (accepted) edit('insertLineBreak');
  input.dispatchEvent(new KeyboardEvent('keyup', {key: 'Enter', keyCode: 13, bubbles: true}));
  check(['\\r'], 'hardware Enter must not double submit');
  input.dispatchEvent(new InputEvent('input', {inputType:'insertText', data:'x', bubbles:true}));
  check(['x'], 'normal typing');
  edit('insertLineBreak', input, true); check([], 'composition must not submit');
  edit('insertLineBreak', document.getElementById('other')); check([], 'other fields must not submit');
  return 'PASS';
};`,
  );
  const bundle = path.join(temporary, "fixture.bundle.js");
  run("pnpm", [
    "--filter",
    "@slz/mac-companion",
    "exec",
    "esbuild",
    entry,
    "--bundle",
    "--platform=browser",
    `--outfile=${bundle}`,
  ]);
  const html = path.join(temporary, "fixture.html");
  await fs.writeFile(
    html,
    `<div id="terminal"></div><textarea id="other"></textarea><script>${(await fs.readFile(bundle, "utf8")).replaceAll("</script", "<\\/script")}</script>`,
  );
  const executable = path.join(temporary, "checks");
  run("xcrun", [
    "swiftc",
    "-swift-version",
    "5",
    "-parse-as-library",
    path.join(
      root,
      "apps/vision-client/SlopZooka/SlopZooka/TerminalKeyboard.swift",
    ),
    path.join(root, "apps/vision-client/tests/TerminalKeyboardChecks.swift"),
    "-o",
    executable,
  ]);
  run(executable, [html]);
  // Exercise the production renderer and zoom bridge in real WebKit. The fake
  // transport records PTY resize messages without creating any sessions.
  const esbuild = await import(
    pathToFileURL(
      path.join(root, "apps/mac-companion/node_modules/esbuild/lib/main.js"),
    ).href
  );
  const viewportBundle = path.join(temporary, "viewport.js");
  const renderer = await fs.readFile(
    path.join(root, "apps/mac-companion/src/terminal.ts"),
    "utf8",
  );
  esbuild.buildSync({
    stdin: {
      resolveDir: path.join(root, "apps/mac-companion/src"),
      loader: "ts",
      contents: `
import { isClientMessage, MAX_TERMINAL_DIMENSION } from "../../../packages/protocol/src/index.js";
const sent = [];
class ViewportSocket {
  static OPEN = 1; static CLOSING = 2;
  readyState = 1;
  constructor() { queueMicrotask(() => this.receive({type: 'hello', version: 1})); }
  receive(message) { this.onmessage?.({data: JSON.stringify(message)}); }
  send(raw) {
    const message = JSON.parse(raw); sent.push(message);
    if (message.type === 'attach') queueMicrotask(() => this.receive({
      type: 'attached', session: {id: message.sessionId, cols: 80, rows: 24, status: 'running'},
      cursor: 0, snapshot: '', writable: true
    }));
  }
  close() { this.readyState = 3; this.onclose?.(); }
}
window.WebSocket = ViewportSocket;
${renderer}
window.runViewportChecks = async () => {
  const check = (ok, label) => { if (!ok) throw Error(label); };
  const until = async (condition) => {
    for (let i = 0; i < 120; i++) {
      if (condition()) return;
      await new Promise(resolve => setTimeout(resolve, 16));
    }
    throw Error('Resize did not reach the PTY transport');
  };
  const resizes = () => sent.filter(message => message.type === 'resize');
  await until(() => resizes().length > 0);
  check(typeof window.slzSetTerminalZoom === 'function', 'Native zoom bridge missing');
  let normalCols = terminal.cols, normalRows = terminal.rows;
  for (const zoom of [0.8, 0.5, 0.3, 0.1, 1, 2, 0.8]) {
    const before = resizes().length;
    window.slzSetTerminalZoom(zoom);
    await until(() => resizes().length > before);
    const size = resizes().at(-1);
    check(isClientMessage(size), 'Invalid resize at zoom ' + zoom);
    check(size.cols === terminal.cols && size.rows === terminal.rows, 'PTY and emulator grids diverged');
    if (zoom === 0.8 || zoom === 0.5 || zoom === 0.3) {
      check(terminal.cols > normalCols && terminal.rows > normalRows, 'Zoom-out must increase the PTY grid');
    }
    const screen = document.querySelector('.xterm-screen').getBoundingClientRect();
    const viewport = mount.getBoundingClientRect();
    if (terminal.cols < MAX_TERMINAL_DIMENSION) check(screen.width >= viewport.width - screen.width / terminal.cols - 20, 'Right-side gap at zoom ' + zoom + ': ' + JSON.stringify({screen: screen.width, viewport: viewport.width, cols: terminal.cols}));
    if (terminal.rows < MAX_TERMINAL_DIMENSION) check(screen.height >= viewport.height - screen.height / terminal.rows - 1, 'Bottom gap at zoom ' + zoom);
  }
  window.slzDetachTerminal();
  return 'PASS';
};`,
    },
    bundle: true,
    platform: "browser",
    outfile: viewportBundle,
  });
  const viewportHTML = path.join(temporary, "viewport.html");
  const viewportCSS = await fs.readFile(
    path.join(temporary, "viewport.css"),
    "utf8",
  );
  const viewportScript = (await fs.readFile(viewportBundle, "utf8")).replaceAll(
    "</script",
    "<\\/script",
  );
  // Use the production surface so renderer/UI changes cannot leave this
  // viewport fixture with stale element IDs or layout rules.
  const surface = (
    await fs.readFile(
      path.join(root, "apps/mac-companion/public/terminal.html"),
      "utf8",
    )
  )
    .replace(
      '<link rel="stylesheet" href="/terminal.css" />',
      () => `<style>${viewportCSS}</style>`,
    )
    .replace(
      '<script type="module" src="/terminal.js"></script>',
      () => `<script>${viewportScript}</script>`,
    );
  await fs.writeFile(viewportHTML, surface);
  run(executable, [viewportHTML, "viewport"]);
} finally {
  await fs.rm(temporary, { recursive: true, force: true });
}
