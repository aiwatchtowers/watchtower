package sessionhost

// promptState is what one session's agent prompt holds that was not
// submitted — the host's twin of TerminalCenter's promptDrafts,
// pendingReturns, ownerReturnsInPause, ownerBackslashPending and the
// typed-not-submitted hints (spec 2026-10-31 §8 p. 4b, PROJ-12/PROJ-16).
// Deliver (typed-never-submitted delivery) decides on it: a Return of its
// own goes only into a prompt that holds nothing, and a phone line
// (hold_if_prompt_text) is held while holdsText. A session is one run, so a
// relaunch starts with an empty prompt. Guarded by session.mu.
type promptState struct {
	// draft is the owner's text in the prompt, by the draft model's key
	// table (draft.go): what they typed since their last submitting
	// Return, or a line left without its Return (inexact). It also keeps
	// the pending `\` a Return after which is a line break.
	draft draftModel
	// pendingReturn: a delivered line is in its pause before its Return.
	pendingReturn bool
	// leftTyped: a delivered line was left without its Return and the
	// owner has not submitted it yet (also a draft; kept for the reason).
	leftTyped bool
	// dialog: the last PromptHint said a permission dialog is up; input
	// then answers the dialog and changes nothing here.
	dialog bool
	// ownerReturnInPause: the owner's own submitting Return came during
	// pendingReturn's pause; it sent the line, so no Return of ours follows.
	ownerReturnInPause bool
}

// ownerInput feeds one chunk of the owner's typing (an attached client's
// Input; InputTo never comes here) into the draft model (draftModel.feed,
// TerminalCenter.ownerInput's twin): input while a permission dialog is up
// changes nothing; a submitting Return (IsSubmit) empties the prompt and,
// during a line's pause, sent that line; Shift+Tab (IsShiftTab) leaves it as
// it was. Any other key while the pasted line still waits in its pause (no
// Return of the owner's sent it yet) reaches that line, so the draft turns
// inexact: the line is left typed, never submitted with it.
func (p *promptState) ownerInput(b []byte, prof Profile) {
	switch p.draft.feed(b, prof, p.dialog) {
	case keySubmit:
		p.leftTyped = false
		if p.pendingReturn {
			p.ownerReturnInPause = true
		}
	case keyEdit:
		if p.pendingReturn && !p.ownerReturnInPause {
			p.draft.setInexact()
		}
	case keyIgnored, keyNeutral:
	}
}

// holdsText reports whether the prompt holds text not submitted right now:
// the owner's draft, a line left without its Return, or a line in its pause
// before its Return — what a delivery only pastes beside and a phone line is
// held over (held(prompt_has_text)).
func (p *promptState) holdsText() bool {
	return p.draft.holdsText() || p.pendingReturn || p.leftTyped
}

// pasted is a delivery's line pasted at the cursor (its bracketed payload):
// what precedes the cursor is now that line's end (draftModel.appPasted).
func (p *promptState) pasted(payload []byte) {
	p.draft.appPasted(pasteEndsInBackslash(payload))
}

// beginPause marks a pasted line waiting out its pause before its Return.
func (p *promptState) beginPause() {
	p.pendingReturn = true
	p.ownerReturnInPause = false
}

// endPause ends the pause and reports whether the owner's own submitting
// Return came during it.
func (p *promptState) endPause() (ownerReturned bool) {
	ownerReturned = p.ownerReturnInPause
	p.pendingReturn = false
	p.ownerReturnInPause = false
	return ownerReturned
}

// leaveTyped marks a delivered line left in the prompt without its Return:
// the next line must not submit it with its own.
func (p *promptState) leaveTyped() {
	p.draft.setInexact()
	p.leftTyped = true
}

// appSubmitted is the delivery's own Return after its pause, into a prompt
// that held nothing else: the prompt is empty again.
func (p *promptState) appSubmitted() { p.draft = draftModel{} }
