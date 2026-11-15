package sync

import (
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	gosync "sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// syncedAtStart is the fixed run start of these tests.
var syncedAtStart = time.Date(2026, 11, 15, 12, 0, 0, 0, time.UTC)

// slackTS is the Slack ts of a message posted at t.
func slackTS(t time.Time) string { return fmt.Sprintf("%d.000100", t.Unix()) }

// mentionSearch answers search.messages with one page holding a mention of
// U001 (the account's user, per auth.test) from U002 for every ts in *tss.
func mentionSearch(mu *gosync.Mutex, tss *[]string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		matches := make([]map[string]any, 0, len(*tss))
		for _, ts := range *tss {
			matches = append(matches, map[string]any{
				"user": "U002", "username": "bob", "ts": ts, "text": "<@U001> ping " + ts,
				"channel": map[string]any{"id": "C001", "name": "general"},
			})
		}
		mu.Unlock()
		jsonOK(w, map[string]any{
			"ok": true,
			"messages": map[string]any{
				"matches": matches,
				"paging":  map[string]any{"count": 100, "total": len(matches), "page": 1, "pages": 1},
				"total":   len(matches),
			},
		})
	}
}

// newSyncedAtSetup is a search-path setup whose clock reads *now.
func newSyncedAtSetup(t *testing.T, handler http.HandlerFunc, now *time.Time) *testSetup {
	t.Helper()
	ts := newTestSetup(t, searchAuditMux(handler))
	ts.orch.logger = log.New(io.Discard, "", 0)
	ts.orch.now = func() time.Time { return *now }
	return ts
}

// detectedMentions is the pipeline's mention detector at watermark.
func detectedMentions(t *testing.T, ts *testSetup, watermark time.Time) []string {
	t.Helper()
	cands, err := ts.db.FindPendingMentions(ts.accountID, ts.ns("U001"), float64(watermark.Unix()))
	require.NoError(t, err)
	out := make([]string, 0, len(cands))
	for _, c := range cands {
		out = append(out, c.MessageTS)
	}
	return out
}

func storedSyncedAt(t *testing.T, ts *testSetup, msgTS string) float64 {
	t.Helper()
	var v float64
	require.NoError(t, ts.db.QueryRow(`SELECT synced_at FROM messages WHERE channel_id = ? AND ts = ?`,
		ts.ns("C001"), msgTS).Scan(&v))
	return v
}

// Review focus 3: a run that came 45 minutes late (cadence backed off) stores
// a mention posted before the Inbox watermark; it is still detected.
func TestInbox_LateStoredMessageDetected(t *testing.T) {
	var mu gosync.Mutex
	late := slackTS(syncedAtStart.Add(-45 * time.Minute))
	tss := []string{late}
	now := syncedAtStart
	ts := newSyncedAtSetup(t, mentionSearch(&mu, &tss), &now)
	require.NoError(t, ts.db.SetSlackFirstCycleAtOnce(ts.accountID, syncedAtStart.AddDate(0, 0, -30)))
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, "2026-11-14"))

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))

	assert.Equal(t, float64(syncedAtStart.Unix()), storedSyncedAt(t, ts, late), "stamped with the time it was stored")
	assert.Equal(t, []string{late}, detectedMentions(t, ts, syncedAtStart.Add(-30*time.Minute)))
}

// Review focus 5: an account's first sync stores weeks of history; none of
// it reaches the Inbox, while a message posted from the run's start on does.
func TestInbox_FirstSyncDoesNotFloodInbox(t *testing.T) {
	var mu gosync.Mutex
	old := slackTS(syncedAtStart.AddDate(0, 0, -3))
	recent := slackTS(syncedAtStart.Add(-2 * time.Hour))
	inRun := slackTS(syncedAtStart)
	tss := []string{old, recent, inRun}
	now := syncedAtStart
	ts := newSyncedAtSetup(t, mentionSearch(&mu, &tss), &now)

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))

	first, err := ts.db.SlackFirstCycleAt(ts.accountID)
	require.NoError(t, err)
	assert.True(t, syncedAtStart.Equal(first), "first_cycle_at = the first run's start, got %v", first)
	assert.Equal(t, slackTSUnix(old), storedSyncedAt(t, ts, old))
	assert.Equal(t, slackTSUnix(recent), storedSyncedAt(t, ts, recent))
	assert.Equal(t, []string{inRun}, detectedMentions(t, ts, syncedAtStart.Add(-30*time.Minute)))
}

