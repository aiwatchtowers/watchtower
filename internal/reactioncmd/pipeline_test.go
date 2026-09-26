package reactioncmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/slack-go/slack"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/tools"
)

var errBoom = errors.New("provider down")

type mockGenerator struct {
	mu     sync.Mutex
	out    string
	err    error
	calls  int
	source string
}

func (m *mockGenerator) Generate(ctx context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls++
	m.source, _ = digest.SourceFromContext(ctx)
	if m.err != nil {
		return "", nil, "", m.err
	}
	return m.out, &digest.Usage{}, "", nil
}

type stubLister struct{ items []slack.ReactedItem }

func (s stubLister) ListUserReactions(_ context.Context, _ string) ([]slack.ReactedItem, error) {
	return s.items, nil
}

// newTestRegistry builds a registry with the real create_target tool plus a
// fake external "create_jira_issue" so the external-stays-pending path is
// exercised without a live Jira client.
func newTestRegistry(t *testing.T, database *db.DB) *tools.Registry {
	t.Helper()
	reg := tools.New(database)
	require.NoError(t, reg.Register(tools.NewCreateTarget()))
	// create_idea is execute-trusted by migration 00065, so it is the tool that
	// makes "a historical reaction creates a real entity" observable.
	require.NoError(t, reg.Register(tools.NewCreateIdea()))
	schema, err := jsonschema.For[struct {
		Summary string `json:"summary"`
		Reason  string `json:"reason"`
	}](nil)
	require.NoError(t, err)
	require.NoError(t, reg.Register(&tools.Tool{
		Name:        "create_jira_issue",
		Description: "fake external jira tool for tests",
		InputSchema: schema,
		Access:      tools.AccessWrite,
		External:    true,
		Validate:    func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute:     func(context.Context, *db.DB, tools.Call) (any, error) { return "ok", nil },
	}))
	return reg
}

func newTestPipeline(t *testing.T, database *db.DB, gen digest.Generator, items []slack.ReactedItem) *Pipeline {
	t.Helper()
	accountsFn := func(context.Context) ([]Account, error) {
		return []Account{{AccountID: 1, OwnerID: "1:UOWNER", Lister: stubLister{items: items}}}, nil
	}
	return New(database, &config.Config{}, gen, newTestRegistry(t, database), accountsFn, nil)
}

// newLoggingTestPipeline is newTestPipeline with the pipeline's logger wired to
// a buffer, so the operator-visible log lines can be asserted.
func newLoggingTestPipeline(t *testing.T, database *db.DB, gen digest.Generator, items []slack.ReactedItem, logs *bytes.Buffer) *Pipeline {
	t.Helper()
	accountsFn := func(context.Context) ([]Account, error) {
		return []Account{{AccountID: 1, OwnerID: "1:UOWNER", Lister: stubLister{items: items}}}, nil
	}
	return New(database, &config.Config{}, gen, newTestRegistry(t, database), accountsFn, log.New(logs, "", 0))
}

func countAgentActions(t *testing.T, database *db.DB, status string) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(
		`SELECT COUNT(*) FROM agent_actions WHERE status = ?`, status).Scan(&n))
	return n
}

func TestReactionCmd_DispatchesNewCommandAsProposal(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &mockGenerator{out: `{"text":"Handle the deploy","intent":"unblock release","reason":"owner flagged it"}`}
	items := []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "please handle the deploy", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}),
	}
	p := newTestPipeline(t, database, gen, items)

	n, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	assert.Equal(t, 1, gen.calls)
	assert.Equal(t, "reactioncmd.command", gen.source, "the AI call is tagged for tier routing")

	// A pending create_target proposal exists (ask trust by default).
	assert.Equal(t, 1, countAgentActions(t, database, "pending"))
	var tool, status string
	require.NoError(t, database.QueryRow(
		`SELECT a.tool, a.status FROM reaction_commands r JOIN agent_actions a ON a.id = r.action_id`).Scan(&tool, &status))
	assert.Equal(t, "create_target", tool)
	assert.Equal(t, "pending", status)

	var ledgerStatus string
	require.NoError(t, database.QueryRow(`SELECT status FROM reaction_commands`).Scan(&ledgerStatus))
	assert.Equal(t, "dispatched", ledgerStatus)
}

