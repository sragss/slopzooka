/** Use xterm's streaming parser so split OSCs, terminators, and ordinary titles
 * cannot be mistaken for bells. Works with the session service's headless screen. */
export function observeTerminalNotifications(
  terminal: {
    onBell(listener: () => void): { dispose(): void };
    parser: {
      registerOscHandler(
        id: number,
        handler: (data: string) => boolean,
      ): { dispose(): void };
    };
  },
  notify: () => void,
): void {
  terminal.onBell(notify);
  terminal.parser.registerOscHandler(9, (data) => {
    // OSC 9;4 is progress reporting, not a desktop notification.
    if (/^\d+;/.test(data)) return false;
    notify();
    return true;
  });
  terminal.parser.registerOscHandler(777, (data) => {
    if (!data.startsWith("notify;")) return false;
    notify();
    return true;
  });
}