// A new account row for a workspace already synced (the shared → full move)
// re-stores the same messages under its own namespaced keys. They are older
// than its first cycle, so they keep their post time even inside the 24-hour
// lookback, and a later run's re-fetch never moves them.
func TestInbox_SharedToFullMoveDoesNotFloodInbox(t *testing.T) {
	var mu gosync.Mutex
	recent := slackTS(syncedAtStart.Add(-2 * time.Hour))
	tss := []string{recent}
	now := syncedAtStart
	ts := newSyncedAtSetup(t, mentionSearch(&mu, &tss), &now)

	// The old row already holds the message under its own keys.
	oldID, err := ts.db.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	require.NoError(t, ts.db.UpsertMessage(db.Message{
		ChannelID: fmt.Sprintf("%d:C001", oldID), TS: recent, UserID: fmt.Sprintf("%d:U002", oldID),
		Text: "<@U001> ping", SyncedAt: slackTSUnix(recent),
	}))

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, slackTSUnix(recent), storedSyncedAt(t, ts, recent))
	// Behind the watermark: inside the 24-hour lookback alone it would be
	// stamped now and flood the Inbox.
	assert.Empty(t, detectedMentions(t, ts, syncedAtStart.Add(-30*time.Minute)))

	now = syncedAtStart.Add(time.Hour)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))
	assert.Equal(t, slackTSUnix(recent), storedSyncedAt(t, ts, recent), "a re-fetch never moves synced_at")
}

// A history backfill stores messages with their post time: one posted an
// hour ago is behind the watermark and never reaches the Inbox.
func TestInbox_BackfilledMessageNotDetected(t *testing.T) {
	var mu gosync.Mutex
	recent := slackTS(syncedAtStart.Add(-time.Hour))
	tss := []string{recent}
	now := syncedAtStart
	ts := newSyncedAtSetup(t, mentionSearch(&mu, &tss), &now)
	require.NoError(t, ts.db.UpdateSlackAccountConnection(ts.accountID, "T001", "Acme", "acme", ts.ns("U001")))
	require.NoError(t, ts.db.SetSlackFirstCycleAtOnce(ts.accountID, syncedAtStart.AddDate(0, 0, -30)))
	// A Run earlier in the process leaves its bounds on the orchestrator.
	ts.orch.runStart = syncedAtStart
	ts.orch.firstCycleAt = syncedAtStart.AddDate(0, 0, -30)

	_, err := ts.orch.BackfillSearch(context.Background(), syncedAtStart.AddDate(0, 0, -1), syncedAtStart)
	require.NoError(t, err)

	assert.Equal(t, slackTSUnix(recent), storedSyncedAt(t, ts, recent))
	assert.Empty(t, detectedMentions(t, ts, syncedAtStart.Add(-30*time.Minute)))
	assert.False(t, ts.orch.backfilling, "the backfill mode ends with the call")
}