// TestReactionCmd_Idempotent pins REACT-03 end to end: a second poll of the
// same reactions dispatches nothing and creates no second proposal.
func TestReactionCmd_Idempotent(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &mockGenerator{out: `{"text":"Handle the deploy","reason":"owner flagged it"}`}
	items := []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "x", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}),
	}
	p := newTestPipeline(t, database, gen, items)

	n1, err := p.Run(context.Background())
	require.NoError(t, err)
	require.Equal(t, 1, n1)

	n2, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, n2, "re-poll dispatches nothing")
	assert.Equal(t, 1, gen.calls, "no second compose call")
	assert.Equal(t, 1, countAgentActions(t, database, "pending"), "no second proposal")
}

// TestReactionCmd_ExternalStaysPending pins REACT-04/AGENT-03: an external tool
// (create_jira_issue) reaction records a pending proposal, never auto-applied.
func TestReactionCmd_ExternalStaysPending(t *testing.T) {
	database := seededPipelineDB(t, 1)
	// Even if the owner trusted it to execute, External refuses — assert the
	// stored proposal is pending, not applied.
	gen := &mockGenerator{out: `{"summary":"Ship the fix","reason":"owner flagged it"}`}
	items := []slack.ReactedItem{
		msgItem("C1", "222.2", "UAUTHOR", "we should ticket this", "",
			slack.ItemReaction{Name: "ticket", Users: []string{"UOWNER"}}),
	}
	p := newTestPipeline(t, database, gen, items)

	n, err := p.Run(context.Background())
	require.NoError(t, err)
	require.Equal(t, 1, n)
	assert.Equal(t, 1, countAgentActions(t, database, "pending"))
	assert.Equal(t, 0, countAgentActions(t, database, "applied"))
}

func TestReactionCmd_ComposeFailureMarksFailed(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &mockGenerator{out: "this is not json"}
	items := []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "x", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}),
	}
	p := newTestPipeline(t, database, gen, items)

	n, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	assert.Equal(t, 0, countAgentActions(t, database, "pending"))

	var status, errText string
	require.NoError(t, database.QueryRow(`SELECT status, error FROM reaction_commands`).Scan(&status, &errText))
	assert.Equal(t, "failed", status)
	assert.Contains(t, errText, "compose")
}

