package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"log"
	"os"
	"path/filepath"
	"strings"
	gosync "sync"
	"testing"
	"time"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/builtin"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/reactioncmd"
	"watchtower/internal/tools"
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

// A poll cut off by a cancelled context (shutdown, or a sleep interrupting the
// cycle) does not stamp the throttle: the next cycle polls again.
func TestDaemon_PhaseReactionCommands_CancelledPollDoesNotStampTheThrottle(t *testing.T) {
	cfg := &config.Config{ReactionCommands: config.ReactionCommandsConfig{Enabled: true, IntervalHours: 6}}
	d, _ := newReactionTestDaemon(t, cfg)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	d.phaseReactionCommands(ctx)
	assert.True(t, d.lastReactionCmd.IsZero(), "a cancelled poll must not stamp the throttle")

	d.phaseReactionCommands(context.Background())
	assert.False(t, d.lastReactionCmd.IsZero())
}

// A poll cut off by the loop's cancel records its reaction-commands row
// without an error: cancelled, not failed (the slack-sync row's rule).
func TestDaemon_PhaseReactionCommands_CancelledPollIsNoErrorRow(t *testing.T) {
	cfg := &config.Config{ReactionCommands: config.ReactionCommandsConfig{Enabled: true}}
	d, _ := newReactionTestDaemon(t, cfg)
	ctx, cancel := context.WithCancelCause(context.Background())
	accountsFn := func(context.Context) ([]reactioncmd.Account, error) {
		cancel(errCycleSlept)
		return nil, ctx.Err()
	}
	d.SetReactionCommandsPipeline(reactioncmd.New(d.db, cfg, nil, nil, accountsFn, nil))

	d.phaseReactionCommands(ctx)

	var status, errMsg string
	require.NoError(t, d.db.QueryRow(`SELECT status, COALESCE(error_msg, '') FROM pipeline_runs
		WHERE pipeline = 'reaction-commands'`).Scan(&status, &errMsg))
	assert.Empty(t, errMsg, "a cancelled poll is no failure")
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

// reactionsGen answers every compose call with out (or err), counting calls.
type reactionsGen struct {
	mu     gosync.Mutex
	out    string
	err    error
	calls  int
	onCall func()
}

func (g *reactionsGen) Generate(ctx context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.calls++
	if g.onCall != nil {
		g.onCall()
	}
	if err := ctx.Err(); err != nil {
		return "", nil, "", err // a real provider call fails on a cancelled context
	}
	if g.err != nil {
		return "", nil, "", g.err
	}
	return g.out, &digest.Usage{}, "", nil
}

// onCall, when set, runs inside each compose call (before the reply).
func (g *reactionsGen) hook(fn func()) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.onCall = fn
}

func (g *reactionsGen) set(out string, err error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.out, g.err = out, err
}

// reactionsLister is the owner's reactions.list, swappable between polls.
type reactionsLister struct {
	mu    gosync.Mutex
	items []slack.ReactedItem
}

func (l *reactionsLister) ListUserReactions(context.Context, string) ([]slack.ReactedItem, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.items, nil
}

func (l *reactionsLister) set(items ...slack.ReactedItem) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.items = items
}

// ownerReaction is the owner's emoji reaction on message ts in channel C1.
func ownerReaction(ts, emoji string) slack.ReactedItem {
	m := &slack.Message{}
	m.Timestamp, m.User, m.Text = ts, "UAUTHOR", "please handle the deploy"
	return slack.ReactedItem{
		Item:      slack.Item{Type: "message", Channel: "C1", Message: m},
		Reactions: []slack.ItemReaction{{Name: emoji, Users: []string{"UOWNER"}}},
	}
}

// reactionsFixture is a daemon over a real database with one seeded Slack
// account (owner UOWNER), a reaction-commands pipeline over gen and lister
// with create_target, create_idea and a fake external create_jira_issue,
// and the built-ins wired with the Reactions built-in active.
type reactionsFixture struct {
	d      *Daemon
	db     *db.DB
	cfg    *config.Config
	gen    *reactionsGen
	lister *reactionsLister
}

