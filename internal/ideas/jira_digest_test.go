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

// seedJiraAccount inserts an enabled jira_accounts row and returns its id.
func seedJiraAccount(t *testing.T, database *db.DB) int64 {
	t.Helper()
	id, err := database.CreateJiraAccount(db.JiraAccount{
		CloudID: fmt.Sprintf("cloud-%d", time.Now().UnixNano()),
		SiteURL: "https://example.atlassian.net",
		Label:   "Test",
	})
	require.NoError(t, err)
	return id
}

// setIdeasJiraFloorRaw seeds an account's ideas_jira_floor directly,
// bypassing the pipeline's own empty-floor init-and-skip pass.
func setIdeasJiraFloorRaw(t *testing.T, database *db.DB, accountID int64, floor string) {
	t.Helper()
	_, err := database.Exec(`UPDATE jira_accounts SET ideas_jira_floor = ? WHERE id = ?`, floor, accountID)
	require.NoError(t, err)
}

func seedJiraIssueIdeas(t *testing.T, database *db.DB, accountID int64, key, projectKey, summary, status, statusCategory, description, updatedAt string) {
	t.Helper()
	_, err := database.Exec(`INSERT INTO jira_issues
		(account_id, key, id, project_key, board_id, summary, description_text, status, status_category, sprint_id, created_at, updated_at, synced_at)
		VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, 0, ?, ?, ?)`,
		accountID, key, key, projectKey, summary, description, status, statusCategory, updatedAt, updatedAt, updatedAt)
	require.NoError(t, err)
}

func seedJiraCommentIdeas(t *testing.T, database *db.DB, accountID int64, issueKey, id, author, body, updatedAt string) {
	t.Helper()
	require.NoError(t, database.UpsertJiraComments([]db.JiraComment{{
		AccountID: accountID, IssueKey: issueKey, ID: id, Author: author,
		BodyText: body, CreatedAt: updatedAt, UpdatedAt: updatedAt,
	}}))
}

