package tools

import (
	"context"
	"database/sql"
	"encoding/json"
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
	// Lanes, not chapters: task-b's files all went to an agent chapter, so
	// it has no chapter of its own, and its ticket still counts.
	m := reviewmap.Map{
		Chapters: []reviewmap.Chapter{
			{Key: "agent:1", Paths: []string{"pay/pay.go"}},
			{Key: "lane:ABC-1-login", Lane: "ABC-1-login", JiraKey: "ABC-1"},
		},
		Lanes: []reviewmap.LaneInfo{
			{Name: "ABC-1-login", JiraKey: "ABC-1"},
			{Name: "foreign", TargetID: foreign}, // another workbench's target
			{Name: "gone", JiraKey: "ABC-404"},   // not synced
			{Name: "plain"},                      // no ticket
			{Name: "task-b", TargetID: target},
		},
	}
	items, err := LaneIntent(d, p, m)
	require.NoError(t, err)
	require.Len(t, items, 2)
	assert.Equal(t, "ABC-1 Login with a passkey", items[0].Text)
	assert.Equal(t, strings.Repeat("é", maxLaneDescriptionRunes), items[0].Intent)
	assert.Equal(t, reviewai.SourceLane, items[0].Source)
	assert.Equal(t, reviewai.IntentItem{Text: "Payments lane", Intent: "take card payments", Source: reviewai.SourceLane}, items[1])
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

// The gate finds the overview by the session's items alone: the overview
// made with one lane ticket still passes once that ticket's title changed,
// and a lane item that is not done never refuses.
func TestProj14_LaneTicketEditedStillFindsTheOverview(t *testing.T) {
	fx, wb, session, reg := repoSession(t)
	linkIntent(t, fx.d, wb, session, 1)
	ctx := context.Background()
	p, err := fx.d.GetWorkbench(wb)
	require.NoError(t, err)
	snap, err := SnapshotReviewSession(ctx, fx.d, p, session)
	require.NoError(t, err)
	in, err := ReviewOverviewInput(ctx, fx.d, p, session)
	require.NoError(t, err)
	made := WithLaneIntent(in.Intent, []reviewai.IntentItem{{Text: "ABC-1 Login", Source: reviewai.SourceLane}})
	js, err := json.Marshal(reviewai.Overview{Coverage: []reviewai.Coverage{
		{Index: 1, Item: "goal 1", Status: "done", Source: reviewai.SourceSession},
		{Index: 2, Item: "ABC-1 Login", Status: "not_found", Source: reviewai.SourceLane},
	}})
	require.NoError(t, err)
	require.NoError(t, fx.d.PutReviewOverview(wb, snap.Tree, snap.Base, reviewai.IntentHash(made, in.Notes), string(js), "m"))

	renamed := WithLaneIntent(in.Intent, []reviewai.IntentItem{{Text: "ABC-1 Login with a passkey", Source: reviewai.SourceLane}})
	assert.Equal(t, reviewai.IntentHash(made, in.Notes), reviewai.IntentHash(renamed, in.Notes))
	mustApply(t, reg, wb, "finish_session", `{"summary":"Done.","reason":"r"}`)
}
