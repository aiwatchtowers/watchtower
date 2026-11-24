import WatchtowerCore

/// Reading the owner's keystrokes: does an input submit the agent's prompt.
extension TerminalCenter {
    /// Whether the owner's input submits the agent's prompt: it ends in the
    /// profile's `submit` (a plain Return, CR) that does not follow ESC
    /// (Option+Return), does not end in the profile's `newline`, and whose
    /// last printable input before it — in this chunk or earlier ones
    /// (`backslashBefore`), escape sequences such as cursor keys and paste
    /// brackets skipped — is not `\` (`\` then Return is a line break).
    /// Anything else is a draft: Ctrl+J (LF), Shift+Return under an extended
    /// keyboard protocol (an escape sequence ending in `u` or `~`), any
    /// other key (`isShiftTab` aside). When unsure the input counts as a
    /// draft, which costs the owner a Return of their own, never a line
    /// submitted with theirs — so the `\` rule holds for every agent.
    static func isSubmit(_ bytes: [UInt8], backslashBefore: Bool, profile: AgentInputProfile = .claude) -> Bool {
        if let newline = profile.newline, endsIn(bytes, newline) { return false }
        guard endsIn(bytes, profile.submit) else { return false }
        let body = bytes.dropLast(profile.submit.count)
        if body.last == 0x1B { return false }
        return !endsAfterBackslash(body, backslashBefore: backslashBefore)
    }

    /// Whether the owner's input is exactly Shift+Tab (`ESC [ Z`), a mode
    /// switch that leaves the prompt's text as it was, so the draft state
    /// stays (#1748). Esc and Ctrl+C are not exempt: Claude Code's cancel
    /// moves a queued message back into the prompt. Twin of Go
    /// `sessionhost.IsShiftTab`, which says more.
    static func isShiftTab(_ bytes: [UInt8]) -> Bool { bytes == [0x1B, 0x5B, 0x5A] }

    /// Whether `bytes` ends in the non-empty key sequence `key`.
    private static func endsIn(_ bytes: [UInt8], _ key: [UInt8]) -> Bool {
        !key.isEmpty && bytes.suffix(key.count).elementsEqual(key)
    }

    /// Whether, after `bytes`, the last printable input is `\` with only
    /// escape sequences (CSI `ESC [ … final`, SS3 `ESC O x`, `ESC x`) since —
    /// paste brackets are CSI sequences too. A CR or LF ends the line and
    /// clears it; any other byte keeps it as it was (fail safe: a draft).
    static func endsAfterBackslash<Bytes: Collection>(_ bytes: Bytes, backslashBefore: Bool) -> Bool
        where Bytes.Element == UInt8 {
        var pending = backslashBefore
        var index = bytes.startIndex
        while index != bytes.endIndex {
            let byte = bytes[index]
            index = bytes.index(after: index)
            switch byte {
            case 0x1B:
                index = escapeSequenceEnd(in: bytes, after: index)
            case 0x0D, 0x0A:
                pending = false
            case 0x20...0x7E, 0x80...:
                pending = byte == UInt8(ascii: "\\")
            default:
                break
            }
        }
        return pending
    }

    /// The index just past the escape sequence whose ESC came before
    /// `start`.
    private static func escapeSequenceEnd<Bytes: Collection>(in bytes: Bytes, after start: Bytes.Index) -> Bytes.Index
        where Bytes.Element == UInt8 {
        guard start != bytes.endIndex else { return start }
        var index = bytes.index(after: start)
        switch bytes[start] {
        case UInt8(ascii: "["):
            // Parameters and intermediates, then one final byte 0x40–0x7E.
            while index != bytes.endIndex, !(0x40...0x7E).contains(bytes[index]) {
                index = bytes.index(after: index)
            }
            return index == bytes.endIndex ? index : bytes.index(after: index)
        case UInt8(ascii: "O"):
            return index == bytes.endIndex ? index : bytes.index(after: index)
        default:
            return index
        }
    }
}
