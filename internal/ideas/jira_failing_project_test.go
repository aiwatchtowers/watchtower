package ideas

import (
	"bytes"
	"context"
	"log"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// selectJiraProject seeds a selected board for projectKey and its sync state:
// lastSynced "" = never synced, lastError "" = the latest attempt succeeded.
func selectJiraProject(t *testing.T, d *db.DB, accountID int64, boardID int, projectKey, lastSynced, lastError string, selected bool) {
	t.Helper()
	require.NoError(t, d.UpsertJiraBoard(db.JiraBoard{AccountID: accountID, ID: boardID, Name: projectKey, ProjectKey: projectKey, BoardType: "scrum", IsSelected: selected}))
	_, err := d.Exec(`INSERT INTO jira_sync_state (account_id, project_key, last_synced_at, last_error, last_error_at) VALUES (?, ?, ?, ?, ?)`,
		accountID, projectKey, lastSynced, lastError, lastSynced)
	require.NoError(t, err)
}

// jiraTopicsFor replies with one idea per issue key present in the prompt.
func jiraTopicsFor(keys ...string) func(string) (string, error) {
	return func(user string) (string, error) {
		var ideas []string
		for _, k := range keys {
			if strings.Contains(user, k) {
				ideas = append(ideas, `{"text":"idea `+k+`","author":"A","ref":"`+k+`"}`)
			}
		}
		return `{"topics":[{"title":"t","summary":"s","ideas":[` + strings.Join(ideas, ",") + `],"decisions":[]}]}`, nil
	}
}

// Project B fails to sync while A keeps syncing. The account-wide floor must
// not advance past B's last successful sync, or B's changes made during the
// outage land below the floor once B recovers and are never mined (IDEA-01).
func TestIdeas01_JiraFloorHeldBackByFailingProject(t *testing.T) {
	d := newTestDB(t)
	now := time.Now().UTC()
	acctID := seedJiraAccount(t, d)
	jt := func(tm time.Time) string { return db.FormatJiraTime(tm.UTC()) }
	setIdeasJiraFloorRaw(t, d, acctID, jt(now.Add(-3*time.Hour)))

	selectJiraProject(t, d, acctID, 1, "AAA", now.Add(-5*time.Minute).Format(time.RFC3339), "", true)
	bSynced := now.Add(-time.Hour)
	selectJiraProject(t, d, acctID, 2, "BBB", bSynced.Format(time.RFC3339), "sync: 500", true)

	seedJiraIssueIdeas(t, d, acctID, "AAA-1", "AAA", "old A", "Open", "new", "x", jt(now.Add(-2*time.Hour)))
	seedJiraIssueIdeas(t, d, acctID, "AAA-2", "AAA", "fresh A", "Open", "new", "x", jt(now.Add(-10*time.Minute)))

	gen := &fakeGen{reply: jiraTopicsFor("AAA-1", "AAA-2", "BBB-1")}
	p := New(d, testCfg(), gen, testLogger())
	require.NoError(t, p.runJiraDigests(context.Background(), time.Time{}))
	floor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, jt(now.Add(-2*time.Hour)), floor, "the floor stops below B's last successful sync")

	// B recovers: its outage-era change arrives with an updated_at below A-2's.
	require.NoError(t, d.UpdateJiraSyncState(acctID, "BBB", now.Format(time.RFC3339), 1))
	seedJiraIssueIdeas(t, d, acctID, "BBB-1", "BBB", "outage B", "Open", "new", "x", jt(now.Add(-30*time.Minute)))
	require.NoError(t, p.runJiraDigests(context.Background(), time.Time{}))

	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	var all string
	for _, sd := range digests {
		all += sd.TopicsJSON
	}
	for _, k := range []string{"AAA-1", "AAA-2", "BBB-1"} {
		assert.Contains(t, all, `"ref":"`+k+`"`, "%s is mined exactly because the floor waited", k)
	}
	floor, err = d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, jt(now.Add(-10*time.Minute)), floor)
}

// Nothing below the clamp: no AI call, no row, floor untouched.
func TestIdeas01_JiraFailingProjectNothingMineable_CleanNoOp(t *testing.T) {
	d := newTestDB(t)
	now := time.Now().UTC()
	acctID := seedJiraAccount(t, d)
	jt := func(tm time.Time) string { return db.FormatJiraTime(tm.UTC()) }
	floor := jt(now.Add(-2 * time.Hour))
	setIdeasJiraFloorRaw(t, d, acctID, floor)
	selectJiraProject(t, d, acctID, 2, "BBB", now.Add(-3*time.Hour).Format(time.RFC3339), "sync: 500", true)
	seedJiraIssueIdeas(t, d, acctID, "AAA-1", "AAA", "fresh A", "Open", "new", "x", jt(now.Add(-10*time.Minute)))

	gen := &fakeGen{reply: jiraTopicsFor("AAA-1")}
	p := New(d, testCfg(), gen, testLogger())
	require.NoError(t, p.runJiraDigests(context.Background(), time.Time{}))
	assert.Zero(t, gen.calls)
	got, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	assert.Equal(t, floor, got)
}

