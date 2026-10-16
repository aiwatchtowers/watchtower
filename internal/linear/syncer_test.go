package linear

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSyncer_FirstPassStoresIssuesCommentsAndHistory(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}, {"id": "t-2", "key": "OPS", "name": "Ops"}}
	f.issuePages = [][]map[string]any{{issueNode("i-1", "ENG-1", "started", "2026-10-02T00:00:00.000Z")}}
	f.commentPages = [][]map[string]any{{commentNode("c-1", "i-1", "ENG-1", `{"type":"doc","content":[{"type":"suggestion_userMentions","attrs":{"id":"user-9"}}]}`, "2026-10-03T00:00:00.000Z")}}
	f.users = []map[string]any{{"id": "user-1", "name": "Owner", "displayName": "owner", "email": "owner@example.com"}}
	f.issuePages[0][0]["assignee"] = map[string]any{"id": "user-1", "name": "Owner", "email": "owner@example.com"}
	d, s := newTestSyncer(t, f)
	_, err := d.Exec(`INSERT INTO users (id, name, email) VALUES ('1:U1','owner','Owner@Example.com')`)
	require.NoError(t, err)

	n, err := s.Sync(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	var assigneeSlack string
	require.NoError(t, d.QueryRow(`SELECT assignee_slack_id FROM linear_issues WHERE id='i-1'`).Scan(&assigneeSlack))
	assert.Equal(t, "1:U1", assigneeSlack)

	issues, _ := d.GetLinearIssueByKey("ENG-1")
	require.Len(t, issues, 1)
	assert.Equal(t, "in_progress", issues[0].StatusCategory)
	var mentions string
	require.NoError(t, d.QueryRow(`SELECT mentioned_user_ids FROM linear_comments WHERE id='c-1'`).Scan(&mentions))
	assert.Equal(t, `["user-9"]`, mentions)
	var hist int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM linear_issue_history WHERE field='status'`).Scan(&hist))
	assert.Equal(t, 1, hist)
	// Only the viewer's team was selected and synced; the watermark is the newest
	// issue updatedAt (the newer comment does not raise it, ruling R9).
	st, _ := d.GetLinearSyncState(s.AccountID(), "t-1")
	assert.Equal(t, "2026-10-02T00:00:00.000Z", st.Watermark)
	assert.Empty(t, f.issueFiltersForTeam("t-2"))
	// First pass asked for open issues too.
	assert.Contains(t, f.lastIssueFilterJSON("t-1"), `"nin":["completed","canceled"]`)
}

func TestSyncer_SecondPassUsesWatermark(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	f.issuePages = [][]map[string]any{{issueNode("i-1", "ENG-1", "started", "2026-10-02T00:00:00.000Z")}}
	_, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)
	_, err = s.Sync(context.Background())
	require.NoError(t, err)
	got := f.lastIssueFilterJSON("t-1")
	assert.Contains(t, got, `"gte":"2026-10-02T00:00:00.000Z"`)
	assert.NotContains(t, got, `"nin"`)
}

func TestLinear01_PageErrorHoldsWatermark(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	f.issuePages = [][]map[string]any{
		{issueNode("i-1", "ENG-1", "started", "2026-10-02T00:00:00.000Z")},
		{issueNode("i-2", "ENG-2", "started", "2026-10-04T00:00:00.000Z")},
	}
	f.failIssuePage = 2 // RATELIMITED on the second page
	d, s := newTestSyncer(t, f)
	require.NoError(t, d.RecordLinearSyncSuccess(s.AccountID(), "t-1", "2026-09-01T00:00:00.000Z", "x"))
	_, err := s.Sync(context.Background())
	require.ErrorIs(t, err, ErrRateLimited)
	st, _ := d.GetLinearSyncState(s.AccountID(), "t-1")
	assert.Equal(t, "2026-09-01T00:00:00.000Z", st.Watermark)
	assert.Contains(t, st.LastError, "rate limited")
	got, _ := d.GetLinearIssueByKey("ENG-1") // page 1 is kept: upserts are idempotent
	assert.Len(t, got, 1)
}

// syncTeamWithFailure runs one pass of team t-1 (one good issue page over a
// stored watermark) with the fake's failure hook set by fail, and returns the
// team's watermark, last error and how many issue rows were kept.
func syncTeamWithFailure(t *testing.T, fail func(*fakeLinear)) (watermark, lastErr string, issues int) {
	t.Helper()
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	f.issuePages = [][]map[string]any{{issueNode("i-1", "ENG-1", "started", "2026-10-02T00:00:00.000Z")}}
	fail(f)
	d, s := newTestSyncer(t, f)
	require.NoError(t, d.RecordLinearSyncSuccess(s.AccountID(), "t-1", "2026-09-01T00:00:00.000Z", "x"))
	_, err := s.Sync(context.Background())
	require.Error(t, err)
	st, err := d.GetLinearSyncState(s.AccountID(), "t-1")
	require.NoError(t, err)
	got, err := d.GetLinearIssueByKey("ENG-1")
	require.NoError(t, err)
	return st.Watermark, st.LastError, len(got)
}

func TestLinear01_CommentFailureHoldsWatermark(t *testing.T) {
	watermark, lastErr, issues := syncTeamWithFailure(t, func(f *fakeLinear) { f.failComments = true })
	assert.Equal(t, "2026-09-01T00:00:00.000Z", watermark)
	assert.Contains(t, lastErr, "comments unavailable")
	assert.Equal(t, 1, issues) // the issue page that succeeded is kept
}

func TestLinear01_PlanningFailureHoldsWatermark(t *testing.T) {
	watermark, lastErr, issues := syncTeamWithFailure(t, func(f *fakeLinear) { f.failPlanning = true })
	assert.Equal(t, "2026-09-01T00:00:00.000Z", watermark)
	assert.Contains(t, lastErr, "planning unavailable")
	assert.Equal(t, 1, issues)
}

func TestLinear04_TeamMoveKeepsOneRow(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	f.issuePages = [][]map[string]any{{issueNode("i-1", "ENG-12", "unstarted", "2026-10-02T00:00:00.000Z")}}
	d, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)
	moved := issueNode("i-1", "OPS-40", "unstarted", "2026-10-05T00:00:00.000Z")
	moved["previousIdentifiers"] = []string{"ENG-12"}
	f.issuePages = [][]map[string]any{{moved}}
	_, err = s.Sync(context.Background())
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM linear_issues WHERE id='i-1'`).Scan(&n))
	assert.Equal(t, 1, n)
	got, _ := d.GetLinearIssueByKey("ENG-12")
	require.Len(t, got, 1)
	assert.Equal(t, "OPS-40", got[0].Key)
}

