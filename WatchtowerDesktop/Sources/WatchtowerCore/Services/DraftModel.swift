/// The owner's text in one session's agent prompt as a length (spec
/// 2026-11-24-workchat-polish §6.1, C3): `count` characters, trusted only
/// while `exact`. Twin of Go `sessionhost.draftModel` (the host's, the
/// authority); both follow `internal/sessionhost/testdata/draft_cases.json`.
///
/// Input is decoded strictly in byte order, its parser state kept across
/// chunks (an escape sequence or a bracketed paste may span several writes):
/// a key's effect is decided at the byte where it occurs. A write ending in a
/// lone ESC is the Esc key (inexact) unless the next write goes on with `[`
/// or `O`, which reassembles the sequence; Esc then Return as two writes
/// stays Esc and a submit, as the PROJ-12 guards pin.
/// Only keys whose effect on the prompt is certain keep it exact: printable
/// characters and a single-line bracketed paste add theirs, Backspace takes
/// one (Claude Code's profile only, `exactDraft`), a submitting Return (a CR
/// ending its write; Claude Code 2.1.331 submits `text\r` written at once)
/// empties it and Shift+Tab changes nothing. Everything else — cursor and
/// word-edit keys, Ctrl+U (in 2.1.331 it erases only the last screen row of a
/// wrapped draft), Esc, Tab, a line break (Option+Return `ESC CR` too), a
/// multi-line paste, a paste with an escape in its text, the owner's Ctrl+C (it interrupts a working turn and
/// keeps the text, spec C11) and any key under a profile without
/// `exactDraft` — makes it inexact: from then on only a submit (or the app's
/// clear) empties it. An inexact draft, an open paste and a partial escape
/// sequence always hold text, so an unknown prompt holds a line as before
/// (PROJ-16, PROJ-23).
package struct DraftModel: Equatable, Sendable {
    package var count = 0
    package var exact = true
    /// The character before the cursor is (or may be) `\`: a Return there is
    /// a line break.
    private var backslash = false
    /// A bracketed paste began and its end bracket has not come.
    private var inPaste = false
    /// An escape sequence begun and not yet complete (outside a paste), or
    /// the part of the paste's end bracket seen so far (inside one).
    private var esc: [UInt8] = []
    /// `esc` is a lone ESC that ended its write, already read as the Esc
    /// key; only `[` or `O` next makes it the start of a sequence.
    private var escKey = false
    /// The characters typed since the draft was empty, the app's own paste
    /// or the cursor last became unknown — whether each is a backslash — so
    /// a Backspace knows whether the character then before the cursor is
    /// `\`. Kept only under a profile with `exactDraft`, the only one whose
    /// Backspace reads it.
    private var run: [Bool] = []
    /// A line the app pasted, which `count` leaves out (a delivery in its
    /// pause), precedes the run: a Backspace past the run reaches it.
    private var appLine = false

    /// What one fed chunk was.
    package enum Key: Equatable, Sendable {
        /// Empty, or input into a permission dialog.
        case ignored
        /// A submitting Return.
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

    /// A delivery's own line pasted at the cursor, ending in `\` or not:
    /// the character before the cursor is then the line's last, and the run
    /// starts again behind it. A permission dialog that came up meanwhile
    /// may have taken the paste, so a `\` already before the cursor stays
    /// possible too. The caller decides what the paste does to the count
    /// (left typed: `markInexact`; in its pause: the pause holds the prompt).
    package mutating func appPasted(endingInBackslash: Bool) {
        run = []
        backslash = backslash || endingInBackslash
        appLine = true
    }

    /// The session host left a line typed (`appPasted`, then inexact).
    package mutating func hostLeftTyped(endingInBackslash: Bool) {
        appPasted(endingInBackslash: endingInBackslash)
        setInexact()
    }

    /// Gives up the length and the cursor (a line left typed, a key into a
    /// line in its pause): only a submit empties the draft from now on.
    package mutating func markInexact() { setInexact() }

    /// Whether a bracketed paste payload's text ends in `\`.
    package static func pasteEndsInBackslash(_ payload: [UInt8]) -> Bool {
        payload.count > pasteEnd.count && payload.suffix(pasteEnd.count).elementsEqual(pasteEnd)
            && payload[payload.count - pasteEnd.count - 1] == UInt8(ascii: "\\")
    }

    /// The run's length, for the tests that pin where it is kept.
    var runLength: Int { run.count }
    /// The run's buffer, for the tests that pin that a long one goes.
    var runCapacity: Int { run.capacity }

    /// Reads one chunk of the owner's input. Input while a permission
    /// dialog is up changes nothing (it answers the dialog).
    @discardableResult
    package mutating func feed(_ bytes: [UInt8], profile: AgentInputProfile, dialog: Bool) -> Key {
        guard !bytes.isEmpty, !dialog else { return .ignored }
        var edited = false
        var submitted = false
        for (index, byte) in bytes.enumerated() {
            if escKey, byte != UInt8(ascii: "["), byte != UInt8(ascii: "O") {
                esc = [] // it was the Esc key
                escKey = false
            }
            if inPaste {
                pasteByte(byte, profile: profile)
                edited = true
            } else if !esc.isEmpty || byte == 0x1B {
                edited = escapeByte(byte, last: index == bytes.count - 1) || edited
            } else if byte == 0x0D, index == bytes.count - 1, !backslash, profile.submit == [0x0D] {
                self = Self()
                submitted = true
            } else {
                keyByte(byte, profile: profile)
                edited = true
            }
        }
        if submitted { return .submit }
        if !edited, esc.isEmpty { return .neutral } // a sequence still open may be any key
        if !profile.exactDraft { exact = false } // the cursor is where it was: run stays
        return .edit
    }

    private static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] // ESC[200~
    private static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E] // ESC[201~
    private static let shiftTab: [UInt8] = [0x1B, 0x5B, 0x5A] // ESC[Z

    /// A byte of an escape sequence outside a paste (or the ESC that starts
    /// one): whether the key it completed may have changed the text — false
    /// for Shift+Tab and while the sequence is open. An ESC ending its write
    /// is the Esc key until a later write goes on with it.
    private mutating func escapeByte(_ byte: UInt8, last: Bool) -> Bool {
        if esc.isEmpty {
            esc = [0x1B]
            if last {
                escKey = true
                setInexact()
                return true
            }
            return false
        }
        esc.append(byte)
        escKey = false
        guard Self.escapeComplete(esc) else { return false }
        let seq = esc
        esc = []
        switch seq {
        case Self.pasteStart:
            inPaste = true
        case Self.shiftTab:
            return false
        case [0x1B, 0x0D], [0x1B, 0x0A]: // Option+Return: a line break
            backslash = false
            setInexact()
        default:
            setInexact() // a cursor or word-edit key, Esc then a key, Option+key
            if seq.last == UInt8(ascii: "\\") {
                // Option+`\`, or Esc then `[\` / `O\` typed one key per
                // write (the reassembly cannot tell them apart): a `\` may
                // be before the cursor.
                backslash = true
            }
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

    /// One byte inside a paste: the end bracket is matched as it streams in
    /// (a new ESC restarts the match); every other byte, a broken match's
    /// included, is the paste's text. An escape inside the text may show
    /// wider or narrower than its bytes: a broken match makes the draft
    /// inexact.
    private mutating func pasteByte(_ byte: UInt8, profile: AgentInputProfile) {
        if !esc.isEmpty {
            let next = esc + [byte]
            if Self.pasteEnd.starts(with: next) {
                esc = next == Self.pasteEnd ? [] : next
                if esc.isEmpty { inPaste = false }
                return
            }
            let seen = esc
            esc = []
            seen.forEach { pasteText($0, profile: profile) }
            setInexact()
        }
        if byte == 0x1B {
            esc = [0x1B]
            return
        }
        pasteText(byte, profile: profile)
    }

    /// One byte of a paste's text: it counts as typed, but a line break in
    /// it makes the draft inexact.
    private mutating func pasteText(_ byte: UInt8, profile: AgentInputProfile) {
        addCharacter(byte, profile: profile)
        if byte == 0x0D || byte == 0x0A {
            backslash = false
            setInexact()
        }
    }

    /// One typed byte outside a paste and an escape sequence that is no
    /// submit.
    private mutating func keyByte(_ byte: UInt8, profile: AgentInputProfile) {
        switch byte {
        case 0x7F, 0x08: // Backspace, Ctrl+H
            erase(profile: profile)
        case 0x0D, 0x0A: // a line break: `\` then Return, Ctrl+J, a CR mid-chunk
            backslash = false
            setInexact()
        case ..<0x20: // Ctrl+C, Ctrl+U, Tab, Ctrl+A/E/W/K, …
            setInexact()
        default:
            addCharacter(byte, profile: profile)
        }
    }

    /// One Backspace. Under a profile without `exactDraft` the program may
    /// not erase one character: what precedes the cursor is unknown (read as
    /// `\`: a Return holds). Otherwise it takes a character off an exact
    /// draft, and the character then before the cursor is the run's last,
    /// none in an exact empty draft with no line of the app's before it,
    /// else unknown.
    private mutating func erase(profile: AgentInputProfile) {
        guard profile.exactDraft else {
            backslash = true
            setInexact()
            return
        }
        if !run.isEmpty { run.removeLast() }
        if exact, count > 0 { count -= 1 } // swiftlint:disable:this empty_count
        if let last = run.last {
            backslash = last
        } else {
            backslash = !(exact && count == 0 && !appLine) // swiftlint:disable:this empty_count
        }
    }

    /// Counts printable input — every byte but a UTF-8 continuation byte (a
    /// paste's control characters count too: never fewer than the prompt
    /// shows) — and keeps the pending `\` and, under `exactDraft`, the run.
    private mutating func addCharacter(_ byte: UInt8, profile: AgentInputProfile) {
        guard !(0x80..<0xC0).contains(byte) else { return }
        count += 1
        backslash = byte == UInt8(ascii: "\\")
        if profile.exactDraft { run.append(backslash) }
    }

    /// Gives up the length and the cursor: from now on only a submit
    /// empties it, and the run starts again (a fresh one: a long run's
    /// buffer goes).
    private mutating func setInexact() {
        exact = false
        run = []
    }
}
