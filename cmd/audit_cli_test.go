package cmd

import (
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/auditlog"
	"watchtower/internal/automations"
)

func auditEnv(vals map[string]string) func(string) string {
	return func(k string) string { return vals[k] }
}

func TestCLIAudit_OnlyUnderMarker(t *testing.T) {
	_, ok := cliAuditEvent("kb search", auditEnv(nil), nil)
	assert.False(t, ok, "the owner's own CLI writes no line")

	e, ok := cliAuditEvent("kb search", auditEnv(map[string]string{terminalSessionEnv: "42"}), nil)
	require.True(t, ok)
	assert.Equal(t, "terminal:42", e.Session)
	assert.Equal(t, "cli", e.Surface)
	line := auditlog.Line(e)
	assert.Contains(t, line, `"proc":"cli:kb/search"`, "the path survives the line's sanitising")
	assert.Contains(t, line, `"tool":"kb/search"`)
	assert.Equal(t, "ok", e.Result)
	assert.Zero(t, e.Rows)
	assert.Zero(t, e.Bytes)
	assert.Empty(t, e.Filters)

	e, ok = cliAuditEvent("digest", auditEnv(map[string]string{automations.RunEnvMarker: "9"}), nil)
	require.True(t, ok)
	assert.Equal(t, "run:9", e.Session)
}

func TestCLIAudit_OnlyContentCommands(t *testing.T) {
	env := auditEnv(map[string]string{terminalSessionEnv: "42"})
	for _, path := range []string{"config set", "gmail status", "workbench board", ""} {
		_, ok := cliAuditEvent(path, env, nil)
		assert.False(t, ok, path)
	}
}

func TestCLIAudit_ErrorResult(t *testing.T) {
	e, ok := cliAuditEvent("memory recall", auditEnv(map[string]string{terminalSessionEnv: "42"}), errors.New("boom"))
	require.True(t, ok)
	assert.Equal(t, "error", e.Result)
}

func TestCLIAudit_ListedPathsExist(t *testing.T) {
	for path := range cliContentCommands {
		args := strings.Fields(path)
		c, rest, err := rootCmd.Find(args)
		require.NoError(t, err, path)
		assert.Empty(t, rest, path)
		assert.Equal(t, path, strings.TrimSpace(strings.TrimPrefix(c.CommandPath(), rootCmd.Name())), path)
	}
}

// cliExcludedCommands are commands that print something but deliberately
// write no CLI audit line, each with the reason.
var cliExcludedCommands = map[string]string{
	"meeting-prep recap":           "recaps notes the caller passes in, not synced content",
	"meeting-prep transcript save": "saves the caller's own transcript text",
	"linear status":                "workspace and team names and sync state only",
	"linear teams":                 "team names only",
	"confluence spaces":            "space names only",
	"confluence status":            "sync state only",
	"slack accounts":               "workspace names only",
	"code search":                  "the workbench folder's own files, not synced company data",
	"ai query":                     "its tool reads pass the registry gate in its MCP child",
	"workbench session-feed":       "the owner's own agent session dialog",
	"targets note list":            "the owner's own notes",
	"tools call":                   "reads through the registry gate, which budgets and logs each call",
}

func TestCLIAudit_ExcludedCommandsAreDecided(t *testing.T) {
	for path, reason := range cliExcludedCommands {
		assert.NotEmpty(t, reason, path)
		assert.False(t, cliContentCommands[path], "%s is both listed and excluded", path)
		c, rest, err := rootCmd.Find(strings.Fields(path))
		require.NoError(t, err, path)
		assert.Empty(t, rest, path)
		assert.Equal(t, path, strings.TrimSpace(strings.TrimPrefix(c.CommandPath(), rootCmd.Name())), path)
	}
}

