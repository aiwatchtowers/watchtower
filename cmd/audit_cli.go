package cmd

import (
	"strings"
	"sync"
	"sync/atomic"

	"github.com/spf13/cobra"

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
	"ask":                              true,
	"briefing":                         true,
	"briefing list":                    true,
	"calendar events":                  true,
	"catchup list":                     true,
	"catchup show":                     true,
	"day-plan show":                    true,
	"decisions":                        true,
	"digest":                           true,
	"digest summary":                   true,
	"ideas list":                       true,
	"inbox":                            true,
	"inbox show":                       true,
	"jira blockers":                    true,
	"jira project-map":                 true,
	"jira releases":                    true,
	"jira workload":                    true,
	"kb search":                        true,
	"meeting-prep":                     true,
	"memory index":                     true,
	"memory open":                      true,
	"memory recall":                    true,
	"meeting-prep transcript chapters": true,
	"meeting-prep transcript followup": true,
	"meeting-prep transcript list":     true,
	"meeting-prep transcript notes":    true,
	"meeting-prep transcript recap":    true,
	"meeting-prep transcript show":     true,
	"people":                           true,
	"tracks":                           true,
	"tracks events":                    true,
	"tracks show":                      true,
	"trends":                           true,
}

// contentRan is the path of the content command whose Run started in this
// process ("" when none did): a --help, a usage error or an unknown command
// never runs one, so it writes no line.
var contentRan atomic.Pointer[string]

// wrapContentCommands makes every listed command record contentRan when its
// Run starts. Idempotent: a command is wrapped once.
func wrapContentCommands() {
	wrapMu.Lock()
	defer wrapMu.Unlock()
	for path := range cliContentCommands {
		c, rest, err := rootCmd.Find(strings.Fields(path))
		if err != nil || len(rest) > 0 || wrapped[c] {
			continue
		}
		wrapped[c] = true
		mark := func() { contentRan.Store(&path) }
		switch {
		case c.RunE != nil:
			run := c.RunE
			c.RunE = func(cmd *cobra.Command, args []string) error { mark(); return run(cmd, args) }
		case c.Run != nil:
			run := c.Run
			c.Run = func(cmd *cobra.Command, args []string) { mark(); run(cmd, args) }
		}
	}
}

var (
	wrapMu  sync.Mutex
	wrapped = map[*cobra.Command]bool{}
)

// auditPath is a command path as the audit line names it: its words joined
// by "/" (a space would not survive the line's sanitising).
func auditPath(path string) string { return strings.Join(strings.Fields(path), "/") }

// cliAuditEvent is the audit line of a content command that ran under an
// agent marker, or false: another command, or no marker (the owner at a
// shell). The terminal session wins over the automation run when both are
// set.
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
		Proc: "cli:" + auditPath(path), Surface: "cli", Session: session, Tool: auditPath(path), Result: result,
	}, true
}

// auditCLIRun writes the line of the content command that ran, if any.
func auditCLIRun(getenv func(string) string, runErr error) {
	p := contentRan.Swap(nil)
	if p == nil {
		return
	}
	if e, ok := cliAuditEvent(*p, getenv, runErr); ok {
		auditlog.Read(e)
	}
}