func newReactionsFixture(t *testing.T) *reactionsFixture {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	cfg, err := config.Load(filepath.Join(t.TempDir(), "absent.yaml"))
	require.NoError(t, err)
	cfg.ActiveWorkspace = "test-ws"
	cfg.ReactionCommands.Enabled = true
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o755))

	database := db.OpenTestDB(t)
	_, err = database.Exec(`INSERT INTO slack_accounts (id, team_id, team_name, current_user_id) VALUES (1, 'T1', 'team', '1:UOWNER')`)
	require.NoError(t, err)
	require.NoError(t, database.MarkReactionCommandsSeeded(1))
	_, err = database.Exec(`INSERT INTO reaction_command_map (emoji, kind, tool) VALUES ('bulb', 'builtin_tool', 'create_idea')
		ON CONFLICT(emoji) DO UPDATE SET tool = 'create_idea', enabled = 1`)
	require.NoError(t, err)

	reg := tools.New(database)
	require.NoError(t, reg.Register(tools.NewCreateTarget()))
	require.NoError(t, reg.Register(tools.NewCreateIdea()))
	schema, err := jsonschema.For[struct {
		Summary string `json:"summary"`
		Reason  string `json:"reason"`
	}](nil)
	require.NoError(t, err)
	require.NoError(t, reg.Register(&tools.Tool{
		Name: "create_jira_issue", Description: "fake external jira tool", InputSchema: schema,
		Access: tools.AccessWrite, External: true,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute:  func(context.Context, *db.DB, tools.Call) (any, error) { return "ok", nil },
	}))

	gen := &reactionsGen{out: `{"text":"Handle the deploy","reason":"owner flagged it"}`}
	lister := &reactionsLister{}
	accountsFn := func(context.Context) ([]reactioncmd.Account, error) {
		return []reactioncmd.Account{{AccountID: 1, OwnerID: "1:UOWNER", Lister: lister}}, nil
	}
	l := log.New(os.Stderr, "[test-reactions] ", 0)
	d := newDaemon(nil, cfg)
	d.SetLogger(l)
	d.SetDB(database)
	d.SetReactionCommandsPipeline(reactioncmd.New(database, cfg, gen, reg, accountsFn, l))
	wireTestBuiltins(t, d, database, cfg, automations.RealClock{})
	d.builtinActive[reactionsID] = true
	return &reactionsFixture{d: d, db: database, cfg: cfg, gen: gen, lister: lister}
}

// assertSlotFree checks every Reactions run was Ended: each run id can be
// Begun again (ErrReactionRunBusy otherwise), and holds no outcome.
func (f *reactionsFixture) assertSlotFree(t *testing.T) {
	t.Helper()
	for _, r := range f.runs(t) {
		require.NoError(t, f.d.reactionSlot.Begin(r.ID, reactioncmd.Dispatch{}), "run %d still holds its command", r.ID)
		_, ok := f.d.reactionSlot.End(r.ID)
		assert.False(t, ok)
	}
}

func (f *reactionsFixture) poll() { f.d.phaseReactionCommands(context.Background()) }

func (f *reactionsFixture) runs(t *testing.T) []db.AutomationRun {
	t.Helper()
	a, err := f.db.GetBuiltinAutomation(reactionsID)
	require.NoError(t, err)
	runs, err := f.db.ListAutomationRuns(a.ID, 0)
	require.NoError(t, err)
	return runs
}

