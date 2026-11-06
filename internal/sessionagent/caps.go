package sessionagent

// Signal values of Caps.FailureSignal and Caps.InterruptSignal: how the
// agent reports a failed or interrupted turn.
const (
	SignalHook = "hook" // a hook event (Claude Code's StopFailure)
	SignalPull = "pull" // read from the transcript by the adapter's Watch
	SignalNone = "none"
)

// Caps is what a Workbench session's agent offers (spec
// 2026-11-05-llm-transport-independence §3.5 "Session capabilities").
// Consumers ask it instead of the kind. The rows are the adapters' Caps();
// agent_capabilities.json carries the same rows to Swift and the phone
// (TestSessionAgent_CapsFixtureMatchesAdapters, the Kit's
// AgentSessionCapabilitiesTests), the POLICY-02 dual-path style.
type Caps struct {
	// StateEvents is the hook events that move the row's state.
	StateEvents []string `json:"state_events"`
	// FailureSignal reports a failed turn: SignalHook, SignalPull or
	// SignalNone.
	FailureSignal string `json:"failure_signal"`
	// InterruptSignal reports the owner's Esc: SignalHook or SignalPull.
	InterruptSignal string `json:"interrupt_signal"`
	// IdleSignal: the agent reports an idle prompt (Claude Code's
	// Notification idle_prompt).
	IdleSignal bool `json:"idle_signal"`
	// PermissionWait: a PermissionRequest hook can hold the prompt while the
	// Mac terminal still shows it, and answer it (PROJ-21: the phone's
	// answer).
	PermissionWait bool `json:"permission_wait"`
	// MidturnInput: a line pasted with its Return while the agent works is
	// taken at the agent's next step instead of waiting for the turn's end.
	MidturnInput bool `json:"midturn_input"`
	// PhoneInput: the hub types a phone line (or the wrap-up line) into the
	// session (PROJ-16).
	PhoneInput bool `json:"phone_input"`
	// Elicitation: the agent reports an MCP elicitation through a hook
	// (Claude Code's Notification elicitation_dialog).
	Elicitation bool `json:"elicitation"`
	// RegistryProbe: `workbench session-probe` can tell a stale background
	// count from live work (Claude Code's session registry, Codex's rollout).
	RegistryProbe bool `json:"registry_probe"`
	// CompressedTranscript: a compressed transcript is read like a plain
	// one (Codex's zstd rollouts, N1).
	CompressedTranscript bool `json:"compressed_transcript"`
	// SubagentFeed: subagents' own transcripts reach the Workchat feed.
	SubagentFeed bool `json:"subagent_feed"`
	// Analytics: the session's transcript is imported into agent analytics
	// (AGENTLOG-01..07).
	Analytics bool `json:"analytics"`
	// LaunchHooks: the whole hook set arrives with the launch flags, the same
	// lines in every folder, and a hook finds its row (and workbench) through
	// WATCHTOWER_TERMINAL_SESSION_ID (`--agent <kind>`); otherwise the hooks
	// are installed into the folder and name the workbench (`--workbench N`).
	LaunchHooks bool `json:"launch_hooks"`
	// BackgroundTasks: the agent's Stop and SubagentStop list the background
	// tasks still in flight; otherwise the count is the subagent turns still
	// open.
	BackgroundTasks bool `json:"background_tasks"`
	// AppSessionID: the app chooses the agent's session id when it starts a
	// new session (Claude Code's --session-id), so the row holds one from
	// its creation and a relaunch resumes it; otherwise the agent mints its
	// own and its first SessionStart reports it.
	AppSessionID bool `json:"app_session_id"`
}

// TakesLineWhileWorking reports whether a line may go into the session while
// its agent works. Mid-turn input alone is not enough: every dialog that can
// open mid-turn must raise a hook state first (an MCP elicitation
// included), or a line pasted with its Return would answer a form Watchtower
// cannot see.
func (c Caps) TakesLineWhileWorking() bool { return c.MidturnInput && c.Elicitation }

// TakesInterrupt reports whether the phone's one Esc (PROJ-21) may go to the
// session: a prompt the hooks report is never at risk (PermissionWait), and
// no unreported form can be open (Elicitation).
func (c Caps) TakesInterrupt() bool { return c.PermissionWait && c.Elicitation }

// RolloutWatch reports that a failed or interrupted turn is read from the
// agent's transcript, not a hook (failure_signal "pull"): the session host's
// watch, or the app's bridge probe (spec 2026-11-05 §3.5, G5).
func (c Caps) RolloutWatch() bool { return c.FailureSignal == SignalPull }

// CapsOf is the row of the stored kind s (terminal_sessions.kind); a kind
// that is not an agent offers nothing.
func CapsOf(s string) Caps {
	a, ok := For(Kind(s))
	if !ok {
		return Caps{}
	}
	return a.Caps()
}