// TestReactionCmd_TransientFailureRetries pins the transient-vs-terminal
// contract: a generator error (provider down) is NOT recorded in the ledger, so
// a later poll retries and succeeds — the reaction is not burned by an outage.
func TestReactionCmd_TransientFailureRetries(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &mockGenerator{err: errBoom}
	items := []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "handle the deploy", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}),
	}
	p := newTestPipeline(t, database, gen, items)

	n, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, n, "transient failure dispatches nothing")

	var ledgerRows int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM reaction_commands`).Scan(&ledgerRows))
	assert.Equal(t, 0, ledgerRows, "a transient failure is NOT recorded in the ledger")

	// The provider recovers; the same reaction now succeeds.
	gen.mu.Lock()
	gen.err = nil
	gen.out = `{"text":"Handle the deploy","reason":"owner flagged it"}`
	gen.mu.Unlock()

	n2, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, n2, "the retry succeeds")
	assert.Equal(t, 1, countAgentActions(t, database, "pending"))
}

func TestReactionCmd_NoDictionaryIsNoOp(t *testing.T) {
	database := seededPipelineDB(t, 1)
	_, err := database.Exec(`DELETE FROM reaction_command_map`)
	require.NoError(t, err)
	gen := &mockGenerator{out: `{}`}
	p := newTestPipeline(t, database, gen, nil)

	n, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	assert.Equal(t, 0, gen.calls)
}

// newCappedTestPipeline builds a pipeline over several accounts, each with its
// own reaction history, so the per-Run (not per-account) budget is observable.
func newCappedTestPipeline(t *testing.T, database *db.DB, gen digest.Generator, perAccount map[int64][]slack.ReactedItem) *Pipeline {
	t.Helper()
	accountsFn := func(context.Context) ([]Account, error) {
		ids := make([]int64, 0, len(perAccount))
		for id := range perAccount {
			ids = append(ids, id)
		}
		sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
		out := make([]Account, 0, len(ids))
		for _, id := range ids {
			out = append(out, Account{AccountID: id, OwnerID: "1:UOWNER", Lister: stubLister{items: perAccount[id]}})
		}
		return out, nil
	}
	return New(database, &config.Config{}, gen, newTestRegistry(t, database), accountsFn, nil)
}

// dictionaryReactions builds n distinct dispatchable (create_target) owner
// reactions in one channel.
func dictionaryReactions(channel string, n int) []slack.ReactedItem {
	out := make([]slack.ReactedItem, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, msgItem(channel, fmt.Sprintf("10%d.1", i), "UAUTHOR", "handle this", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}))
	}
	return out
}

// freeSkipReaction is a candidate whose emoji maps to a tool the registry does
// not hold: dispatch records it "skipped" BEFORE reaching compose, so it costs
// no AI call and must not consume a slot of the run's budget.
func freeSkipReaction(t *testing.T, database *db.DB) slack.ReactedItem {
	t.Helper()
	_, err := database.Exec(`INSERT OR REPLACE INTO reaction_command_map (emoji, kind, tool, enabled)
		VALUES ('no_entry', 'builtin_tool', 'not_a_registered_tool', 1)`)
	require.NoError(t, err)
	return msgItem("C9", "999.9", "UAUTHOR", "unmapped", "",
		slack.ItemReaction{Name: "no_entry", Users: []string{"UOWNER"}})
}

// TestReactionCmd_DispatchCapDefersOverflow pins the per-Run compose budget: a
// backlog larger than the cap spends exactly maxDispatchPerRun AI calls, the
// free skip does not eat a slot, and the deferred remainder drains on the next
// poll without re-proposing anything already dispatched (REACT-03 across the
// cap boundary).
func TestReactionCmd_DispatchCapDefersOverflow(t *testing.T) {
	database := seededPipelineDB(t, 1)
	// The free skip comes FIRST on purpose: an implementation that claims the
	// budget before the free-skip branches would spend a slot on it, and a
	// fixture that puts it last would only notice indirectly.
	items := append([]slack.ReactedItem{freeSkipReaction(t, database)}, dictionaryReactions("C1", maxDispatchPerRun+2)...)
	gen := &mockGenerator{out: `{"text":"Handle this","reason":"owner flagged it"}`}
	logs := new(bytes.Buffer)
	p := newLoggingTestPipeline(t, database, gen, items, logs)

	n1, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, maxDispatchPerRun, n1)
	// The deferred count is the only operator-visible evidence that a backlog is
	// draining rather than stuck, so assert the rendered numbers, not just that
	// something was logged.
	assert.Contains(t, logs.String(), fmt.Sprintf(
		"dispatched %d, deferred 2 to the next cycle (cap %d)", maxDispatchPerRun, maxDispatchPerRun))
	assert.Equal(t, maxDispatchPerRun, gen.calls, "the free skip does not consume budget")
	assert.Equal(t, maxDispatchPerRun, countRows(t, database, "agent_actions"))
	// cap dispatched + the free skip; the 2 deferred ones stay UNrecorded so
	// the next poll sees them as unseen.
	assert.Equal(t, maxDispatchPerRun+1, countRows(t, database, "reaction_commands"))

	logs.Reset()
	n2, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, n2, "the deferred remainder drains on the next poll")
	assert.NotContains(t, logs.String(), "deferred", "a run that stays under the cap defers nothing")
	assert.Equal(t, maxDispatchPerRun+2, gen.calls, "no re-compose of the first batch")
	assert.Equal(t, maxDispatchPerRun+2, countRows(t, database, "agent_actions"), "no duplicate proposals")
	assert.Equal(t, maxDispatchPerRun+3, countRows(t, database, "reaction_commands"))
}

// TestReactionCmd_DispatchCapIsSharedAcrossAccounts pins that the budget is per
// Run, not per account: two accounts each holding a full backlog still spend
// maxDispatchPerRun AI calls between them, never 2x.
func TestReactionCmd_DispatchCapIsSharedAcrossAccounts(t *testing.T) {
	database := seededPipelineDB(t, 1, 2)
	gen := &mockGenerator{out: `{"text":"Handle this","reason":"owner flagged it"}`}
	p := newCappedTestPipeline(t, database, gen, map[int64][]slack.ReactedItem{
		1: dictionaryReactions("C1", maxDispatchPerRun),
		2: dictionaryReactions("C2", maxDispatchPerRun),
	})

	n, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, maxDispatchPerRun, n, "the cap is shared, not per account")
	assert.Equal(t, maxDispatchPerRun, gen.calls)
	assert.Equal(t, maxDispatchPerRun, countRows(t, database, "agent_actions"))
}

// TestReactionCmd_UnderCapDispatchesEverything pins the degenerate side of the
// budget: a backlog smaller than the cap is not truncated by it.
func TestReactionCmd_UnderCapDispatchesEverything(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &mockGenerator{out: `{"text":"Handle this","reason":"owner flagged it"}`}
	p := newTestPipeline(t, database, gen, dictionaryReactions("C1", 3))

	n, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 3, n)
	assert.Equal(t, 3, gen.calls)
}

// addAbortTrigger installs a SQLite trigger that aborts every `op`
// (INSERT/UPDATE/DELETE) on reaction_commands, returning a func that drops it —
// the seed_test failure-injection precedent.
func addAbortTrigger(t *testing.T, database *db.DB, op string) func() {
	t.Helper()
	name := "abort_ledger_" + op
	_, err := database.Exec(fmt.Sprintf(`CREATE TRIGGER %s BEFORE %s ON reaction_commands
		BEGIN SELECT RAISE(ABORT, 'injected ledger %s failure'); END`, name, op, op))
	require.NoError(t, err)
	return func() {
		_, err := database.Exec(`DROP TRIGGER ` + name)
		require.NoError(t, err)
	}
}

func ledgerStatuses(t *testing.T, database *db.DB) []string {
	t.Helper()
	rows, err := database.Query(`SELECT status FROM reaction_commands ORDER BY id`)
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

// TestReactionCmd_FinalizeFailureAfterProposeNeverRedispatches pins the
// provisional-row fix for the double-fire: the ledger write that records the
// outcome fails AFTER Propose created the entity (create_idea is
// execute-trusted, so the idea already exists). The provisional row written
// before Propose keeps the reaction "seen", so the next poll composes and
// proposes nothing — at most one side effect, never two.
func TestReactionCmd_FinalizeFailureAfterProposeNeverRedispatches(t *testing.T) {
	database := seededPipelineDB(t, 1)
	_, err := database.Exec(`INSERT INTO reaction_command_map (emoji, kind, tool) VALUES ('bulb', 'builtin_tool', 'create_idea')
		ON CONFLICT(emoji) DO UPDATE SET tool = 'create_idea', enabled = 1`)
	require.NoError(t, err)
	gen := &mockGenerator{out: `{"title":"Cache the deploy","essence":"cache builds","reason":"owner flagged it"}`}
	items := []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "we could cache builds", "",
			slack.ItemReaction{Name: "bulb", Users: []string{"UOWNER"}}),
	}
	var logs bytes.Buffer
	p := newLoggingTestPipeline(t, database, gen, items, &logs)

	drop := addAbortTrigger(t, database, "UPDATE")
	n, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, n, "the side effect happened, so it counts as dispatched")
	require.Equal(t, 1, gen.calls)
	actions := countAgentActions(t, database, "applied")
	require.Equal(t, 1, actions, "create_idea applied synchronously")
	assert.Equal(t, []string{db.ReactionCommandProvisional}, ledgerStatuses(t, database), "the finalize failed, the claim stayed")
	assert.Contains(t, logs.String(), "will not re-dispatch")

	drop()
	n2, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, n2, "the next poll dispatches nothing")
	assert.Equal(t, 1, gen.calls, "no second compose call")
	assert.Equal(t, 1, countAgentActions(t, database, "applied"), "no second idea")
	var ideas int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM ideas`).Scan(&ideas))
	assert.Equal(t, 1, ideas)
}

