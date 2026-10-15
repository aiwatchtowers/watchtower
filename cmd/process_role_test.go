package cmd

import "testing"

func TestProcessRole(t *testing.T) {
	for _, tc := range []struct {
		path string
		args []string
		want string
	}{
		{"sync", []string{"sync", "--daemon"}, "daemon"},
		{"sync", []string{"sync", "--daemon", "--detach"}, "daemon"},
		{"sync", []string{"sync", "--daemon=true"}, "daemon"},
		{"sync", []string{"sync", "--daemon=false"}, "cli:sync"},
		{"sync", []string{"sync", "--now"}, "cli:sync"},
		{"sync", []string{"sync", "--", "--daemon"}, "cli:sync"},
		{"mcp", []string{"mcp", "--workbench", "3"}, "mcp"},
		{"workbench session-state", nil, "hook:session-state"},
		{"workbench ask-guard", nil, "hook:ask-guard"},
		{"workbench brief", nil, "hook:brief"},
		{"workbench check", nil, "hook:check"},
		{"workbench cleanup", nil, "cli:workbench cleanup"},
		{"sync stop", []string{"sync", "stop", "--daemon"}, "cli:sync stop"},
		{"", nil, "cli"},
	} {
		if got := processRole(tc.path, tc.args); got != tc.want {
			t.Errorf("processRole(%q, %q) = %q, want %q", tc.path, tc.args, got, tc.want)
		}
	}
}

// roleFor resolves the command the way cobra will run it, root flags and
// all — including the hook subcommands whose no-op PersistentPreRunE
// replaces the root's.
func TestRoleForResolvesTheCommandCobraRuns(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"workbench", "session-state", "--workbench", "3"}, "hook:session-state"},
		{[]string{"workbench", "ask-guard", "--agent", "codex", "--stop"}, "hook:ask-guard"},
		{[]string{"--workspace", "acme", "sync", "--daemon", "--detach"}, "daemon"},
		{[]string{"--config", "/x/config.yaml", "mcp"}, "mcp"},
		{[]string{"workbench", "cleanup", "--apply"}, "cli:workbench cleanup"},
		{[]string{}, "cli"},
		{[]string{"no-such-command"}, "cli"},
	} {
		if got := roleFor(tc.args); got != tc.want {
			t.Errorf("roleFor(%q) = %q, want %q", tc.args, got, tc.want)
		}
	}
}