func TestStampSyncedAt(t *testing.T) {
	start := syncedAtStart
	nowUnix := float64(start.Add(time.Minute).UnixNano()) / 1e9
	unix := func(t time.Time) float64 { return float64(t.Unix()) }
	cases := []struct {
		name        string
		firstCycle  time.Time
		backfilling bool
		ts          time.Time
		wantNow     bool
	}{
		{"established account, posted in the lookback", start.AddDate(0, 0, -30), false, start.Add(-23 * time.Hour), true},
		{"established account, posted at the lookback edge", start.AddDate(0, 0, -30), false, start.Add(-24 * time.Hour), true},
		{"established account, posted before the lookback", start.AddDate(0, 0, -30), false, start.Add(-25 * time.Hour), false},
		{"first run, posted before it started", start, false, start.Add(-time.Second), false},
		{"first run, posted as it started", start, false, start, true},
		{"second day, posted after the first cycle", start.Add(-2 * time.Hour), false, start.Add(-time.Hour), true},
		{"second day, posted before the first cycle", start.Add(-2 * time.Hour), false, start.Add(-3 * time.Hour), false},
		{"no first cycle recorded", time.Time{}, false, start.Add(-time.Hour), true},
		{"backfill", start.AddDate(0, 0, -30), true, start.Add(-time.Hour), false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			o := &Orchestrator{
				runStart: start, firstCycleAt: tc.firstCycle, backfilling: tc.backfilling,
				now: func() time.Time { return start.Add(time.Minute) },
			}
			want := unix(tc.ts)
			if tc.wantNow {
				want = nowUnix
			}
			assert.Equal(t, want, o.stampSyncedAt(unix(tc.ts)))
		})
	}
}

// first_cycle_at is written by the account's first run attempt; a retry of a
// first run that did not finish (Slack refused its search here) keeps it.
func TestFirstCycleAt_WrittenOnceAndKeptOnRetry(t *testing.T) {
	var mu gosync.Mutex
	failing := true
	tss := []string{slackTS(syncedAtStart)}
	ok := mentionSearch(&mu, &tss)
	handler := func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		f := failing
		mu.Unlock()
		if f {
			jsonOK(w, map[string]any{"ok": false, "error": "invalid_arguments"})
			return
		}
		ok(w, r)
	}
	now := syncedAtStart
	ts := newSyncedAtSetup(t, handler, &now)

	require.Error(t, ts.orch.Run(context.Background(), SyncOptions{}), "the first attempt fails")
	mu.Lock()
	failing = false
	mu.Unlock()
	now = syncedAtStart.Add(15 * time.Minute)
	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))

	first, err := ts.db.SlackFirstCycleAt(ts.accountID)
	require.NoError(t, err)
	assert.True(t, syncedAtStart.Equal(first), "got %v", first)
	assert.True(t, syncedAtStart.Equal(ts.orch.firstCycleAt), "the retry reads the first attempt back")
	assert.True(t, now.Equal(ts.orch.runStart))
}

// The mention query (run before the blanket search while the account is
// behind) stamps what it stores by the same rule: a late mention only it
// returns is still detected.
func TestInbox_MentionQueryStampsSyncedAt(t *testing.T) {
	late := slackTS(syncedAtStart.Add(-45 * time.Minute))
	other := slackTS(syncedAtStart.Add(-10 * time.Minute))
	handler := func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		ts, text := other, "unrelated"
		if strings.HasPrefix(r.FormValue("query"), "<@") {
			ts, text = late, "<@U001> ping"
		}
		jsonOK(w, map[string]any{
			"ok": true,
			"messages": map[string]any{
				"matches": []map[string]any{{"user": "U002", "username": "bob", "ts": ts, "text": text,
					"channel": map[string]any{"id": "C001", "name": "general"}}},
				"paging": map[string]any{"count": 100, "total": 1, "page": 1, "pages": 1},
				"total":  1,
			},
		})
	}
	now := syncedAtStart
	ts := newSyncedAtSetup(t, handler, &now)
	require.NoError(t, ts.db.UpdateSlackAccountConnection(ts.accountID, "T001", "Acme", "acme", ts.ns("U001")))
	require.NoError(t, ts.db.SetSlackFirstCycleAtOnce(ts.accountID, syncedAtStart.AddDate(0, 0, -30)))
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, "2026-11-14"))
	ts.orch.outcome.RateLimited = true // the previous run was throttled: behind

	require.NoError(t, ts.orch.Run(context.Background(), SyncOptions{}))

	assert.Equal(t, float64(syncedAtStart.Unix()), storedSyncedAt(t, ts, late))
	assert.Equal(t, []string{late}, detectedMentions(t, ts, syncedAtStart.Add(-30*time.Minute)))
}
