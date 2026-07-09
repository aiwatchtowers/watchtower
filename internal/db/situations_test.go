package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// seedWorkspace is a shared fixture helper for tests needing a workspace row.
func seedWorkspace(t *testing.T, d *DB) {
	t.Helper()
	require.NoError(t, d.UpsertWorkspace(Workspace{ID: "T1", Name: "test", Domain: "test.slack.com"}))
}

func TestSituationRoundTripAndSignals(t *testing.T) {
	d := openTestDB(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "sig one")
	insertMessage(t, d, "C1", "2.1", "U2", "sig two")
	sig1 := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream"})
	sig2 := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "mention"})

	id, err := d.CreateSituation(DashboardSituation{Title: "release X blocked", Kind: "external", Priority: "high", Rank: 0.9, AIReason: "prod impact"})
	require.NoError(t, err)
	s, err := d.GetSituation(int(id))
	require.NoError(t, err)
	require.Equal(t, "open", s.Status, "status must default open")
	require.Equal(t, "none", s.CardStatus)

	require.NoError(t, d.AddSituationSignals(int(id), []int{int(sig1), int(sig2)}))
	require.NoError(t, d.AddSituationSignals(int(id), []int{int(sig1)})) // idempotent
	members, err := d.ListSituationSignals(int(id))
	require.NoError(t, err)
	require.Len(t, members, 2)

	open, err := d.ListOpenSituations()
	require.NoError(t, err)
	require.Len(t, open, 1)
}

func TestComposeWatermarkRoundTrip(t *testing.T) {
	d := openTestDB(t)
	seedWorkspace(t, d) // use this file's actual workspace fixture helper
	ts, err := d.GetComposeLastRunTS()
	require.NoError(t, err)
	require.Equal(t, 0.0, ts)
	require.NoError(t, d.SetComposeLastRunTS(123.5))
	ts, _ = d.GetComposeLastRunTS()
	require.Equal(t, 123.5, ts)
}

func TestInboxItemComposedAtRoundTrip(t *testing.T) {
	// create item → ComposedAt empty; UPDATE via MarkSignalsComposed comes in Task 3,
	// here only assert the column scans (create + Get → ComposedAt == "").
	d := openTestDB(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "sig one")
	id := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream"})

	it, err := d.GetInboxItem(id)
	require.NoError(t, err)
	require.Equal(t, "", it.ComposedAt)
}

func TestListUncomposedSignals_OrderCapAndMark(t *testing.T) {
	d := openTestDB(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "one")
	insertMessage(t, d, "C1", "2.1", "U2", "two")
	insertMessage(t, d, "C1", "3.1", "U2", "three")
	id1 := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream"})
	id2 := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "stream"})
	id3 := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "3.1", SenderUserID: "U2", TriggerType: "stream"})

	items, err := d.ListUncomposedSignals(2)
	require.NoError(t, err)
	require.Len(t, items, 2)
	require.Equal(t, int(id1), items[0].ID)
	require.Equal(t, int(id2), items[1].ID)

	require.NoError(t, d.MarkSignalsComposed([]int{int(id1), int(id2)}))

	items, err = d.ListUncomposedSignals(10)
	require.NoError(t, err)
	require.Len(t, items, 1)
	require.Equal(t, int(id3), items[0].ID)

	// Auto-archived items (ArchiveExpiredAmbient/ArchiveStaleActionable) keep
	// status='pending' — only archived_at/archive_reason are set — so without
	// an archived_at filter the oldest-first scan would resurface months-old
	// auto-archived junk ahead of id3. Archive id3 directly (mirroring what
	// the archive helpers actually write) and assert it's excluded.
	_, err = d.Exec(`UPDATE inbox_items SET archived_at = ?, archive_reason = 'seen_expired' WHERE id = ?`,
		time.Now().UTC().Format(time.RFC3339), id3)
	require.NoError(t, err)

	items, err = d.ListUncomposedSignals(10)
	require.NoError(t, err)
	require.Empty(t, items, "archived-but-still-pending signals must be excluded from the compose feed")
}

func TestListTrackEventsSince_OnlyNewAndNonDismissed(t *testing.T) {
	d := openTestDB(t)
	liveTrackID, err := d.UpsertTrack(Track{Text: "live track", Priority: "medium"})
	require.NoError(t, err)
	deadTrackID, err := d.UpsertTrack(Track{Text: "dismissed track", Priority: "medium"})
	require.NoError(t, err)
	require.NoError(t, d.DismissTrack(int(deadTrackID)))

	// Old event on the live track — inserted via raw SQL with an explicit past created_at,
	// since InsertTrackEvent always defaults created_at=now.
	_, err = d.Exec(`INSERT INTO track_events (track_id, summary, source_type, source_id, created_at)
		VALUES (?, ?, ?, ?, ?)`, liveTrackID, "old event", "test", "1", "2020-01-01T00:00:00Z")
	require.NoError(t, err)

	newEventID, err := d.InsertTrackEvent(TrackEvent{TrackID: int(liveTrackID), Summary: "new event", SourceType: "test", SourceID: "2"})
	require.NoError(t, err)

	// Event on the dismissed track after the watermark — must be excluded.
	_, err = d.InsertTrackEvent(TrackEvent{TrackID: int(deadTrackID), Summary: "dismissed track event", SourceType: "test", SourceID: "3"})
	require.NoError(t, err)

	events, err := d.ListTrackEventsSince("2021-01-01T00:00:00Z")
	require.NoError(t, err)
	require.Len(t, events, 1)
	require.Equal(t, newEventID, events[0].ID)
}

