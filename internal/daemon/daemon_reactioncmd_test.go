package daemon

import (
	"context"
	"go/ast"
	"go/parser"
	"go/token"
	"log"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/reactioncmd"
)

// reactionProbe builds a reaction-commands pipeline whose only observable is
// how many times the daemon let it poll: the seeded dictionary is non-empty,
// so Run reaches accountsFn, which counts and reports zero accounts (no Slack,
// no AI, no registry).
func reactionProbe(t *testing.T, d *Daemon, database *db.DB, cfg *config.Config) *int {
	t.Helper()
	polls := 0
	accountsFn := func(context.Context) ([]reactioncmd.Account, error) {
		polls++
		return nil, nil
	}
	d.SetReactionCommandsPipeline(reactioncmd.New(database, cfg, nil, nil, accountsFn, nil))
	return &polls
}

func newReactionTestDaemon(t *testing.T, cfg *config.Config) (*Daemon, *int) {
	t.Helper()
	orch, base, _ := testDaemonWithTempHome(t)
	cfg.ActiveWorkspace = base.ActiveWorkspace
	cfg.Workspaces = base.Workspaces
	cfg.Sync = base.Sync

	database := db.OpenTestDB(t)

	// One enabled Slack account, so the phase has something to poll; the
	// no-accounts test deletes it.
	_, err := database.Exec(`INSERT INTO slack_accounts (id, team_id, team_name, current_user_id) VALUES (1, 'T1', 'team', '1:UOWNER')`)
	require.NoError(t, err)

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[test-reaction] ", 0))
	d.SetDB(database)
	return d, reactionProbe(t, d, database, cfg)
}

// TestDaemon_PhaseReactionCommands_DefaultPollsEveryCycle pins the owner's
// 2026-09-26 call: a reaction is a command the owner is waiting on, and the
// poll itself is one cheap reactions.list call (the ledger makes re-polling
// free of AI), so the default is no throttle at all — every daemon cycle, and
// therefore every `Sync Now`, polls. interval_hours <= 0 means "no throttle",
// not "fall back to a compiled-in interval".
func TestDaemon_PhaseReactionCommands_DefaultPollsEveryCycle(t *testing.T) {
	cfg := &config.Config{ReactionCommands: config.ReactionCommandsConfig{
		Enabled:       true,
		IntervalHours: config.DefaultReactionCommandsIntervalHours,
	}}
	d, polls := newReactionTestDaemon(t, cfg)

	d.phaseReactionCommands(context.Background())
	d.phaseReactionCommands(context.Background())
	d.phaseReactionCommands(context.Background())

	assert.Equal(t, 3, *polls, "with the default interval every cycle polls")
}

// TestDaemon_PhaseReactionCommands_ExplicitIntervalStillThrottles is the
// control: an owner who set interval_hours > 0 keeps the throttle.
func TestDaemon_PhaseReactionCommands_ExplicitIntervalStillThrottles(t *testing.T) {
	cfg := &config.Config{ReactionCommands: config.ReactionCommandsConfig{Enabled: true, IntervalHours: 6}}
	d, polls := newReactionTestDaemon(t, cfg)

	d.phaseReactionCommands(context.Background())
	d.phaseReactionCommands(context.Background())
	d.phaseReactionCommands(context.Background())

	assert.Equal(t, 1, *polls, "an explicit interval throttles repeat cycles")
}

// TestDaemon_ReactionCommandsDefaultOn pins that a config with no
// reaction_commands block enables the feature (owner call 2026-09-26; the
// first-poll seed in internal/reactioncmd is what makes that safe).
func TestDaemon_ReactionCommandsDefaultOn(t *testing.T) {
	assert.True(t, config.DefaultReactionCommandsEnabled)
	assert.Equal(t, 0, config.DefaultReactionCommandsIntervalHours, "default = every cycle")
}

// TestDaemon_RunSync_PollsReactionsBeforeAIPipelines pins the phase order that
// gives `Sync Now` its latency: the reaction poll runs right after the source
// syncs, before the channel digests and everything AI-heavy that follows them
// — the pipeline reads the reacted message from reactions.list itself and its
// thread from the just-synced messages table, nothing from a later phase.
// Pinned statically (the repo's go/parser scan precedent) because runSync has
// no seam to observe phase order at run time.
func TestDaemon_RunSync_PollsReactionsBeforeAIPipelines(t *testing.T) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "daemon.go", nil, 0)
	require.NoError(t, err)

	var runSync *ast.FuncDecl
	for _, decl := range file.Decls {
		if fd, ok := decl.(*ast.FuncDecl); ok && fd.Name.Name == "runSync" {
			runSync = fd
		}
	}
	require.NotNil(t, runSync, "runSync not found in daemon.go")

	order := map[string]int{}
	for i, stmt := range runSync.Body.List {
		ast.Inspect(stmt, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
				if _, seen := order[sel.Sel.Name]; !seen {
					order[sel.Sel.Name] = i
				}
			}
			return true
		})
	}
	reactions, ok := order["phaseReactionCommands"]
	require.True(t, ok, "runSync must call phaseReactionCommands")
	calendarSync, ok := order["phaseCalendarSync"]
	require.True(t, ok, "runSync must call phaseCalendarSync")
	slackSync, ok := order["phaseSlackSync"]
	require.True(t, ok, "runSync must call phaseSlackSync")

	assert.Greater(t, reactions, slackSync, "the poll needs the Slack sync's messages for thread context")
	assert.Less(t, reactions, calendarSync, "the poll must not wait behind the other source syncs either — Jira alone can take minutes")
}

// TestDaemon_PhaseReactionCommands_NoSlackAccountsWritesNoRun pins the
// Slack-less install (Google/Jira-only, now default-on): with no enabled Slack
// account there is nothing to poll, and the phase must not record a 0-item
// `reaction-commands` pipeline_runs row every cycle — the phaseSlackSync
// zero-orchestrators precedent.
func TestDaemon_PhaseReactionCommands_NoSlackAccountsWritesNoRun(t *testing.T) {
	cfg := &config.Config{ReactionCommands: config.ReactionCommandsConfig{Enabled: true}}
	d, polls := newReactionTestDaemon(t, cfg)
	_, err := d.db.Exec(`DELETE FROM slack_accounts`)
	require.NoError(t, err)

	d.phaseReactionCommands(context.Background())

	assert.Equal(t, 0, *polls, "no account, no poll")
	var runs int
	require.NoError(t, d.db.QueryRow(`SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'reaction-commands'`).Scan(&runs))
	assert.Equal(t, 0, runs, "no pipeline_runs row for a no-op cycle")
}
