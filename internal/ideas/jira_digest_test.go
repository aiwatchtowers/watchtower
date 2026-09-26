package ideas

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// jiraTimeLayoutForTest is Jira Cloud's timestamp layout, spelled out
// independently of the production db.FormatJiraTime so an assertion about the
// stored format still fails if production drifts.
const jiraTimeLayoutForTest = "2006-01-02T15:04:05.000-0700"

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
	err := p.runJiraDigests(context.Background(), time.Time{})
	require.NoError(t, err)
	assert.Equal(t, 1, gen.calls)

	digests, err := d.ListStreamDigestsAfter(0, "")
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

func TestIdeas01_JiraGeneratorErrorNoRowFloorUnchanged(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour)
	acctID := seedJiraAccount(t, d)
	floor := base.Format(time.RFC3339)
	setIdeasJiraFloorRaw(t, d, acctID, floor)
	u1 := base.Add(10 * time.Second).Format(time.RFC3339)
	seedJiraIssueIdeas(t, d, acctID, "WT-1", "WT", "Add caching layer", "Open", "new", "desc", u1)

	gen := &fakeGen{reply: func(string) (string, error) { return "", fmt.Errorf("boom") }}
	p := New(d, testCfg(), gen, testLogger())
	err := p.runJiraDigests(context.Background(), time.Time{})
	require.Error(t, err)

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	assert.Empty(t, digests)

	newFloor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, floor, newFloor)
}

