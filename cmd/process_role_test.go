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

func TestSurfaceFor(t *testing.T) {
	for _, tc := range []struct {
		role string
		args []string
		want string
	}{
		{"cli:ai session", []string{"ai", "session"}, "chat"},
		{"cli:ai query", []string{"ai", "query", "hi"}, "chat"},
		{"cli:ai models", []string{"ai", "models"}, "watchtower"},
		{"mcp", []string{"mcp", "--workbench", "3"}, "workbench"},
		{"mcp", []string{"mcp", "--workbench=3"}, "workbench"},
		{"mcp", []string{"mcp", "--chat", "--surface", "automation", "--automation-run", "7"}, "watchtower"},
		{"mcp", []string{"mcp", "--chat", "--surface=automation"}, "watchtower"},
		{"mcp", []string{"mcp", "--chat", "--surface", "main"}, "chat"},
		{"mcp", []string{"mcp", "--chat"}, "chat"},
		{"mcp", []string{"mcp", "--chat=false"}, "watchtower"},
		{"mcp", []string{"mcp"}, "watchtower"},
		{"cli:workbench review overview", nil, "workbench"},
		{"cli:workbench", nil, "workbench"},
		{"cli:terminal open", nil, "workbench"},
		{"hook:ask-guard", nil, "workbench"},
		{"hook:session-state", nil, "workbench"},
		{"daemon", []string{"sync", "--daemon"}, "watchtower"},
		{"cli:briefing generate", nil, "watchtower"},
		{"cli", nil, "watchtower"},
	} {
		if got := surfaceFor(tc.role, tc.args); got != tc.want {
			t.Errorf("surfaceFor(%q, %q) = %q, want %q", tc.role, tc.args, got, tc.want)
		}
	}
}
