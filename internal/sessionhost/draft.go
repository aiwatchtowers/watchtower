package sessionhost

import (
	"bytes"
	"strings"
)

// draftModel is the owner's text in one session's agent prompt as a length
// (spec 2026-11-24-workchat-polish §6.1, C3): count runes, trusted only
// while exact. The zero value is the empty prompt of a new run. Twin of
// WatchtowerCore's DraftModel; both follow testdata/draft_cases.json.
//
// Input is decoded strictly in byte order, its parser state kept across
// chunks (an escape sequence or a bracketed paste may span several writes):
// a key's effect is decided at the byte where it occurs. Only keys whose
// effect on the prompt is certain keep it exact: printable runes and a
// single-line bracketed paste add their runes, Backspace takes one, a
// submitting Return empties it and Shift+Tab changes nothing. Everything
// else — cursor and word-edit keys, Ctrl+U (in Claude Code 2.1.331 it erases
// only the last screen row of a wrapped draft), Esc, Tab, a line break, a
// multi-line paste, the owner's Ctrl+C (it interrupts a working turn and
// keeps the text, spec C11) and any key under a profile without ExactDraft —
// makes it inexact: from then on only a submit (or the app's clear) empties
// it. An inexact draft, an open paste and a partial escape sequence always
// hold text, so an unknown prompt holds a line as before (PROJ-16, PROJ-23).
type draftModel struct {
	count int
	// inexact: count is no longer known to match the prompt.
	inexact bool
	// backslash: the last printable input was `\`, with only escape
	// sequences or paste brackets since — a Return there is a line break.
	backslash bool
	// inPaste: a bracketed paste began and its end bracket has not come.
	inPaste bool
	// esc: an escape sequence begun in an earlier chunk, not yet complete.
	esc string
	// shape: while exact, one byte per rune of the draft — `\` for a
	// backslash, `.` for anything else — so an erase knows whether the
	// draft then ends in `\`.
	shape string
}

// draftKey is what one fed chunk was.
type draftKey int

const (
	// keyIgnored: empty, or input into a permission dialog.
	keyIgnored draftKey = iota
	// keySubmit: a submitting Return (a CR ending the chunk, outside a
	// paste or an escape sequence and not after `\`).
	keySubmit
	// keyNeutral: only Shift+Tab, a mode switch.
	keyNeutral
	// keyEdit: anything else, which may change the prompt's text.
	keyEdit
)

// Escape sequences the key table knows.
const (
	escPasteStart = "\x1b[200~"
	escPasteEnd   = "\x1b[201~"
	escShiftTab   = "\x1b[Z"
)

// holdsText reports whether the prompt may hold text: count > 0, inexact,
// inside an open paste, or in the middle of an escape sequence.
func (d draftModel) holdsText() bool {
	return d.count > 0 || d.inexact || d.inPaste || d.esc != ""
}

// clearedByApp is the app's own clear of the prompt (Task 7's clear_first):
// empty and exact, whatever the draft was.
func (d *draftModel) clearedByApp() { *d = draftModel{} }

// feed reads one chunk of the owner's input. Input while a dialog is up
// changes nothing (it answers the dialog).
func (d *draftModel) feed(b []byte, prof Profile, dialog bool) draftKey {
	if len(b) == 0 || dialog {
		return keyIgnored
	}
	edited, submitted := false, false
	for i, c := range b {
		switch {
		case d.esc != "" || c == 0x1B:
			edited = d.escapeByte(c, i == len(b)-1) || edited
		case d.inPaste:
			d.pasteByte(c)
			edited = true
		case c == 0x0D && i == len(b)-1 && !d.backslash && bytes.Equal(prof.Submit, []byte{0x0D}):
			*d = draftModel{}
			submitted = true
		default:
			d.keyByte(c)
			edited = true
		}
	}
	switch {
	case submitted:
		return keySubmit
	case !edited && d.esc == "": // a sequence still open may be any key
		return keyNeutral
	}
	if !prof.ExactDraft {
		d.setInexact()
	}
	return keyEdit
}

// escapeByte takes a byte of an escape sequence (or the ESC that starts
// one) and reports whether the key it completed may have changed the text:
// false for Shift+Tab and while the sequence is still open. A lone ESC
// ending a chunk outside a paste is the Esc key.
func (d *draftModel) escapeByte(c byte, last bool) bool {
	if d.esc == "" {
		if last && !d.inPaste {
			d.setInexact() // the Esc key
			return true
		}
		d.esc = "\x1b"
		return false
	}
	d.esc += string(c)
	if !escapeComplete(d.esc) {
		return false
	}
	seq := d.esc
	d.esc = ""
	switch {
	case d.inPaste && seq == escPasteEnd:
		d.inPaste = false
	case d.inPaste:
		d.setInexact() // an escape inside pasted text: of unknown width
	case seq == escPasteStart:
		d.inPaste = true
	case seq == escShiftTab:
		return false
	default:
		d.setInexact() // a cursor or word-edit key, Option+key, Option+Return
	}
	return true
}

// escapeComplete reports whether s (starting with ESC) is a whole escape
// sequence: CSI `ESC [ … final`, SS3 `ESC O x`, or `ESC x`.
func escapeComplete(s string) bool {
	switch {
	case len(s) < 2:
		return false
	case s[1] == '[':
		return len(s) >= 3 && s[len(s)-1] >= 0x40 && s[len(s)-1] <= 0x7E
	case s[1] == 'O':
		return len(s) >= 3
	default:
		return true
	}
}

// pasteByte takes one byte of a paste's text: it counts as typed, but a
// line break in it makes the draft inexact.
func (d *draftModel) pasteByte(c byte) {
	d.addRune(c)
	if c == 0x0D || c == 0x0A {
		d.backslash = false
		d.setInexact()
	}
}

// keyByte takes one typed byte outside a paste and an escape sequence that
// is no submit.
func (d *draftModel) keyByte(c byte) {
	switch {
	case c == 0x7F || c == 0x08: // Backspace, Ctrl+H
		if !d.inexact && d.count > 0 {
			d.count--
			d.shape = d.shape[:len(d.shape)-1]
			d.backslash = strings.HasSuffix(d.shape, `\`)
		}
	case c == 0x0D || c == 0x0A: // a line break: `\` then Return, Ctrl+J, a CR mid-chunk
		d.backslash = false
		d.setInexact()
	case c < 0x20: // Ctrl+C, Ctrl+U, Tab, Ctrl+A/E/W/K, …
		d.setInexact()
	default:
		d.addRune(c)
	}
}

// addRune counts printable input: every byte but a UTF-8 continuation byte
// (a paste's control characters count too — never fewer than the prompt
// shows), and keeps the pending `\`.
func (d *draftModel) addRune(c byte) {
	if c >= 0x80 && c < 0xC0 {
		d.backslash = false
		return
	}
	d.count++
	d.backslash = c == '\\'
	if !d.inexact {
		if d.backslash {
			d.shape += `\`
		} else {
			d.shape += "."
		}
	}
}

// setInexact gives up the length: from now on only a submit empties it.
func (d *draftModel) setInexact() {
	d.inexact = true
	d.shape = ""
}