// TestReactionCmd_ClaimFailureProposesNothingAndRetries: when the provisional
// row itself cannot be written, the command is not composed or proposed at
// all, and the next poll (ledger writable again) dispatches it normally.
func TestReactionCmd_ClaimFailureProposesNothingAndRetries(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &mockGenerator{out: `{"text":"Handle the deploy","reason":"owner flagged it"}`}
	items := []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "handle the deploy", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}),
	}
	p := newTestPipeline(t, database, gen, items)

	drop := addAbortTrigger(t, database, "INSERT")
	budget := &dispatchBudget{remaining: 1}
	u := db.OwnerReaction{AccountID: 1, ChannelID: "1:C1", MessageTS: "111.1", Emoji: "white_check_mark"}
	c := candidate{AccountID: 1, ChannelID: u.ChannelID, MessageTS: u.MessageTS, Emoji: u.Emoji, Mapping: testDict()["white_check_mark"]}
	assert.False(t, p.dispatchOne(context.Background(), u, c, budget))
	assert.Equal(t, 1, budget.remaining, "a failed claim refunds its slot")
	n, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	assert.Equal(t, 0, gen.calls, "no compose without a claimed row")
	assert.Equal(t, 0, countAgentActions(t, database, "pending"), "nothing proposed")
	assert.Empty(t, ledgerStatuses(t, database))

	drop()
	n2, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, n2, "retried on the next poll")
	assert.Equal(t, 1, countAgentActions(t, database, "pending"))
	assert.Equal(t, []string{"dispatched"}, ledgerStatuses(t, database))
}

