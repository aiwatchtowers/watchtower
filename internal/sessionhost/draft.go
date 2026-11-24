package sessionhost

import "bytes"

// draftModel is the owner's text in one session's agent prompt as a length
// (spec 2026-11-24-workchat-polish §6.1, C3): count runes, trusted only
// while exact. The zero value is the empty prompt of a new run. Twin of
// WatchtowerCore's DraftModel; both follow testdata/draft_cases.json.
//
// Only keys whose effect on the prompt is certain keep it exact: printable
// runes and a single-line bracketed paste add their runes (a paste may come
// as several chunks: its brackets and its text are separate writes), Backspace
// takes one, a submitting Return empties it and Shift+Tab changes nothing.
// Everything else — cursor and word-edit keys, Ctrl+U (in Claude Code
// 2.1.331 it erases only the last screen row of a wrapped draft), Esc, Tab, a
// line break, a multi-line paste, the owner's Ctrl+C (it interrupts a working
// turn and keeps the text, spec C11), the app's own interrupt Esc
// (appInterrupt) and any key under a profile without ExactDraft — makes it
// inexact: from then on only a submit (or the app's clear) empties it. An
// inexact draft always holds text, so an unknown prompt holds a line as
// before (PROJ-16, PROJ-23).
type draftModel struct {
	count int
	// inexact: count is no longer known to match the prompt.
	inexact bool
	// backslash: the last printable input was `\`, with only escape
	// sequences or paste brackets since — a Return there is a line break.
	backslash bool
	// inPaste: a bracketed paste began and its end bracket has not come.
	inPaste bool
}

// draftKey is what one fed chunk was.
type draftKey int

const (
	// keyIgnored: empty, or input into a permission dialog.
	keyIgnored draftKey = iota
	// keySubmit: a submitting Return (IsSubmit).
	keySubmit
	// keyNeutral: Shift+Tab, a mode switch.
	keyNeutral
	// keyEdit: anything else, which may change the prompt's text.
	keyEdit
)

// holdsText reports whether the prompt may hold text: count > 0 or inexact.
func (d draftModel) holdsText() bool { return d.count > 0 || d.inexact }

// clearedByApp is the app's own clear of the prompt (Task 7's clear_first):
// empty and exact, whatever the draft was.
func (d *draftModel) clearedByApp() { *d = draftModel{} }

// appInterrupt is the app's own Esc into the session (the phone's
// Interrupt, an InputTo): Claude Code may move a queued message back into
// the prompt, so the draft's length is no longer known.
func (d *draftModel) appInterrupt() { d.inexact = true }

// feed reads one chunk of the owner's input. Input while a dialog is up
// changes nothing (it answers the dialog).
func (d *draftModel) feed(b []byte, prof Profile, dialog bool) draftKey {
	if len(b) == 0 || dialog {
		return keyIgnored
	}
	if !d.inPaste && IsShiftTab(b) {
		return keyNeutral
	}
	// A Return inside a paste's text is the paste's, never a submit.
	submit := !d.inPaste && IsSubmit(b, d.backslash, prof)
	d.backslash = EndsAfterBackslash(b, d.backslash)
	if submit {
		d.count, d.inexact = 0, false
		return keySubmit
	}
	d.edit(b)
	if !prof.ExactDraft {
		d.inexact = true
	}
	return keyEdit
}

// shiftTab is Shift+Tab's sequence (IsShiftTab), neutral inside a chunk too.
var shiftTab = []byte("\x1b[Z")

// edit applies the key table to a chunk that is no submit.
func (d *draftModel) edit(b []byte) {
	for i := 0; i < len(b); {
		if d.inPaste {
			i += d.pasted(b[i:])
			continue
		}
		c := b[i]
		switch {
		case c == 0x1B && bytes.HasPrefix(b[i:], pasteStart):
			d.inPaste = true
			i += len(pasteStart)
		case c == 0x1B:
			if !bytes.HasPrefix(b[i:], shiftTab) {
				d.inexact = true // a cursor or word-edit key, Esc, Option+key
			}
			i = escapeSequenceEnd(b, i+1)
		case c == 0x7F || c == 0x08: // Backspace, Ctrl+H
			if !d.inexact && d.count > 0 {
				d.count--
				if d.count == 0 {
					d.backslash = false // the `\` went with the rest
				}
			}
			i++
		case c < 0x20: // a line break, Ctrl+C, Ctrl+U, Tab, Ctrl+A/E/W/K, …
			d.inexact = true
			i++
		default:
			d.add(b[i : i+1])
			i++
		}
	}
}

// pasted reads a paste's text up to its end bracket and returns the bytes
// it took; a line break in it makes the draft inexact.
func (d *draftModel) pasted(b []byte) int {
	text, n := b, len(b)
	if end := bytes.Index(b, pasteEnd); end >= 0 {
		text, n = b[:end], end+len(pasteEnd)
		d.inPaste = false
	}
	d.add(text)
	if bytes.ContainsAny(text, "\r\n") {
		d.inexact = true
	}
	return n
}

// add counts the runes of b: every byte but a UTF-8 continuation byte (a
// paste's control characters count too — never fewer than the prompt shows).
func (d *draftModel) add(b []byte) {
	for _, c := range b {
		if c < 0x80 || c >= 0xC0 {
			d.count++
		}
	}
}
