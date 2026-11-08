// Package agentkind names the coding agents a Workbench terminal session can
// run (terminal_sessions.kind): Claude Code and Codex CLI. Every place that
// means "an agent session" asks this package instead of spelling a kind.
//
// registry is the one list of agent kinds: Parse, IsAgent, Label,
// DisplayName, SQLKinds, All, Names, Choices and every "must be X or Y"
// message derive from it. Adding a session agent starts here and continues
// down docs/features/adding-a-harness.md, whose executable form is the
// TestLLMTRANSPORT01_* completeness tests.
package agentkind

import (
	"fmt"
	"strings"
)

// Kind is an agent kind as terminal_sessions.kind stores it.
type Kind string

const (
	Claude Kind = "claude"
	Codex  Kind = "codex"
)

// Descriptor is one registered agent kind.
type Descriptor struct {
	Kind Kind
	// Label is the kind's agent_label value (workbench comments).
	Label string
	// DisplayName is the kind's product name for UI and brief text.
	DisplayName string
}

// registry is every agent kind, in display order. The session adapter of
// each lives in internal/sessionagent, which checks at start that its
// adapters are exactly these kinds.
var registry = []Descriptor{
	{Kind: Claude, Label: "claude-code", DisplayName: "Claude Code"},
	{Kind: Codex, Label: "codex-cli", DisplayName: "Codex"},
}

// Registry is every registered agent kind's descriptor, in display order.
func Registry() []Descriptor { return append([]Descriptor(nil), registry...) }

// All is every agent kind, in display order.
func All() []Kind {
	out := make([]Kind, len(registry))
	for i, d := range registry {
		out[i] = d.Kind
	}
	return out
}

// Names is every agent kind as stored, in display order.
func Names() []string {
	out := make([]string, len(registry))
	for i, d := range registry {
		out[i] = string(d.Kind)
	}
	return out
}

// Choices is the kinds as one human-readable list joined by conj ("claude
// or codex"), for usage text and refusals.
func Choices(conj string) string { return choices(Names(), conj) }

func choices(names []string, conj string) string {
	if len(names) <= 1 {
		return strings.Join(names, "")
	}
	return strings.Join(names[:len(names)-1], ", ") + " " + conj + " " + names[len(names)-1]
}

func lookup(s string) (Descriptor, bool) {
	for _, d := range registry {
		if string(d.Kind) == s {
			return d, true
		}
	}
	return Descriptor{}, false
}

// Parse reads s as an agent kind; false for any other value, `shell`
// included. The match is exact: the column stores lowercase.
func Parse(s string) (Kind, bool) {
	d, ok := lookup(s)
	return d.Kind, ok
}

// Unsupported is the refusal of a value that is no agent kind of this
// version: an honest answer instead of an empty name, a panic or a silent
// fallback to another agent.
func Unsupported(s string) error {
	return fmt.Errorf("agent kind %q is not supported by this version (%s)", s, Choices("or"))
}

// ParseOrRefuse is Parse with Unsupported as the error.
func ParseOrRefuse(s string) (Kind, error) {
	if k, ok := Parse(s); ok {
		return k, nil
	}
	return "", Unsupported(s)
}

// IsAgent reports whether a terminal_sessions.kind value is an agent kind.
func IsAgent(s string) bool {
	_, ok := Parse(s)
	return ok
}

// Label is the kind's agent_label value (workbench comments); "" for a value
// that is no agent kind.
func (k Kind) Label() string {
	d, _ := lookup(string(k))
	return d.Label
}

// DisplayName is the kind's product name for UI and brief text; "" for a
// value that is no agent kind.
func (k Kind) DisplayName() string {
	d, _ := lookup(string(k))
	return d.DisplayName
}

// SQLKinds is the agent kinds as an SQL list literal, for
// `kind IN `+SQLKinds(), so no query spells the list by hand.
func SQLKinds() string {
	quoted := make([]string, len(registry))
	for i, d := range registry {
		quoted[i] = "'" + string(d.Kind) + "'"
	}
	return "(" + strings.Join(quoted, ",") + ")"
}