func TestLinear04_MoveToUnselectedTeamIsReconciled(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"} // OPS (t-2) stays unselected
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}, {"id": "t-2", "key": "OPS", "name": "Ops"}}
	f.issuePages = [][]map[string]any{{issueNode("i-1", "ENG-12", "unstarted", "2026-10-02T00:00:00.000Z")}}
	d, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)
	assert.Zero(t, f.calls["issueIDs"], "a first pass has nothing stored that could have moved")

	moved := issueNode("i-1", "OPS-40", "started", "2026-10-05T00:00:00.000Z")
	moved["previousIdentifiers"] = []string{"ENG-12"}
	moved["team"] = map[string]any{"id": "t-2", "key": "OPS"}
	stranger := issueNode("i-9", "OPS-41", "started", "2026-10-05T00:00:00.000Z")
	stranger["team"] = map[string]any{"id": "t-2", "key": "OPS"}
	f.issuePages = [][]map[string]any{{moved, stranger}}
	f.commentPages = [][]map[string]any{{commentNode("c-1", "i-1", "OPS-40", "", "2026-10-06T00:00:00.000Z")}}
	_, err = s.Sync(context.Background())
	require.NoError(t, err)

	var key, team, state string
	require.NoError(t, d.QueryRow(`SELECT key, team_id, state_type FROM linear_issues WHERE id='i-1'`).Scan(&key, &team, &state))
	assert.Equal(t, []string{"OPS-40", "t-2", "started"}, []string{key, team, state})
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM linear_issues WHERE id='i-9'`).Scan(&n))
	assert.Zero(t, n, "an issue of an unselected team that was never stored is not fetched")
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM linear_comments WHERE id='c-1'`).Scan(&n))
	assert.Equal(t, 1, n)

	f.mu.Lock()
	defer f.mu.Unlock()
	var lookup map[string]any
	for _, r := range f.requests {
		if r.Kind == "issueIDs" {
			lookup, _ = r.Vars["filter"].(map[string]any)
		}
	}
	b, _ := json.Marshal(lookup)
	assert.JSONEq(t, `{"team":{"id":{"nin":["t-1"]}},"updatedAt":{"gte":"2026-10-02T00:00:00.000Z"}}`, string(b))
}

func TestSyncer_ArchivedIssueIsDeleted(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	node := issueNode("i-1", "ENG-1", "completed", "2026-10-02T00:00:00.000Z")
	node["archivedAt"] = "2026-10-02T00:00:00.000Z"
	f.issuePages = [][]map[string]any{{node}}
	d, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)
	var del int
	require.NoError(t, d.QueryRow(`SELECT is_deleted FROM linear_issues WHERE id='i-1'`).Scan(&del))
	assert.Equal(t, 1, del)
}