func TestRunJiraDigests_InsertsRowAndAdvancesFloor(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour)
	acctID := seedJiraAccount(t, d)
	floor := base.Format(time.RFC3339)
	setIdeasJiraFloorRaw(t, d, acctID, floor)

	u1 := base.Add(10 * time.Second).Format(time.RFC3339)
	u2 := base.Add(20 * time.Second).Format(time.RFC3339)
	seedJiraIssueIdeas(t, d, acctID, "WT-1", "WT", "Add caching layer", "Open", "new", "We should add a caching layer.", u1)
	seedJiraIssueIdeas(t, d, acctID, "WT-2", "WT", "Ship v2", "Done", "done", "Shipping v2 today.", u2)
	seedJiraCommentIdeas(t, d, acctID, "WT-2", "c1", "Bob", "Agreed, we decided to ship v2 this week.", u2)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"topics":[
			{"title":"Caching","summary":"s","ideas":[{"text":"add a caching layer","author":"Ann","ref":"WT-1"}],"decisions":[]},
			{"title":"Ship v2","summary":"s2","ideas":[],"decisions":[{"text":"ship v2 this week","author":"Bob","ref":"WT-2"}]}
		]}`, nil
	}}

	p := New(d, testCfg(), gen, testLogger())
	err := p.runJiraDigests(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, gen.calls)

	digests, err := d.ListStreamDigestsAfter(0)
	require.NoError(t, err)
	require.Len(t, digests, 1)
	sd := digests[0]
	assert.Equal(t, "jira", sd.Source)
	assert.Equal(t, acctID, sd.AccountID)
	assert.Equal(t, "", sd.Scope)
	assert.Contains(t, sd.TopicsJSON, `"ref":"WT-1"`)
	assert.Contains(t, sd.TopicsJSON, `"ref":"WT-2"`)

	newFloor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, u2, newFloor)
}

func TestRunJiraDigests_GeneratorError_NoRowFloorUnchanged(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour)
	acctID := seedJiraAccount(t, d)
	floor := base.Format(time.RFC3339)
	setIdeasJiraFloorRaw(t, d, acctID, floor)
	u1 := base.Add(10 * time.Second).Format(time.RFC3339)
	seedJiraIssueIdeas(t, d, acctID, "WT-1", "WT", "Add caching layer", "Open", "new", "desc", u1)

	gen := &fakeGen{reply: func(string) (string, error) { return "", fmt.Errorf("boom") }}
	p := New(d, testCfg(), gen, testLogger())
	err := p.runJiraDigests(context.Background())
	require.Error(t, err)

	digests, err := d.ListStreamDigestsAfter(0)
	require.NoError(t, err)
	assert.Empty(t, digests)

	newFloor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, floor, newFloor)
}

// TestRunJiraDigests_NoChangedIssues_CleanNoOp covers the degenerate
// zero-new-material branch (see feedback_test_degenerate_clean_exit): an
// already-initialized account with no issue updated past its floor must not
// call the generator, insert a row, or touch the floor.
func TestRunJiraDigests_NoChangedIssues_CleanNoOp(t *testing.T) {
	d := newTestDB(t)
	acctID := seedJiraAccount(t, d)
	floor := time.Now().Add(-time.Hour).Format(time.RFC3339)
	setIdeasJiraFloorRaw(t, d, acctID, floor)

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called with no changed issues")
		return "", nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	err := p.runJiraDigests(context.Background())
	require.NoError(t, err)
	assert.Zero(t, gen.calls)

	digests, err := d.ListStreamDigestsAfter(0)
	require.NoError(t, err)
	assert.Empty(t, digests)

	newFloor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, floor, newFloor)
}

// TestRunJiraDigests_FloorEmpty_InitializesAndSkips covers the no-backfill
// first-run path: a never-initialized account skips extraction entirely and
// just sets its floor to now.
func TestRunJiraDigests_FloorEmpty_InitializesAndSkips(t *testing.T) {
	d := newTestDB(t)
	acctID := seedJiraAccount(t, d) // ideas_jira_floor defaults to ""
	old := time.Now().Add(-24 * time.Hour).Format(time.RFC3339)
	seedJiraIssueIdeas(t, d, acctID, "WT-1", "WT", "Old issue", "Open", "new", "desc", old)

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called on the init pass")
		return "", nil
	}}
	before := time.Now()
	p := New(d, testCfg(), gen, testLogger())
	err := p.runJiraDigests(context.Background())
	require.NoError(t, err)
	assert.Zero(t, gen.calls)

	newFloor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	require.NotEmpty(t, newFloor)
	// The floor is now formatted in Jira's own dotted-millisecond layout
	// (jiraFloorInitLayout), not bare RFC3339 — round-1 review Finding 1.
	parsed, perr := time.Parse(jiraFloorInitLayout, newFloor)
	require.NoError(t, perr)
	assert.WithinDuration(t, before, parsed, 2*time.Minute, "floor should initialize near now (minus the backoff), got %s", newFloor)

	digests, err := d.ListStreamDigestsAfter(0)
	require.NoError(t, err)
	assert.Empty(t, digests)
}

// TestRunJiraDigests_FloorInit_SameSecondIssueNotExcluded proves round-1
// review Finding 1 is fixed: an issue updated within a couple of seconds of
// the init instant — rendered in Jira's own dotted-millisecond format, which
// used to lexically sort BELOW a bare RFC3339 "...Z" floor — is not silently
// excluded from the very next real pass.
func TestRunJiraDigests_FloorInit_SameSecondIssueNotExcluded(t *testing.T) {
	d := newTestDB(t)
	acctID := seedJiraAccount(t, d)

	// First pass: floor is empty, so this only initializes it (no AI call).
	initGen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called on the init pass")
		return "", nil
	}}
	p := New(d, testCfg(), initGen, testLogger())
	require.NoError(t, p.runJiraDigests(context.Background()))
	require.Zero(t, initGen.calls)

	// An issue updated an instant after initialization, in Jira's raw
	// dotted-millisecond format — the exact shape that used to compare as
	// lexically "before" a bare RFC3339 floor and get silently dropped.
	updatedAt := time.Now().UTC().Add(time.Second).Format(jiraFloorInitLayout)
	seedJiraIssueIdeas(t, d, acctID, "WT-1", "WT", "Same-second issue", "Open", "new", "desc", updatedAt)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"topics":[{"title":"t","summary":"s","ideas":[{"text":"idea","author":"Ann","ref":"WT-1"}],"decisions":[]}]}`, nil
	}}
	p2 := New(d, testCfg(), gen, testLogger())
	require.NoError(t, p2.runJiraDigests(context.Background()))
	assert.Equal(t, 1, gen.calls)

	digests, err := d.ListStreamDigestsAfter(0)
	require.NoError(t, err)
	require.Len(t, digests, 1)
	assert.Contains(t, digests[0].TopicsJSON, `"ref":"WT-1"`)

	newFloor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, updatedAt, newFloor)
}

// TestRunJiraDigests_HallucinatedRef_Dropped covers ref validation: a
// candidate whose ref is not a bare key from the rendered block is dropped,
// but the pass still completes normally (row inserted, floor advanced).
func TestRunJiraDigests_HallucinatedRef_Dropped(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour)
	acctID := seedJiraAccount(t, d)
	setIdeasJiraFloorRaw(t, d, acctID, base.Format(time.RFC3339))
	u1 := base.Add(10 * time.Second).Format(time.RFC3339)
	seedJiraIssueIdeas(t, d, acctID, "WT-1", "WT", "Real issue", "Open", "new", "desc", u1)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"topics":[{"title":"t","summary":"s","ideas":[{"text":"invented","author":"Ann","ref":"WT-999"}],"decisions":[]}]}`, nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	err := p.runJiraDigests(context.Background())
	require.NoError(t, err)

	digests, err := d.ListStreamDigestsAfter(0)
	require.NoError(t, err)
	require.Len(t, digests, 1)
	assert.Equal(t, "[]", digests[0].TopicsJSON)

	newFloor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, u1, newFloor)
}
