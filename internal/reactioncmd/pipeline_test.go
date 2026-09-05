package reactioncmd

import (
	"context"
	"encoding/json"
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