func TestSyncer_AuthRevokedAbortsPass(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1", "t-2"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG"}, {"id": "t-2", "key": "OPS"}}
	f.alwaysUnauthorized = true
	_, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	assert.ErrorIs(t, err, ErrAuthRevoked)
}

func TestSyncer_FirstPassSinceIsBackfillWindow(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	_, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)
	// now (2026-10-10) - 30 backfill days.
	assert.Contains(t, f.lastIssueFilterJSON("t-1"), `"gte":"2026-09-10T00:00:00.000Z"`)
}

func TestLinear01_QuietTeamRecordsSinceAsWatermark(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	d, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)
	st, _ := d.GetLinearSyncState(s.AccountID(), "t-1")
	assert.Equal(t, "2026-09-10T00:00:00.000Z", st.Watermark) // the backfill since
	_, err = s.Sync(context.Background())
	require.NoError(t, err)
	got := f.lastIssueFilterJSON("t-1")
	assert.Contains(t, got, `"gte":"2026-09-10T00:00:00.000Z"`)
	assert.NotContains(t, got, `"nin"`)
}

func TestSyncer_StoresPlanningAndUsers(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	f.cycles = []map[string]any{{"id": "cy-1", "number": 7, "name": "Cycle 7", "startsAt": "2026-10-01T00:00:00.000Z",
		"endsAt": "2026-10-15T00:00:00.000Z", "completedAt": nil, "progress": 0.5}}
	f.projects = []map[string]any{{"id": "pr-1", "name": "Launch", "state": "started", "progress": 0.25,
		"targetDate": "2026-12-01", "url": "https://linear.app/acme/project/launch", "lead": map[string]any{"id": "user-1"}}}
	f.users = []map[string]any{{"id": "user-2", "name": "Colleague A", "displayName": "a", "email": "a@example.com"}}
	d, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)
	var cycleTeam string
	var number int
	require.NoError(t, d.QueryRow(`SELECT team_id, number FROM linear_cycles WHERE id='cy-1'`).Scan(&cycleTeam, &number))
	assert.Equal(t, "t-1", cycleTeam)
	assert.Equal(t, 7, number)
	var lead string
	require.NoError(t, d.QueryRow(`SELECT lead_id FROM linear_projects WHERE id='pr-1'`).Scan(&lead))
	assert.Equal(t, "user-1", lead)
	var email string
	require.NoError(t, d.QueryRow(`SELECT email FROM linear_user_map WHERE linear_user_id='user-2'`).Scan(&email))
	assert.Equal(t, "a@example.com", email)
}

func TestFetchViewer(t *testing.T) {
	f := newFakeLinear(t)
	_, s := newTestSyncer(t, f)
	v, err := s.client.FetchViewer(context.Background())
	require.NoError(t, err)
	assert.Equal(t, Viewer{UserID: "user-1", Email: "owner@example.com", Name: "Owner",
		OrgID: "org-1", OrgName: "Acme", URLKey: "acme"}, v)
}

func decodeIssue(t *testing.T, node map[string]any) issueNodeJSON {
	t.Helper()
	raw, err := json.Marshal(node)
	require.NoError(t, err)
	var n issueNodeJSON
	require.NoError(t, json.Unmarshal(raw, &n))
	n.raw = raw
	return n
}

