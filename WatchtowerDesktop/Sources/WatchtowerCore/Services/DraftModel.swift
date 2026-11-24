/// The owner's text in one session's agent prompt as a length (spec
/// 2026-11-24-workchat-polish §6.1, C3): `count` characters, trusted only
/// while `exact`. Twin of Go `sessionhost.draftModel` (the host's, the
/// authority); both follow `internal/sessionhost/testdata/draft_cases.json`.
///
/// Input is decoded strictly in byte order, its parser state kept across
/// chunks (an escape sequence or a bracketed paste may span several writes):
/// a key's effect is decided at the byte where it occurs. Only keys whose
/// effect on the prompt is certain keep it exact: printable characters and a
/// single-line bracketed paste add theirs, Backspace takes one, a submitting
/// Return empties it and Shift+Tab changes nothing. Everything else — cursor
/// and word-edit keys, Ctrl+U (in Claude Code 2.1.331 it erases only the last
/// screen row of a wrapped draft), Esc, Tab, a line break, a multi-line
/// paste, the owner's Ctrl+C (it interrupts a working turn and keeps the
/// text, spec C11) and any key under a profile without `exactDraft` — makes
/// it inexact: from then on only a submit (or the app's clear) empties it.
/// An inexact draft, an open paste and a partial escape sequence always hold
/// text, so an unknown prompt holds a line as before (PROJ-16, PROJ-23).
package struct DraftModel: Equatable, Sendable {
    package var count = 0
    package var exact = true
    /// The last printable input was `\`, with only escape sequences or
    /// paste brackets since: a Return there is a line break.
    private var backslash = false
    /// A bracketed paste began and its end bracket has not come.
    private var inPaste = false
    /// An escape sequence begun in an earlier chunk, not yet complete.
    private var esc: [UInt8] = []
    /// While exact, one entry per character of the draft — whether it is a
    /// backslash — so an erase knows whether the draft then ends in `\`.
    private var shape: [Bool] = []

    /// What one fed chunk was.
    package enum Key: Equatable, Sendable {
        /// Empty, or input into a permission dialog.
        case ignored
        /// A submitting Return (a CR ending the chunk, outside a paste or an
        /// escape sequence and not after `\`).
        case submit
        /// Only Shift+Tab, a mode switch.
        case neutral
        /// Anything else, which may change the prompt's text.
        case edit
    }

    package init() {}

    /// Whether the prompt may hold text: characters counted, inexact, inside
    /// an open paste or in the middle of an escape sequence.
    package var holdsText: Bool {
        count > 0 || !exact || inPaste || !esc.isEmpty // swiftlint:disable:this empty_count
    }

    /// The app's own clear of the prompt (Task 7's `clear_first`): empty
    /// and exact, whatever the draft was.
    package mutating func clearedByApp() { self = Self() }

    /// Reads one chunk of the owner's input. Input while a permission
    /// dialog is up changes nothing (it answers the dialog).
    @discardableResult
    package mutating func feed(_ bytes: [UInt8], profile: AgentInputProfile, dialog: Bool) -> Key {
        guard !bytes.isEmpty, !dialog else { return .ignored }
        var edited = false
        var submitted = false
        for (index, byte) in bytes.enumerated() {
            let last = index == bytes.count - 1
            if !esc.isEmpty || byte == 0x1B {
                edited = escapeByte(byte, last: last) || edited
            } else if inPaste {
                pasteByte(byte)
                edited = true
            } else if byte == 0x0D, last, !backslash, profile.submit == [0x0D] {
                self = Self()
                submitted = true
            } else {
                keyByte(byte)
                edited = true
            }
        }
        if submitted { return .submit }
        if !edited, esc.isEmpty { return .neutral } // a sequence still open may be any key
        if !profile.exactDraft { setInexact() }
        return .edit
    }

    private static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] // ESC[200~
    private static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E] // ESC[201~
    private static let shiftTab: [UInt8] = [0x1B, 0x5B, 0x5A] // ESC[Z

    /// A byte of an escape sequence (or the ESC that starts one): whether
    /// the key it completed may have changed the text — false for Shift+Tab
    /// and while the sequence is still open. A lone ESC ending a chunk
    /// outside a paste is the Esc key.
    private mutating func escapeByte(_ byte: UInt8, last: Bool) -> Bool {
        if esc.isEmpty {
            if last, !inPaste {
                setInexact() // the Esc key
                return true
            }
            esc = [0x1B]
            return false
        }
        esc.append(byte)
        guard Self.escapeComplete(esc) else { return false }
        let seq = esc
        esc = []
        switch seq {
        case Self.pasteEnd where inPaste:
            inPaste = false
        case _ where inPaste:
            setInexact() // an escape inside pasted text: of unknown width
        case Self.pasteStart:
            inPaste = true
        case Self.shiftTab:
            return false
        default:
            setInexact() // a cursor or word-edit key, Option+key, Option+Return
        }
        return true
    }

    /// Whether `seq` (starting with ESC) is a whole escape sequence: CSI
    /// `ESC [ … final`, SS3 `ESC O x`, or `ESC x`.
    private static func escapeComplete(_ seq: [UInt8]) -> Bool {
        guard seq.count >= 2 else { return false }
        switch seq[1] {
        case UInt8(ascii: "["): return seq.count >= 3 && (0x40...0x7E).contains(seq[seq.count - 1])
        case UInt8(ascii: "O"): return seq.count >= 3
        default: return true
        }
    }

    /// One byte of a paste's text: it counts as typed, but a line break in
    /// it makes the draft inexact.
    private mutating func pasteByte(_ byte: UInt8) {
        addCharacter(byte)
        if byte == 0x0D || byte == 0x0A {
            backslash = false
            setInexact()
        }
    }

    /// One typed byte outside a paste and an escape sequence that is no
    /// submit.
    private mutating func keyByte(_ byte: UInt8) {
        switch byte {
        case 0x7F, 0x08: // Backspace, Ctrl+H
            if exact, count > 0 { // swiftlint:disable:this empty_count
                count -= 1
                shape.removeLast()
                backslash = shape.last == true
            }
        case 0x0D, 0x0A: // a line break: `\` then Return, Ctrl+J, a CR mid-chunk
            backslash = false
            setInexact()
        case ..<0x20: // Ctrl+C, Ctrl+U, Tab, Ctrl+A/E/W/K, …
            setInexact()
        default:
            addCharacter(byte)
        }
    }

    /// Counts printable input — every byte but a UTF-8 continuation byte (a
    /// paste's control characters count too: never fewer than the prompt
    /// shows) — and keeps the pending `\`.
    private mutating func addCharacter(_ byte: UInt8) {
        if (0x80..<0xC0).contains(byte) {
            backslash = false
            return
        }
        count += 1
        backslash = byte == UInt8(ascii: "\\")
        if exact { shape.append(backslash) }
    }

    /// Gives up the length: from now on only a submit empties it.
    private mutating func setInexact() {
        exact = false
        shape = []
    }
}
