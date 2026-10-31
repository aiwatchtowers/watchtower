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
	// draft: the prompt holds text not submitted — the owner typed since
	// their last submitting Return, or a line was left without its Return.
	draft bool
	// pendingReturn: a delivered line is in its pause before its Return.
	pendingReturn bool
	// leftTyped: a delivered line was left without its Return and the
	// owner has not submitted it yet (also a draft; kept for the reason).
	leftTyped bool
	// dialog: the last PromptHint said a permission dialog is up; input
	// then answers the dialog and changes nothing here.
	dialog bool
	// backslash: the owner's last printable prompt input was `\`, with only
	// escape sequences or paste brackets since — a Return there is a line
	// break, not a submit.
	backslash bool
	// ownerReturnInPause: the owner's own submitting Return came during
	// pendingReturn's pause; it sent the line, so no Return of ours follows.
	ownerReturnInPause bool
}

// ownerInput feeds one chunk of client input (Input or InputTo) by
// TerminalCenter.ownerInput's rule: input while a permission dialog is up
// changes nothing; a submitting Return (IsSubmit) empties the prompt; any
// other input leaves a draft.
func (p *promptState) ownerInput(b []byte, prof Profile) {
	if len(b) == 0 || p.dialog {
		return
	}
	if IsSubmit(b, p.backslash, prof) {
		p.draft = false
		p.leftTyped = false
		if p.pendingReturn {
			p.ownerReturnInPause = true
		}
	} else {
		p.draft = true
	}
	p.backslash = EndsAfterBackslash(b, p.backslash)
}

// holdsText reports whether the prompt holds text not submitted right now:
// the owner's draft, a line left without its Return, or a line in its pause
// before its Return — what a delivery only pastes beside and a phone line is
// held over (held(prompt_has_text)).
func (p *promptState) holdsText() bool {
	return p.draft || p.pendingReturn || p.leftTyped
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
	p.draft = true
	p.leftTyped = true
}
