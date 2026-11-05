package agentkind

import (
	"fmt"
	"strings"
	"testing"
)

func TestAgentKind_ParseAcceptsOnlyAgentKinds(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want Kind
		ok   bool
	}{
		{"claude", Claude, true},
		{"codex", Codex, true},
		{"shell", "", false},
		{"", "", false},
		{"Claude", "", false},
		{"CODEX", "", false},
		{" codex", "", false},
		{"gemini", "", false},
	} {
		got, ok := Parse(tc.in)
		if got != tc.want || ok != tc.ok {
			t.Errorf("Parse(%q) = %q, %v; want %q, %v", tc.in, got, ok, tc.want, tc.ok)
		}
		if IsAgent(tc.in) != tc.ok {
			t.Errorf("IsAgent(%q) = %v, want %v", tc.in, !tc.ok, tc.ok)
		}
	}
}

func TestAgentKind_LabelAndDisplayName(t *testing.T) {
	for _, tc := range []struct {
		k            Kind
		label, title string
	}{
		{Claude, "claude-code", "Claude Code"},
		{Codex, "codex-cli", "Codex"},
		{"shell", "", ""},
		{"", "", ""},
	} {
		if got := tc.k.Label(); got != tc.label {
			t.Errorf("%q.Label() = %q, want %q", tc.k, got, tc.label)
		}
		if got := tc.k.DisplayName(); got != tc.title {
			t.Errorf("%q.DisplayName() = %q, want %q", tc.k, got, tc.title)
		}
	}
}

// SQLKinds lists exactly the kinds Parse accepts, so a new kind cannot be
// added to one and forgotten in the other.
func TestAgentKind_SQLKindsMatchesParse(t *testing.T) {
	if got := SQLKinds(); got != "('claude','codex')" {
		t.Fatalf("SQLKinds() = %q", got)
	}
	inner := strings.TrimSuffix(strings.TrimPrefix(SQLKinds(), "("), ")")
	for quoted := range strings.SplitSeq(inner, ",") {
		s := strings.Trim(quoted, "'")
		if _, ok := Parse(s); !ok || fmt.Sprintf("'%s'", s) != quoted {
			t.Errorf("SQLKinds lists %s, which Parse rejects", quoted)
		}
	}
}

// The rows G7's spikes on codex 0.159.2 support (the Swift twin
// AgentSessionCapsTests pins the same rows).
func TestAgentKind_SessionCaps(t *testing.T) {
	if got := Claude.SessionCaps(); got != (SessionCaps{MidturnInput: true, PhoneInput: true, PermissionWait: true, IdleSignal: true, Elicitation: true}) {
		t.Fatalf("claude = %+v", got)
	}
	if got := Codex.SessionCaps(); got != (SessionCaps{MidturnInput: true, PhoneInput: true}) {
		t.Fatalf("codex = %+v", got)
	}
	if got := SessionCapsOf("shell"); got != (SessionCaps{}) {
		t.Fatalf("shell = %+v", got)
	}
	// Claude reports every mid-turn dialog; Codex's MCP forms raise no state,
	// so nothing goes to it while it works and the phone sends it no Esc.
	if !Claude.SessionCaps().TakesLineWhileWorking() || !Claude.SessionCaps().TakesInterrupt() {
		t.Fatal("claude must take a line while working and an interrupt")
	}
	if Codex.SessionCaps().TakesLineWhileWorking() || Codex.SessionCaps().TakesInterrupt() {
		t.Fatal("codex must take neither a line while working nor an interrupt")
	}
}