func TestMapIssue_HistoryRelationsAndStateChange(t *testing.T) {
	node := issueNode("i-1", "ENG-1", "started", "2026-10-02T00:00:00.000Z")
	node["startedAt"] = "2026-09-20T00:00:00.000Z"
	node["labels"] = map[string]any{"nodes": []any{map[string]any{"name": "bug"}}}
	node["relations"] = map[string]any{"nodes": []any{
		map[string]any{"id": "r-1", "type": "blocks", "relatedIssue": map[string]any{"id": "i-2"}},
		map[string]any{"id": "r-2", "type": "similar", "relatedIssue": map[string]any{"id": "i-3"}},
	}}
	node["history"] = map[string]any{"nodes": []any{
		map[string]any{"id": "h-1", "createdAt": "2026-09-25T00:00:00.000Z",
			"toState":    map[string]any{"id": "s-1", "name": "Doing"},
			"toAssignee": map[string]any{"id": "user-2", "name": "Colleague A"}},
		map[string]any{"id": "h-2", "createdAt": "2026-09-26T00:00:00.000Z",
			"fromAssignee": map[string]any{"id": "user-2", "name": "Colleague A"}},
	}}
	n := decodeIssue(t, node)

	issue := mapIssue(7, n)
	assert.Equal(t, int64(7), issue.AccountID)
	assert.Equal(t, "2026-09-25T00:00:00.000Z", issue.StateChangedAt)
	assert.Equal(t, []string{"bug"}, issue.Labels)
	assert.Equal(t, "ENG", issue.TeamKey)
	assert.False(t, issue.IsDeleted)
	assert.JSONEq(t, string(n.raw), issue.RawJSON)

	hist := mapHistory(7, n)
	require.Len(t, hist, 3) // h-1 yields status + assignee
	assert.Equal(t, "status", hist[0].Field)
	assert.Equal(t, "Doing", hist[0].ToString)
	assert.Equal(t, "assignee", hist[1].Field)
	assert.Equal(t, "user-2", hist[1].ToValue)
	assert.Equal(t, "assignee", hist[2].Field)
	assert.Equal(t, "user-2", hist[2].FromValue)

	rels := mapRelations(n)
	require.Len(t, rels, 1)
	assert.Equal(t, "i-2", rels[0].RelatedIssueID)

	// No status history: a started issue falls back to startedAt.
	node["history"] = map[string]any{"nodes": []any{}}
	assert.Equal(t, "2026-09-20T00:00:00.000Z", mapIssue(7, decodeIssue(t, node)).StateChangedAt)
	// ... a completed one to completedAt, a canceled one to canceledAt.
	node["completedAt"] = "2026-09-22T00:00:00.000Z"
	node["canceledAt"] = "2026-09-23T00:00:00.000Z"
	node["state"] = map[string]any{"name": "Done", "type": "completed"}
	assert.Equal(t, "2026-09-22T00:00:00.000Z", mapIssue(7, decodeIssue(t, node)).StateChangedAt)
	node["state"] = map[string]any{"name": "Canceled", "type": "canceled"}
	assert.Equal(t, "2026-09-23T00:00:00.000Z", mapIssue(7, decodeIssue(t, node)).StateChangedAt)
	node["state"] = map[string]any{"name": "Todo", "type": "unstarted"}
	assert.Empty(t, mapIssue(7, decodeIssue(t, node)).StateChangedAt)

	// A move within one category does not count, as in Jira: In Progress →
	// In Review (both started) keeps the Todo → In Progress time.
	node["state"] = map[string]any{"name": "In Review", "type": "started"}
	node["history"] = map[string]any{"nodes": []any{
		map[string]any{"id": "h-1", "createdAt": "2026-09-25T00:00:00.000Z",
			"fromState": map[string]any{"id": "s-0", "name": "Todo", "type": "unstarted"},
			"toState":   map[string]any{"id": "s-1", "name": "In Progress", "type": "started"}},
		map[string]any{"id": "h-3", "createdAt": "2026-09-28T00:00:00.000Z",
			"fromState": map[string]any{"id": "s-1", "name": "In Progress", "type": "started"},
			"toState":   map[string]any{"id": "s-2", "name": "In Review", "type": "started"}},
	}}
	assert.Equal(t, "2026-09-25T00:00:00.000Z", mapIssue(7, decodeIssue(t, node)).StateChangedAt)
	// Only in-category moves in the history: the category's own timestamp.
	node["history"] = map[string]any{"nodes": []any{
		map[string]any{"id": "h-3", "createdAt": "2026-09-28T00:00:00.000Z",
			"fromState": map[string]any{"id": "s-1", "name": "In Progress", "type": "started"},
			"toState":   map[string]any{"id": "s-2", "name": "In Review", "type": "started"}},
	}}
	assert.Equal(t, "2026-09-20T00:00:00.000Z", mapIssue(7, decodeIssue(t, node)).StateChangedAt)
	node["state"] = map[string]any{"name": "Todo", "type": "unstarted"}
	node["trashed"] = true
	assert.True(t, mapIssue(7, decodeIssue(t, node)).IsDeleted)
}

func TestLinear01_CommentsDoNotRaiseWatermark(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	f.issuePages = [][]map[string]any{{issueNode("i-1", "ENG-1", "started", "2026-10-02T00:00:00.000Z")}}
	f.commentPages = [][]map[string]any{{commentNode("c-1", "i-1", "ENG-1", "", "2026-10-06T00:00:00.000Z")}}
	d, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)
	st, _ := d.GetLinearSyncState(s.AccountID(), "t-1")
	assert.Equal(t, "2026-10-02T00:00:00.000Z", st.Watermark)
	_, err = s.Sync(context.Background())
	require.NoError(t, err)
	assert.Contains(t, f.lastIssueFilterJSON("t-1"), `"gte":"2026-10-02T00:00:00.000Z"`)
}
