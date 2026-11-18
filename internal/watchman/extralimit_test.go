package watchman

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
)

func TestCheckLimits_OwnerRowsAdd(t *testing.T) {
	extra := []db.WatchmanExtraLimit{
		{ID: 1, Kind: "command", Pattern: "terraform apply"},
		{ID: 2, Kind: "tool", Pattern: "create_jira_issue"},
	}
	bash := func(s string) PermissionAsk {
		return PermissionAsk{Tool: "Bash", Summary: s, Worktrees: []string{"/wt"}}
	}
	for _, tc := range []struct {
		name string
		r    PermissionAsk
		want HardLimit
	}{
		{"pattern words lead the command", bash("terraform apply -auto-approve"), LimitOwner},
		{"after a wrapper and a separator", bash("cd infra && env TF_LOG=1 /usr/local/bin/terraform apply"), LimitOwner},
		{"another subcommand", bash("terraform plan"), ""},
		{"pattern words in the middle", bash("echo terraform apply"), ""},
		{"a prefix of a word is no word", bash("terraform applyall"), ""},
		{"tool by its full name", PermissionAsk{Tool: "create_jira_issue"}, LimitOwner},
		{"tool by its MCP suffix", PermissionAsk{Tool: "mcp__acme__create_jira_issue"}, LimitOwner},
		{"tool with another name", PermissionAsk{Tool: "mcp__acme__get_jira_issue"}, ""},
		{"a command pattern never matches a tool", PermissionAsk{Tool: "terraform apply"}, ""},
		// The built-in table comes first.
		{"built-in before the owner's", bash("terraform apply && git push origin main"), LimitMainRef},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := CheckLimits(tc.r, extra)
			assert.Equal(t, tc.want != "", ok)
			assert.Equal(t, tc.want, got)
		})
	}
	// Without owner rows only the built-in table parks.
	_, ok := CheckLimits(bash("terraform apply"), nil)
	assert.False(t, ok)
}

func TestValidateLimitPattern(t *testing.T) {
	for _, tc := range []struct {
		kind, pattern string
		ok            bool
	}{
		{"command", "terraform apply", true},
		{"command", "  ", false},
		{"command", `echo "open`, false},
		{"command", "echo \"two\nlines\"", false},
		{"tool", "create_jira_issue", true},
		{"tool", "two words", false},
		{"tool", "", false},
		{"other", "x", false},
	} {
		err := ValidateLimitPattern(tc.kind, tc.pattern)
		assert.Equal(t, tc.ok, err == nil, "%s %q: %v", tc.kind, tc.pattern, err)
	}
}

func TestBuiltinLimits_ListsTheTable(t *testing.T) {
	got := BuiltinLimits()
	assert.Len(t, got, len(hardLimits))
	assert.Equal(t, LimitUnreadable, got[0])
	assert.NotContains(t, got, LimitOwner)
}
