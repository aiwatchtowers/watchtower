// Package agentkind names the coding agents a Workbench terminal session can
// run (terminal_sessions.kind): Claude Code and Codex CLI. Every place that
// means "an agent session" asks this package instead of spelling a kind.
package agentkind

// Kind is an agent kind as terminal_sessions.kind stores it.
type Kind string

const (
	Claude Kind = "claude"
	Codex  Kind = "codex"
)

// Parse reads s as an agent kind; false for any other value, `shell`
// included. The match is exact: the column stores lowercase.
func Parse(s string) (Kind, bool) {
	switch k := Kind(s); k {
	case Claude, Codex:
		return k, true
	default:
		return "", false
	}
}

// IsAgent reports whether a terminal_sessions.kind value is an agent kind.
func IsAgent(s string) bool {
	_, ok := Parse(s)
	return ok
}

// Label is the kind's agent_label value (workbench comments); "" for a value
// that is no agent kind.
func (k Kind) Label() string {
	switch k {
	case Claude:
		return "claude-code"
	case Codex:
		return "codex-cli"
	default:
		return ""
	}
}

// DisplayName is the kind's product name for UI and brief text; "" for a
// value that is no agent kind.
func (k Kind) DisplayName() string {
	switch k {
	case Claude:
		return "Claude Code"
	case Codex:
		return "Codex"
	default:
		return ""
	}
}

// SQLKinds is the agent kinds as an SQL list literal, for
// `kind IN `+SQLKinds(), so no query spells the list by hand.
func SQLKinds() string { return "('claude','codex')" }