// Failing projects that must NOT hold the floor: one failing for longer than
// the cap (treated as abandoned), one no longer selected, one never synced.
func TestIdeas01_JiraFailingProjectExemptions(t *testing.T) {
	for name, seed := range map[string]func(t *testing.T, d *db.DB, acct int64, now time.Time){
		"stale": func(t *testing.T, d *db.DB, acct int64, now time.Time) {
			selectJiraProject(t, d, acct, 2, "BBB", now.Add(-jiraLaggingProjectMaxAge-time.Hour).Format(time.RFC3339), "sync: 500", true)
		},
		"unselected": func(t *testing.T, d *db.DB, acct int64, now time.Time) {
			selectJiraProject(t, d, acct, 2, "BBB", now.Add(-time.Hour).Format(time.RFC3339), "sync: 500", false)
		},
		"never-synced": func(t *testing.T, d *db.DB, acct int64, now time.Time) {
			selectJiraProject(t, d, acct, 2, "BBB", "", "sync: 500", true)
		},
	} {
		t.Run(name, func(t *testing.T) {
			d := newTestDB(t)
			now := time.Now().UTC()
			acctID := seedJiraAccount(t, d)
			jt := func(tm time.Time) string { return db.FormatJiraTime(tm.UTC()) }
			setIdeasJiraFloorRaw(t, d, acctID, jt(now.Add(-3*time.Hour)))
			seed(t, d, acctID, now)
			seedJiraIssueIdeas(t, d, acctID, "AAA-1", "AAA", "fresh A", "Open", "new", "x", jt(now.Add(-10*time.Minute)))

			gen := &fakeGen{reply: jiraTopicsFor("AAA-1")}
			p := New(d, testCfg(), gen, testLogger())
			require.NoError(t, p.runJiraDigests(context.Background(), time.Time{}))
			got, err := d.IdeasJiraFloor(acctID)
			require.NoError(t, err)
			assert.Equal(t, jt(now.Add(-10*time.Minute)), got)
		})
	}
}

// jira_issues.updated_at keeps Jira's own offset and the bound is compared as
// a string, so a clamp rendered in UTC would let a -0400 issue that happened
// AFTER the failing project's last sync through (and move the floor past the
// failing project's backlog). The clamp must hold every offset the data
// carries: here -0400 and +0530.
func TestIdeas01_JiraFailingProjectClampIsOffsetSafe(t *testing.T) {
	d := newTestDB(t)
	now := time.Now().UTC().Truncate(time.Second)
	acctID := seedJiraAccount(t, d)
	ny := time.FixedZone("", -4*3600)
	ist := time.FixedZone("", 5*3600+1800)
	jt := func(tm time.Time, loc *time.Location) string { return db.FormatJiraTime(tm.In(loc)) }

	bSynced := now.Add(-time.Hour)
	clamp := bSynced.Add(-jiraLaggingProjectOverlap)
	setIdeasJiraFloorRaw(t, d, acctID, jt(now.Add(-5*time.Hour), ny))
	selectJiraProject(t, d, acctID, 1, "AAA", now.Add(-5*time.Minute).Format(time.RFC3339), "", true)
	selectJiraProject(t, d, acctID, 2, "BBB", bSynced.Format(time.RFC3339), "sync: 500", true)

	seedJiraIssueIdeas(t, d, acctID, "AAA-1", "AAA", "before clamp", "Open", "new", "x", jt(clamp.Add(-30*time.Minute), ny))
	seedJiraIssueIdeas(t, d, acctID, "AAA-2", "AAA", "after clamp", "Open", "new", "x", jt(clamp.Add(20*time.Minute), ny))
	seedJiraIssueIdeas(t, d, acctID, "AAA-3", "AAA", "before clamp east", "Open", "new", "x", jt(clamp.Add(-10*time.Minute), ist))

	gen := &fakeGen{reply: jiraTopicsFor("AAA-1", "AAA-2", "AAA-3", "BBB-1")}
	p := New(d, testCfg(), gen, testLogger())
	require.NoError(t, p.runJiraDigests(context.Background(), time.Time{}))

	floor, err := d.IdeasJiraFloor(acctID)
	require.NoError(t, err)
	floorUnix, ok := db.ParseJiraTime(floor)
	require.True(t, ok)
	assert.LessOrEqual(t, floorUnix, clamp.Unix(), "the floor never passes the failing project's last sync, whatever the offset")
	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	var mined string
	for _, sd := range digests {
		mined += sd.TopicsJSON
	}
	assert.Contains(t, mined, `"ref":"AAA-1"`)
	assert.NotContains(t, mined, `"ref":"AAA-2"`, "an issue after the clamp is never mined while the project fails")

	// B recovers with a change made during the outage; nothing is lost.
	require.NoError(t, d.UpdateJiraSyncState(acctID, "BBB", now.Format(time.RFC3339), 1))
	seedJiraIssueIdeas(t, d, acctID, "BBB-1", "BBB", "outage B", "Open", "new", "x", jt(clamp.Add(10*time.Minute), ny))
	require.NoError(t, p.runJiraDigests(context.Background(), time.Time{}))
	digests, err = d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	mined = ""
	for _, sd := range digests {
		mined += sd.TopicsJSON
	}
	for _, k := range []string{"AAA-1", "AAA-2", "AAA-3", "BBB-1"} {
		assert.Contains(t, mined, `"ref":"`+k+`"`)
	}
}

