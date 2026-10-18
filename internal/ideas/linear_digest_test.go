package ideas

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func lt(tm time.Time) string { return db.FormatJiraTime(tm.UTC()) }

func seedLinearIssueIdeas(t *testing.T, d *db.DB, accountID int64, id, key, team, title, state, desc, updatedAt string) {
	t.Helper()
	require.NoError(t, d.UpsertLinearIssue(db.LinearIssue{
		AccountID: accountID, ID: id, Key: key, TeamKey: team, Title: title, StateName: state,
		StatusCategory: "todo", DescriptionText: desc, CreatedAt: updatedAt, UpdatedAt: updatedAt,
	}))
}

func seedLinearCommentIdeas(t *testing.T, d *db.DB, accountID int64, issueID, key, id, author, body, updatedAt string) {
	t.Helper()
	require.NoError(t, d.UpsertLinearComment(db.LinearComment{
		AccountID: accountID, ID: id, IssueID: issueID, IssueKey: key, AuthorDisplayName: author,
		BodyText: body, CreatedAt: updatedAt, UpdatedAt: updatedAt,
	}))
}

// A Linear workspace's changed issues (and their new comments) are mined into
// a stream_digests(source='linear') row and the floor moves to the newest
// rendered issue.
func TestRunLinearDigests_InsertsRowAndAdvancesFloor(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour)
	acct := db.SeedLinearTestAccount(t, d)
	require.NoError(t, d.SetIdeasLinearFloor(acct, lt(base)))
	u1, u2 := lt(base.Add(10*time.Second)), lt(base.Add(20*time.Second))
	seedLinearIssueIdeas(t, d, acct, "i1", "ENG-1", "ENG", "Add caching layer", "Todo", "We should add caching.", u1)
	seedLinearIssueIdeas(t, d, acct, "i2", "ENG-2", "ENG", "Ship v2", "Done", "Shipping v2.", u2)
	seedLinearCommentIdeas(t, d, acct, "i2", "ENG-2", "c1", "Bob", "Agreed, we decided to ship v2 this week.", u2)

	var seen string
	gen := &fakeGen{reply: func(user string) (string, error) {
		seen = user
		return `{"topics":[{"title":"Ship v2","summary":"s","ideas":[{"text":"add caching","author":"Ann","ref":"ENG-1"}],
			"decisions":[{"text":"ship v2 this week","author":"Bob","ref":"ENG-2"},{"text":"invented","author":"X","ref":"ENG-99"}]}]}`, nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	require.NoError(t, p.runLinearDigests(context.Background(), time.Time{}))
	require.Equal(t, 1, gen.calls)
	assert.Contains(t, seen, "=== PROJECT ENG ===")
	assert.Contains(t, seen, "Bob: Agreed, we decided to ship v2 this week.", "the new comment is rendered")

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	require.Len(t, digests, 1)
	assert.Equal(t, "linear", digests[0].Source)
	assert.Equal(t, acct, digests[0].AccountID)
	assert.Contains(t, digests[0].TopicsJSON, `"ref":"ENG-2"`)
	assert.NotContains(t, digests[0].TopicsJSON, "ENG-99", "IDEA-02: a ref the model was not shown is dropped")

	floor, err := d.IdeasLinearFloor(acct)
	require.NoError(t, err)
	assert.Equal(t, u2, floor)
}

// IDEA-01: a generator error writes no row and leaves the floor where it was.
func TestIdeas01_LinearGeneratorErrorNoRowFloorUnchanged(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour)
	acct := db.SeedLinearTestAccount(t, d)
	require.NoError(t, d.SetIdeasLinearFloor(acct, lt(base)))
	seedLinearIssueIdeas(t, d, acct, "i1", "ENG-1", "ENG", "t", "Todo", "d", lt(base.Add(time.Second)))

	gen := &fakeGen{reply: func(string) (string, error) { return "", fmt.Errorf("boom") }}
	p := New(d, testCfg(), gen, testLogger())
	require.Error(t, p.runLinearDigests(context.Background(), time.Time{}))

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	assert.Empty(t, digests)
	floor, err := d.IdeasLinearFloor(acct)
	require.NoError(t, err)
	assert.Equal(t, lt(base), floor)
}

// IDEA-01: an empty floor initializes without mining (no backfill); nothing
// changed above the floor is a clean no-op (no AI call, no row, floor kept).
func TestIdeas01_LinearInitAndNoChangedIssuesCleanNoOp(t *testing.T) {
	d := newTestDB(t)
	acct := db.SeedLinearTestAccount(t, d)
	seedLinearIssueIdeas(t, d, acct, "i1", "ENG-1", "ENG", "old", "Todo", "d", lt(time.Now().Add(-48*time.Hour)))
	gen := &fakeGen{reply: func(string) (string, error) { return `{"topics":[]}`, nil }}
	p := New(d, testCfg(), gen, testLogger())

	require.NoError(t, p.runLinearDigests(context.Background(), time.Time{}))
	floor, err := d.IdeasLinearFloor(acct)
	require.NoError(t, err)
	require.NotEmpty(t, floor, "the first run initializes the floor")
	assert.Zero(t, gen.calls, "and mines nothing")

	require.NoError(t, p.runLinearDigests(context.Background(), time.Time{}))
	again, err := d.IdeasLinearFloor(acct)
	require.NoError(t, err)
	assert.Equal(t, floor, again)
	assert.Zero(t, gen.calls)
}

