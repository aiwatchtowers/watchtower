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
	database := db.OpenTestDB(t)
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
	database := db.OpenTestDB(t)
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
	database := db.OpenTestDB(t)
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
	database := db.OpenTestDB(t)
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
	database := db.OpenTestDB(t)
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
	database := db.OpenTestDB(t)
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
	database := db.OpenTestDB(t)
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
	database := db.OpenTestDB(t)
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
	database := db.OpenTestDB(t)
	gen := &mockGenerator{out: `{"text":"Handle this","reason":"owner flagged it"}`}
	p := newTestPipeline(t, database, gen, dictionaryReactions("C1", 3))

	n, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 3, n)
	assert.Equal(t, 3, gen.calls)
}