// A backfill bound is the opposite direction: an issue inside the window must
// never be excluded because its offset makes its string sort above a bound
// rendered in another offset.
func TestIdeas01_JiraBackfillBoundIsOffsetSafe(t *testing.T) {
	d := newTestDB(t)
	now := time.Now().UTC().Truncate(time.Second)
	acctID := seedJiraAccount(t, d)
	ist := time.FixedZone("", 5*3600+1800)
	ny := time.FixedZone("", -4*3600)
	to := now.Add(-24 * time.Hour)
	setIdeasJiraFloorRaw(t, d, acctID, db.FormatJiraTime(to.Add(-48*time.Hour).In(ny)))
	seedJiraIssueIdeas(t, d, acctID, "WT-1", "WT", "inside window", "Open", "new", "x", db.FormatJiraTime(to.Add(-30*time.Minute).In(ist)))
	seedJiraIssueIdeas(t, d, acctID, "WT-2", "WT", "older", "Open", "new", "x", db.FormatJiraTime(to.Add(-5*time.Hour).In(ny)))

	gen := &fakeGen{reply: jiraTopicsFor("WT-1", "WT-2")}
	p := New(d, testCfg(), gen, testLogger())
	require.NoError(t, p.runJiraDigests(context.Background(), to))
	digests, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	require.NotEmpty(t, digests)
	var mined string
	for _, sd := range digests {
		mined += sd.TopicsJSON
	}
	assert.Contains(t, mined, `"ref":"WT-1"`, "a +0530 issue inside the window is mined")
	assert.Contains(t, mined, `"ref":"WT-2"`)
}

func TestJiraIssueBoundISO_PicksOffsetByDirection(t *testing.T) {
	at := time.Now().UTC().Truncate(time.Second)
	offs := []int{-4 * 3600, 5*3600 + 1800, 0}
	assert.Equal(t, db.FormatJiraTime(at.In(time.FixedZone("", -4*3600))), jiraIssueBoundISO(at, offs, true))
	assert.Equal(t, db.FormatJiraTime(at.In(time.FixedZone("", 5*3600+1800))), jiraIssueBoundISO(at, offs, false))
	assert.Equal(t, db.FormatJiraTime(at), jiraIssueBoundISO(at, nil, true), "no candidates → UTC")
}

// A project past the cap logs "no longer holding the floor" once a day, not
// every pass.
func TestIdeas01_JiraAbandonedProjectLoggedOncePerDay(t *testing.T) {
	d := newTestDB(t)
	now := time.Now().UTC()
	acctID := seedJiraAccount(t, d)
	selectJiraProject(t, d, acctID, 2, "BBB", now.Add(-jiraLaggingProjectMaxAge-time.Hour).Format(time.RFC3339), "sync: 500", true)
	var buf bytes.Buffer
	p := New(d, testCfg(), &fakeGen{reply: jiraTopicsFor()}, log.New(&buf, "", 0))
	for i := 0; i < 3; i++ {
		_, ok, err := p.failingJiraProjectClamp(acctID, now)
		require.NoError(t, err)
		assert.False(t, ok)
	}
	assert.Equal(t, 1, strings.Count(buf.String(), "no longer holding the ideas floor"))
	_, _, err := p.failingJiraProjectClamp(acctID, now.Add(24*time.Hour))
	require.NoError(t, err)
	assert.Equal(t, 2, strings.Count(buf.String(), "no longer holding the ideas floor"), "a new day logs again")
}
