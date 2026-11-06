package daemon

import (
	"bytes"
	"context"
	"go/parser"
	"go/token"
	"log"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations/builtin"
	"watchtower/internal/db"
)

// newApprovalTestDaemon is a daemon on a test database with a runnable
// needs-approval built-in row (Task 8 ships its recipe) and a fake executor.
func newApprovalTestDaemon(t *testing.T) (*Daemon, *db.DB, *fakeAutomationRunner, *bytes.Buffer, int64) {
	t.Helper()
	orch, cfg, _ := testDaemonWithTempHome(t)
	database := db.OpenTestDB(t)
	d := newDaemon(orch, cfg)
	var logs bytes.Buffer
	d.SetLogger(log.New(&logs, "", 0))
	d.SetDB(database)
	exec := &fakeAutomationRunner{}
	d.SetAutomations(&fakeAutomationRunner{}, exec)
	now := time.Now().UTC()
	id, err := database.UpsertBuiltinAutomation(db.Automation{
		BuiltinID: builtin.NeedsApprovalID, Slug: builtin.NeedsApprovalID, Name: "Needs approval",
		TriggerKind: "event", TriggerSpec: `{"type":"approval"}`, OutputsJSON: `["inbox"]`,
		RecipeText: "---\nname: Needs approval\n---\n", ContentHash: "c", ApprovalHash: "h",
	})
	require.NoError(t, err)
	require.NoError(t, database.ConfirmShippedBuiltin(id, "c", "h", now))
	require.NoError(t, database.SetBuiltinEnabled(builtin.NeedsApprovalID, true, now))
	return d, database, exec, &logs, id
}

func queuedRuns(t *testing.T, database *db.DB, id int64) int {
	t.Helper()
	runs, err := database.ListAutomationRuns(id, 0)
	require.NoError(t, err)
	n := 0
	for _, r := range runs {
		if r.Status == db.RunQueued {
			n++
		}
	}
	return n
}

func TestDaemon_ApprovalSweepAfterUnsnooze(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "daemon.go", nil, 0)
	require.NoError(t, err)
	order := topLevelCallOrder(daemonFunc(t, file, "runSync", true))
	sweep, ok := order["phaseApprovalSweep"]
	require.True(t, ok, "runSync must run phaseApprovalSweep")
	assert.Greater(t, sweep, order["phaseUnsnooze"])
}

func TestApprovalSweep_FiresAndWakesTheExecutor(t *testing.T) {
	d, database, exec, _, id := newApprovalTestDaemon(t)
	_, err := database.InsertReminder(db.Reminder{Note: "ping acme", RemindAt: "2000-01-01T00:00:00Z"})
	require.NoError(t, err)
	d.phaseApprovalSweep(context.Background())
	assert.Equal(t, 1, queuedRuns(t, database, id))
	assert.Equal(t, int32(1), exec.wakes.Load())
}

func TestApprovalSweep_ReadErrorLoggedCycleContinues(t *testing.T) {
	d, database, _, logs, id := newApprovalTestDaemon(t)
	_, err := database.Exec(`DROP TABLE reminders`)
	require.NoError(t, err)
	d.phaseApprovalSweep(context.Background()) // returns: the cycle goes on
	assert.Contains(t, logs.String(), "approval sweep: ")
	assert.Zero(t, queuedRuns(t, database, id))
}

// The daemon's hook: Fire with the in-process executor wake, replacing a
// hook a registry built during wiring set.
func TestDaemon_InstallApprovalHookWakesInProcess(t *testing.T) {
	d, database, exec, logs, id := newApprovalTestDaemon(t)
	database.SetApprovalHook(func(string) { t.Error("the wiring-time hook was kept") })
	d.installApprovalHook()
	_, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{}`})
	require.NoError(t, err)
	assert.Equal(t, 1, queuedRuns(t, database, id))
	assert.Equal(t, int32(1), exec.wakes.Load())
	assert.False(t, strings.Contains(logs.String(), "approval hook"), logs.String())
}

// Run installs the daemon's own approval hook, replacing the one a tool
// registry set while the daemon was wired.
func TestDaemon_RunInstallsInProcessApprovalHook(t *testing.T) {
	d, database, exec, _, id := newApprovalTestDaemon(t)
	wiring := false
	database.SetApprovalHook(func(string) { wiring = true })
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	require.NoError(t, d.Run(ctx))

	before := exec.wakes.Load()
	_, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{}`})
	require.NoError(t, err)
	assert.False(t, wiring, "Run replaced the wiring-time hook")
	assert.Equal(t, 1, queuedRuns(t, database, id))
	assert.Equal(t, before+1, exec.wakes.Load(), "the in-process executor was woken")
}
