package reactioncmd

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"strings"
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

func TestScanTrackerEvidence(t *testing.T) {
	pre := db.TrackerPrefixes{
		Jira:   map[string]bool{"ABC": true, "OPS": true},
		Linear: map[string]bool{"ENG": true, "OPS": true},
	}
	for _, tc := range []struct {
		name  string
		texts []string
		want  trackerEvidence
	}{
		{"jira only", []string{"see ABC-12 please"}, trackerEvidence{jira: true}},
		{"linear url", []string{"https://linear.app/acme/issue/ENG-7/fix"}, trackerEvidence{linear: true}},
		{"both", []string{"ABC-1", "ENG-2"}, trackerEvidence{jira: true, linear: true}},
		{"collision prefix counts for neither", []string{"OPS-3"}, trackerEvidence{}},
		{"unknown prefix", []string{"XYZ-3 and UTF-8"}, trackerEvidence{}},
		{"lowercase is not a key", []string{"abc-12"}, trackerEvidence{}},
		{"no texts", nil, trackerEvidence{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			assert.Equal(t, tc.want, scanTrackerEvidence(tc.texts, pre))
		})
	}
}

func TestRouteIssueTool(t *testing.T) {
	for _, tc := range []struct {
		name          string
		mapped        string
		ev            trackerEvidence
		jira, linear  bool
		want          string
		wantExplained bool
	}{
		{"jira keys", toolLinearIssue, trackerEvidence{jira: true}, true, true, toolJiraIssue, true},
		{"linear keys", toolJiraIssue, trackerEvidence{linear: true}, true, true, toolLinearIssue, true},
		{"ambiguous keeps the dictionary's jira", toolJiraIssue, trackerEvidence{jira: true, linear: true}, true, true, toolJiraIssue, true},
		{"ambiguous keeps the dictionary's linear", toolLinearIssue, trackerEvidence{jira: true, linear: true}, true, true, toolLinearIssue, true},
		{"no keys, both connected", toolJiraIssue, trackerEvidence{}, true, true, toolJiraIssue, false},
		{"no keys, linear only", toolJiraIssue, trackerEvidence{}, false, true, toolLinearIssue, true},
		{"no keys, jira only", toolLinearIssue, trackerEvidence{}, true, false, toolJiraIssue, true},
		{"no keys, nothing connected", toolJiraIssue, trackerEvidence{}, false, false, toolJiraIssue, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, why := routeIssueTool(tc.mapped, tc.ev, tc.jira, tc.linear)
			assert.Equal(t, tc.want, got)
			assert.Equal(t, tc.wantExplained, why != "")
		})
	}
}

func TestFormatLinearTeams_NamesTheAccountOfASharedKey(t *testing.T) {
	got := formatLinearTeams([]db.ReactionLinearTeam{{AccountID: 1, Key: "DES"}, {AccountID: 1, Key: "ENG"}, {AccountID: 2, Key: "ENG"}})
	assert.Equal(t, []string{"DES", "ENG (account_id 1)", "ENG (account_id 2)"}, got)
}

func TestArgGuide_LinearIssue(t *testing.T) {
	g := argGuide(toolLinearIssue)
	assert.NotEqual(t, argGuide("some_unknown_tool"), g)
	for _, want := range []string{`"team"`, `"title"`, `"reason"`, "Available Linear teams"} {
		assert.Contains(t, g, want)
	}
}

// ---- pipeline routing --------------------------------------------------------

type capturingGenerator struct {
	mu   sync.Mutex
	out  string
	msgs []string
}

func (g *capturingGenerator) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.msgs = append(g.msgs, user)
	return g.out, &digest.Usage{}, "", nil
}

// fakeIssueTool is an External stand-in for an issue tool, on the given
// surfaces, that accepts a bare reason (the real tools are tested in internal/tools).
func fakeIssueTool(t *testing.T, name string, surfaces ...string) *tools.Tool {
	t.Helper()
	schema, err := jsonschema.For[struct {
		Reason string `json:"reason"`
	}](nil)
	require.NoError(t, err)
	return &tools.Tool{
		Name: name, Description: "fake " + name, InputSchema: schema,
		Access: tools.AccessWrite, External: true, Surfaces: surfaces,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute:  func(context.Context, *db.DB, tools.Call) (any, error) { return "ok", nil },
	}
}

