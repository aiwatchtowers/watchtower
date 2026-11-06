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
