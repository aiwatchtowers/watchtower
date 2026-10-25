package cmd

import (
	"strings"

	"watchtower/internal/auditlog"
	"watchtower/internal/automations"
)

// cliContentCommands are the command paths that print synced company content
// (#606 spec §4). Run by an agent — under WATCHTOWER_TERMINAL_SESSION_ID or
// WATCHTOWER_AUTOMATION_RUN_ID — each leaves one audit line; nothing caps
// them (the CLI is the owner's tool). Every key must resolve through rootCmd
// (TestCLIAudit_ListedPathsExist). `tools call` is not here: it reads through
// the registry, whose gate already budgets and logs each call.
var cliContentCommands = map[string]bool{
	"ask":              true,
	"briefing":         true,
	"briefing list":    true,
	"calendar events":  true,
	"catchup list":     true,
	"catchup show":     true,
	"day-plan show":    true,
	"decisions":        true,
	"digest":           true,
	"digest summary":   true,
	"ideas list":       true,
	"inbox":            true,
	"inbox show":       true,
	"jira blockers":    true,
	"jira project-map": true,
	"jira releases":    true,
	"jira workload":    true,
	"kb search":        true,
	"meeting-prep":     true,
	"memory index":     true,
	"memory open":      true,
	"memory recall":    true,
	"people":           true,
	"tracks":           true,
	"tracks events":    true,
	"tracks show":      true,
	"trends":           true,
}

// cliCommandPath is the command path below the root that args run ("" for
// the root or an unknown command), resolved the way cobra's Execute will.
func cliCommandPath(args []string) string {
	c, _, err := rootCmd.Find(args)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(c.CommandPath(), rootCmd.Name()))
}

// cliAuditEvent is the audit line of a content command run under an agent
// marker, or false: another command, or no marker (the owner at a shell).
// The terminal session wins over the automation run when both are set.
func cliAuditEvent(path string, getenv func(string) string, runErr error) (auditlog.Event, bool) {
	if !cliContentCommands[path] {
		return auditlog.Event{}, false
	}
	var session string
	if id := strings.TrimSpace(getenv(terminalSessionEnv)); id != "" {
		session = "terminal:" + id
	} else if id := strings.TrimSpace(getenv(automations.RunEnvMarker)); id != "" {
		session = "run:" + id
	} else {
		return auditlog.Event{}, false
	}
	result := auditlog.ResultOK
	if runErr != nil {
		result = auditlog.ResultError
	}
	return auditlog.Event{
		Proc: "cli:" + path, Surface: "cli", Session: session, Tool: path, Result: result,
	}, true
}