// TestIdeas01_JiraNoChangedIssuesCleanNoOp covers the degenerate
// zero-new-material branch (see feedback_test_degenerate_clean_exit): an
// already-initialized account with no issue updated past its floor must not
// call the generator, insert a row, or touch the floor.
func TestIdeas01_JiraNoChangedIssuesCleanNoOp(t *testing.T) {
	d := newTestDB(t)
	acctID := seedJiraAccount(t, d)
	floor := time.Now().Add(-time.Hour).Format(time.RFC3339)
	setIdeasJiraFloorRaw(t, d, acctID, floor)

	gen := &fakeGen{reply: func(string) (string, error) {
		t.Fatal("generator must not be called with no changed issues")
		return "", nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	err := p.runJiraDigests(context.Background(), time.Time{})
	require.NoError(t, err)
	assert.Zero(t, gen.calls)

	digests, err := d.ListStreamDigestsAfter(0, "")
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
	err := p.runJiraDigests(context.Background(), time.Time{})
	require.NoError(t, err)
	assert.Zero(t, gen.calls)

	newFloor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	require.NotEmpty(t, newFloor)
	// The floor is formatted in Jira's own dotted-millisecond layout
	// (db.FormatJiraTime), not bare RFC3339 — round-1 review Finding 1. The
	// layout is spelled out here rather than reusing the production helper, so
	// the assertion would still catch the production side silently changing.
	parsed, perr := time.Parse(jiraTimeLayoutForTest, newFloor)
	require.NoError(t, perr)
	assert.WithinDuration(t, before, parsed, 2*time.Minute, "floor should initialize near now (minus the backoff), got %s", newFloor)

	digests, err := d.ListStreamDigestsAfter(0, "")
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
	require.NoError(t, p.runJiraDigests(context.Background(), time.Time{}))
	require.Zero(t, initGen.calls)

	// An issue updated an instant after initialization, in Jira's raw
	// dotted-millisecond format — the exact shape that used to compare as
	// lexically "before" a bare RFC3339 floor and get silently dropped.
	updatedAt := db.FormatJiraTime(time.Now().UTC().Add(time.Second))
	seedJiraIssueIdeas(t, d, acctID, "WT-1", "WT", "Same-second issue", "Open", "new", "desc", updatedAt)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"topics":[{"title":"t","summary":"s","ideas":[{"text":"idea","author":"Ann","ref":"WT-1"}],"decisions":[]}]}`, nil
	}}
	p2 := New(d, testCfg(), gen, testLogger())
	require.NoError(t, p2.runJiraDigests(context.Background(), time.Time{}))
	assert.Equal(t, 1, gen.calls)

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	require.Len(t, digests, 1)
	assert.Contains(t, digests[0].TopicsJSON, `"ref":"WT-1"`)

	newFloor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, updatedAt, newFloor)
}

// TestGB4_JiraStreamPeriodNormalizedToRFC3339UTC pins GB4: a Jira account's
// raw updated_at timestamps (dotted-ms with a non-UTC offset, e.g. "+0300")
// must land in stream_digests.period_from/period_to as plain RFC3339 UTC —
// the same format the Gmail pre-digest pass already writes — so
// ListStreamDigestsAfter/HasStreamDigestCovering's plain string comparisons
// stay format-safe across both sources.
func TestGB4_JiraStreamPeriodNormalizedToRFC3339UTC(t *testing.T) {
	d := newTestDB(t)
	acctID := seedJiraAccount(t, d)
	floor := "2026-08-01T10:00:00.000+0300"
	setIdeasJiraFloorRaw(t, d, acctID, floor)
	updatedAt := "2026-08-01T12:30:00.000+0300"
	seedJiraIssueIdeas(t, d, acctID, "WT-1", "WT", "Issue", "Open", "new", "desc", updatedAt)

	gen := &fakeGen{reply: func(string) (string, error) {
		return `{"topics":[{"title":"t","summary":"s","ideas":[{"text":"i","author":"Ann","ref":"WT-1"}],"decisions":[]}]}`, nil
	}}
	p := New(d, testCfg(), gen, testLogger())
	require.NoError(t, p.runJiraDigests(context.Background(), time.Time{}))

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	require.Len(t, digests, 1)
	sd := digests[0]

	parsedFrom, ferr := time.Parse(time.RFC3339, sd.PeriodFrom)
	require.NoError(t, ferr, "period_from must be stored as RFC3339 UTC, got %q", sd.PeriodFrom)
	parsedTo, terr := time.Parse(time.RFC3339, sd.PeriodTo)
	require.NoError(t, terr, "period_to must be stored as RFC3339 UTC, got %q", sd.PeriodTo)
	assert.True(t, strings.HasSuffix(sd.PeriodFrom, "Z"), "RFC3339 UTC must end in Z, not a raw offset, got %q", sd.PeriodFrom)
	assert.True(t, strings.HasSuffix(sd.PeriodTo, "Z"), "RFC3339 UTC must end in Z, not a raw offset, got %q", sd.PeriodTo)

	wantFrom, ok := db.ParseJiraTime(floor)
	require.True(t, ok)
	wantTo, ok := db.ParseJiraTime(updatedAt)
	require.True(t, ok)
	assert.Equal(t, wantFrom, parsedFrom.Unix())
	assert.Equal(t, wantTo, parsedTo.Unix())

	// Boundary compare: HasStreamDigestCovering must correctly recognize the
	// normalized period against an RFC3339 UTC window built from the same
	// instants.
	covered, cerr := d.HasStreamDigestCovering("jira", acctID,
		time.Unix(wantFrom, 0).UTC().Format(time.RFC3339),
		time.Unix(wantTo, 0).UTC().Format(time.RFC3339))
	require.NoError(t, cerr)
	assert.True(t, covered, "coverage check must correctly match the normalized RFC3339 period")
}

// TestIdeas02_JiraHallucinatedRefDropped covers ref validation: a candidate
// whose ref is not a bare key from the rendered block never reaches the
// database at all, while the pass still completes normally (the AI call itself
// succeeded, so the mined window's floor advances).
//
// Re-expressed 2026-09-13 (audit fix wave 2): the invented ref used to leave
// behind a stream_digests row carrying "[]". This now asserts zero rows, which
// is strictly stronger — the earlier assertion accepted a row as long as its
// topics were empty, this one accepts no row at all.
func TestIdeas02_JiraHallucinatedRefDropped(t *testing.T) {
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
	err := p.runJiraDigests(context.Background(), time.Time{})
	require.NoError(t, err)

	assertNoStreamDigestCites(t, d, "WT-999")
	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	assert.Empty(t, digests,
		"an invented ref must not reach stream_digests at all — not even as an empty row")

	newFloor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, u1, newFloor, "the window was mined, so its floor still advances")
}

// TestIdeas01_JiraEmptyTopics_NoRowFloorAdvances is the other route to the
// same no-empty-row rule: the model answered with an affirmative but empty
// "topics" array. No row is written, yet the window was genuinely mined, so
// the floor advances.
func TestIdeas01_JiraEmptyTopics_NoRowFloorAdvances(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour)
	acctID := seedJiraAccount(t, d)
	setIdeasJiraFloorRaw(t, d, acctID, base.Format(time.RFC3339))
	u1 := base.Add(10 * time.Second).Format(time.RFC3339)
	seedJiraIssueIdeas(t, d, acctID, "WT-1", "WT", "Real issue", "Open", "new", "desc", u1)

	gen := &fakeGen{reply: func(string) (string, error) { return `{"topics":[]}`, nil }}
	p := New(d, testCfg(), gen, testLogger())
	require.NoError(t, p.runJiraDigests(context.Background(), time.Time{}))
	require.Equal(t, 1, gen.calls)

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	assert.Empty(t, digests, "a window with no topics must write no stream_digests row")

	newFloor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, u1, newFloor)
}

// TestIdeas01_JiraFloorStopsAtBudgetDroppedIssue pins the floor to what the
// renderer actually put in front of the model, in the shape that makes the
// rule sharp: renderJiraBlock groups by project, not by time, so the dropped
// issue (OPS-1, updated second) is OLDER than a rendered one (WT-2, updated
// third). A floor taken as the max over rendered issues would land on WT-2's
// updated_at and bury OPS-1 for good — the floor must stop at the last issue
// below the first dropped one instead.
func TestIdeas01_JiraFloorStopsAtBudgetDroppedIssue(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour)
	acctID := seedJiraAccount(t, d)
	floor := base.Format(time.RFC3339)
	setIdeasJiraFloorRaw(t, d, acctID, floor)

	u1 := base.Add(10 * time.Second).Format(time.RFC3339)
	u2 := base.Add(20 * time.Second).Format(time.RFC3339)
	u3 := base.Add(30 * time.Second).Format(time.RFC3339)
	seedJiraIssueIdeas(t, d, acctID, "WT-1", "WT", "first", "Open", "new", "desc", u1)
	seedJiraIssueIdeas(t, d, acctID, "OPS-1", "OPS", "second project", "Open", "new", "desc", u2)
	seedJiraIssueIdeas(t, d, acctID, "WT-2", "WT", "third", "Open", "new", "desc", u3)

	// A budget that fits project WT's whole group and nothing more, so the
	// OPS group is dropped even though its issue is older than WT-2.
	issues, err := d.ListJiraIssuesUpdatedSince(acctID, floor, "", jiraIssuesPerAccountLimit)
	require.NoError(t, err)
	require.Len(t, issues, 3)
	wtOnly, _ := renderJiraBlock([]db.JiraIssue{issues[0], issues[2]}, nil, 1000000, "")

	var seenBlock string
	gen := &fakeGen{reply: func(user string) (string, error) {
		seenBlock = user
		return `{"topics":[{"title":"t","summary":"s","ideas":[{"text":"i","author":"Ann","ref":"WT-1"}],"decisions":[]}]}`, nil
	}}
	p := New(d, testCfgWithBudget(len(wtOnly)), gen, testLogger())
	require.NoError(t, p.runJiraDigests(context.Background(), time.Time{}))
	require.Equal(t, 1, gen.calls)
	require.Contains(t, seenBlock, "WT-2", "project WT must have rendered whole")
	require.NotContains(t, seenBlock, "OPS-1", "the OPS group must not have been rendered")

	newFloor, ferr := d.IdeasJiraFloor(acctID)
	require.NoError(t, ferr)
	assert.Equal(t, u1, newFloor,
		"the floor must stop below the dropped OPS-1, not jump to the rendered WT-2")

	// Both unmined issues are still visible to the next run — including WT-2,
	// which is re-read (cost, never loss: IDEA-05 dedups a re-mine).
	left, lerr := d.ListJiraIssuesUpdatedSince(acctID, newFloor, "", jiraIssuesPerAccountLimit)
	require.NoError(t, lerr)
	require.Len(t, left, 2)
	assert.Equal(t, "OPS-1", left[0].Key)
	assert.Equal(t, "WT-2", left[1].Key)

	digests, derr := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, derr)
	require.Len(t, digests, 1)
	assert.Equal(t, normalizeJiraStreamPeriod(u1), digests[0].PeriodTo,
		"period_to must describe what the row's floor claims, not what was loaded")
}

// TestIdeas01_JiraTieAtBudgetCut_DrainedNotBuried pins the boundary-tie rule
// on the reviewer's reproduction: one bulk edit stamps the same updated_at on
// issues in two projects, and the budget fits the first project whole. A floor
// set to the last rendered issue would sit exactly ON that timestamp, and
// ListJiraIssuesUpdatedSince reloads with a strict >, so BBB-1 — never
// rendered — would be invisible to every later run. The whole tie group must
// be rendered instead.
func TestIdeas01_JiraTieAtBudgetCut_DrainedNotBuried(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour)
	acctID := seedJiraAccount(t, d)
	floor := base.Format(time.RFC3339)
	setIdeasJiraFloorRaw(t, d, acctID, floor)

	u1 := base.Add(10 * time.Second).Format(time.RFC3339)
	u2 := base.Add(20 * time.Second).Format(time.RFC3339)
	seedJiraIssueIdeas(t, d, acctID, "AAA-1", "AAA", "first", "Open", "new", "desc", u1)
	seedJiraIssueIdeas(t, d, acctID, "BBB-1", "BBB", "bulk-edited twin", "Open", "new", "desc", u1)
	seedJiraIssueIdeas(t, d, acctID, "AAA-2", "AAA", "second", "Open", "new", "desc", u2)

	// A budget that fits project AAA whole and nothing more.
	issues, err := d.ListJiraIssuesUpdatedSince(acctID, floor, "", jiraIssuesPerAccountLimit)
	require.NoError(t, err)
	require.Len(t, issues, 3)
	aaaOnly, _ := renderJiraBlock([]db.JiraIssue{issues[0], issues[2]}, nil, 1000000, "")

	var seenBlock string
	gen := &fakeGen{reply: func(user string) (string, error) {
		seenBlock = user
		return `{"topics":[{"title":"t","summary":"s","ideas":[{"text":"i","author":"Ann","ref":"AAA-1"}],"decisions":[]}]}`, nil
	}}
	p := New(d, testCfgWithBudget(len(aaaOnly)), gen, testLogger())
	require.NoError(t, p.runJiraDigests(context.Background(), time.Time{}))
	require.Equal(t, 1, gen.calls)

	assert.Contains(t, seenBlock, "BBB-1",
		"the tie-mate must be drained into the same prompt, not dropped below the floor")

	newFloor, ferr := d.IdeasJiraFloor(acctID)
	require.NoError(t, ferr)

	// The invariant, stated directly: every issue the prompt did NOT carry
	// must still be above the floor, so a later run can still reach it.
	left, lerr := d.ListJiraIssuesUpdatedSince(acctID, newFloor, "", jiraIssuesPerAccountLimit)
	require.NoError(t, lerr)
	stillVisible := make(map[string]bool, len(left))
	for _, is := range left {
		stillVisible[is.Key] = true
	}
	for _, is := range issues {
		if !strings.Contains(seenBlock, is.Key) {
			assert.True(t, stillVisible[is.Key],
				"%s was never rendered, so it must remain above the floor", is.Key)
		}
	}
}

// seedJiraIssuesInOneTimestamp inserts n issues in one project all carrying
// the same updated_at, in one transaction — the boundary-drain ceiling only
// engages past maxTieDrainUnits units, so its guard needs a bulk fixture.
func seedJiraIssuesInOneTimestamp(t *testing.T, d *db.DB, accountID int64, n int, updatedAt string) {
	t.Helper()
	tx, err := d.Begin()
	require.NoError(t, err)
	defer func() { _ = tx.Rollback() }()
	stmt, err := tx.Prepare(`INSERT INTO jira_issues
		(account_id, key, id, project_key, board_id, summary, description_text, status, status_category, sprint_id, created_at, updated_at, synced_at)
		VALUES (?, ?, ?, 'WT', 0, 's', 'd', 'Open', 'new', 0, ?, ?, ?)`)
	require.NoError(t, err)
	defer stmt.Close()
	for i := 0; i < n; i++ {
		key := fmt.Sprintf("WT-%05d", i)
		_, err = stmt.Exec(accountID, key, key, updatedAt, updatedAt, updatedAt)
		require.NoError(t, err)
	}
	require.NoError(t, tx.Commit())
}

// TestIdeas01_JiraTieGroupBeyondCeiling_BoundedAndFloorAdvances is the Jira
// twin of the email ceiling guard, and the one that matters most: the ceiling
// was raised from 50 to 1000 on the strength of Jira bulk-edit traffic, and
// this branch — the count, the fault line, and the advance-anyway disposition
// — had no test at all until now (final-review §9).
//
// Same strength as the email half: the constant is pinned, the rendered count
// is exact, and the fault line is matched in full.
func TestIdeas01_JiraTieGroupBeyondCeiling_BoundedAndFloorAdvances(t *testing.T) {
	require.Equal(t, 1000, maxTieDrainUnits,
		"the drain ceiling must stay out of reach of ordinary bulk activity: a tie group is "+
			"all-or-nothing, so whatever the ceiling trims goes under the floor unmined. "+
			"If this constant is deliberately changed, re-derive the counts below with it.")

	d := newTestDB(t)
	base := time.Now().Add(-time.Hour)
	acctID := seedJiraAccount(t, d)
	floor := base.Format(time.RFC3339)
	setIdeasJiraFloorRaw(t, d, acctID, floor)

	// 1005 issues sharing one updated_at — one bulk edit, past the ceiling by
	// 5, and past the loader's own 300-issue cap, so this also exercises the
	// unbounded boundary drain handing the renderer more than one pass holds.
	const seeded, wantRendered, wantUnrendered = 1005, 1000, 5
	u1 := base.Add(10 * time.Second).Format(time.RFC3339)
	seedJiraIssuesInOneTimestamp(t, d, acctID, seeded, u1)

	var seenBlock string
	var logged bytes.Buffer
	gen := &fakeGen{reply: func(user string) (string, error) {
		seenBlock = user
		return `{"topics":[]}`, nil
	}}
	p := New(d, testCfgWithBudget(1), gen, log.New(&logged, "", 0))
	require.NoError(t, p.runJiraDigests(context.Background(), time.Time{}))
	require.Equal(t, 1, gen.calls)

	assert.Equal(t, wantRendered, strings.Count(seenBlock, " — Open — "),
		"the drain must take the group up to the ceiling and stop exactly there")
	assert.Less(t, len(seenBlock), tieDrainCharCeiling/2,
		"this fixture must exercise the unit ceiling, not the byte ceiling")

	newFloor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, u1, newFloor,
		"above the ceiling the floor still passes the timestamp — a bounded residual, not a stall")

	out := logged.String()
	assert.Contains(t, out, "ERROR", "hitting the ceiling is a fault, not a note")
	assert.Contains(t, out, fmt.Sprintf(
		"ERROR: jira account %d: %d issue(s) sharing updated_at %s were NOT rendered — the boundary drain stopped at its ceilings (%d units / %d chars,",
		acctID, wantUnrendered, u1, maxTieDrainUnits, tieDrainCharCeiling),
		"the fault must name the source, the count, the timestamp and both ceilings")
}

// TestIdeas01_JiraTieDrainStopsAtByteCeiling is the Jira half of the drain's
// byte bound — the dimension the unit ceiling cannot see, and the one a Jira
// bulk edit reaches first, since an issue renders far fatter than a Gmail
// thread line (description plus up to maxCommentsPerIssue comments).
//
// Fixture arithmetic, pinned literally: 8 issues share one updated_at, each
// rendering a ~100 KB line, against a 600 000-char ceiling — so 5 fit and 3 do
// not, well under the 1000-unit ceiling.
func TestIdeas01_JiraTieDrainStopsAtByteCeiling(t *testing.T) {
	require.Equal(t, 10, tieDrainBudgetFactor,
		"the byte ceiling protects against an over-context drain; changing the factor means "+
			"re-deriving the counts below with it")

	d := newTestDB(t)
	base := time.Now().Add(-time.Hour)
	acctID := seedJiraAccount(t, d)
	floor := base.Format(time.RFC3339)
	setIdeasJiraFloorRaw(t, d, acctID, floor)

	const seeded, wantRendered, wantUnrendered = 8, 5, 3
	const fatSummary = 100000 // summaries are not excerpt-capped, so this sets the line size
	u1 := base.Add(10 * time.Second).Format(time.RFC3339)
	for i := 0; i < seeded; i++ {
		seedJiraIssueIdeas(t, d, acctID, fmt.Sprintf("WT-%03d", i), "WT",
			strings.Repeat("s", fatSummary), "Open", "new", "d", u1)
	}

	var seenBlock string
	var logged bytes.Buffer
	gen := &fakeGen{reply: func(user string) (string, error) {
		seenBlock = user
		return `{"topics":[]}`, nil
	}}
	p := New(d, testCfgWithBudget(1), gen, log.New(&logged, "", 0))
	require.NoError(t, p.runJiraDigests(context.Background(), time.Time{}))
	require.Equal(t, 1, gen.calls)

	const ceiling = tieDrainCharCeiling
	assert.Equal(t, wantRendered, strings.Count(seenBlock, " — Open — "),
		"the drain must stop on bytes, having taken as many tie-mates as the ceiling allows")
	assert.LessOrEqual(t, len(seenBlock), ceiling, "the block must never exceed the byte ceiling")
	assert.Less(t, wantRendered, maxTieDrainUnits,
		"bytes, not units, must be what stopped this drain")

	newFloor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, u1, newFloor,
		"the byte ceiling inherits the unit ceiling's disposition: advance anyway, never retreat")

	assert.Contains(t, logged.String(), fmt.Sprintf(
		"ERROR: jira account %d: %d issue(s) sharing updated_at %s were NOT rendered — the boundary drain stopped at its ceilings (%d units / %d chars,",
		acctID, wantUnrendered, u1, maxTieDrainUnits, ceiling),
		"a byte-ceiling breach must report the same counted fault as a unit-ceiling breach")
}

// TestIdeas01_JiraOversizedIssue_RenderedAnywayFloorAdvances is the Jira half
// of the same controller ruling (2026-09-13): a prompt budget too small for
// even the oldest issue must still render that one issue, overshooting the
// cap, so the pass mines the window and its floor moves instead of the account
// re-reading the same issue forever.
func TestIdeas01_JiraOversizedIssue_RenderedAnywayFloorAdvances(t *testing.T) {
	d := newTestDB(t)
	base := time.Now().Add(-time.Hour)
	acctID := seedJiraAccount(t, d)
	floor := base.Format(time.RFC3339)
	setIdeasJiraFloorRaw(t, d, acctID, floor)
	u1 := base.Add(10 * time.Second).Format(time.RFC3339)
	seedJiraIssueIdeas(t, d, acctID, "WT-1", "WT", "Real issue", "Open", "new", "desc", u1)

	var logged bytes.Buffer
	var seenBlock string
	gen := &fakeGen{reply: func(user string) (string, error) {
		seenBlock = user
		return `{"topics":[{"title":"t","summary":"s","ideas":[{"text":"i","author":"Ann","ref":"WT-1"}],"decisions":[]}]}`, nil
	}}
	const budget = 1
	p := New(d, testCfgWithBudget(budget), gen, log.New(&logged, "", 0))
	require.NoError(t, p.runJiraDigests(context.Background(), time.Time{}))

	require.Equal(t, 1, gen.calls, "the oversized issue must still be mined")
	assert.Contains(t, seenBlock, "WT-1", "the one oversized issue must be rendered")
	assert.Greater(t, len(seenBlock), budget, "the overshoot is what makes progress possible")

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	require.Len(t, digests, 1)

	newFloor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, u1, newFloor, "the rendered issue's floor must advance, or the pass stalls forever")

	// The operator must be able to see why the prompt outgrew their cap.
	assert.Contains(t, logged.String(), "WT-1", "the overshoot log must name the issue")
	assert.Contains(t, logged.String(), "ideas.max_prompt_chars", "the overshoot log must name the cap")
}