// TestReactionCmd_ReleaseFailureAfterTransientStrandsInsteadOfRetrying: a
// transient compose failure whose release (delete of the claim) also fails
// leaves the row provisional — the safe direction: that reaction is not
// retried, and nothing is ever proposed for it twice.
func TestReactionCmd_ReleaseFailureAfterTransientStrandsInsteadOfRetrying(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &mockGenerator{err: errBoom}
	items := []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "handle the deploy", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}),
	}
	var logs bytes.Buffer
	p := newLoggingTestPipeline(t, database, gen, items, &logs)

	drop := addAbortTrigger(t, database, "DELETE")
	defer drop()
	_, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{db.ReactionCommandProvisional}, ledgerStatuses(t, database))
	assert.Contains(t, logs.String(), "will NOT be retried")

	gen.mu.Lock()
	gen.err = nil
	gen.out = `{"text":"Handle the deploy","reason":"owner flagged it"}`
	gen.mu.Unlock()
	n, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	assert.Equal(t, 1, gen.calls, "the stranded claim is not re-composed")
}

// TestReactionCmd_StrandedProvisionalRowSurfacesAsFailed pins how a stranded
// row becomes visible: a provisional row older than strandedAfter is turned
// into a terminal `failed` row carrying strandedDetail (so `reaction-commands
// list` shows why) and logged, without ever being re-dispatched; a fresh
// provisional row (a dispatch in flight) is left as it is.
func TestReactionCmd_StrandedProvisionalRowSurfacesAsFailed(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &mockGenerator{out: `{"text":"Handle the deploy","reason":"owner flagged it"}`}
	items := []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "x", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}),
		msgItem("C1", "222.2", "UAUTHOR", "y", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}),
	}
	stale := time.Now().Add(-strandedAfter - time.Minute).UTC().Format("2006-01-02T15:04:05Z")
	fresh := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	for ts, created := range map[string]string{"111.1": stale, "222.2": fresh} {
		_, err := database.Exec(`INSERT INTO reaction_commands (account_id, channel_id, message_ts, emoji, status, created_at)
			VALUES (1, '1:C1', ?, 'white_check_mark', 'pending', ?)`, ts, created)
		require.NoError(t, err)
	}
	var logs bytes.Buffer
	p := newLoggingTestPipeline(t, database, gen, items, &logs)

	n, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, n)
	assert.Equal(t, 0, gen.calls, "neither row is re-dispatched")

	var status, errText string
	require.NoError(t, database.QueryRow(`SELECT status, error FROM reaction_commands WHERE message_ts = '111.1'`).Scan(&status, &errText))
	assert.Equal(t, "failed", status)
	assert.Equal(t, strandedDetail, errText)
	require.NoError(t, database.QueryRow(`SELECT status FROM reaction_commands WHERE message_ts = '222.2'`).Scan(&status))
	assert.Equal(t, db.ReactionCommandProvisional, status, "an in-flight claim is not failed")
	assert.Contains(t, logs.String(), "stranded provisional")
}