func TestListTargetsUpdatedSince_ActiveOnly(t *testing.T) {
	d := openTestDB(t)
	ts := "2026-01-15T00:00:00Z"

	activeAfterID, err := d.CreateTarget(Target{Text: "active after", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	doneAfterID, err := d.CreateTarget(Target{Text: "done after", Status: "done", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	activeBeforeID, err := d.CreateTarget(Target{Text: "active before", Status: "in_progress", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	_, err = d.Exec(`UPDATE targets SET updated_at = ? WHERE id = ?`, "2026-01-20T00:00:00Z", activeAfterID)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE targets SET updated_at = ? WHERE id = ?`, "2026-01-20T00:00:00Z", doneAfterID)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE targets SET updated_at = ? WHERE id = ?`, "2026-01-10T00:00:00Z", activeBeforeID)
	require.NoError(t, err)

	targets, err := d.ListTargetsUpdatedSince(ts)
	require.NoError(t, err)
	require.Len(t, targets, 1)
	require.Equal(t, int(activeAfterID), targets[0].ID)
}

// TestListTargetsUpdatedSince_ExcludesJustConvertedTarget pins the fix for a
// duplication bug: converting a situation into a target bumps the target's
// own updated_at, so without this exclusion the very next compose cycle
// would pick the freshly-converted target back up and spawn a target_update
// situation about the target's own creation. The exclusion only holds while
// the owning situation's updated_at is itself within the query window — once
// the compose watermark advances past the conversion moment (simulated here
// by backdating the situation), a later, genuine update to the target
// surfaces normally again.
func TestListTargetsUpdatedSince_ExcludesJustConvertedTarget(t *testing.T) {
	d := openTestDB(t)
	ts := "2020-01-01T00:00:00Z"

	targetID, err := d.CreateTarget(Target{Text: "converted target", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	situationID, err := d.CreateSituation(DashboardSituation{Title: "convert me"})
	require.NoError(t, err)

	require.NoError(t, d.MarkSituationConverted(int(situationID), int(targetID), 0))

	targets, err := d.ListTargetsUpdatedSince(ts)
	require.NoError(t, err)
	require.Empty(t, targets, "just-converted target must not surface as its own target_update")

	// Backdate the situation's updated_at to before the watermark, simulating
	// the compose cycle having already moved past the conversion moment.
	_, err = d.Exec(`UPDATE situations SET updated_at = ? WHERE id = ?`, "2019-01-01T00:00:00Z", situationID)
	require.NoError(t, err)

	targets, err = d.ListTargetsUpdatedSince(ts)
	require.NoError(t, err)
	require.Len(t, targets, 1, "a later real update to the target must surface once the conversion ages out of the window")
	require.Equal(t, int(targetID), targets[0].ID)
}

func TestSituationCardLifecycle(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateSituation(DashboardSituation{Title: "needs card"})
	require.NoError(t, err)

	needing, err := d.ListSituationsNeedingCards()
	require.NoError(t, err)
	require.Len(t, needing, 1)
	require.Equal(t, int(id), needing[0].ID)

	require.NoError(t, d.SetSituationCard(int(id), "summary", "why", "chronology"))
	s, err := d.GetSituation(int(id))
	require.NoError(t, err)
	require.Equal(t, "ready", s.CardStatus)
	require.NotEmpty(t, s.CardGeneratedAt)
	require.Equal(t, "summary", s.Summary)

	needing, err = d.ListSituationsNeedingCards()
	require.NoError(t, err)
	require.Len(t, needing, 0)

	require.NoError(t, d.ResetSituationCard(int(id)))
	s, err = d.GetSituation(int(id))
	require.NoError(t, err)
	require.Equal(t, "none", s.CardStatus)

	needing, err = d.ListSituationsNeedingCards()
	require.NoError(t, err)
	require.Len(t, needing, 1)

	require.NoError(t, d.MarkSituationCardFailed(int(id)))
	s, err = d.GetSituation(int(id))
	require.NoError(t, err)
	require.Equal(t, "failed", s.CardStatus)

	needing, err = d.ListSituationsNeedingCards()
	require.NoError(t, err)
	require.Len(t, needing, 1)
}

func TestSituationLifecycle_SnoozeStaleAutoclose(t *testing.T) {
	d := openTestDB(t)

	snoozeID, err := d.CreateSituation(DashboardSituation{Title: "snoozed one"})
	require.NoError(t, err)
	past := time.Now().UTC().Add(-time.Hour).Format("2006-01-02T15:04:05Z")
	require.NoError(t, d.SnoozeSituation(int(snoozeID), past))
	s, err := d.GetSituation(int(snoozeID))
	require.NoError(t, err)
	require.Equal(t, "snoozed", s.Status)
	require.Equal(t, past, s.SnoozeUntil)

	n, err := d.UnsnoozeExpiredSituations()
	require.NoError(t, err)
	require.Equal(t, 1, n)
	s, err = d.GetSituation(int(snoozeID))
	require.NoError(t, err)
	require.Equal(t, "open", s.Status)

	// Stale: one old, one fresh, one with empty last_signal_at.
	staleID, err := d.CreateSituation(DashboardSituation{Title: "stale candidate"})
	require.NoError(t, err)
	oldTS := time.Now().UTC().Add(-8 * 24 * time.Hour).Format("2006-01-02T15:04:05Z")
	_, err = d.Exec(`UPDATE situations SET last_signal_at = ? WHERE id = ?`, oldTS, staleID)
	require.NoError(t, err)

	freshID, err := d.CreateSituation(DashboardSituation{Title: "fresh"})
	require.NoError(t, err)
	freshTS := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	_, err = d.Exec(`UPDATE situations SET last_signal_at = ? WHERE id = ?`, freshTS, freshID)
	require.NoError(t, err)

	emptyID, err := d.CreateSituation(DashboardSituation{Title: "no signal yet"})
	require.NoError(t, err)

	n, err = d.MarkStaleSituations(7 * 24 * time.Hour)
	require.NoError(t, err)
	require.Equal(t, 1, n)
	s, err = d.GetSituation(int(staleID))
	require.NoError(t, err)
	require.Equal(t, "stale", s.Status)
	s, err = d.GetSituation(int(freshID))
	require.NoError(t, err)
	require.Equal(t, "open", s.Status)
	s, err = d.GetSituation(int(emptyID))
	require.NoError(t, err)
	require.Equal(t, "open", s.Status)

	// Autoclose: situation A resolved member, situation B pending member, situation C no members.
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "resolved sig")
	insertMessage(t, d, "C1", "2.1", "U2", "pending sig")
	resolvedItemID := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream"})
	pendingItemID := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "stream"})
	_, err = d.Exec(`UPDATE inbox_items SET status = 'resolved' WHERE id = ?`, resolvedItemID)
	require.NoError(t, err)

	situationAID, err := d.CreateSituation(DashboardSituation{Title: "A resolved"})
	require.NoError(t, err)
	require.NoError(t, d.AddSituationSignals(int(situationAID), []int{int(resolvedItemID)}))

	situationBID, err := d.CreateSituation(DashboardSituation{Title: "B pending"})
	require.NoError(t, err)
	require.NoError(t, d.AddSituationSignals(int(situationBID), []int{int(pendingItemID)}))

	situationCID, err := d.CreateSituation(DashboardSituation{Title: "C no members"})
	require.NoError(t, err)

	n, err = d.AutoCloseResolvedSituations()
	require.NoError(t, err)
	require.Equal(t, 1, n)

	s, err = d.GetSituation(int(situationAID))
	require.NoError(t, err)
	require.Equal(t, "done", s.Status)
	require.Equal(t, "signals_resolved", s.ResolvedReason)

	s, err = d.GetSituation(int(situationBID))
	require.NoError(t, err)
	require.Equal(t, "open", s.Status)

	s, err = d.GetSituation(int(situationCID))
	require.NoError(t, err)
	require.Equal(t, "open", s.Status)
}

func TestMarkSituationConverted(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateSituation(DashboardSituation{Title: "convert me"})
	require.NoError(t, err)
	targetID, err := d.CreateTarget(Target{Text: "converted target", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	require.NoError(t, d.MarkSituationConverted(int(id), int(targetID), 0))

	s, err := d.GetSituation(int(id))
	require.NoError(t, err)
	require.Equal(t, "converted", s.Status)
	require.NotNil(t, s.ConvertedTargetID)
	require.Equal(t, int(targetID), *s.ConvertedTargetID)
	require.Nil(t, s.ConvertedTrackID)
}

func TestSuggestedResolutionSetAndClear(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateSituation(DashboardSituation{Title: "story", Kind: "external", Priority: "medium"})
	require.NoError(t, err)

	tx, err := d.Begin()
	require.NoError(t, err)
	require.NoError(t, d.SetSuggestedResolutionTx(tx, int(id), "answered in thread"))
	require.NoError(t, tx.Commit())

	got, err := d.GetSituation(int(id))
	require.NoError(t, err)
	require.Equal(t, "answered in thread", got.SuggestedResolution)
	require.Equal(t, "open", got.Status, "DASH-07: suggestion must never change status")

	require.NoError(t, d.ClearSuggestedResolution(int(id)))

	got, err = d.GetSituation(int(id))
	require.NoError(t, err)
	require.Equal(t, "", got.SuggestedResolution)
}
