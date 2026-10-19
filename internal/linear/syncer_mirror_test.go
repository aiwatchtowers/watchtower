package linear

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSyncer_MirrorsStatesAndLabelsForSelectedTeams(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}, {"id": "t-2", "key": "OPS", "name": "Ops"}}
	f.states = map[string][]map[string]any{
		"t-1": {{"id": "s-2", "name": "Done", "type": "completed", "position": 2.0}, {"id": "s-1", "name": "Todo", "type": "unstarted", "position": 1.0}},
		"t-2": {{"id": "s-9", "name": "Other", "type": "started", "position": 1.0}},
	}
	f.labels = []map[string]any{
		{"id": "l-1", "name": "Bug", "team": map[string]any{"id": "t-1"}},
		{"id": "l-2", "name": "Company", "team": nil},
	}
	d, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)

	states, err := d.ListLinearTeamStates(s.AccountID(), "t-1")
	require.NoError(t, err)
	require.Len(t, states, 2)
	assert.Equal(t, "Todo", states[0].Name)
	assert.Equal(t, "completed", states[1].Type)
	labels, err := d.ListLinearLabels(s.AccountID(), "t-1")
	require.NoError(t, err)
	require.Len(t, labels, 2)
	// The deselected team's states were never fetched or stored.
	assert.Equal(t, []string{"t-1"}, f.stateRequestTeams())
	other, _ := d.ListLinearTeamStates(s.AccountID(), "t-2")
	assert.Empty(t, other)
}

func TestSyncer_WorkspaceLabelsOncePerPass(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1", "t-2"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}, {"id": "t-2", "key": "OPS", "name": "Ops"}}
	f.labels = []map[string]any{
		{"id": "l-1", "name": "Bug", "team": map[string]any{"id": "t-1"}},
		{"id": "l-3", "name": "Ops", "team": map[string]any{"id": "t-2"}},
		{"id": "l-2", "name": "Company", "team": nil},
	}
	d, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)

	assert.Equal(t, []string{"t-1", "t-2"}, f.stateRequestTeams())
	assert.Equal(t, 1, f.workspaceLabelRequests(), "two selected teams, one workspace-label request")
	for team, want := range map[string][]string{"t-1": {"Bug", "Company"}, "t-2": {"Company", "Ops"}} {
		labels, err := d.ListLinearLabels(s.AccountID(), team)
		require.NoError(t, err)
		var names []string
		for _, l := range labels {
			names = append(names, l.Name)
		}
		assert.ElementsMatch(t, want, names, team)
	}
}

func TestSyncer_RefreshIssueStampsSlackIDs(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	f.users = []map[string]any{
		{"id": "user-1", "name": "Owner", "displayName": "owner", "email": "owner@example.com"},
		{"id": "user-2", "name": "Colleague A", "displayName": "colleague", "email": "colleague@example.com"},
	}
	f.issuePages = [][]map[string]any{{issueNode("i-1", "ENG-1", "started", "2026-10-02T00:00:00.000Z")}}
	d, s := newTestSyncer(t, f)
	_, err := d.Exec(`INSERT INTO users (id, name, email) VALUES ('1:U2','colleague','colleague@example.com')`)
	require.NoError(t, err)
	_, err = s.Sync(context.Background())
	require.NoError(t, err)

	assigned := issueNode("i-1", "ENG-1", "started", "2026-10-09T00:00:00.000Z")
	assigned["assignee"] = map[string]any{"id": "user-2", "name": "Colleague A", "email": "colleague@example.com"}
	f.issuePages = [][]map[string]any{{assigned}}
	require.NoError(t, s.RefreshIssue(context.Background(), "i-1"))

	var assigneeSlack string
	require.NoError(t, d.QueryRow(`SELECT assignee_slack_id FROM linear_issues WHERE id='i-1'`).Scan(&assigneeSlack))
	assert.Equal(t, "1:U2", assigneeSlack, "an approved assign shows its Slack assignee at once")
}

func TestSyncer_RefreshIssueNoWatermark(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	f.issuePages = [][]map[string]any{{
		issueNode("i-1", "ENG-1", "started", "2026-10-02T00:00:00.000Z"),
		issueNode("i-2", "ENG-2", "started", "2026-10-03T00:00:00.000Z"),
	}}
	d, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)
	beforeState, err := d.GetLinearSyncState(s.AccountID(), "t-1")
	require.NoError(t, err)
	beforeMoved, err := d.GetLinearMovedWatermark(s.AccountID())
	require.NoError(t, err)

	f.issuePages = [][]map[string]any{{
		issueNode("i-1", "ENG-1", "completed", "2026-10-09T00:00:00.000Z"),
		issueNode("i-2", "ENG-2", "completed", "2026-10-03T00:00:00.000Z"),
	}}
	f.commentPages = [][]map[string]any{{commentNode("c-1", "i-1", "ENG-1", "", "2026-10-09T00:00:00.000Z")}}
	require.NoError(t, s.RefreshIssue(context.Background(), "i-1"))

	issues, _ := d.GetLinearIssueByKey("ENG-1")
	require.Len(t, issues, 1)
	assert.Equal(t, "done", issues[0].StatusCategory)
	var comments int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM linear_comments WHERE id='c-1'`).Scan(&comments))
	assert.Equal(t, 1, comments)
	other, _ := d.GetLinearIssueByKey("ENG-2")
	assert.Equal(t, "in_progress", other[0].StatusCategory, "only the named issue is fetched")

	afterState, _ := d.GetLinearSyncState(s.AccountID(), "t-1")
	assert.Equal(t, beforeState, afterState)
	afterMoved, _ := d.GetLinearMovedWatermark(s.AccountID())
	assert.Equal(t, beforeMoved, afterMoved)
}