// IDEA-01: the floor stops at the first issue the prompt budget dropped, never
// at the newest rendered one (the Jira rule, shared code).
func TestIdeas01_LinearFloorStopsAtBudgetDroppedIssue(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour)
	acct := db.SeedLinearTestAccount(t, d)
	floor := lt(base)
	require.NoError(t, d.SetIdeasLinearFloor(acct, floor))
	u1, u2, u3 := lt(base.Add(10*time.Second)), lt(base.Add(20*time.Second)), lt(base.Add(30*time.Second))
	seedLinearIssueIdeas(t, d, acct, "i1", "ENG-1", "ENG", "first", "Todo", "desc", u1)
	seedLinearIssueIdeas(t, d, acct, "i2", "OPS-1", "OPS", "second team", "Todo", "desc", u2)
	seedLinearIssueIdeas(t, d, acct, "i3", "ENG-2", "ENG", "third", "Todo", "desc", u3)

	issues, err := d.ListLinearIssuesUpdatedSince(acct, floor, "", jiraIssuesPerAccountLimit)
	require.NoError(t, err)
	require.Len(t, issues, 3)
	units, _, err := New(d, testCfg(), nil, testLogger()).linearUnits(acct, issues, floor)
	require.NoError(t, err)
	engOnly, _ := renderJiraBlock([]db.JiraIssue{units[0], units[2]}, nil, 1000000, "")

	gen := &fakeGen{reply: jiraTopicsFor("ENG-1", "ENG-2")}
	p := New(d, testCfgWithBudget(len(engOnly)), gen, testLogger())
	require.NoError(t, p.runLinearDigests(context.Background(), time.Time{}))

	got, err := d.IdeasLinearFloor(acct)
	require.NoError(t, err)
	assert.Equal(t, u1, got, "the floor must stop below the dropped OPS-1")
}

// IDEA-01 / spec §5: a selected team whose latest sync failed holds the
// account's floor at its last successful sync, so its changes are mined once
// it recovers.
func TestIdeas01_LinearFloorHeldBackByFailingTeam(t *testing.T) {
	d := newTestDB(t)
	now := time.Now().UTC()
	acct := db.SeedLinearTestAccount(t, d)
	require.NoError(t, d.UpsertLinearTeams(acct, []db.LinearTeam{{ID: "ta", Key: "AAA"}, {ID: "tb", Key: "BBB"}},
		map[string]bool{"ta": true, "tb": true}))
	require.NoError(t, d.SetIdeasLinearFloor(acct, lt(now.Add(-3*time.Hour))))
	require.NoError(t, d.RecordLinearSyncSuccess(acct, "ta", "", lt(now.Add(-5*time.Minute))))
	require.NoError(t, d.RecordLinearSyncSuccess(acct, "tb", "", lt(now.Add(-time.Hour))))
	require.NoError(t, d.RecordLinearSyncError(acct, "tb", "boom"))

	seedLinearIssueIdeas(t, d, acct, "a1", "AAA-1", "AAA", "old A", "Todo", "x", lt(now.Add(-2*time.Hour)))
	seedLinearIssueIdeas(t, d, acct, "a2", "AAA-2", "AAA", "fresh A", "Todo", "x", lt(now.Add(-10*time.Minute)))

	p := New(d, testCfg(), &fakeGen{reply: jiraTopicsFor("AAA-1", "AAA-2")}, testLogger())
	require.NoError(t, p.runLinearDigests(context.Background(), time.Time{}))
	floor, err := d.IdeasLinearFloor(acct)
	require.NoError(t, err)
	assert.Equal(t, lt(now.Add(-2*time.Hour)), floor, "the floor stops below team B's last successful sync")
}

// The consolidator mints a mention of a Linear stream candidate with source
// 'linear' and its bare key as the ref, so get_task_context can find it.
func TestConsolidate_LinearStreamMentionCarriesLinearSource(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	acct := db.SeedLinearTestAccount(t, d)
	seedStreamDigestIdeas(t, d, "linear", acct, []streamTopic{{
		Title: "Caching", Summary: "s",
		Decisions: []streamCandidate{{Text: "ship caching", Author: "Ann", Ref: "ENG-1"}},
	}})
	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"ops":[{"op":"new_decision","title":"Ship caching","essence":"e",
			"mentions":[{"source":"jira","ref":"ENG-1","quote":"ship caching","author":"Ann","said_at":"2026-08-01T00:00:00Z"}]}]}`, nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	_, _, err := p.runConsolidate(context.Background())
	require.NoError(t, err)

	ideas, err := d.ListIdeasByMentionRef("linear", "ENG-1", 10)
	require.NoError(t, err)
	require.Len(t, ideas, 1, "the mention's source comes from the stream row, never from the model")
}
