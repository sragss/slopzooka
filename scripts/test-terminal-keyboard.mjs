import { swiftSources } from "./swift-sources.mjs";
import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sharedSources = await swiftSources(path.join(root, "apps/shared"));
const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "slz-keyboard-"));
const run = (command, args) =>
  execFileSync(command, args, { cwd: root, stdio: "inherit", timeout: 60_000 });
try {
  const entry = path.join(temporary, "fixture.js");
  await fs.writeFile(
    entry,
    `
import { Terminal } from ${JSON.stringify(path.join(root, "apps/mac-companion/node_modules/@xterm/xterm"))};
import { bindTerminalTextInput } from ${JSON.stringify(path.join(root, "apps/mac-companion/src/terminal-text-input.ts"))};
const terminal = new Terminal();
terminal.open(document.getElementById('terminal'));
const detachTextInput = bindTerminalTextInput(terminal);
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
  const physicalKey = (options, text, keypress = false) => {
    const event = {bubbles: true, cancelable: true, ...options};
    input.dispatchEvent(new KeyboardEvent('keydown', event));
    if (keypress) input.dispatchEvent(new KeyboardEvent('keypress', {...event, charCode: text.charCodeAt(0), keyCode: text.charCodeAt(0), which: text.charCodeAt(0)}));
    const accepted = input.dispatchEvent(new InputEvent('beforeinput', {inputType: 'insertText', data: text, bubbles: true, cancelable: true, composed: true}));
    if (accepted) {
      input.value += text;
      input.dispatchEvent(new InputEvent('input', {inputType: 'insertText', data: text, bubbles: true, composed: true}));
    }
    input.dispatchEvent(new KeyboardEvent('keyup', event));
  };
  const keyOnly = (key, keyCode, modifiers = {}) => {
    const options = {key, code: key, keyCode, which: keyCode, bubbles: true, cancelable: true, ...modifiers};
    input.dispatchEvent(new KeyboardEvent('keydown', options));
    input.dispatchEvent(new KeyboardEvent('keyup', options));
  };
  for (const mode of ['none', 'text']) {
    input.inputMode = mode;
    for (const keyCode of [0, 229, 65]) {
      for (const [key, text, modifiers = {}] of [
        ['A', 'A', {shiftKey: true}], ['A', 'A', {modifierCapsLock: true}],
        ['!', '!', {shiftKey: true}], ['_', '_', {shiftKey: true}],
        ['é', 'é', {altKey: true}], ['😀', '😀'],
      ]) {
        physicalKey({key, keyCode, code: 'KeyA', ...modifiers}, text);
        await new Promise(resolve => setTimeout(resolve, 0));
        check([text], 'committed text without keypress ' + key + ' keyCode=' + keyCode + ' inputmode=' + mode);
      }
    }
    for (const key of ['Shift', 'CapsLock', 'Unidentified']) {
      for (const keyCode of [0, 229]) {
        physicalKey({key, keyCode, shiftKey: true}, 'A');
        await new Promise(resolve => setTimeout(resolve, 0));
        check(['A'], 'committed text after modifier-only or unidentified keydown ' + key);
      }
    }
    physicalKey({key: 'A', code: 'KeyA', keyCode: 65, shiftKey: true}, 'A', true);
    check(['A'], 'native keypress plus beforeinput must send once');
    physicalKey({key: 'a', code: 'KeyA', keyCode: 65}, 'a');
    check(['a'], 'handled keydown plus beforeinput must send once');
    physicalKey({key: 'A', code: 'KeyA', keyCode: 0, shiftKey: true, repeat: true}, 'A');
    physicalKey({key: 'A', code: 'KeyA', keyCode: 0, shiftKey: true, repeat: true}, 'A');
    check(['A', 'A'], 'repeat must send once per committed edit');
    const namedKeys = [
      ['ArrowUp', 38], ['ArrowDown', 40], ['ArrowLeft', 37], ['ArrowRight', 39],
      ['Home', 36], ['End', 35], ['PageUp', 33], ['PageDown', 34],
      ['Enter', 13], ['Tab', 9], ['Backspace', 8], ['Delete', 46], ['Escape', 27],
      ...Array.from({length: 12}, (_, i) => ['F' + (i + 1), 112 + i]),
    ];
    for (let mask = 0; mask < 16; mask++) {
      const modifiers = {shiftKey: !!(mask & 1), altKey: !!(mask & 2), ctrlKey: !!(mask & 4), metaKey: !!(mask & 8)};
      for (const [key, canonical] of namedKeys) {
        keyOnly(key, canonical, modifiers);
        const expected = data; data = [];
        for (const keyCode of [0, 229]) {
          keyOnly(key, keyCode, modifiers);
          check(expected, key + ' modifier mask=' + mask + ' keyCode=' + keyCode + ' inputmode=' + mode);
        }
      }
    }
    for (const [key, code, canonical, modifiers = {}] of [
      [' ', 'Space', 32], ['[', 'BracketLeft', 219], ['\\\\', 'Backslash', 220], [']', 'BracketRight', 221],
      ['@', 'Digit2', 50, {shiftKey: true}], ['_', 'Minus', 189, {shiftKey: true}], ['6', 'Digit6', 54],
    ]) {
      for (const keyCode of [canonical, 0, 229]) {
        for (const physicalCode of [code, '']) {
          const options = {key, code: physicalCode, keyCode, ctrlKey: true, bubbles: true, cancelable: true, ...modifiers};
          input.dispatchEvent(new KeyboardEvent('keydown', options)); input.dispatchEvent(new KeyboardEvent('keyup', options));
        check([String.fromCharCode({' ': 0, '[': 27, '\\\\': 28, ']': 29, '@': 0, '_': 31, '6': 30}[key])], 'Control punctuation ' + key + ' keyCode=' + keyCode);
        }
      }
    }
    for (const key of ['Shift', 'Control', 'Alt', 'Meta', 'CapsLock', 'Fn', 'FnLock', 'Globe']) {
      keyOnly(key, 0); check([], key + ' alone must not create terminal bytes');
    }
    keyOnly('F1', 0, {modifierFn: true}); check(['\\x1bOP'], 'delivered Fn function key');
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
  arrow(input, {key: 'Unidentified', code: 'ArrowUp', keyCode: 229});
  check(['\\x1b[1;3A'], 'An unidentified navigation key must use its physical code');
  if (!arrow(document.getElementById('other'))) throw Error('other fields must retain native arrow behavior');
  check([], 'other fields must not send arrow shortcuts');
  const handledArrow = new KeyboardEvent('keydown', {key: 'UIKeyInputUpArrow', keyCode: 0, altKey: true, bubbles: true, cancelable: true});
  handledArrow.preventDefault(); input.dispatchEvent(handledArrow);
  check([], 'already handled arrow must not emit input');
  input.dispatchEvent(new KeyboardEvent('keydown', {key: 'A', code: 'KeyA', keyCode: 0, shiftKey: true, bubbles: true}));
  input.dispatchEvent(new FocusEvent('blur'));
  const afterBlur = new InputEvent('beforeinput', {inputType: 'insertText', data: 'A', bubbles: true, cancelable: true});
  if (!input.dispatchEvent(afterBlur)) throw Error('Blur must clear pending hardware text');
  check([], 'stale hardware stroke after blur');
  const otherText = new InputEvent('beforeinput', {inputType: 'insertText', data: 'A', bubbles: true, cancelable: true});
  if (!document.getElementById('other').dispatchEvent(otherText)) throw Error('Other text fields must keep native text editing');
  input.value = '';
  input.dispatchEvent(new CompositionEvent('compositionstart', {data: '', bubbles: true}));
  input.dispatchEvent(new KeyboardEvent('keydown', {key: 'Unidentified', keyCode: 229, isComposing: true, bubbles: true}));
  const composing = new InputEvent('beforeinput', {inputType: 'insertCompositionText', data: '中', isComposing: true, bubbles: true, cancelable: true});
  if (!input.dispatchEvent(composing)) throw Error('Composition must retain native editing');
  input.value = '中';
  input.dispatchEvent(new CompositionEvent('compositionupdate', {data: '中', bubbles: true}));
  await new Promise(resolve => setTimeout(resolve, 0));
  input.dispatchEvent(new CompositionEvent('compositionend', {data: '中', bubbles: true}));
  input.dispatchEvent(new KeyboardEvent('keyup', {key: 'Unidentified', keyCode: 229, bubbles: true}));
  await new Promise(resolve => setTimeout(resolve, 0));
  check(['中'], 'IME commit must remain native and send once');
  input.value = '';
  edit('deleteContentBackward'); check(['\\x7f'], 'editing-only Backspace');
  edit('deleteContentForward'); check(['\\x1b[3~'], 'editing-only Delete');
  for (const keyCode of [0, 229]) {
    input.value = 'x';
    const accepted = input.dispatchEvent(new KeyboardEvent('keydown', {key: 'Backspace', code: 'Backspace', keyCode, bubbles: true, cancelable: true}));
    if (accepted) edit('deleteContentBackward');
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
  terminal.options.screenReaderMode = true;
  input.dispatchEvent(new KeyboardEvent('keydown', {key: 'A', code: 'KeyA', keyCode: 0, shiftKey: true, bubbles: true}));
  const accessibleText = new InputEvent('beforeinput', {inputType: 'insertText', data: 'A', bubbles: true, cancelable: true});
  if (!input.dispatchEvent(accessibleText)) throw Error('Screen-reader mode must retain native text editing');
  input.dispatchEvent(new KeyboardEvent('keyup', {key: 'A', keyCode: 0, bubbles: true}));
  check([], 'screen-reader native editing must not be replayed');
  terminal.options.screenReaderMode = false;
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
  // Exercise the production renderer and its native bridges in real WebKit.
  // The fake transport records outgoing messages without creating any sessions.
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
  constructor() { viewportSocket = this; queueMicrotask(() => this.receive({type: 'hello', version: 1, supportsTakeControl: true, supportsInputAck: true})); }
  receive(message) { this.onmessage?.({data: JSON.stringify(message)}); }
  send(raw) {
    const message = JSON.parse(raw); sent.push(message);
    if (message.type === 'input' && message.probeId !== undefined) queueMicrotask(() => this.receive({
      type: 'input-ack', sessionId: message.sessionId, probeId: message.probeId
    }));
    if (message.type === 'attach') queueMicrotask(() => this.receive({
      type: 'attached', session: {id: message.sessionId, cols: 80, rows: 24, status: 'running'},
      cursor: 0, snapshot: '', writable: true
    }));
  }
  close() { this.readyState = 3; this.onclose?.({code: 1000}); }
}
window.WebSocket = ViewportSocket;
${renderer}
if (new URLSearchParams(location.search).has('legacy')) delete window.slzSetTerminalZoom;
window.runViewportChecks = async () => {
  const check = (ok, label) => { if (!ok) throw Error(label); };
  const until = async (condition, attempts = 120) => {
    for (let i = 0; i < attempts; i++) {
      if (condition()) return;
      await new Promise(resolve => setTimeout(resolve, 16));
    }
    throw Error('Resize did not reach the PTY transport');
  };
  const resizes = () => sent.filter(message => message.type === 'resize');
  await until(() => resizes().length > 0);
  check(!dragScrollbackAvailable, 'An empty terminal must leave pinch-drag to WebKit');
  const isFocused = () => document.activeElement === terminal.textarea;
  const native = new URLSearchParams(location.search).has('native');
  const selectSurface = () => mount.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true}));
  if (native) {
    check(!isFocused() && terminal.textarea.inputMode === 'none', 'A headset terminal must suppress the software keyboard before native activation');
    selectSurface();
    check(isFocused() && terminal.textarea.inputMode === 'none', 'Early pointer selection must focus without the floating keyboard');
    window.slzBlurTerminal();
    window.slzFocusTerminal(false);
  }
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
  await Promise.resolve(); // Let the sampled receipt return before retiring this socket.
  window.slzFocusTerminal(true);
  check(isFocused() && terminal.textarea.inputMode === 'text', 'The Keyboard button must request software UI while keeping input focused');
  selectSurface();
  check(isFocused() && terminal.textarea.inputMode === 'text', 'Selection must preserve an explicitly requested keyboard during the same focus session');
  if (native) {
    let refocused = false;
    terminal.textarea.addEventListener('focus', () => { refocused = true; }, {once: true});
    window.slzFocusTerminal(true);
    check(refocused && terminal.textarea.inputMode === 'text', 'Another explicit request must restart WebKit focus so the system can reopen the keyboard');
  }
  window.slzInterruptTerminal();
  check(isFocused() && terminal.textarea.inputMode === 'text', 'Interrupt must preserve the requested keyboard mode');
  checkInputs(['a', '\\x1b[D', '\\r', '\\x03', '\\x1b'], 'Focused interrupt must send exactly one Escape');
  window.slzFocusTerminal(false);
  check(isFocused() && terminal.textarea.inputMode === 'none', 'Reactivating a terminal must restore physical input without software UI');
  hardwareKey('b', 'KeyB', 66);
  checkInputs(['a', '\\x1b[D', '\\r', '\\x03', '\\x1b', 'b'], 'Hardware typing must work after reactivation');
  window.slzFocusTerminal(true);
  window.slzBlurTerminal();
  check(!isFocused() && terminal.textarea.inputMode === (native ? 'none' : 'text'), 'Losing headset terminal focus must clear the explicit keyboard request');
  selectSurface();
  const selectedMode = native ? 'none' : 'text';
  check(isFocused() && terminal.textarea.inputMode === selectedMode, 'Selecting a headset terminal must focus for typing without reopening the floating keyboard');
  hardwareKey('e', 'KeyE', 69);
  window.slzBlurTerminal();
  window.slzInterruptTerminal();
  check(!isFocused() && terminal.textarea.inputMode === selectedMode, 'Interrupt must not change focus or keyboard mode');
  checkInputs(['a', '\\x1b[D', '\\r', '\\x03', '\\x1b', 'b', 'e', '\\x1b'], 'Hardware typing must work immediately after selection and unfocused interrupt must send exactly one Escape');
  window.slzFocusTerminal(false);
  const attachments = () => sent.filter(message => message.type === 'attach').length;
  const beforeReconnect = attachments();
  window.dispatchEvent(new Event('online'));
  await until(() => attachments() > beforeReconnect && resizes().length > 1);
  check(isFocused() && terminal.textarea.inputMode === 'none', 'Reconnecting must preserve physical keyboard focus and software suppression');
  hardwareKey('d', 'KeyD', 68);
  checkInputs(['a', '\\x1b[D', '\\r', '\\x03', '\\x1b', 'b', 'e', '\\x1b', 'd'], 'Hardware typing must survive reconnection');
  terminal.blur();
  const controlKey = window.slzSendTerminalControlKey;
  const beforeControlKeys = inputs().length;
  // The onscreen controls must work while a toolbar button owns focus.
  controlKey('ArrowDown');
  controlKey('Enter');
  controlKey('Enter');
  await new Promise(resolve => terminal.write('\\x1b[?1h', resolve));
  for (const key of ['ArrowUp', 'ArrowDown', 'ArrowRight', 'ArrowLeft']) controlKey(key);
  controlKey('toString');
  await new Promise(resolve => terminal.write('\\x1b[?1l', resolve));
  check(JSON.stringify(inputs().slice(beforeControlKeys)) === JSON.stringify([
    '\\x1b[B', '\\r', '\\r', '\\x1bOA', '\\x1bOB', '\\x1bOC', '\\x1bOD',
  ]), 'Terminal buttons must send exactly one key per tap and honor application cursor mode');
  check(!isFocused() && terminal.textarea.inputMode === 'none', 'Terminal buttons must preserve focus and keyboard mode');
  window.slzFocusTerminal(false);
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
  const nativeKey = window.slzTerminalModifiedKey;
  const beforeNativeKeys = inputs().length;
  window.slzFocusTerminal(false);
  nativeKey('ArrowUp', {altKey: true});
  nativeKey('ArrowUp', {altKey: true});
  nativeKey('ArrowLeft', {shiftKey: true});
  nativeKey('ArrowDown', {altKey: true, ctrlKey: true, shiftKey: true});
  nativeKey('End', {ctrlKey: true});
  nativeKey('Tab', {shiftKey: true});
  nativeKey('Enter', {altKey: true});
  nativeKey('Escape', {altKey: true});
  check(JSON.stringify(inputs().slice(beforeNativeKeys)) === JSON.stringify([
    '\\x1b[1;3A', '\\x1b[1;3A', '\\x1b[1;2D', '\\x1b[1;8B',
    '\\x1b[1;5F', '\\x1b[Z', '\\x1b\\r', '\\x1b\\x1b',
  ]), 'Native modifier chords must reach the PTY once with standard xterm encoding');
  check(isFocused() && terminal.textarea.inputMode === 'none', 'Native shortcuts must preserve hardware focus');
  window.slzFocusTerminal(true);
  const beforeSoftwareKeyboard = inputs().length;
  nativeKey('ArrowUp', {altKey: true});
  check(JSON.stringify(inputs().slice(beforeSoftwareKeyboard)) === JSON.stringify(['\\x1b[1;3A']), 'Native Option+Up must also work with the software keyboard');
  const commit = (text, options = {}) => {
    const target = terminal.textarea;
    const key = {key: text, code: 'KeyA', keyCode: 0, shiftKey: true, bubbles: true, cancelable: true, ...options};
    target.dispatchEvent(new KeyboardEvent('keydown', key));
    const accepted = target.dispatchEvent(new InputEvent('beforeinput', {inputType: 'insertText', data: text, bubbles: true, cancelable: true, composed: true}));
    if (accepted) {
      target.value += text;
      target.dispatchEvent(new InputEvent('input', {inputType: 'insertText', data: text, bubbles: true, composed: true}));
    }
    target.dispatchEvent(new KeyboardEvent('keyup', key));
  };
  const beforeText = inputs().length;
  for (const showKeyboard of [false, true]) {
    window.slzFocusTerminal(showKeyboard);
    commit('A'); commit('!');
    hardwareKey('F5', 'F5', 0, {shiftKey: true});
    check(isFocused() && terminal.textarea.inputMode === (showKeyboard ? 'text' : 'none'), 'Text and function shortcuts must preserve focus and keyboard mode');
  }
  check(JSON.stringify(inputs().slice(beforeText)) === JSON.stringify(['A', '!', '\\x1b[15;2~', 'A', '!', '\\x1b[15;2~']), 'Committed capitals, punctuation, and Shift-F5 must reach transport exactly once');

  await new Promise(resolve => terminal.write('copy this\\r\\nand this', resolve));
  terminal.select(0, 0, 4);
  check(window.slzSelectedTerminalText() === 'copy', 'Copy must read the xterm selection');
  window.slzSelectAllTerminalText();
  check(window.slzSelectedTerminalText().includes('copy this\\nand this'), 'Select All must include xterm output');
  terminal.clearSelection();
  check(window.slzSelectedTerminalText() === '', 'Copy without a selection must return no text');
  terminal.blur();
  window.slzSelectAllTerminalText();
  check(!terminal.hasSelection(), 'Select All must only act in the focused terminal');
  window.slzFocusTerminal(false);

  const paste = (text) => {
    const clipboardData = new DataTransfer();
    clipboardData.setData('text/plain', text);
    terminal.textarea.dispatchEvent(new ClipboardEvent('paste', {clipboardData, bubbles: true, cancelable: true}));
  };
  await new Promise(resolve => terminal.write('\\x1b[?2004h', resolve));
  const beforePaste = inputs().length;
  paste('line one\\nline two');
  check(JSON.stringify(inputs().slice(beforePaste)) === JSON.stringify(['\\x1b[200~line one\\rline two\\x1b[201~']), 'WebKit paste must use xterm bracketed paste exactly once');
  await new Promise(resolve => terminal.write('\\x1b[?2004l', resolve));

  const beforeMeta = inputs().length;
  window.slzSetTerminalOptionAsMeta(true);
  hardwareKey('∫', 'KeyB', 0, {altKey: true});
  hardwareKey('ƒ', 'KeyF', 229, {altKey: true});
  hardwareKey('≥', 'Period', 0, {altKey: true});
  check(JSON.stringify(inputs().slice(beforeMeta)) === JSON.stringify(['\\x1bb', '\\x1bf', '\\x1b.']), 'Option as Meta must send CLI shortcuts using the physical key');
  window.slzSetTerminalOptionAsMeta(false);
  const beforeOptionText = inputs().length;
  commit('é', {key: 'é', code: 'KeyE', altKey: true, shiftKey: false});
  await new Promise(resolve => setTimeout(resolve, 0));
  check(JSON.stringify(inputs().slice(beforeOptionText)) === JSON.stringify(['é']), 'Turning Option as Meta off must restore Option text input');

  const beforeComposition = inputs().length;
  terminal.textarea.dispatchEvent(new CompositionEvent('compositionstart', {bubbles: true}));
  nativeKey('ArrowUp', {altKey: true});
  terminal.textarea.dispatchEvent(new CompositionEvent('compositionend', {bubbles: true}));
  terminal.blur();
  nativeKey('ArrowUp', {altKey: true});
  check(inputs().length === beforeComposition, 'Native modifier chords must leave composition and other focus alone');
  window.slzFocusTerminal(false);
  await new Promise(resolve => setTimeout(resolve, 0));

  // A burst of tiny PTY frames must not pay one WebKit timer per frame.
  let burstWrites = 0;
  const originalWrite = terminal.write.bind(terminal);
  terminal.write = (...args) => { burstWrites++; return originalWrite(...args); };
  const burstStart = performance.now();
  for (let cursor = 1; cursor <= 1000; cursor++) {
    viewportSocket.receive({type: 'output', sessionId, cursor, data: 'x'});
  }
  const beforeBurstInput = inputs().length;
  hardwareKey('e', 'KeyE', 69);
  check(inputs().length === beforeBurstInput + 1, 'Input must send while output is pending');
  await until(() => sent.some(message => message.type === 'ack' && message.cursor === 1000), 600);
  const burstMs = Math.round(performance.now() - burstStart);
  terminal.write = originalWrite;
  window.fixtureBurst = {burstMs, burstWrites};
  const screenText = Array.from({length: terminal.buffer.active.length}, (_, i) => terminal.buffer.active.getLine(i).translateToString(true)).join('');
  check(screenText.includes('x'.repeat(1000)), 'Batched output must reach the real terminal buffer without loss');
  check(burstWrites < 20, 'Tiny output frames must share parser batches: writes=' + burstWrites + ' elapsedMs=' + burstMs);

  viewportSocket.receive({type: 'ownership', sessionId, writable: false});
  await until(() => !button.hidden);
  const beforeReadOnlyShortcut = inputs().length;
  hardwareKey('UIKeyInputUpArrow', '', 0, {altKey: true});
  hardwareKey('c', 'KeyC', 0, {ctrlKey: true});
  commit('Z'); hardwareKey('F1', 'F1', 0);
  paste('read-only paste');
  nativeKey('ArrowUp', {altKey: true});
  controlKey('ArrowDown');
  controlKey('Enter');
  check(inputs().length === beforeReadOnlyShortcut, 'Keyboard shortcuts and paste must respect read-only ownership');
  const write = (text) => new Promise(resolve => terminal.write(text, resolve));
  await write('history\\r\\n'.repeat(terminal.rows * 3));
  const bottom = terminal.buffer.active.baseY;
  check(bottom >= terminal.rows, 'The scrollback fixture must have history');
  await until(() => dragScrollbackAvailable);
  const tenthOfLine = 0.1 / terminal.rows;
  window.slzScrollback(-tenthOfLine);
  check(terminal.buffer.active.viewportY === bottom, 'Keep sub-line scroll deltas');
  window.slzScrollback(-10 * tenthOfLine);
  check(terminal.buffer.active.viewportY === bottom - 1, 'Accumulate fractional movement into one line');
  window.slzScrollback(-4);
  check(terminal.buffer.active.viewportY === 0, 'Clamp at the oldest retained line');
  window.slzScrollback(4);
  check(terminal.buffer.active.viewportY === bottom, 'Clamp at the live viewport');
  window.slzScrollback(-1);
  check(terminal.buffer.active.viewportY === bottom - terminal.rows, 'VoiceOver page distance must use the current fitted grid');
  check(inputs().length === beforeReadOnlyShortcut && isFocused(), 'Local history must work read only without PTY input or a focus change');
  check(!readOnlyBadge.hidden, 'Revoked viewers must show read-only state');
  delete document.documentElement.dataset.nativeTerminal;
  check(getComputedStyle(button).display !== 'none', 'Browser takeover action must be visible');
  document.documentElement.dataset.nativeTerminal = 'true';
  check(getComputedStyle(button).display === 'none', 'Take Control must stay hidden on Vision Pro');
  if (!native) delete document.documentElement.dataset.nativeTerminal;
  button.click();
  check(sent.at(-1).type === 'take-control', 'Takeover must use the existing session connection');
  check(!button.hidden, 'Control must not change before the service confirms it');
  viewportSocket.receive({type: 'ownership', sessionId, writable: true});
  await until(() => readOnlyBadge.hidden);
  check(button.hidden, 'Confirmed takeover dismisses the action');
  check(document.activeElement === terminal.textarea, 'Taking control must focus terminal input');
  const beforeWheel = inputs().length;
  const wheel = () => {
    const target = terminal.element.querySelector('.xterm-screen');
    const rect = target.getBoundingClientRect();
    target.dispatchEvent(new WheelEvent('wheel', {
      deltaY: -3, deltaMode: WheelEvent.DOM_DELTA_LINE,
      clientX: rect.left + 5, clientY: rect.top + 5, bubbles: true, cancelable: true,
    }));
  };
  // xterm uses its own view/layout update to synchronize a buffer switch.
  await write('\\x1b[?1049h');
  await until(() => !dragScrollbackAvailable);
  window.slzScrollback(-1);
  check(terminal.buffer.active.type === 'alternate' && terminal.buffer.active.viewportY === 0, 'The strip must leave the alternate buffer still');
  check(inputs().length === beforeWheel, 'The strip must not send alternate-screen arrow keys');
  wheel();
  check(inputs().at(-1) === '\\x1b[A' && inputs().length === beforeWheel + 1, 'Ordinary alternate-screen wheel must retain xterm arrow emulation');
  await write('\\x1b[?1000h\\x1b[?1006h');
  window.slzScrollback(1);
  check(inputs().length === beforeWheel + 1, 'The strip must not emit mouse reports');
  wheel();
  check(inputs().at(-1) === '\\x1b[<64;1;1M' && inputs().length === beforeWheel + 2, 'Ordinary wheel must retain xterm SGR mouse reporting');
  await write('\\x1b[?1000l\\x1b[?1006l\\x1b[?1049l');
  await until(() => dragScrollbackAvailable);
  await write('\\x1b[?1000h');
  terminal.scrollToBottom();
  const mouseModeBottom = terminal.buffer.active.viewportY;
  window.slzScrollback(-1, true);
  check(terminal.buffer.active.viewportY === mouseModeBottom, 'A delayed body drag must respect current mouse reporting');
  window.slzScrollback(-1);
  check(terminal.buffer.active.viewportY < mouseModeBottom, 'The separate strip must still scroll local history before exiting mouse mode');
  await until(() => !dragScrollbackAvailable);
  await write('\\x1b[?1000l');
  await until(() => dragScrollbackAvailable);
  const beforeInvalidScroll = terminal.buffer.active.viewportY;
  for (const invalid of [NaN, Infinity, 5, '1']) window.slzScrollback(invalid);
  check(terminal.buffer.active.viewportY === beforeInvalidScroll, 'Reject nonnumeric and unbounded scroll deltas');
  window.slzDetachTerminal();
  check(!dragScrollbackAvailable, 'Detach must disable body drag');
  window.slzScrollback(-1);
  check(terminal.buffer.active.viewportY === beforeInvalidScroll, 'A detached renderer must ignore scroll commands');
  const beforeDetachedKeys = inputs().length;
  controlKey('Enter');
  check(inputs().length === beforeDetachedKeys, 'Terminal buttons must drop input after disconnect');
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
    ...sharedSources,
    ...[
      "CompanionWebView",
      "CompanionModels",
      "CompanionTransport",
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
    path.join(root, "packages/transport/NativeStream.swift"),
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