func (f *reactionsFixture) ledger(t *testing.T) []string {
	t.Helper()
	rows, err := f.db.Query(`SELECT status FROM reaction_commands ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		require.NoError(t, rows.Scan(&s))
		out = append(out, s)
	}
	require.NoError(t, rows.Err())
	return out
}

// writeReactionsCopy writes recipe as the Reactions owner copy and syncs
// the row (an edited copy waits for the owner's confirmation).
func (f *reactionsFixture) writeReactionsCopy(t *testing.T, recipe []byte) *db.Automation {
	t.Helper()
	path := builtin.OwnerCopyPath(f.cfg.WorkspaceDir(), reactionsID)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
	require.NoError(t, os.WriteFile(path, recipe, 0o600))
	a, err := builtin.SyncOne(context.Background(), f.db, f.cfg.WorkspaceDir(), f.cfg, reactionsID, time.Now())
	require.NoError(t, err)
	return a
}

// editedReactionsCopy is the shipped recipe with a changed compose prompt.
func editedReactionsCopy(t *testing.T) []byte {
	t.Helper()
	e, ok := builtin.Lookup(reactionsID)
	require.True(t, ok)
	prompt, err := e.DefaultPrompt("compose", "")
	require.NoError(t, err)
	data, err := builtin.RenderOwnerCopy(e, map[string]string{"compose": prompt + "\nKeep it short."})
	require.NoError(t, err)
	return data
}

func TestReactionsBuiltin_DispatchesThroughRecipe(t *testing.T) {
	f := newReactionsFixture(t)
	f.lister.set(ownerReaction("111.1", "white_check_mark"), ownerReaction("222.2", "white_check_mark"))
	f.poll()

	runs := f.runs(t)
	require.Len(t, runs, 2, "one automation run per claimed reaction")
	for _, r := range runs {
		assert.Equal(t, db.TriggerSync, r.Trigger)
		assert.Equal(t, db.RunSucceeded, r.Status, r.Error)
	}
	assert.Equal(t, []string{"dispatched", "dispatched"}, f.ledger(t))
	var tool, ctxType, ctxID string
	require.NoError(t, f.db.QueryRow(`SELECT a.tool, a.context_type, a.context_id FROM reaction_commands r
		JOIN agent_actions a ON a.id = r.action_id WHERE r.message_ts = '111.1'`).Scan(&tool, &ctxType, &ctxID))
	assert.Equal(t, "create_target", tool)
	assert.Equal(t, "reaction", ctxType)
	assert.Equal(t, "1:C1@111.1", ctxID, "REACT-02: the reacted message's real ref")
	assert.Equal(t, 2, countRows(t, f.db, `SELECT COUNT(*) FROM agent_actions WHERE surface = 'reaction'`))

	f.poll()
	assert.Len(t, f.runs(t), 2, "a re-poll runs nothing (REACT-03)")
	assert.Equal(t, 2, f.gen.calls)
	f.assertSlotFree(t)
}

func TestReactionsBuiltin_InstantToolsStayInstant(t *testing.T) {
	f := newReactionsFixture(t)
	f.gen.set(`{"essence":"cache the builds","reason":"owner flagged it"}`, nil)
	f.lister.set(ownerReaction("111.1", "bulb"))
	f.poll()

	assert.Equal(t, []string{"dispatched"}, f.ledger(t))
	assert.Len(t, f.runs(t), 1, "composed by the recipe")
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM agent_actions WHERE tool = 'create_idea' AND surface = 'reaction' AND status = 'applied'`),
		"create_idea applies at once on the reaction surface")
}