// Through the real Execute: only a content command whose Run started writes
// a line — not --help, a usage error or an unknown command.
func TestCLIAudit_ExecuteWritesOnlyWhenTheCommandRan(t *testing.T) {
	probe := &cobra.Command{Use: "zz-audit-probe <q>", Hidden: true, Args: cobra.ExactArgs(1),
		RunE: func(*cobra.Command, []string) error { return nil }}
	rootCmd.AddCommand(probe)
	cliContentCommands["zz-audit-probe"] = true
	t.Cleanup(func() {
		rootCmd.RemoveCommand(probe)
		delete(cliContentCommands, "zz-audit-probe")
		rootCmd.SetArgs(nil)
	})
	var lines []string
	t.Cleanup(auditlog.SetSinkForTest(func(s string) { lines = append(lines, s) }))
	t.Setenv(terminalSessionEnv, "42")
	oldArgs := os.Args
	t.Cleanup(func() { os.Args = oldArgs })

	run := func(args ...string) {
		os.Args = append([]string{"watchtower"}, args...)
		rootCmd.SetArgs(args)
		Execute()
	}
	run("zz-audit-probe")              // usage error: no argument
	run("zz-audit-probe-unknown", "x") // unknown command
	run("zz-audit-probe", "q")
	require.Len(t, lines, 1, "only the run that started writes a line: %v", lines)
	assert.Contains(t, lines[0], `"proc":"cli:zz-audit-probe"`)
	assert.Contains(t, lines[0], `"session":"terminal:42"`)
	assert.Contains(t, lines[0], `"result":"ok"`)

	run("zz-audit-probe", "--help")
	require.NoError(t, probe.Flags().Set("help", "false"))
	assert.Len(t, lines, 1, "--help runs nothing")
}

