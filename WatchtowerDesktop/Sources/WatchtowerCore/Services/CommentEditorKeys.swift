/// Which keystrokes send a comment from a multi-line comment field (#178):
/// ⌘↩ or ⌃↩ (Return or the keypad's Enter) send; a plain Return — and
/// ⇧/⌥-Return — stay a new line, as in any text editor. Pure.
package enum CommentEditorKeys {
    package static let returnKeyCode: UInt16 = 36
    package static let keypadEnterKeyCode: UInt16 = 76

    package static func submits(keyCode: UInt16, command: Bool, control: Bool) -> Bool {
        (keyCode == returnKeyCode || keyCode == keypadEnterKeyCode) && (command || control)
    }
}