func TestReactionsBuiltin_ExternalStaysPending(t *testing.T) {
	f := newReactionsFixture(t)
	// Even trusted to execute, an External tool lands pending (AGENT-03).
	_, err := f.db.Exec(`INSERT OR REPLACE INTO tool_trust (tool, surface, trust) VALUES ('create_jira_issue', 'reaction', 'execute')`)
	require.NoError(t, err)
	f.gen.set(`{"summary":"Ship the fix","reason":"owner flagged it"}`, nil)
	f.lister.set(ownerReaction("222.2", "ticket"))
	f.poll()

	assert.Equal(t, []string{"dispatched"}, f.ledger(t))
	assert.Len(t, f.runs(t), 1, "composed by the recipe")
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM agent_actions WHERE tool = 'create_jira_issue' AND status = 'pending'`), "REACT-04")
	assert.Zero(t, countRows(t, f.db, `SELECT COUNT(*) FROM agent_actions WHERE status = 'applied'`))
}

func TestReactionsBuiltin_UnconfirmedCopyClaimsNothing(t *testing.T) {
	f := newReactionsFixture(t)
	a := f.writeReactionsCopy(t, editedReactionsCopy(t))
	require.False(t, a.Confirmed())
	f.lister.set(ownerReaction("111.1", "white_check_mark"), ownerReaction("222.2", "white_check_mark"))

	f.poll()
	f.poll()
	assert.Empty(t, f.ledger(t), "no ledger row while the copy waits")
	assert.Empty(t, f.runs(t))
	assert.Zero(t, f.gen.calls)

	require.NoError(t, f.db.ConfirmAutomation(a.ID, a.ApprovalHash, time.Now()))
	f.poll()
	assert.Equal(t, []string{"dispatched", "dispatched"}, f.ledger(t), "each reaction once after confirmation")
	f.poll()
	assert.Len(t, f.runs(t), 2)
	assert.Equal(t, 2, f.gen.calls)
}

func TestReactionsBuiltin_ScriptWithoutComposeFinalizesFailed(t *testing.T) {
	f := newReactionsFixture(t)
	shipped := string(editedReactionsCopy(t))
	i := strings.Index(shipped, "```js")
	require.Positive(t, i)
	a := f.writeReactionsCopy(t, []byte(shipped[:i]+"```js\nlog(\"not composing\");\n```\n"))
	require.Empty(t, a.ParseError)
	require.NoError(t, f.db.ConfirmAutomation(a.ID, a.ApprovalHash, time.Now()))
	f.lister.set(ownerReaction("111.1", "white_check_mark"))

	f.poll()
	assert.Equal(t, []string{"failed"}, f.ledger(t))
	var detail string
	require.NoError(t, f.db.QueryRow(`SELECT error FROM reaction_commands`).Scan(&detail))
	assert.Equal(t, "the Reactions automation did not compose: no compose call", detail)
	assert.Zero(t, countRows(t, f.db, `SELECT COUNT(*) FROM agent_actions`))
	assert.Zero(t, f.gen.calls)

	f.poll()
	assert.Len(t, f.runs(t), 1, "a failed row is terminal, never retried")
	f.assertSlotFree(t)
}

func TestReactionsBuiltin_ScriptThatThrowsFinalizesFailed(t *testing.T) {
	f := newReactionsFixture(t)
	shipped := string(editedReactionsCopy(t))
	i := strings.Index(shipped, "```js")
	require.Positive(t, i)
	a := f.writeReactionsCopy(t, []byte(shipped[:i]+"```js\nthrow new Error(\"boom\");\n```\n"))
	require.NoError(t, f.db.ConfirmAutomation(a.ID, a.ApprovalHash, time.Now()))
	f.lister.set(ownerReaction("111.1", "white_check_mark"))

	f.poll()
	assert.Equal(t, []string{"failed"}, f.ledger(t))
	var detail string
	require.NoError(t, f.db.QueryRow(`SELECT error FROM reaction_commands`).Scan(&detail))
	assert.Contains(t, detail, "the Reactions automation did not compose: ")
	assert.Contains(t, detail, "boom")
	f.assertSlotFree(t)
}

func TestReactionsBuiltin_BurstRespectsTheCap(t *testing.T) {
	f := newReactionsFixture(t)
	var items []slack.ReactedItem
	for i := range 30 {
		items = append(items, ownerReaction(fmt.Sprintf("10%02d.1", i), "white_check_mark"))
	}
	f.lister.set(items...)

	f.poll()
	assert.Len(t, f.runs(t), 25, "the per-poll cap")
	assert.Len(t, f.ledger(t), 25)
	f.poll()
	assert.Len(t, f.runs(t), 30, "the rest follow next poll")
	assert.Equal(t, 30, countRows(t, f.db, `SELECT COUNT(*) FROM reaction_commands WHERE status = 'dispatched'`))
	f.poll()
	assert.Len(t, f.runs(t), 30)
}