// addAgentActionAbortTrigger aborts every `op` on agent_actions — the way to
// make Registry.Propose fail before (INSERT) or after (UPDATE) it records its
// row.
func addAgentActionAbortTrigger(t *testing.T, database *db.DB, op string) func() {
	t.Helper()
	name := "abort_agent_actions_" + op
	_, err := database.Exec(fmt.Sprintf(`CREATE TRIGGER %s BEFORE %s ON agent_actions
		BEGIN SELECT RAISE(ABORT, 'injected agent_actions %s failure'); END`, name, op, op))
	require.NoError(t, err)
	return func() {
		_, err := database.Exec(`DROP TRIGGER ` + name)
		require.NoError(t, err)
	}
}

func bulbPipeline(t *testing.T, database *db.DB, gen digest.Generator, logs *bytes.Buffer) *Pipeline {
	t.Helper()
	_, err := database.Exec(`INSERT INTO reaction_command_map (emoji, kind, tool) VALUES ('bulb', 'builtin_tool', 'create_idea')
		ON CONFLICT(emoji) DO UPDATE SET tool = 'create_idea', enabled = 1`)
	require.NoError(t, err)
	items := []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "we could cache builds", "",
			slack.ItemReaction{Name: "bulb", Users: []string{"UOWNER"}}),
	}
	return newLoggingTestPipeline(t, database, gen, items, logs)
}

func countAllAgentActions(t *testing.T, database *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&n))
	return n
}

// TestReactionCmd_ProposeErrorAfterRecordingNeverRedispatches: an
// execute-trusted Propose inserts its agent_actions row, then fails stamping
// it (injected on UPDATE). The error alone would look transient; the pipeline
// finds the recorded row, finalizes the ledger as dispatched with its id, and
// the next poll proposes nothing — no second card, no second entity.
func TestReactionCmd_ProposeErrorAfterRecordingNeverRedispatches(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &mockGenerator{out: `{"title":"Cache the deploy","essence":"cache builds","reason":"owner flagged it"}`}
	var logs bytes.Buffer
	p := bulbPipeline(t, database, gen, &logs)

	drop := addAgentActionAbortTrigger(t, database, "UPDATE")
	_, err := p.Run(context.Background())
	require.NoError(t, err)
	drop()
	require.Equal(t, 1, countAllAgentActions(t, database), "Propose recorded its row before failing")

	var status string
	var actionID, recorded int64
	require.NoError(t, database.QueryRow(`SELECT status, action_id FROM reaction_commands`).Scan(&status, &actionID))
	require.NoError(t, database.QueryRow(`SELECT id FROM agent_actions`).Scan(&recorded))
	assert.Equal(t, "dispatched", status)
	assert.Equal(t, recorded, actionID, "the ledger links the action Propose recorded")

	_, err = p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, gen.calls, "no second compose call")
	assert.Equal(t, 1, countAllAgentActions(t, database), "no second proposal")
}

