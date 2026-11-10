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
window.runKeyboardChecks = async () => {
  const check = (expected, label) => {
    if (JSON.stringify(data) !== JSON.stringify(expected)) throw Error(label + ': ' + JSON.stringify(data));
    data = [];
  };
  const edit = (type, target = input, composing = false) => target.dispatchEvent(new InputEvent('beforeinput', {
    inputType: type, bubbles: true, cancelable: true, isComposing: composing
  }));
  edit('insertLineBreak'); check(['\\r'], 'floating Return');
  edit('insertParagraph'); check(['\\r'], 'paragraph Return');
  const accepted = input.dispatchEvent(new KeyboardEvent('keydown', {
    key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true
  }));
  if (accepted) edit('insertLineBreak');
  input.dispatchEvent(new KeyboardEvent('keyup', {key: 'Enter', keyCode: 13, bubbles: true}));
  check(['\\r'], 'hardware Enter must not double submit');
  for (const mode of ['none', 'text']) {
    input.inputMode = mode;
    for (const [key, code, keyCode, expected, modifiers = {}] of [
      ['Backspace', 'Backspace', 8, '\\x7f'],
      ['Delete', 'Delete', 46, '\\x1b[3~'],
      ['Tab', 'Tab', 9, '\\t'],
      ['Escape', 'Escape', 27, '\\x1b'],
      ['ArrowLeft', 'ArrowLeft', 37, '\\x1b[D'],
      ['ArrowUp', 'ArrowUp', 38, '\\x1b[1;3A', {altKey: true}],
      ['Backspace', 'Backspace', 8, '\\b', {ctrlKey: true}],
      ['Backspace', 'Backspace', 8, '\\x1b\\x7f', {altKey: true}],
    ]) {
      const options = {key, code, keyCode, which: keyCode, bubbles: true, cancelable: true, ...modifiers};
      const accepted = input.dispatchEvent(new KeyboardEvent('keydown', options));
      if (accepted && key === 'Backspace') edit('deleteContentBackward');
      if (accepted && key === 'Delete') edit('deleteContentForward');
      input.dispatchEvent(new KeyboardEvent('keyup', options));
      check([expected], key + ' in inputmode=' + mode);
    }
    for (const keyCode of [0, 229, 67]) {
      const options = {key: 'c', code: 'KeyC', keyCode, which: keyCode, ctrlKey: true, bubbles: true, cancelable: true};
      input.dispatchEvent(new KeyboardEvent('keydown', options));
      input.dispatchEvent(new KeyboardEvent('keyup', options));
      check(['\\x03'], 'Control-C with keyCode=' + keyCode + ' in inputmode=' + mode);
    }
    for (const keyCode of [0, 229]) {
      for (let code = 65; code <= 90; code++) {
        for (const key of [String.fromCharCode(code).toLowerCase(), String.fromCharCode(code)]) {
          const options = {key, code: 'Key' + String.fromCharCode(code), keyCode, which: keyCode, ctrlKey: true, bubbles: true, cancelable: true};
          input.dispatchEvent(new KeyboardEvent('keydown', options));
          input.dispatchEvent(new KeyboardEvent('keyup', options));
          check([String.fromCharCode(code - 64)], 'Control-' + key + ' keyCode=' + keyCode + ' in inputmode=' + mode);
        }
      }
      input.dispatchEvent(new KeyboardEvent('keydown', {key: String.fromCharCode(3), code: 'KeyC', keyCode, ctrlKey: true, bubbles: true, cancelable: true}));
      check(['\\x03'], 'Control character key must retain its physical Control-C code');
      for (const extra of [{isComposing: true}, {metaKey: true}, {altKey: true}, {shiftKey: true}]) {
        input.dispatchEvent(new KeyboardEvent('keydown', {key: 'c', code: 'KeyC', keyCode, ctrlKey: true, bubbles: true, cancelable: true, ...extra}));
        check([], 'Composition and additional modifiers must not become plain Control-C');
      }
    }
    for (const [direction, suffix] of [['Up', 'A'], ['Down', 'B'], ['Right', 'C'], ['Left', 'D']]) {
      for (const key of ['UIKeyInput' + direction + 'Arrow', 'Arrow' + direction]) {
        for (const keyCode of [0, 229]) {
          for (const [modifiers, parameter] of [[{altKey: true}, '3'], [{}, ''], [{ctrlKey: true}, '5'], [{shiftKey: true, altKey: true}, '4'], [{ctrlKey: true, altKey: true}, '7']]) {
            const options = {key, code: 'Arrow' + direction, keyCode, which: keyCode, bubbles: true, cancelable: true, ...modifiers};
            input.dispatchEvent(new KeyboardEvent('keydown', options));
            input.dispatchEvent(new KeyboardEvent('keyup', options));
            check(['\\x1b[' + (parameter ? '1;' + parameter : '') + suffix], key + ' modifiers=' + parameter + ' keyCode=' + keyCode + ' in inputmode=' + mode);
          }
        }
      }
    }
  }
  const arrow = (target = input, extra = {}) => target.dispatchEvent(new KeyboardEvent('keydown', {
    key: 'UIKeyInputUpArrow', keyCode: 0, altKey: true, bubbles: true, cancelable: true, ...extra
  }));
  await new Promise(resolve => terminal.write('\\x1b[?1h', resolve));
  arrow(); check(['\\x1b[1;3A'], 'Alt+Up in application cursor mode');
  arrow(input, {altKey: false}); check(['\\x1bOA'], 'plain Up must retain application cursor mode');
  await new Promise(resolve => terminal.write('\\x1b[?1l', resolve));
  arrow(); arrow(input, {repeat: true});
  check(['\\x1b[1;3A', '\\x1b[1;3A'], 'held Alt+Up must emit once per keydown');
  arrow(input, {keyCode: 229, isComposing: true});
  await new Promise(resolve => setTimeout(resolve, 0));
  check([], 'composing arrow must not be converted into a shortcut');
  arrow(input, {metaKey: true}); check([], 'Command must not be dropped from arrow shortcuts');
  if (!arrow(document.getElementById('other'))) throw Error('other fields must retain native arrow behavior');
  check([], 'other fields must not send arrow shortcuts');
  const handledArrow = new KeyboardEvent('keydown', {key: 'UIKeyInputUpArrow', keyCode: 0, altKey: true, bubbles: true, cancelable: true});
  handledArrow.preventDefault(); input.dispatchEvent(handledArrow);
  check([], 'already handled arrow must not emit input');
  edit('deleteContentBackward'); check(['\\x7f'], 'editing-only Backspace');
  edit('deleteContentForward'); check(['\\x1b[3~'], 'editing-only Delete');
  for (const keyCode of [0, 229]) {
    input.value = 'x';
    input.dispatchEvent(new KeyboardEvent('keydown', {key: 'Backspace', code: 'Backspace', keyCode, bubbles: true, cancelable: true}));
    edit('deleteContentBackward');
    input.dispatchEvent(new KeyboardEvent('keyup', {key: 'Backspace', code: 'Backspace', keyCode, bubbles: true}));
    await new Promise(resolve => setTimeout(resolve, 0));
    check(['\\x7f'], 'Backspace with unusable keyCode=' + keyCode + ' must send exactly once');
    input.value = '';
  }
  edit('deleteContentBackward'); edit('deleteContentBackward');
  check(['\\x7f', '\\x7f'], 'repeated editing-only Backspace');
  edit('deleteContentBackward', input, true); check([], 'composition deletion must not emit a terminal key');
  edit('deleteContentForward', input, true); check([], 'composition forward deletion must not emit a terminal key');
  edit('deleteContentBackward', document.getElementById('other')); check([], 'other fields must keep their deletion behavior');
  edit('deleteContentForward', document.getElementById('other')); check([], 'other fields must keep forward deletion');
  const alreadyHandled = new InputEvent('beforeinput', {inputType: 'deleteContentBackward', bubbles: true, cancelable: true});
  alreadyHandled.preventDefault(); input.dispatchEvent(alreadyHandled);
  check([], 'already handled deletion must not duplicate input');
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
    path.join(
      root,
      "apps/vision-client/SlopZooka/SlopZooka/TerminalZoom.swift",
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
let viewportSocket;
class ViewportSocket {
  static OPEN = 1; static CLOSING = 2;
  readyState = 1;
  constructor() { viewportSocket = this; queueMicrotask(() => this.receive({type: 'hello', version: 1, supportsTakeControl: true})); }
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
if (new URLSearchParams(location.search).has('legacy')) delete window.slzSetTerminalZoom;
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
  const isFocused = () => document.activeElement === terminal.textarea;
  const inputs = () => sent.filter(message => message.type === 'input').map(message => message.data);
  const checkInputs = (expected, label) => check(JSON.stringify(inputs()) === JSON.stringify(expected), label + ': ' + JSON.stringify(inputs()));
  const hardwareKey = (key, code, keyCode, modifiers = {}) => {
    const target = document.activeElement;
    const options = {key, code, keyCode, which: keyCode, bubbles: true, cancelable: true, ...modifiers};
    const accepted = target.dispatchEvent(new KeyboardEvent('keydown', options));
    if (accepted && key.length === 1) target.dispatchEvent(new KeyboardEvent('keypress', {
      ...options, keyCode: key.charCodeAt(0), charCode: key.charCodeAt(0), which: key.charCodeAt(0)
    }));
    target.dispatchEvent(new KeyboardEvent('keyup', options));
  };
  check(isFocused(), 'Opening a terminal must be ready for physical keyboard typing');
  check(terminal.textarea.inputMode === 'none', 'Automatic focus must suppress only the software keyboard');
  check(!terminal.textarea.readOnly && !terminal.textarea.disabled, 'Hardware input must remain editable');
  hardwareKey('a', 'KeyA', 65);
  hardwareKey('ArrowLeft', 'ArrowLeft', 37);
  hardwareKey('Enter', 'Enter', 13);
  hardwareKey('c', 'KeyC', 0, {ctrlKey: true});
  checkInputs(['a', '\\x1b[D', '\\r', '\\x03'], 'Hardware text, arrows, Return, and Ctrl+C must reach the PTY without requesting software UI');
  window.slzFocusTerminal(true);
  check(isFocused() && terminal.textarea.inputMode === 'text', 'The Keyboard button must request software UI while keeping input focused');
  window.slzInterruptTerminal();
  check(isFocused() && terminal.textarea.inputMode === 'text', 'Interrupt must preserve the requested keyboard mode');
  checkInputs(['a', '\\x1b[D', '\\r', '\\x03', '\\x1b'], 'Focused interrupt must send exactly one Escape');
  window.slzFocusTerminal(false);
  check(isFocused() && terminal.textarea.inputMode === 'none', 'Reactivating a terminal must restore physical input without software UI');
  hardwareKey('b', 'KeyB', 66);
  checkInputs(['a', '\\x1b[D', '\\r', '\\x03', '\\x1b', 'b'], 'Hardware typing must work after reactivation');
  terminal.blur();
  mount.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true}));
  check(isFocused() && terminal.textarea.inputMode === 'text', 'Tapping the terminal must explicitly request the software keyboard');
  terminal.blur();
  window.slzInterruptTerminal();
  check(!isFocused() && terminal.textarea.inputMode === 'text', 'Interrupt must not change focus or keyboard mode');
  checkInputs(['a', '\\x1b[D', '\\r', '\\x03', '\\x1b', 'b', '\\x1b'], 'Unfocused interrupt must send exactly one Escape');
  window.slzFocusTerminal(false);
  const attachments = () => sent.filter(message => message.type === 'attach').length;
  const beforeReconnect = attachments();
  window.dispatchEvent(new Event('online'));
  await until(() => attachments() > beforeReconnect && resizes().length > 1);
  check(isFocused() && terminal.textarea.inputMode === 'none', 'Reconnecting must preserve physical keyboard focus and software suppression');
  hardwareKey('d', 'KeyD', 68);
  checkInputs(['a', '\\x1b[D', '\\r', '\\x03', '\\x1b', 'b', '\\x1b', 'd'], 'Hardware typing must survive reconnection');
  const legacy = new URLSearchParams(location.search).has('legacy');
  check(legacy || typeof window.slzSetTerminalZoom === 'function', 'Native zoom bridge missing');
  let normalCols = terminal.cols, normalRows = terminal.rows;
  for (const zoom of [0.6, 0.7, 0.5, 0.3, 0.1, 1, 2, 0.6]) {
    const before = resizes().length;
    window.applyNativeZoom(zoom);
    await until(() => resizes().length > before);
    const size = resizes().at(-1);
    check(isFocused() && terminal.textarea.inputMode === 'none', 'Zoom must preserve physical keyboard focus and software suppression');
    check(isClientMessage(size), 'Invalid resize at zoom ' + zoom);
    check(size.cols === terminal.cols && size.rows === terminal.rows, 'PTY and emulator grids diverged');
    if (zoom === 0.6 || zoom === 0.7 || zoom === 0.5 || zoom === 0.3) {
      check(terminal.cols > normalCols && terminal.rows > normalRows, 'Zoom-out must increase the PTY grid');
    }
    const screen = document.querySelector('.xterm-screen').getBoundingClientRect();
    const viewport = mount.getBoundingClientRect();
    if (terminal.cols < MAX_TERMINAL_DIMENSION) check(screen.width >= viewport.width - screen.width / terminal.cols - 20, 'Right-side gap at zoom ' + zoom + ': ' + JSON.stringify({screen: screen.width, viewport: viewport.width, cols: terminal.cols}));
    if (terminal.rows < MAX_TERMINAL_DIMENSION) check(screen.height >= viewport.height - screen.height / terminal.rows - 1, 'Bottom gap at zoom ' + zoom);
  }
  const button = document.getElementById('take-control');
  const beforeShortcut = inputs().length;
  for (const showKeyboard of [false, true]) {
    window.slzFocusTerminal(showKeyboard);
    hardwareKey('UIKeyInputUpArrow', '', 0, {altKey: true});
    check(isFocused() && terminal.textarea.inputMode === (showKeyboard ? 'text' : 'none'), 'Alt+Up must preserve focus and keyboard mode');
  }
  check(JSON.stringify(inputs().slice(beforeShortcut)) === JSON.stringify(['\\x1b[1;3A', '\\x1b[1;3A']), 'Alt+Up must reach the production PTY transport exactly once in each keyboard mode');
  viewportSocket.receive({type: 'ownership', sessionId, writable: false});
  await until(() => !button.hidden);
  const beforeReadOnlyShortcut = inputs().length;
  hardwareKey('UIKeyInputUpArrow', '', 0, {altKey: true});
  hardwareKey('c', 'KeyC', 0, {ctrlKey: true});
  check(inputs().length === beforeReadOnlyShortcut, 'Normalized arrow and Control shortcuts must respect read-only ownership');
  check(!readOnlyBadge.hidden, 'Revoked viewers must show read-only state');
  check(getComputedStyle(button).display !== 'none', 'Browser takeover action must be visible');
  document.documentElement.dataset.nativeTerminal = 'true';
  check(getComputedStyle(button).display === 'none', 'Take Control must stay hidden on Vision Pro');
  delete document.documentElement.dataset.nativeTerminal;
  button.click();
  check(sent.at(-1).type === 'take-control', 'Takeover must use the existing session connection');
  check(!button.hidden, 'Control must not change before the service confirms it');
  viewportSocket.receive({type: 'ownership', sessionId, writable: true});
  await until(() => readOnlyBadge.hidden);
  check(button.hidden, 'Confirmed takeover dismisses the action');
  check(document.activeElement === terminal.textarea, 'Taking control must focus terminal input');
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
  run(executable, [viewportHTML, "legacy"]);
  const nativeChecks = path.join(temporary, "native-focus-checks");
  run("xcrun", [
    "swiftc",
    "-swift-version",
    "5",
    "-parse-as-library",
    ...[
      "CompanionWebView",
      "CompanionModels",
      "TerminalNavigation",
      "TerminalZoom",
    ].map((name) =>
      path.join(root, `apps/vision-client/SlopZooka/SlopZooka/${name}.swift`),
    ),
    path.join(
      root,
      "apps/vision-client/tests/TerminalSessionControllerChecks.swift",
    ),
    "-o",
    nativeChecks,
  ]);
  run(nativeChecks, []);
  const browserChecks = path.join(temporary, "browser-navigation-checks");
  run("xcrun", [
    "swiftc",
    "-swift-version",
    "5",
    "-parse-as-library",
    path.join(
      root,
      "apps/vision-client/SlopZooka/SlopZooka/BrowserNavigation.swift",
    ),
    path.join(root, "apps/vision-client/tests/BrowserNavigationChecks.swift"),
    "-o",
    browserChecks,
  ]);
  run(browserChecks, []);
} finally {
  await fs.rm(temporary, { recursive: true, force: true });
}