func TestReactionsBuiltin_TransientComposeReleases(t *testing.T) {
	f := newReactionsFixture(t)
	f.gen.set("", errors.New("provider down"))
	f.lister.set(ownerReaction("111.1", "white_check_mark"))

	f.poll()
	assert.Empty(t, f.ledger(t), "a transient compose failure releases the row (REACT-03)")
	require.Len(t, f.runs(t), 1)
	assert.Equal(t, db.RunFailed, f.runs(t)[0].Status, "the run is honest about the failure")
	assert.Zero(t, countRows(t, f.db, `SELECT COUNT(*) FROM agent_actions`))

	f.gen.set(`{"text":"Handle the deploy","reason":"owner flagged it"}`, nil)
	f.poll()
	assert.Equal(t, []string{"dispatched"}, f.ledger(t))
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM agent_actions`), "exactly one side effect")
}

// published counts the reaction events the bus received.
func published(r *recordingEvents) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.published)
}

func TestReactionsBuiltin_EventsStillPublished(t *testing.T) {
	f := newReactionsFixture(t)
	bus := newRecordingEvents(automations.SlackReactionAdded)
	f.d.SetAutomationEvents(bus)
	f.d.cycleEvents = bus
	a := f.writeReactionsCopy(t, editedReactionsCopy(t))
	f.poll() // seeds the event ledger

	ts := fmt.Sprintf("%d.000100", time.Now().Unix()+5)
	f.lister.set(ownerReaction(ts, "white_check_mark"))
	f.poll()
	assert.Equal(t, 1, published(bus), "an unconfirmed copy still publishes slack.reaction_added")
	assert.Empty(t, f.ledger(t))

	require.NoError(t, f.db.ConfirmAutomation(a.ID, a.ApprovalHash, time.Now()))
	ts2 := fmt.Sprintf("%d.000200", time.Now().Unix()+5)
	f.lister.set(ownerReaction(ts, "white_check_mark"), ownerReaction(ts2, "white_check_mark"))
	f.poll()
	assert.Equal(t, 2, published(bus), "the active built-in publishes too, each reaction once")
	assert.Equal(t, []string{"dispatched", "dispatched"}, f.ledger(t))
}

func TestReactionsBuiltin_LegacyWhenNotActive(t *testing.T) {
	f := newReactionsFixture(t)
	f.d.builtinActive[reactionsID] = false
	f.lister.set(ownerReaction("111.1", "white_check_mark"))
	f.poll()

	assert.Empty(t, f.runs(t), "the legacy pass composes in Go")
	assert.Equal(t, []string{"dispatched"}, f.ledger(t))
	assert.Equal(t, 1, f.gen.calls)
}

// A Reactions run that could not run its script (its executor failed)
// leaves no command in the slot: a fresh run Begins, and nothing is pending.
func TestReactionsBuiltin_FailedExecuteLeavesNoPendingEntry(t *testing.T) {
	f := newReactionsFixture(t)
	f.lister.set(ownerReaction("111.1", "white_check_mark"))
	_, err := f.db.Exec(`CREATE TRIGGER fail_claim BEFORE UPDATE OF status ON automation_runs
		WHEN NEW.status = 'running' BEGIN SELECT RAISE(ABORT, 'injected claim failure'); END`)
	require.NoError(t, err)

	f.poll()
	f.assertSlotFree(t)
	assert.Equal(t, []string{"failed"}, f.ledger(t))
	var detail string
	require.NoError(t, f.db.QueryRow(`SELECT error FROM reaction_commands`).Scan(&detail))
	assert.Contains(t, detail, "injected claim failure")

	run, err := f.d.builtins.EnqueueSync(reactionsID, automations.BuiltinInput{})
	require.NoError(t, err)
	require.NoError(t, f.d.reactionSlot.Begin(run.ID, reactioncmd.Dispatch{MessageTS: "fresh"}))
	_, ok := f.d.reactionSlot.End(run.ID)
	assert.False(t, ok, "the fresh run's slot holds no outcome")
}

// A cancelled pass releases a claimed row whose run never composed (the
// script did not get to run, or its compose failed on the cancelled
// context), so a shutdown never burns the reactions it claimed.
func TestReactionsBuiltin_CancelledPassReleases(t *testing.T) {
	f := newReactionsFixture(t)
	f.lister.set(ownerReaction("111.1", "white_check_mark"))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	f.d.phaseReactionCommands(ctx)
	assert.Empty(t, f.ledger(t), "released for the next poll")
	assert.Zero(t, countRows(t, f.db, `SELECT COUNT(*) FROM agent_actions`))
	f.assertSlotFree(t)

	f.poll()
	assert.Equal(t, []string{"dispatched"}, f.ledger(t))
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM agent_actions`))
}

