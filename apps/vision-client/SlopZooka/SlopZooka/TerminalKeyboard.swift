import Foundation

/// WebKit can deliver Return and deletion as editing events without a usable keydown.
/// Route those events through xterm's key handling, preserving its terminal key sequences.
enum TerminalKeyboard {
    static let script = """
    document.addEventListener('beforeinput', function(event) {
        const input = event.target;
        if (event.defaultPrevented || event.isComposing ||
            !(input instanceof HTMLTextAreaElement) ||
            !input.classList.contains('xterm-helper-textarea')) return;
        const key = {
            insertLineBreak: ['Enter', 13],
            insertParagraph: ['Enter', 13],
            deleteContentBackward: ['Backspace', 8],
            deleteContentForward: ['Delete', 46]
        }[event.inputType];
        if (!key) return;
        event.preventDefault();
        const options = { key: key[0], code: key[0], keyCode: key[1], which: key[1],
                          bubbles: true, cancelable: true };
        input.dispatchEvent(new KeyboardEvent('keydown', options));
        input.dispatchEvent(new KeyboardEvent('keyup', options));
    }, true);
    """
}
