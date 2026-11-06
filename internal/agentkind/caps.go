package agentkind

// SessionCaps is what a Workbench session's agent offers beyond its state
// hooks (spec 2026-11-05-llm-transport-independence §3.5 "Session
// capabilities"). Consumers ask it instead of the kind; the Go hub reads
// PhoneInput, TakesLineWhileWorking and the PermissionWait pair, the rest is
// recorded for A5's shared fixture. A temporary home:
// internal/sessionagent's Adapter.Caps (plan Task A5) replaces it, and the
// Swift twin `AgentSessionCaps` (WatchtowerCore) mirrors it by hand until
// A5's shared fixture.
type SessionCaps struct {
	// MidturnInput: a line pasted with its Return while the agent works is
	// taken at the agent's next step instead of waiting for the turn's end.
	MidturnInput bool
	// PhoneInput: the hub types a phone line (or the wrap-up line) into the
	// session (PROJ-16).
	PhoneInput bool
	// PermissionWait: a PermissionRequest hook can hold the prompt while the
	// Mac terminal still shows it, and answer it (PROJ-21: the phone's
	// answer).
	PermissionWait bool
	// IdleSignal: the agent reports an idle prompt (Claude Code's
	// Notification idle_prompt).
	IdleSignal bool
	// Elicitation: the agent reports an MCP elicitation through a hook
	// (Claude Code's Notification elicitation_dialog).
	Elicitation bool
	// RolloutWatch: a failed or interrupted turn is read from the agent's
	// transcript, not a hook (failure_signal "pull"): the session host's
	// rollout watch, or the app's bridge probe (spec 2026-11-05 §3.5, G5).
	RolloutWatch bool
}

// TakesLineWhileWorking reports whether a line may go into the session while its agent
// works. Mid-turn input alone is not enough: every dialog that can open
// mid-turn must raise a hook state first (an MCP elicitation included), or a
// line pasted with its Return would answer a form Watchtower cannot see.
func (c SessionCaps) TakesLineWhileWorking() bool { return c.MidturnInput && c.Elicitation }

// TakesInterrupt reports whether the phone's one Esc (PROJ-21) may go to the session: a
// prompt the hooks report is never at risk (PermissionWait), and no
// unreported form can be open (Elicitation).
func (c SessionCaps) TakesInterrupt() bool { return c.PermissionWait && c.Elicitation }

// SessionCaps is k's row; a kind that is not an agent offers nothing.
//
// Codex rows come from G7's spikes on codex 0.159.2 (2026-11-05):
//   - a line pasted with its Return mid-turn is shown as "submitted after
//     next tool call" and goes into the same turn's next model request,
//     with a UserPromptSubmit hook event, as Claude Code queues one (but
//     without Elicitation no line is sent while it works);
//   - its PermissionRequest hook can hold and answer, but while the hook
//     holds the terminal shows "Running hook" and no prompt, so a
//     permission-wait hook would take the Mac's own answer away for the
//     whole hold: not enabled (owner decision);
//   - no Notification hook event exists, and an MCP elicitation shows a
//     form in the terminal but fires no hook and writes nothing to the
//     rollout;
//   - a failed turn fires no Stop and Codex has no StopFailure, so the
//     failure is read from the rollout (board #959, G5).
func (k Kind) SessionCaps() SessionCaps {
	switch k {
	case Claude:
		return SessionCaps{MidturnInput: true, PhoneInput: true, PermissionWait: true, IdleSignal: true, Elicitation: true}
	case Codex:
		return SessionCaps{MidturnInput: true, PhoneInput: true, RolloutWatch: true}
	}
	return SessionCaps{}
}

// SessionCapsOf is the row of the stored kind s (terminal_sessions.kind);
// a kind that is not an agent offers nothing.
func SessionCapsOf(s string) SessionCaps {
	k, ok := Parse(s)
	if !ok {
		return SessionCaps{}
	}
	return k.SessionCaps()
}
