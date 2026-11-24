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
// a key's effect is decided at the byte where it occurs. A write ending in a
// lone ESC is the Esc key (inexact) unless the next write goes on with `[`
// or `O`, which reassembles the sequence (a paste's opening bracket split
// after its ESC included); Esc then Return as two writes stays Esc and a
// submit, as the PROJ-12 guards pin.
// Only keys whose effect on the prompt is certain keep it exact: printable
// runes and a single-line bracketed paste add their runes, Backspace takes
// one (Claude Code's profile only, ExactDraft), a submitting Return (a CR
// ending its write; Claude Code 2.1.331 submits `text\r` written at once)
// empties it and Shift+Tab changes nothing. Everything else — cursor and
// word-edit keys, Ctrl+U (in 2.1.331 it erases only the last screen row of a
// wrapped draft), Esc, Tab, a line break (Option+Return `ESC CR` too), a
// multi-line paste, a paste with an escape in its text, the owner's Ctrl+C (it interrupts a working turn and
// keeps the text, spec C11) and any key under a profile without ExactDraft —
// makes it inexact: from then on only a submit (or the app's clear) empties
// it. An inexact draft, an open paste and a partial escape sequence always
// hold text, so an unknown prompt holds a line as before (PROJ-16, PROJ-23).
type draftModel struct {
	count int
	// inexact: count is no longer known to match the prompt.
	inexact bool
	// backslash: the character before the cursor is (or may be) `\` — a
	// Return there is a line break.
	backslash bool
	// inPaste: a bracketed paste began and its end bracket has not come.
	inPaste bool
	// esc: an escape sequence begun and not yet complete (outside a paste),
	// or the part of the paste's end bracket seen so far (inside one).
	esc string
	// escKey: esc is a lone ESC that ended its write, already read as the
	// Esc key; only `[` or `O` next makes it the start of a sequence.
	escKey bool
	// run: the characters typed since the draft was empty, the app's own
	// paste or the cursor last became unknown — `\` for a backslash, `.`
	// for anything else — so a Backspace knows whether the character then
	// before the cursor is `\`. Kept only under a profile with ExactDraft,
	// the only one whose Backspace reads it.
	run []byte
	// appLine: a line the app pasted, which count leaves out (a delivery in
	// its pause), precedes the run: a Backspace past the run reaches it.
	appLine bool
}

// draftKey is what one fed chunk was.
type draftKey int

