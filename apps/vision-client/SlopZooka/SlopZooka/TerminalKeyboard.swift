import Foundation

/// visionOS's floating keyboard can submit Return as an editing event rather than a keydown.
/// xterm handles Enter keydowns but ignores insertLineBreak/insertParagraph input events.
enum TerminalKeyboard {
    static let script = """
    document.addEventListener('beforeinput', function(event) {
        const input = event.target;
        if (event.defaultPrevented || event.isComposing ||
            !(input instanceof HTMLTextAreaElement) ||
            !input.classList.contains('xterm-helper-textarea') ||
            !['insertLineBreak', 'insertParagraph'].includes(event.inputType)) return;
        event.preventDefault();
        const options = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
                          bubbles: true, cancelable: true };
        input.dispatchEvent(new KeyboardEvent('keydown', options));
        input.dispatchEvent(new KeyboardEvent('keyup', options));
    }, true);
    """
}