func routingPipeline(t *testing.T, database *db.DB, gen digest.Generator, linearSurfaces []string, items []slack.ReactedItem, logs *bytes.Buffer) *Pipeline {
	t.Helper()
	reg := tools.New(database)
	require.NoError(t, reg.Register(fakeIssueTool(t, toolJiraIssue, "main", "target", "reaction")))
	require.NoError(t, reg.Register(fakeIssueTool(t, toolLinearIssue, linearSurfaces...)))
	accountsFn := func(context.Context) ([]Account, error) {
		return []Account{{AccountID: 1, OwnerID: "1:UOWNER", Lister: stubLister{items: items}}}, nil
	}
	return New(database, &config.Config{}, gen, reg, accountsFn, log.New(logs, "", 0))
}

func connectJira(t *testing.T, database *db.DB, projects ...string) {
	t.Helper()
	ja, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c", SiteURL: "https://acme.atlassian.net", SiteName: "Acme"})
	require.NoError(t, err)
	for _, p := range projects {
		_, err := database.Exec(`INSERT INTO jira_sync_state (account_id, project_key) VALUES (?, ?)`, ja, p)
		require.NoError(t, err)
	}
}

func connectLinear(t *testing.T, database *db.DB, teams ...string) {
	t.Helper()
	la, err := database.CreateLinearAccount("")
	require.NoError(t, err)
	var ts []db.LinearTeam
	sel := map[string]bool{}
	for _, k := range teams {
		ts = append(ts, db.LinearTeam{ID: "team-" + k, Key: k})
		sel["team-"+k] = true
	}
	require.NoError(t, database.UpsertLinearTeams(la, ts, sel))
}

func addChannelMessage(t *testing.T, database *db.DB, channel, ts, text string) {
	t.Helper()
	_, err := database.Exec(`INSERT INTO messages (channel_id, ts, text) VALUES (?, ?, ?)`, channel, ts, text)
	require.NoError(t, err)
}

func ticketReaction(text string) []slack.ReactedItem {
	return []slack.ReactedItem{msgItem("C1", "500.1", "UAUTHOR", text, "",
		slack.ItemReaction{Name: "ticket", Users: []string{"UOWNER"}})}
}

func dispatchedTool(t *testing.T, database *db.DB) (tool, status string) {
	t.Helper()
	require.NoError(t, database.QueryRow(
		`SELECT a.tool, a.status FROM reaction_commands r JOIN agent_actions a ON a.id = r.action_id`).Scan(&tool, &status))
	return tool, status
}

// A :ticket: (create_jira_issue in the seeded dictionary) in a channel whose
// keys are Linear's files a Linear issue — still a pending proposal (REACT-04,
// AGENT-03) — and the composer is offered the Linear teams.
func TestReactionCmd_LinearChannelFilesLinearIssue(t *testing.T) {
	database := seededPipelineDB(t, 1)
	connectJira(t, database, "ABC")
	connectLinear(t, database, "ENG", "DES")
	addChannelMessage(t, database, "1:C1", "400.1", "ENG-41 is still open")
	gen := &capturingGenerator{out: `{"reason":"owner flagged it"}`}
	var logs bytes.Buffer
	p := routingPipeline(t, database, gen, []string{"main", "target", "reaction"}, ticketReaction("login is broken again"), &logs)

	n, err := p.Run(context.Background(), nil)
	require.NoError(t, err)
	require.Equal(t, 1, n, logs.String())
	tool, status := dispatchedTool(t, database)
	assert.Equal(t, toolLinearIssue, tool)
	assert.Equal(t, "pending", status, "an External Linear create never auto-applies")
	require.Len(t, gen.msgs, 1)
	assert.Contains(t, gen.msgs[0], "Action to build: create_linear_issue")
	assert.Contains(t, gen.msgs[0], "Available Linear teams: DES, ENG")
	assert.NotContains(t, gen.msgs[0], "Available Jira projects")
	assert.Contains(t, logs.String(), "files with create_linear_issue instead of create_jira_issue")
}

