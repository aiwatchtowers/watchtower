package sessionhost

import (
	"bytes"
	"time"
)

// Profile is how lines are typed into one agent's terminal prompt — the Go
// twin of WatchtowerCore's AgentInputProfile (spec 2026-10-12 §8). The text
// itself always goes as one bracketed paste (PastePayload); the profile holds
// what follows it and what the owner-draft tracker must know about the
// agent's composer.
type Profile struct {
	// Submit is the key pressed after the pause, as a write of its own.
	Submit []byte
	// Newline is the agent's own composer key that inserts a line break
	// instead of submitting, read as a draft; nil when the agent has none
	// beyond the ones IsSubmit knows for every agent.
	Newline []byte
	// PasteSettle is a hand-off's pause between its paste and its Return.
	PasteSettle time.Duration
	// SubmitSettle is the same pause for an ask's answer.
	SubmitSettle time.Duration
}

// ProfileFor returns the agent's profile: Codex's for "codex", Claude
// Code's otherwise (a shell or an unknown agent is typed into as Claude
// Code's, as TerminalCenter.inputProfile does).
func ProfileFor(agent string) Profile {
	if agent == "codex" {
		// CR submits a bracketed paste, multi-line too, as one prompt; Ctrl+J
		// (LF) inserts a line break. The pauses are Claude Code's.
		return Profile{Submit: []byte{0x0D}, Newline: []byte{0x0A},
			PasteSettle: 150 * time.Millisecond, SubmitSettle: 500 * time.Millisecond}
	}
	return Profile{Submit: []byte{0x0D}, PasteSettle: 150 * time.Millisecond, SubmitSettle: 500 * time.Millisecond}
}

// IsSubmit reports whether the owner's input submits the agent's prompt: it
// ends in the profile's Submit (a plain Return) that does not follow ESC
// (Option+Return), does not end in the profile's Newline, and whose last
// printable input before it — in this chunk or earlier ones
// (backslashBefore), escape sequences and paste brackets skipped — is not
// `\` (`\` then Return is a line break). Anything else is a draft. When
// unsure the input counts as a draft, which costs the owner a Return of
// their own, never a line submitted with theirs. Twin of
// TerminalCenter.isSubmit.
func IsSubmit(b []byte, backslashBefore bool, p Profile) bool {
	if len(p.Newline) > 0 && bytes.HasSuffix(b, p.Newline) {
		return false
	}
	if len(p.Submit) == 0 || !bytes.HasSuffix(b, p.Submit) {
		return false
	}
	body := b[:len(b)-len(p.Submit)]
	if len(body) > 0 && body[len(body)-1] == 0x1B {
		return false
	}
	return !EndsAfterBackslash(body, backslashBefore)
}

// EndsAfterBackslash reports whether, after b, the last printable input is
// `\` with only escape sequences (CSI `ESC [ … final`, SS3 `ESC O x`,
// `ESC x`) since — paste brackets are CSI sequences too. A CR or LF ends the
// line and clears it; any other byte keeps it as it was (fail safe: a
// draft). Twin of TerminalCenter.endsAfterBackslash.
func EndsAfterBackslash(b []byte, backslashBefore bool) bool {
	pending := backslashBefore
	for i := 0; i < len(b); {
		c := b[i]
		i++
		switch {
		case c == 0x1B:
			i = escapeSequenceEnd(b, i)
		case c == 0x0D || c == 0x0A:
			pending = false
		case c >= 0x20 && c <= 0x7E || c >= 0x80:
			pending = c == '\\'
		}
	}
	return pending
}

// escapeSequenceEnd returns the index just past the escape sequence whose
// ESC came right before start.
func escapeSequenceEnd(b []byte, start int) int {
	if start >= len(b) {
		return start
	}
	i := start + 1
	switch b[start] {
	case '[':
		// Parameters and intermediates, then one final byte 0x40–0x7E.
		for i < len(b) && (b[i] < 0x40 || b[i] > 0x7E) {
			i++
		}
		if i == len(b) {
			return i
		}
		return i + 1
	case 'O':
		if i >= len(b) {
			return i
		}
		return i + 1
	default:
		return i
	}
}
