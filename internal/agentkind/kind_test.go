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

// The registry is the one list: All, Names, Choices and SQLKinds derive
// from it, in its order, and each entry has its label and product name.
func TestAgentKind_RegistryDerivesEveryList(t *testing.T) {
	all := All()
	if len(all) != 2 || all[0] != Claude || all[1] != Codex {
		t.Fatalf("All() = %v", all)
	}
	if got := strings.Join(Names(), ","); got != "claude,codex" {
		t.Errorf("Names() = %q", got)
	}
	if got := Choices("or"); got != "claude or codex" {
		t.Errorf(`Choices("or") = %q`, got)
	}
	for _, d := range Registry() {
		if d.Label == "" || d.DisplayName == "" {
			t.Errorf("agent kind %q: registry entry needs a label and a display name", d.Kind)
		}
		if d.Kind.Label() != d.Label || d.Kind.DisplayName() != d.DisplayName {
			t.Errorf("agent kind %q: accessors disagree with the registry", d.Kind)
		}
	}
}

// choices joins three or more names with commas before the conjunction.
func TestAgentKind_ChoicesJoinsLongLists(t *testing.T) {
	for _, tc := range []struct {
		names []string
		want  string
	}{
		{[]string{"a"}, "a"},
		{[]string{"a", "b"}, "a or b"},
		{[]string{"a", "b", "c"}, "a, b or c"},
	} {
		if got := choices(tc.names, "or"); got != tc.want {
			t.Errorf("choices(%v) = %q, want %q", tc.names, got, tc.want)
		}
	}
}

// An unknown kind is an honest refusal naming the value and what this
// version supports.
func TestAgentKind_UnsupportedNamesTheValue(t *testing.T) {
	err := Unsupported("gemini")
	if err == nil || err.Error() != `agent kind "gemini" is not supported by this version (claude or codex)` {
		t.Fatalf("Unsupported = %v", err)
	}
	if _, err := ParseOrRefuse("gemini"); err == nil || err.Error() != Unsupported("gemini").Error() {
		t.Errorf("ParseOrRefuse(gemini) = %v", err)
	}
	if k, err := ParseOrRefuse("codex"); err != nil || k != Codex {
		t.Errorf("ParseOrRefuse(codex) = %q, %v", k, err)
	}
}
