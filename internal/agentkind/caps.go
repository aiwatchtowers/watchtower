package agentkind

// SessionCaps is what a Workbench session's agent offers beyond its state
// hooks (spec 2026-11-05-llm-transport-independence §3.5 "Session
// capabilities"). Consumers ask it instead of the kind. A temporary home:
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
	// answer and Interrupt).
	PermissionWait bool
	// IdleSignal: the agent reports an idle prompt (Claude Code's
	// Notification idle_prompt).
	IdleSignal bool
	// Elicitation: the agent reports an MCP elicitation through a hook
	// (Claude Code's Notification elicitation_dialog).
	Elicitation bool
}

// SessionCaps is k's row; a kind that is not an agent offers nothing.
//
// Codex rows come from G7's spikes on codex 0.159.2 (2026-11-05):
//   - a line pasted with its Return mid-turn is shown as "submitted after
//     next tool call" and goes into the same turn's next model request,
//     with a UserPromptSubmit hook event, as Claude Code queues one;
//   - its PermissionRequest hook can hold and answer, but while the hook
//     holds the terminal shows "Running hook" and no prompt, so a
//     permission-wait hook would take the Mac's own answer away for the
//     whole hold: not enabled (owner decision);
//   - no Notification hook event exists, and an MCP elicitation fires no
//     hook and writes nothing to the rollout.
func (k Kind) SessionCaps() SessionCaps {
	switch k {
	case Claude:
		return SessionCaps{MidturnInput: true, PhoneInput: true, PermissionWait: true, IdleSignal: true, Elicitation: true}
	case Codex:
		return SessionCaps{MidturnInput: true, PhoneInput: true}
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