// The Jira path is unchanged: Jira keys in the channel keep create_jira_issue
// and its Jira project grounding.
func TestReactionCmd_JiraChannelKeepsJiraIssue(t *testing.T) {
	database := seededPipelineDB(t, 1)
	connectJira(t, database, "ABC", "OPS")
	connectLinear(t, database, "ENG")
	gen := &capturingGenerator{out: `{"reason":"owner flagged it"}`}
	var logs bytes.Buffer
	p := routingPipeline(t, database, gen, []string{"main", "target", "reaction"}, ticketReaction("ABC-9 regressed"), &logs)

	_, err := p.Run(context.Background(), nil)
	require.NoError(t, err)
	tool, status := dispatchedTool(t, database)
	assert.Equal(t, toolJiraIssue, tool)
	assert.Equal(t, "pending", status)
	require.Len(t, gen.msgs, 1)
	assert.Contains(t, gen.msgs[0], "Available Jira projects: ABC, OPS")
}

// A channel mentioning both trackers' keys is ambiguous: the dictionary's own
// tool stands, and the log says why.
func TestReactionCmd_MixedChannelKeepsDictionaryTool(t *testing.T) {
	database := seededPipelineDB(t, 1)
	connectJira(t, database, "ABC")
	connectLinear(t, database, "ENG")
	addChannelMessage(t, database, "1:C1", "400.1", "ABC-1 blocks ENG-2")
	gen := &capturingGenerator{out: `{"reason":"owner flagged it"}`}
	var logs bytes.Buffer
	p := routingPipeline(t, database, gen, []string{"main", "target", "reaction"}, ticketReaction("needs a ticket"), &logs)

	_, err := p.Run(context.Background(), nil)
	require.NoError(t, err)
	tool, _ := dispatchedTool(t, database)
	assert.Equal(t, toolJiraIssue, tool, "the :ticket: mapping wins when the channel is ambiguous")
	assert.Contains(t, logs.String(), "both Jira and Linear keys")
}

// A Linear-only install files the seeded :ticket: in Linear even in a channel
// that mentions no keys.
func TestReactionCmd_LinearOnlyInstallFilesLinearIssue(t *testing.T) {
	database := seededPipelineDB(t, 1)
	connectLinear(t, database, "ENG")
	gen := &capturingGenerator{out: `{"reason":"r"}`}
	var logs bytes.Buffer
	p := routingPipeline(t, database, gen, []string{"main", "target", "reaction"}, ticketReaction("please track this"), &logs)

	_, err := p.Run(context.Background(), nil)
	require.NoError(t, err)
	tool, _ := dispatchedTool(t, database)
	assert.Equal(t, toolLinearIssue, tool)
}

// A routed tool the reaction surface cannot dispatch never replaces the
// dictionary's tool.
func TestReactionCmd_RoutedToolOffTheSurfaceKeepsDictionaryTool(t *testing.T) {
	database := seededPipelineDB(t, 1)
	connectLinear(t, database, "ENG")
	addChannelMessage(t, database, "1:C1", "400.1", "ENG-41")
	gen := &capturingGenerator{out: `{"reason":"r"}`}
	var logs bytes.Buffer
	p := routingPipeline(t, database, gen, []string{"main"}, ticketReaction("x"), &logs)

	_, err := p.Run(context.Background(), nil)
	require.NoError(t, err)
	tool, _ := dispatchedTool(t, database)
	assert.Equal(t, toolJiraIssue, tool)
	assert.True(t, strings.Contains(logs.String(), "the reaction surface cannot dispatch"), logs.String())
}

// Routing applies only to issue tools: a create_target reaction in a Linear
// channel stays create_target.
func TestReactionCmd_NonIssueToolIsNotRouted(t *testing.T) {
	database := seededPipelineDB(t, 1)
	connectLinear(t, database, "ENG")
	addChannelMessage(t, database, "1:C1", "400.1", "ENG-41")
	gen := &mockGenerator{out: `{"text":"Do it","reason":"r"}`}
	items := []slack.ReactedItem{msgItem("C1", "500.1", "UAUTHOR", "ENG-41 do it", "",
		slack.ItemReaction{Name: "white_check_mark", Users: []string{"UOWNER"}})}
	p := newTestPipeline(t, database, gen, items)

	_, err := p.Run(context.Background(), nil)
	require.NoError(t, err)
	tool, _ := dispatchedTool(t, database)
	assert.Equal(t, "create_target", tool)
}