// stopReactions marks the Reactions row stopped by the daemon (AUTO-08).
func (f *reactionsFixture) stopReactions(t *testing.T) {
	t.Helper()
	_, err := f.db.Exec(`UPDATE automations SET disabled_reason = 'runaway script' WHERE builtin_id = ?`, reactionsID)
	require.NoError(t, err)
}

func TestReactionsBuiltin_StoppedCopyClaimsNothing(t *testing.T) {
	f := newReactionsFixture(t)
	bus := newRecordingEvents(automations.SlackReactionAdded)
	f.d.SetAutomationEvents(bus)
	f.d.cycleEvents = bus
	f.poll() // seeds the event ledger
	f.stopReactions(t)

	ts := fmt.Sprintf("%d.000100", time.Now().Unix()+5)
	var items []slack.ReactedItem
	items = append(items, ownerReaction(ts, "white_check_mark"))
	for i := range 30 {
		items = append(items, ownerReaction(fmt.Sprintf("10%02d.1", i), "white_check_mark"))
	}
	f.lister.set(items...)
	f.poll()
	f.poll()

	assert.Empty(t, f.ledger(t), "a stopped built-in claims nothing")
	assert.Empty(t, f.runs(t))
	assert.Zero(t, f.gen.calls, "no budget spent")
	assert.Equal(t, 1, published(bus), "events are still published")
}

// The row is stopped while the pass runs (inside the first compose): the
// first reaction dispatches, the next ones' EnqueueSync refuses, so they are
// released with no run and no action, and dispatch once it can run again.
func TestReactionsBuiltin_StoppedMidPassReleases(t *testing.T) {
	f := newReactionsFixture(t)
	f.gen.hook(func() {
		f.gen.onCall = nil // runs under g.mu: clear directly
		f.stopReactions(t)
	})
	f.lister.set(ownerReaction("111.1", "white_check_mark"), ownerReaction("222.2", "white_check_mark"),
		ownerReaction("333.3", "white_check_mark"))
	f.poll()

	assert.Equal(t, []string{"dispatched"}, f.ledger(t), "the rest were released")
	assert.Len(t, f.runs(t), 1, "no run for a released row")
	assert.Equal(t, 1, countRows(t, f.db, `SELECT COUNT(*) FROM agent_actions`))
	assert.Equal(t, 1, f.gen.calls)
	f.assertSlotFree(t)

	_, err := f.db.Exec(`UPDATE automations SET disabled_reason = '' WHERE builtin_id = ?`, reactionsID)
	require.NoError(t, err)
	f.poll()
	assert.Equal(t, []string{"dispatched", "dispatched", "dispatched"}, f.ledger(t))
	assert.Equal(t, 3, countRows(t, f.db, `SELECT COUNT(*) FROM agent_actions`), "each reaction once")
}
