/// The owner's text in one session's agent prompt as a length (spec
/// 2026-11-24-workchat-polish §6.1, C3): `count` characters, trusted only
/// while `exact`. Twin of Go `sessionhost.draftModel` (the host's, the
/// authority); both follow `internal/sessionhost/testdata/draft_cases.json`.
///
/// Only keys whose effect on the prompt is certain keep it exact: printable
/// characters and a single-line bracketed paste add theirs (a paste may come
/// as several chunks: its brackets and its text are separate writes),
/// Backspace takes one, a submitting Return empties it and Shift+Tab changes
/// nothing. Everything else — cursor and word-edit keys, Ctrl+U (in Claude
/// Code 2.1.331 it erases only the last screen row of a wrapped draft), Esc,
/// Tab, a line break, a multi-line paste, the owner's Ctrl+C (it interrupts a
/// working turn and keeps the text, spec C11), the app's own interrupt Esc
/// and any key under a profile without `exactDraft` — makes it inexact: from
/// then on only a submit (or the app's clear) empties it.
/// An inexact draft always holds text, so an unknown prompt holds a line as
/// before (PROJ-16, PROJ-23).
package struct DraftModel: Equatable, Sendable {
    package var count = 0
    package var exact = true
    /// The last printable input was `\`, with only escape sequences or
    /// paste brackets since: a Return there is a line break.
    private var backslash = false
    /// A bracketed paste began and its end bracket has not come.
    private var inPaste = false

    /// What one fed chunk was.
    package enum Key: Equatable, Sendable {
        /// Empty, or input into a permission dialog.
        case ignored
        /// A submitting Return (`PromptKeys.isSubmit`).
        case submit
        /// Shift+Tab, a mode switch.
        case neutral
        /// Anything else, which may change the prompt's text.
        case edit
    }

    package init() {}

    /// Whether the prompt may hold text: `count > 0` or not `exact`.
    package var holdsText: Bool { count > 0 || !exact } // swiftlint:disable:this empty_count

    /// The app's own clear of the prompt (Task 7's `clear_first`): empty
    /// and exact, whatever the draft was.
    package mutating func clearedByApp() { self = Self() }

    /// Reads one chunk of the owner's input. Input while a permission
    /// dialog is up changes nothing (it answers the dialog).
    @discardableResult
    package mutating func feed(_ bytes: [UInt8], profile: AgentInputProfile, dialog: Bool) -> Key {
        guard !bytes.isEmpty, !dialog else { return .ignored }
        if !inPaste, PromptKeys.isShiftTab(bytes) { return .neutral }
        // A Return inside a paste's text is the paste's, never a submit.
        let submit = !inPaste && PromptKeys.isSubmit(bytes, backslashBefore: backslash, profile: profile)
        backslash = PromptKeys.endsAfterBackslash(bytes, backslashBefore: backslash)
        if submit {
            count = 0
            exact = true
            return .submit
        }
        edit(bytes)
        if !profile.exactDraft { exact = false }
        return .edit
    }

    private static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] // ESC[200~
    private static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E] // ESC[201~
    private static let shiftTab: [UInt8] = [0x1B, 0x5B, 0x5A] // ESC[Z

    /// The key table over a chunk that is no submit.
    private mutating func edit(_ bytes: [UInt8]) {
        var index = 0
        while index < bytes.count {
            if inPaste {
                index = pasted(bytes[index...])
                continue
            }
            let byte = bytes[index]
            let rest = bytes[index...]
            switch byte {
            case 0x1B where rest.starts(with: Self.pasteStart):
                inPaste = true
                index += Self.pasteStart.count
            case 0x1B:
                if !rest.starts(with: Self.shiftTab) { exact = false } // cursor/word-edit key, Esc, Option+key
                index = PromptKeys.escapeSequenceEnd(in: bytes, after: index + 1)
            case 0x7F, 0x08: // Backspace, Ctrl+H
                if exact, count > 0 { // swiftlint:disable:this empty_count
                    count -= 1
                    if count == 0 { backslash = false } // swiftlint:disable:this empty_count
                }
                index += 1
            case ..<0x20: // a line break, Ctrl+C, Ctrl+U, Tab, Ctrl+A/E/W/K, …
                exact = false
                index += 1
            default:
                add(bytes[index...index])
                index += 1
            }
        }
    }

    /// Reads a paste's text up to its end bracket; returns the index past
    /// what it took. A line break in it makes the draft inexact.
    private mutating func pasted(_ bytes: ArraySlice<UInt8>) -> Int {
        var text = bytes
        var next = bytes.endIndex
        if let end = Self.firstIndex(of: Self.pasteEnd, in: bytes) {
            text = bytes[bytes.startIndex..<end]
            next = end + Self.pasteEnd.count
            inPaste = false
        }
        add(text)
        if text.contains(0x0D) || text.contains(0x0A) { exact = false }
        return next
    }

    /// Counts the characters of `bytes`: every byte but a UTF-8
    /// continuation byte (a paste's control characters count too — never
    /// fewer than the prompt shows).
    private mutating func add(_ bytes: ArraySlice<UInt8>) {
        count += bytes.count { $0 < 0x80 || $0 >= 0xC0 }
    }

    /// The index in `bytes` where `needle` starts first.
    private static func firstIndex(of needle: [UInt8], in bytes: ArraySlice<UInt8>) -> Int? {
        var index = bytes.startIndex
        while index + needle.count <= bytes.endIndex {
            if bytes[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }
}
