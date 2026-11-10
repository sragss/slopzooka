import type { Terminal } from "@xterm/xterm";

/** Commit WebKit text even when a hardware key produces no keypress event. */
export function bindTerminalTextInput(terminal: Terminal): () => void {
  const input = terminal.textarea;
  if (!input) return () => {};
  let pending: { event: KeyboardEvent; emitted: boolean } | undefined;
  let composing = false;
  const reset = (event?: Event) => {
    pending = undefined;
    if (event?.type === "blur") composing = false;
  };
  const composition = (event: Event) => {
    composing = event.type === "compositionstart";
    reset();
  };
  const keydown = (event: KeyboardEvent) => {
    pending =
      !composing && !event.isComposing && !event.ctrlKey && !event.metaKey
        ? { event, emitted: false }
        : undefined;
  };
  const beforeinput = (event: InputEvent) => {
    if (
      !pending ||
      event.defaultPrevented ||
      !event.cancelable ||
      composing ||
      event.isComposing ||
      event.inputType !== "insertText" ||
      !event.data
    )
      return;
    const key = pending;
    reset();
    // xterm may already have sent this key on keydown/keypress. Prevent the
    // native edit either way, so its composition poller cannot resend the text.
    event.preventDefault();
    if (!key.emitted && !key.event.defaultPrevented)
      terminal.input(event.data, true);
  };
  const subscription = terminal.onKey(() => {
    if (pending) pending.emitted = true;
  });
  input.addEventListener("keydown", keydown, true);
  input.addEventListener("beforeinput", beforeinput, true);
  for (const type of ["keyup", "blur"])
    input.addEventListener(type, reset, true);
  for (const type of ["compositionstart", "compositionend"])
    input.addEventListener(type, composition, true);
  return () => {
    reset();
    subscription.dispose();
    input.removeEventListener("keydown", keydown, true);
    input.removeEventListener("beforeinput", beforeinput, true);
    for (const type of ["keyup", "blur"])
      input.removeEventListener(type, reset, true);
    for (const type of ["compositionstart", "compositionend"])
      input.removeEventListener(type, composition, true);
  };
}
