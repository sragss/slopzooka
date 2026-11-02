import Foundation

/// Normalize WebKit editing and hardware-arrow events for xterm's key handling.
enum TerminalKeyboard {
    static let script = """
    document.addEventListener('keydown', function(event) {
        const input = event.target;
        if (event.defaultPrevented || event.isComposing ||
            !(input instanceof HTMLTextAreaElement) ||
            !input.classList.contains('xterm-helper-textarea') ||
            (event.keyCode !== 0 && event.keyCode !== 229)) return;
        const key = {
            ArrowUp: ['ArrowUp', 38], UIKeyInputUpArrow: ['ArrowUp', 38],
            ArrowDown: ['ArrowDown', 40], UIKeyInputDownArrow: ['ArrowDown', 40],
            ArrowLeft: ['ArrowLeft', 37], UIKeyInputLeftArrow: ['ArrowLeft', 37],
            ArrowRight: ['ArrowRight', 39], UIKeyInputRightArrow: ['ArrowRight', 39]
        }[event.key];
        if (!key) return;
        // xterm's UIKit arrow fallback drops modifiers; on Mac it can also
        // mistake Option + a zero keyCode for character composition.
        event.preventDefault();
        event.stopPropagation();
        input.dispatchEvent(new KeyboardEvent('keydown', {
            key: key[0], code: key[0], keyCode: key[1], which: key[1],
            altKey: event.altKey, ctrlKey: event.ctrlKey,
            shiftKey: event.shiftKey, metaKey: event.metaKey,
            repeat: event.repeat, location: event.location,
            bubbles: true, cancelable: true
        }));
    }, true);
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
