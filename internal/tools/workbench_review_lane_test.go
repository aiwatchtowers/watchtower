package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/reviewai"
	"watchtower/internal/reviewmap"
)

// Board #1025: one intent item per lane ticket — a board target of the
// workbench or a synced Jira issue — after the session's own items.
func TestLaneIntent_BoardTargetAndJiraIssue(t *testing.T) {
	fx, wb, _, _ := repoSession(t)
	d := fx.d
	p, err := d.GetWorkbench(wb)
	require.NoError(t, err)
	target := db.SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "Payments lane")
	_, err = d.Exec(`UPDATE targets SET intent = 'take card payments' WHERE id = ?`, target)
	require.NoError(t, err)
	other, err := d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	foreign := db.SeedTestWorkbenchTarget(t, d, other, sql.NullInt64{}, "Not ours")
	acct, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "cloud", SiteURL: "https://acme.example.com", SiteName: "acme"})
	require.NoError(t, err)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		AccountID: acct, Key: "ABC-1", ID: "10001", ProjectKey: "ABC", Summary: "Login with a passkey",
		DescriptionText: "  " + strings.Repeat("é", 700) + "  ",
		Status:          "To Do", StatusCategory: "new", Labels: "[]", Components: "[]", FixVersions: "[]",
		CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z", SyncedAt: "2026-01-01T00:00:00Z",
	}))
	m := reviewmap.Map{Chapters: []reviewmap.Chapter{
		{Key: "lane:task-b/pay", Lane: "task-b", TargetID: target},
		{Key: "lane:ABC-1-login", Lane: "ABC-1-login", JiraKey: "ABC-1"},
		{Key: "lane:task-b/docs", Lane: "task-b", TargetID: target}, // same lane: one item
		{Key: "lane:plain", Lane: "plain"},                          // no ticket
		{Key: "lane:gone", Lane: "gone", JiraKey: "ABC-404"},        // not synced
		{Key: "lane:foreign", Lane: "foreign", TargetID: foreign},   // another workbench's target
		{Key: "dir:x"},
	}}
	items, err := LaneIntent(d, p, m)
	require.NoError(t, err)
	require.Len(t, items, 2)
	assert.Equal(t, reviewai.IntentItem{Text: "Payments lane", Intent: "take card payments", Source: reviewai.SourceLane}, items[0])
	assert.Equal(t, "ABC-1 Login with a passkey", items[1].Text)
	assert.Equal(t, strings.Repeat("é", maxLaneDescriptionRunes), items[1].Intent)
	assert.Equal(t, reviewai.SourceLane, items[1].Source)
}

func TestWithLaneIntent_AfterTheSessionsItemsWithoutRepeats(t *testing.T) {
	session := []reviewai.IntentItem{{Text: "Payments lane", Intent: "pay"}}
	lanes := []reviewai.IntentItem{{Text: "Payments lane", Intent: "pay", Source: reviewai.SourceLane},
		{Text: "ABC-1 Login", Source: reviewai.SourceLane}}
	got := WithLaneIntent(session, lanes)
	assert.Equal(t, []reviewai.IntentItem{session[0], lanes[1]}, got)
	assert.Nil(t, WithLaneIntent(nil, nil), "no session and no lanes stays nil: the cached hash of today")
	assert.Equal(t, lanes, WithLaneIntent(nil, lanes), "a round with no session has lane items only")
}

// The gate reads the overview cached under the session's and the lanes'
// items, and a lane item that is not done never refuses.
func TestProj14_LaneItemsKeyTheOverviewButNeverGate(t *testing.T) {
	fx, wb, session, _ := repoSession(t)
	linkIntent(t, fx.d, wb, session, 1)
	lane := reviewai.IntentItem{Text: "ABC-1 Login", Source: reviewai.SourceLane}
	reg := laneRegistry(t, fx.d, strconv.FormatInt(session, 10), nil,
		func(context.Context, *db.DB, *db.Workbench, int64, ReviewSnapshot) ([]reviewai.IntentItem, error) {
			return []reviewai.IntentItem{lane}, nil
		})

	cacheOverview(t, fx.d, wb, session, "done") // under the session's items alone
	_, err := proposeIn(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
	assert.Contains(t, refusal(t, err), "your changes have no AI overview yet")

	ctx := context.Background()
	p, err := fx.d.GetWorkbench(wb)
	require.NoError(t, err)
	snap, err := SnapshotReviewSession(ctx, fx.d, p, session)
	require.NoError(t, err)
	in, err := ReviewOverviewInput(ctx, fx.d, p, session)
	require.NoError(t, err)
	intent := WithLaneIntent(in.Intent, []reviewai.IntentItem{lane})
	js, err := json.Marshal(reviewai.Overview{Coverage: []reviewai.Coverage{
		{Index: 1, Item: "goal 1", Status: "done", Source: reviewai.SourceSession},
		{Index: 2, Item: "ABC-1 Login", Status: "not_found", Source: reviewai.SourceLane},
	}})
	require.NoError(t, err)
	require.NoError(t, fx.d.PutReviewOverview(wb, snap.Tree, snap.Base, reviewai.IntentHash(intent, in.Notes), string(js), "m"))
	mustApply(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
}
