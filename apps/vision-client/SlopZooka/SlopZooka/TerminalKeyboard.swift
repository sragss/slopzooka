import Foundation

/// Normalize WebKit editing and hardware shortcut events for xterm's key handling.
enum TerminalKeyboard {
    static let script = """
    document.addEventListener('keydown', function(event) {
        const input = event.target;
        if (event.defaultPrevented || event.isComposing ||
            !(input instanceof HTMLTextAreaElement) ||
            !input.classList.contains('xterm-helper-textarea') ||
            (event.keyCode !== 0 && event.keyCode !== 229)) return;
        const key = event.key.replace(/^UIKeyInput(Up|Down|Left|Right)Arrow$/, 'Arrow$1');
        const keys = {
            ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39,
            Backspace: 8, Delete: 46, Enter: 13, Tab: 9, Escape: 27,
            Home: 36, End: 35, PageUp: 33, PageDown: 34
        };
        const fn = /^F([1-9]|1[0-2])$/.exec(key);
        let keyCode = Object.hasOwn(keys, key) ? keys[key] : fn ? 111 + Number(fn[1]) : undefined;
        if (keyCode === undefined && event.ctrlKey && !event.altKey && !event.metaKey) {
            const character = /^[a-z0-9]$/i.test(key) ? key.toUpperCase()
                : /^(Key[A-Z]|Digit[0-9])$/.test(event.code) ? event.code.slice(-1) : null;
            const controls = {
                Space: [' ', 32], BracketLeft: ['[', 219], Backslash: [String.fromCharCode(92), 220],
                BracketRight: [']', 221], Minus: ['_', 189], Slash: ['?', 191],
                Digit2: ['@', 50], Digit6: ['^', 54], Backquote: ['`', 192]
            };
            keyCode = character ? character.charCodeAt(0)
                : Object.values(controls).find(([value]) => value === key)?.[1] ?? controls[event.code]?.[1];
        }
        if (keyCode === undefined) return;
        // Let xterm encode the delivered key and modifiers; Fn/Globe alone
        // and OS-consumed shortcuts must not invent terminal input.
        event.preventDefault();
        event.stopPropagation();
        input.dispatchEvent(new KeyboardEvent('keydown', {
            key, code: event.code || key, keyCode, which: keyCode,
            altKey: event.altKey, ctrlKey: event.ctrlKey,
            shiftKey: event.shiftKey, metaKey: event.metaKey,
            repeat: event.repeat, location: event.location,
            modifierAltGraph: event.getModifierState('AltGraph'),
            modifierCapsLock: event.getModifierState('CapsLock'),
            modifierFn: event.getModifierState('Fn'),
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