// cliNoContentCommands are the runnable commands that print no synced company
// content: account and sync management, settings, the owner's own board,
// targets, automations and sessions, pipelines that print counts. With
// cliContentCommands and cliExcludedCommands they cover every runnable
// command (TestCLIAudit_EveryCommandIsDecided), so a new command that prints
// must be decided.
var cliNoContentCommands = map[string]bool{
	"":                                 true,
	"accounts purges":                  true,
	"actions apply":                    true,
	"actions approve":                  true,
	"actions dismiss":                  true,
	"actions list":                     true,
	"actions propose":                  true,
	"actions reject":                   true,
	"actions show":                     true,
	"actions tools":                    true,
	"actions trust":                    true,
	"agents disable":                   true,
	"agents enable":                    true,
	"agents report":                    true,
	"agents scan":                      true,
	"agents stats":                     true,
	"ai models":                        true,
	"ai session":                       true,
	"ai test":                          true,
	"auth check-cert":                  true,
	"auth login":                       true,
	"auth logout":                      true,
	"auth trust-cert":                  true,
	"automations auto":                 true,
	"automations cancel":               true,
	"automations confirm":              true,
	"automations delete":               true,
	"automations disable":              true,
	"automations dry-run":              true,
	"automations enable":               true,
	"automations install-template":     true,
	"automations list":                 true,
	"automations reply":                true,
	"automations rescan":               true,
	"automations reset":                true,
	"automations run":                  true,
	"automations runs":                 true,
	"automations save":                 true,
	"automations session-ended":        true,
	"automations session-launched":     true,
	"automations show":                 true,
	"automations templates":            true,
	"automations upgrade-builtins":     true,
	"automations validate":             true,
	"automations wake":                 true,
	"backfill status":                  true,
	"caldav add":                       true,
	"caldav add-ics":                   true,
	"caldav list":                      true,
	"caldav remove":                    true,
	"caldav rename":                    true,
	"calendar list":                    true,
	"calendar login":                   true,
	"calendar logout":                  true,
	"calendar select":                  true,
	"calendar status":                  true,
	"calendar sync":                    true,
	"catchup ack":                      true,
	"catchup feedback":                 true,
	"channels":                         true,
	"chat title":                       true,
	"code index":                       true,
	"coach accept":                     true,
	"coach decline":                    true,
	"coach proposals":                  true,
	"coach rollback":                   true,
	"coach run":                        true,
	"coach status":                     true,
	"config init":                      true,
	"config set":                       true,
	"config show":                      true,
	"confluence access":                true,
	"confluence select":                true,
	"confluence sync":                  true,
	"confluence unselect":              true,
	"connections add":                  true,
	"connections disable":              true,
	"connections enable":               true,
	"connections import":               true,
	"connections list":                 true,
	"connections oauth":                true,
	"connections remove":               true,
	"connections tools":                true,
	"day-plan check-conflicts":         true,
	"day-plan reset":                   true,
	"db compact":                       true,
	"db lockstats":                     true,
	"db migrate":                       true,
	"dictate clean":                    true,
	"digest generate":                  true,
	"digest reset-context":             true,
	"digest stats":                     true,
	"extract-pdf-text":                 true,
	"features disable":                 true,
	"features enable":                  true,
	"features list":                    true,
	"feedback":                         true,
	"feedback stats":                   true,
	"gmail login":                      true,
	"gmail logout":                     true,
	"gmail purge":                      true,
	"gmail status":                     true,
	"guide learn":                      true,
	"gmail sync":                       true,
	"google accounts":                  true,
	"google add":                       true,
	"google login":                     true,
	"google remove":                    true,
	"google rename":                    true,
	"ideas mine":                       true,
	"imap add":                         true,
	"imap list":                        true,
	"imap remove":                      true,
	"imap rename":                      true,
	"inbox backfill-mentions":          true,
	"inbox dismiss":                    true,
	"inbox generate":                   true,
	"inbox resolve":                    true,
	"inbox snooze":                     true,
	"inbox task":                       true,
	"instructions forget":              true,
	"instructions preview":             true,
	"instructions remember":            true,
	"instructions set":                 true,
	"instructions show":                true,
	"instructions suggestion add":      true,
	"instructions suggestion dismiss":  true,
	"integrate claude-code":            true,
	"integrate codex":                  true,
	"integrate remove":                 true,
	"integrate status":                 true,
	"jira":                             true,
	"jira accounts":                    true,
	"jira add":                         true,
	"jira boards":                      true,
	"jira boards analyze":              true,
	"jira boards deselect":             true,
	"jira boards override":             true,
	"jira boards select":               true,
	"jira create":                      true,
	"jira disable":                     true,
	"jira enable":                      true,
	"jira features":                    true,
	"jira features disable":            true,
	"jira features enable":             true,
	"jira features reset":              true,
	"jira fields":                      true,
	"jira fields discover":             true,
	"jira fields map":                  true,
	"jira login":                       true,
	"jira logout":                      true,
	"jira remove":                      true,
	"jira rename":                      true,
	"jira status":                      true,
	"jira sync":                        true,
	"jira users map":                   true,
	"jira users resolve":               true,
	"kb reindex":                       true,
	"kb status":                        true,
	"linear":                           true,
	"linear accounts":                  true,
	"linear add":                       true,
	"linear disable":                   true,
	"linear enable":                    true,
	"linear login":                     true,
	"linear remove":                    true,
	"linear sync":                      true,
	"linear teams deselect":            true,
	"linear teams select":              true,
	"logs":                             true,
	"mcp":                              true,
	"meeting-prep extract-topics":      true,
	"memory consolidate":               true,
	"memory migrate-slack-ids":         true,
	"memory reindex":                   true,
	"memory reset-to":                  true,
	"memory seed":                      true,
	"memory status":                    true,
	"outlook login":                    true,
	"outlook logout":                   true,
	"outlook rename":                   true,
	"people generate":                  true,
	"policy show":                      true, // the organization policy: settings, no company content
	"profile":                          true,
	"project":                          true,
	"prompts history":                  true,
	"prompts list":                     true,
	"prompts reset":                    true,
	"prompts rollback":                 true,
	"prompts show":                     true,
	"reaction-commands list":           true,
	"reaction-commands poll":           true,
	"remind":                           true,
	"session-host":                     true,
	"slack add":                        true,
	"slack disable":                    true,
	"slack enable":                     true,
	"slack login":                      true,
	"slack remove":                     true,
	"slack rename":                     true,
	"status":                           true,
	"sync":                             true,
	"sync stop":                        true,
	"targets":                          true,
	"targets ai-update":                true,
	"targets create":                   true,
	"targets delete":                   true,
	"targets dismiss":                  true,
	"targets done":                     true,
	"targets extract":                  true,
	"targets generate":                 true,
	"targets link":                     true,
	"targets next-step":                true,
	"targets note add":                 true,
	"targets promote-subitem":          true,
	"targets show":                     true,
	"targets snooze":                   true,
	"targets suggest-links":            true,
	"targets unlink":                   true,
	"targets update":                   true,
	"tasks":                            true,
	"terminal title":                   true,
	"tools describe":                   true,
	"tools list":                       true,
	"tracks create":                    true,
	"tracks disable":                   true,
	"tracks dismiss":                   true,
	"tracks enable":                    true,
	"tracks generate":                  true,
	"tracks instruction":               true,
	"tracks read":                      true,
	"tracks restore":                   true,
	"tracks scan":                      true,
	"tracks start":                     true,
	"tracks watch":                     true,
	"tune":                             true,
	"usage llm":                        true,
	"usage plan":                       true,
	"version":                          true,
	"watch add":                        true,
	"watch list":                       true,
	"watch remove":                     true,
	"workbench ask-guard":              true,
	"workbench asks":                   true,
	"workbench board":                  true,
	"workbench brief":                  true,
	"workbench check":                  true,
	"workbench cleanup":                true,
	"workbench columns":                true,
	"workbench create":                 true,
	"workbench delete":                 true,
	"workbench escalate-question":      true,
	"workbench git branches":           true,
	"workbench git checkout":           true,
	"workbench git create":             true,
	"workbench git fetch":              true,
	"workbench git status":             true,
	"workbench git switch":             true,
	"workbench launch-args":            true,
	"workbench list":                   true,
	"workbench methodology":            true,
	"workbench permission-wait":        true,
	"workbench resync":                 true,
	"workbench review approve":         true,
	"workbench review context":         true,
	"workbench review diff":            true,
	"workbench review file":            true,
	"workbench review lessons accept":  true,
	"workbench review lessons dismiss": true,
	"workbench review lessons propose": true,
	"workbench review overview":        true,
	"workbench review revert-hunk":     true,
	"workbench review send":            true,
	"workbench review start":           true,
	"workbench session-probe":          true,
	"workbench session-report":         true,
	"workbench session-state":          true,
	"workbench spec-review run":        true, // detached reviewer child: prints nothing, writes only the DB
	"workbench spec-review reveal":     true, // hidden, called by the Desktop: prints nothing, writes only the loop row
	"workbench spec-review start":      true, // prints a status line only
	"workbench show":                   true,
	"workbench target add":             true,
	"workbench worktree create":        true,
	"workbench worktree ensure":        true,
	"workbench worktree forget":        true,
	"workspace init":                   true,
}

func TestCLIAudit_EveryCommandIsDecided(t *testing.T) {
	var walk func(c *cobra.Command)
	walk = func(c *cobra.Command) {
		if c.Runnable() {
			path := strings.TrimSpace(strings.TrimPrefix(c.CommandPath(), rootCmd.Name()))
			n := 0
			for _, listed := range []bool{cliContentCommands[path], cliExcludedCommands[path] != "", cliNoContentCommands[path]} {
				if listed {
					n++
				}
			}
			// cobra's own help and completion commands (added at Execute) and
			// the probe of TestCLIAudit_ExecuteWritesOnlyWhenTheCommandRan.
			builtin := path == "help" || strings.HasPrefix(path, "completion") || path == "zz-audit-probe"
			if !builtin && n != 1 {
				t.Errorf("%q is in %d of cliContentCommands, cliExcludedCommands and cliNoContentCommands; decide it in exactly one", path, n)
			}
		}
		for _, s := range c.Commands() {
			walk(s)
		}
	}
	walk(rootCmd)
}