const (
	// keyIgnored: empty, or input into a permission dialog.
	keyIgnored draftKey = iota
	// keySubmit: a submitting Return.
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
func (d *draftModel) holdsText() bool {
	return d.count > 0 || d.inexact || d.inPaste || d.esc != ""
}

// clearedByApp is the app's own clear of the prompt (Task 7's clear_first):
// empty and exact, whatever the draft was.
func (d *draftModel) clearedByApp() { *d = draftModel{} }

// appPasted is a delivery's own line pasted at the cursor, ending in `\`
// or not: the character before the cursor is then the line's last, and the
// run starts again behind it. A permission dialog that came up meanwhile may
// have taken the paste, so a `\` already before the cursor stays possible
// too. The caller decides what the paste does to the count (left typed:
// inexact; in its pause: the pause holds the prompt).
func (d *draftModel) appPasted(endsInBackslash bool) {
	d.run = nil
	d.backslash = d.backslash || endsInBackslash
	d.appLine = true
}

// pasteEndsInBackslash reports whether a bracketed paste payload's text ends
// in `\`.
func pasteEndsInBackslash(payload []byte) bool {
	return bytes.HasSuffix(payload, []byte("\\"+escPasteEnd))
}

// feed reads one chunk of the owner's input. Input while a dialog is up
// changes nothing (it answers the dialog).
func (d *draftModel) feed(b []byte, prof Profile, dialog bool) draftKey {
	if len(b) == 0 || dialog {
		return keyIgnored
	}
	edited, submitted := false, false
	for i, c := range b {
		if d.escKey && c != '[' && c != 'O' {
			d.esc, d.escKey = "", false // it was the Esc key
		}
		switch {
		case d.inPaste:
			d.pasteByte(c, prof)
			edited = true
		case d.esc != "" || c == 0x1B:
			edited = d.escapeByte(c, i == len(b)-1) || edited
		case c == 0x0D && i == len(b)-1 && !d.backslash && bytes.Equal(prof.Submit, []byte{0x0D}):
			*d = draftModel{} // a fresh run: a long one's buffer goes
			submitted = true
		default:
			d.keyByte(c, prof)
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
		d.inexact = true // the cursor is where it was: run stays
	}
	return keyEdit
}

// escapeByte takes a byte of an escape sequence outside a paste (or the ESC
// that starts one) and reports whether the key it completed may have
// changed the text: false for Shift+Tab and while the sequence is open. An
// ESC ending its write is the Esc key until a later write goes on with it.
func (d *draftModel) escapeByte(c byte, last bool) bool {
	if d.esc == "" {
		d.esc = "\x1b"
		if last {
			d.escKey = true
			d.setInexact()
			return true
		}
		return false
	}
	d.esc += string(c)
	d.escKey = false
	if !escapeComplete(d.esc) {
		return false
	}
	seq := d.esc
	d.esc = ""
	switch seq {
	case escPasteStart:
		d.inPaste = true
	case escShiftTab:
		return false
	case "\x1b\r", "\x1b\n": // Option+Return: a line break
		d.backslash = false
		d.setInexact()
	default:
		d.setInexact() // a cursor or word-edit key, Esc then a key, Option+key
		if seq[len(seq)-1] == '\\' {
			// Option+`\`, or Esc then `[\` / `O\` typed one key per write
			// (the reassembly cannot tell them apart): a `\` may be before
			// the cursor.
			d.backslash = true
		}
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

// pasteByte takes one byte inside a paste: the end bracket is matched as it
// streams in (a new ESC restarts the match); every other byte, a broken
// match's included, is the paste's text. An escape inside the text may show
// wider or narrower than its bytes: a broken match makes the draft inexact.
func (d *draftModel) pasteByte(c byte, prof Profile) {
	if d.esc != "" {
		if next := d.esc + string(c); strings.HasPrefix(escPasteEnd, next) {
			d.esc = next
			if next == escPasteEnd {
				d.esc, d.inPaste = "", false
			}
			return
		}
		seen := d.esc
		d.esc = ""
		for i := range len(seen) {
			d.pasteText(seen[i], prof)
		}
		d.setInexact()
	}
	if c == 0x1B {
		d.esc = "\x1b"
		return
	}
	d.pasteText(c, prof)
}

// pasteText takes one byte of a paste's text: it counts as typed, but a
// line break in it makes the draft inexact.
func (d *draftModel) pasteText(c byte, prof Profile) {
	d.addRune(c, prof)
	if c == 0x0D || c == 0x0A {
		d.backslash = false
		d.setInexact()
	}
}

// keyByte takes one typed byte outside a paste and an escape sequence that
// is no submit.
func (d *draftModel) keyByte(c byte, prof Profile) {
	switch {
	case c == 0x7F || c == 0x08: // Backspace, Ctrl+H
		d.erase(prof)
	case c == 0x0D || c == 0x0A: // a line break: `\` then Return, Ctrl+J, a CR mid-chunk
		d.backslash = false
		d.setInexact()
	case c < 0x20: // Ctrl+C, Ctrl+U, Tab, Ctrl+A/E/W/K, …
		d.setInexact()
	default:
		d.addRune(c, prof)
	}
}

// erase is one Backspace. Under a profile without ExactDraft the program
// may not erase one character: what precedes the cursor is unknown (read
// as `\`: a Return holds). Otherwise it takes a rune off an exact draft, and
// the character then before the cursor is the run's last, none in an exact
// empty draft with no line of the app's before it, else unknown.
func (d *draftModel) erase(prof Profile) {
	if !prof.ExactDraft {
		d.backslash = true
		d.setInexact()
		return
	}
	if n := len(d.run); n > 0 {
		d.run = d.run[:n-1]
	}
	if !d.inexact && d.count > 0 {
		d.count--
	}
	switch {
	case len(d.run) > 0:
		d.backslash = d.run[len(d.run)-1] == '\\'
	case !d.inexact && d.count == 0 && !d.appLine:
		d.backslash = false
	default:
		d.backslash = true
	}
}

// addRune counts printable input: every byte but a UTF-8 continuation byte
// (a paste's control characters count too — never fewer than the prompt
// shows), and keeps the pending `\` and, under ExactDraft, the run.
func (d *draftModel) addRune(c byte, prof Profile) {
	if c >= 0x80 && c < 0xC0 {
		return
	}
	d.count++
	d.backslash = c == '\\'
	switch {
	case !prof.ExactDraft:
	case d.backslash:
		d.run = append(d.run, '\\')
	default:
		d.run = append(d.run, '.')
	}
}

// setInexact gives up the length and the cursor: from now on only a submit
// empties it, and the run starts again (a fresh one: a long run's buffer
// goes).
func (d *draftModel) setInexact() {
	d.inexact = true
	d.run = nil
}