// TestReactionCmd_ProposeErrorBeforeRecordingRetries: a Propose that fails
// before inserting anything (injected on INSERT) provably proposed nothing, so
// the claim is released and the next poll dispatches normally — the pre-fix
// transient-Propose retry semantics are preserved.
func TestReactionCmd_ProposeErrorBeforeRecordingRetries(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &mockGenerator{out: `{"title":"Cache the deploy","essence":"cache builds","reason":"owner flagged it"}`}
	var logs bytes.Buffer
	p := bulbPipeline(t, database, gen, &logs)

	drop := addAgentActionAbortTrigger(t, database, "INSERT")
	n, err := p.Run(context.Background())
	require.NoError(t, err)
	drop()
	assert.Equal(t, 0, n)
	assert.Empty(t, ledgerStatuses(t, database), "the claim was released")

	n, err = p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, n, "retried on the next poll")
	assert.Equal(t, 1, countAllAgentActions(t, database))
	assert.Equal(t, []string{"dispatched"}, ledgerStatuses(t, database))
}

// TestReactionCmd_ProposeValidationErrorMarksFailed: args the tool rejects
// (no "reason") are a terminal Propose failure, finalized as failed through the
// claim — and never re-composed.
func TestReactionCmd_ProposeValidationErrorMarksFailed(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &mockGenerator{out: `{"text":"Handle the deploy"}`}
	items := []slack.ReactedItem{
		msgItem("C1", "111.1", "UAUTHOR", "x", "",
			slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}}),
	}
	p := newTestPipeline(t, database, gen, items)

	_, err := p.Run(context.Background())
	require.NoError(t, err)
	var status, errText string
	require.NoError(t, database.QueryRow(`SELECT status, error FROM reaction_commands`).Scan(&status, &errText))
	assert.Equal(t, "failed", status)
	assert.Contains(t, errText, "propose")

	_, err = p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, gen.calls, "a terminal failure is not re-composed")
}

// TestReactionCmd_LostClaimDispatchesNothingAndRefundsBudget drives the
// concurrent-poll branch: the key is already claimed (another poll holds it)
// when dispatchOne runs, so nothing is composed and the budget slot is
// returned — only compose calls spend the budget.
func TestReactionCmd_LostClaimDispatchesNothingAndRefundsBudget(t *testing.T) {
	database := seededPipelineDB(t, 1)
	gen := &mockGenerator{out: `{"text":"Handle the deploy","reason":"owner flagged it"}`}
	p := newTestPipeline(t, database, gen, nil)
	u := db.OwnerReaction{AccountID: 1, ChannelID: "1:C1", MessageTS: "111.1", Emoji: "white_check_mark"}
	_, claimed, err := database.ClaimReactionCommand(u)
	require.NoError(t, err)
	require.True(t, claimed)

	c := candidate{AccountID: 1, ChannelID: u.ChannelID, MessageTS: u.MessageTS, Emoji: u.Emoji, Mapping: testDict()["white_check_mark"]}
	budget := &dispatchBudget{remaining: 1}
	assert.False(t, p.dispatchOne(context.Background(), u, c, budget))
	assert.Equal(t, 0, gen.calls)
	assert.Equal(t, 1, budget.remaining, "a lost claim refunds its slot")
	assert.Equal(t, 0, countAllAgentActions(t, database))
}
