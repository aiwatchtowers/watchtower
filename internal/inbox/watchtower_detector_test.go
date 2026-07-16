package inbox

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
)

// newTestDB creates an in-memory DB for testing (alias used by this test file).
func newTestDB(t *testing.T) *db.DB {
	t.Helper()
	return testDB(t)
}

// seedDigestWithHighImportance inserts a digest row with the given situations JSON.
// createdAt sets the created_at timestamp of the digest.
func seedDigestWithHighImportance(t *testing.T, d *db.DB, channelID, situations string, createdAt time.Time) {
	t.Helper()
	ts := createdAt.UTC().Format(time.RFC3339)
	_, err := d.Exec(`INSERT INTO digests
		(channel_id, type, period_from, period_to, summary, situations, created_at)
		VALUES (?, 'channel', 0, 1, '', ?, ?)`,
		channelID, situations, ts)
	if err != nil {
		t.Fatalf("seedDigestWithHighImportance: %v", err)
	}
}

// seedBriefing inserts a briefing row for the given userID and date.
func seedBriefing(t *testing.T, d *db.DB, userID, date string) {
	t.Helper()
	ts := time.Now().UTC().Format(time.RFC3339)
	_, err := d.Exec(`INSERT INTO briefings
		(user_id, date, created_at)
		VALUES (?, ?, ?)`,
		userID, date, ts)
	if err != nil {
		t.Fatalf("seedBriefing: %v", err)
	}
}

func TestWatchtowerDetector_DecisionMade(t *testing.T) {
	d := newTestDB(t)
	seedDigestWithHighImportance(t, d, "C1",
		`[{"type":"decision","topic":"Release postponed","importance":"high"}]`,
		time.Now().Add(-30*time.Minute))

	n, err := DetectWatchtowerInternal(context.Background(), d, time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("want 1 decision_made, got %d", n)
	}
}

func TestWatchtowerDetector_BriefingReady(t *testing.T) {
	d := newTestDB(t)
	seedBriefing(t, d, "alice", time.Now().Format("2006-01-02"))

	n, err := DetectWatchtowerInternal(context.Background(), d, time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n < 1 {
		t.Errorf("want >=1 briefing_ready, got %d", n)
	}
}

func TestWatchtowerDetector_LowImportanceSkipped(t *testing.T) {
	d := newTestDB(t)
	seedDigestWithHighImportance(t, d, "C1",
		`[{"type":"decision","topic":"minor","importance":"low"}]`,
		time.Now())

	n, err := DetectWatchtowerInternal(context.Background(), d, time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("low-importance should be skipped, got %d", n)
	}
}

func TestWatchtowerDetector_Dedup(t *testing.T) {
	d := newTestDB(t)
	seedDigestWithHighImportance(t, d, "C1",
		`[{"type":"decision","topic":"Release postponed","importance":"high"}]`,
		time.Now().Add(-30*time.Minute))

	// First run: creates 1 item.
	n1, err := DetectWatchtowerInternal(context.Background(), d, time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n1 != 1 {
		t.Fatalf("first run: want 1, got %d", n1)
	}

	// Second run: should not create a duplicate.
	n2, err := DetectWatchtowerInternal(context.Background(), d, time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n2 != 0 {
		t.Errorf("second run: want 0 duplicates, got %d", n2)
	}
}

func TestWatchtowerDetector_MultipleDecisions(t *testing.T) {
	d := newTestDB(t)
	// Two high-importance decisions in one digest.
	seedDigestWithHighImportance(t, d, "C1",
		`[{"type":"decision","topic":"A","importance":"high"},{"type":"decision","topic":"B","importance":"high"},{"type":"decision","topic":"C","importance":"low"}]`,
		time.Now().Add(-30*time.Minute))

	n, err := DetectWatchtowerInternal(context.Background(), d, time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Errorf("want 2 high-importance decisions, got %d", n)
	}
}

func TestWatchtowerDetector_OlderThanSinceSkipped(t *testing.T) {
	d := newTestDB(t)
	// Digest created 2 hours ago, but sinceTS is 1 hour ago.
	seedDigestWithHighImportance(t, d, "C1",
		`[{"type":"decision","topic":"Old","importance":"high"}]`,
		time.Now().Add(-2*time.Hour))

	n, err := DetectWatchtowerInternal(context.Background(), d, time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("old digest should be skipped, got %d items", n)
	}
}

func TestWatchtowerDetector_BriefingDedup(t *testing.T) {
	d := newTestDB(t)
	seedBriefing(t, d, "alice", time.Now().Format("2006-01-02"))

	n1, err := DetectWatchtowerInternal(context.Background(), d, time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n1 < 1 {
		t.Fatalf("first run: want >=1, got %d", n1)
	}

	n2, err := DetectWatchtowerInternal(context.Background(), d, time.Now().Add(-1*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n2 != 0 {
		t.Errorf("second run: want 0 duplicates, got %d", n2)
	}
}

// seedInboxItemForWT inserts a minimal inbox item and returns its ID (used by dedup tests).
func seedInboxItemForWT(t *testing.T, d *db.DB, channelID, msgTS, triggerType string) int64 {
	t.Helper()
	id, err := d.CreateInboxItem(db.InboxItem{
		ChannelID:    channelID,
		MessageTS:    msgTS,
		SenderUserID: "watchtower",
		TriggerType:  triggerType,
		Snippet:      fmt.Sprintf("test %s", triggerType),
		Status:       "pending",
	})
	if err != nil {
		t.Fatalf("seedInboxItemForWT: %v", err)
	}
	return id
}

// seedDisputeBelief indexes a belief node and flags it dispute_pending, the
// state the memory pipeline leaves behind for the inbox dispute reader (Task 6).
func seedDisputeBelief(t *testing.T, d *db.DB, id, title string) {
	t.Helper()
	if err := d.UpsertMemoryNode(db.MemoryNodeRow{
		ID:         id,
		Type:       "belief",
		Tier:       "long",
		Status:     "active",
		Title:      title,
		Path:       "beliefs/" + id + ".md",
		Subject:    "ent_x",
		Confidence: 0.5,
	}, title, nil); err != nil {
		t.Fatalf("seedDisputeBelief upsert %s: %v", id, err)
	}
	if err := d.SetDisputePending(id, "evidence conflicts"); err != nil {
		t.Fatalf("seedDisputeBelief flag %s: %v", id, err)
	}
}

// countMemoryDisputeItems returns how many decision_made items the dispute
// reader has minted (channel_id='memory').
func countMemoryDisputeItems(t *testing.T, d *db.DB) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM inbox_items
		WHERE channel_id='memory' AND trigger_type='decision_made'`).Scan(&n); err != nil {
		t.Fatalf("countMemoryDisputeItems: %v", err)
	}
	return n
}

// countDisputeFlags returns how many memory_dispute_flags rows remain.
func countDisputeFlags(t *testing.T, d *db.DB) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM memory_dispute_flags`).Scan(&n); err != nil {
		t.Fatalf("countDisputeFlags: %v", err)
	}
	return n
}

func TestWatchtowerDetector_DisputeMinted(t *testing.T) {
	d := newTestDB(t)
	seedDisputeBelief(t, d, "bel_release", "The release is on track")

	n, err := detectMemoryDisputes(d, true)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want 1 dispute item, got %d", n)
	}

	// The minted item carries the watchtower dispute shape.
	var chID, msgTS, sender, trig, snippet, class string
	if err := d.QueryRow(`SELECT channel_id, message_ts, sender_user_id, trigger_type, snippet, item_class
		FROM inbox_items WHERE channel_id='memory'`).Scan(&chID, &msgTS, &sender, &trig, &snippet, &class); err != nil {
		t.Fatalf("loading minted item: %v", err)
	}
	if chID != "memory" || msgTS != "dispute:bel_release" || sender != "watchtower" || trig != "decision_made" {
		t.Errorf("unexpected item identity: ch=%q ts=%q sender=%q trig=%q", chID, msgTS, sender, trig)
	}
	if class != "ambient" {
		t.Errorf("decision_made defaults to ambient item_class, got %q", class)
	}
	for _, want := range []string{"The release is on track", "evidence conflicts", "[[bel_release]]"} {
		if !strings.Contains(snippet, want) {
			t.Errorf("snippet %q missing %q", snippet, want)
		}
	}

	// The flag was cleared in the same run — a dispute surfaces exactly once.
	if got := countDisputeFlags(t, d); got != 0 {
		t.Errorf("flag should be cleared after minting, %d remain", got)
	}
}

func TestWatchtowerDetector_DisputeSecondRunNoDuplicate(t *testing.T) {
	d := newTestDB(t)
	seedDisputeBelief(t, d, "bel_release", "The release is on track")

	if n, err := detectMemoryDisputes(d, true); err != nil || n != 1 {
		t.Fatalf("first run: want 1, got %d (err=%v)", n, err)
	}
	if n, err := detectMemoryDisputes(d, true); err != nil || n != 0 {
		t.Fatalf("second run: want 0 duplicates, got %d (err=%v)", n, err)
	}
	if got := countMemoryDisputeItems(t, d); got != 1 {
		t.Errorf("want exactly 1 dispute item after two runs, got %d", got)
	}
}

func TestWatchtowerDetector_DisputeCapPerCycle(t *testing.T) {
	d := newTestDB(t)
	// Three disputes flagged; the per-cycle cap is <=2.
	seedDisputeBelief(t, d, "bel_a", "Belief A")
	seedDisputeBelief(t, d, "bel_b", "Belief B")
	seedDisputeBelief(t, d, "bel_c", "Belief C")

	n, err := detectMemoryDisputes(d, true)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("cap: want 2 items this cycle, got %d", n)
	}
	if got := countDisputeFlags(t, d); got != 1 {
		t.Errorf("cap: third flag should survive for the next cycle, %d remain", got)
	}

	// Next cycle drains the survivor.
	n2, err := detectMemoryDisputes(d, true)
	if err != nil {
		t.Fatal(err)
	}
	if n2 != 1 {
		t.Fatalf("next cycle: want the surviving 1, got %d", n2)
	}
	if got := countDisputeFlags(t, d); got != 0 {
		t.Errorf("all flags should be drained, %d remain", got)
	}
}

func TestWatchtowerDetector_DisputeGateOff(t *testing.T) {
	d := newTestDB(t)
	seedDisputeBelief(t, d, "bel_release", "The release is on track")

	n, err := detectMemoryDisputes(d, false)
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("gate off: want 0 items, got %d", n)
	}
	if got := countMemoryDisputeItems(t, d); got != 0 {
		t.Errorf("gate off: no items should exist, got %d", got)
	}
	if got := countDisputeFlags(t, d); got != 1 {
		t.Errorf("gate off: flag must stay intact, got %d", got)
	}
}

// liveMemoryDisputeCount returns how many dispute items are still LIVE (not
// archived, not resolved/dismissed) — the liveness predicate the dedup keys on.
func liveMemoryDisputeCount(t *testing.T, d *db.DB) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM inbox_items
		WHERE channel_id='memory' AND trigger_type='decision_made'
		  AND archived_at IS NULL AND status NOT IN ('resolved','dismissed')`).Scan(&n); err != nil {
		t.Fatalf("liveMemoryDisputeCount: %v", err)
	}
	return n
}

// TestWatchtowerDetector_DisputeRemintAfterArchive proves the dedup keys only on
// LIVE items: once the first dispute item has been archived, a re-flagged belief
// surfaces the dispute again (M2 — an archived item must never suppress a
// re-dispute forever).
func TestWatchtowerDetector_DisputeRemintAfterArchive(t *testing.T) {
	d := newTestDB(t)
	seedDisputeBelief(t, d, "bel_release", "The release is on track")

	// First cycle mints one item and clears the flag.
	if n, err := detectMemoryDisputes(d, true); err != nil || n != 1 {
		t.Fatalf("first mint: want 1, got %d (err=%v)", n, err)
	}

	// The owner (or the archive sweep) archives the dispute item.
	if _, err := d.Exec(`UPDATE inbox_items SET archived_at='2026-07-16T00:00:00Z', archive_reason='seen_expired'
		WHERE channel_id='memory' AND message_ts='dispute:bel_release'`); err != nil {
		t.Fatalf("archiving dispute item: %v", err)
	}
	if got := liveMemoryDisputeCount(t, d); got != 0 {
		t.Fatalf("after archive: want 0 live items, got %d", got)
	}

	// The belief flaps again — reflection re-flags it.
	if err := d.SetDisputePending("bel_release", "evidence conflicts again"); err != nil {
		t.Fatalf("re-flag: %v", err)
	}

	// The re-dispute surfaces: the dead row is revived to a fresh live item.
	if n, err := detectMemoryDisputes(d, true); err != nil || n != 1 {
		t.Fatalf("re-mint after archive: want 1, got %d (err=%v)", n, err)
	}
	if got := liveMemoryDisputeCount(t, d); got != 1 {
		t.Errorf("re-dispute must be live again, got %d live", got)
	}
	if got := countDisputeFlags(t, d); got != 0 {
		t.Errorf("flag should be cleared after re-mint, %d remain", got)
	}
	// Still a single row (UNIQUE identity preserved — revived, not duplicated).
	if got := countMemoryDisputeItems(t, d); got != 1 {
		t.Errorf("want exactly 1 dispute row (revived in place), got %d", got)
	}
	// The revived row is pending again, not archived.
	var status string
	var archivedAt *string
	if err := d.QueryRow(`SELECT status, archived_at FROM inbox_items
		WHERE channel_id='memory' AND message_ts='dispute:bel_release'`).Scan(&status, &archivedAt); err != nil {
		t.Fatalf("loading revived item: %v", err)
	}
	if status != "pending" || archivedAt != nil {
		t.Errorf("revived item should be pending+unarchived, got status=%q archived=%v", status, archivedAt)
	}
}

// TestWatchtowerDetector_DisputeLiveItemReflagNoDuplicate proves a re-flag while
// the prior dispute item is still LIVE produces no duplicate — the flag is
// cleared and the single open item is left untouched (M2).
func TestWatchtowerDetector_DisputeLiveItemReflagNoDuplicate(t *testing.T) {
	d := newTestDB(t)
	seedDisputeBelief(t, d, "bel_release", "The release is on track")
	if n, err := detectMemoryDisputes(d, true); err != nil || n != 1 {
		t.Fatalf("first mint: want 1, got %d (err=%v)", n, err)
	}

	// Re-flag WITHOUT archiving — the item is still open on the dashboard.
	if err := d.SetDisputePending("bel_release", "evidence conflicts again"); err != nil {
		t.Fatalf("re-flag: %v", err)
	}
	if n, err := detectMemoryDisputes(d, true); err != nil || n != 0 {
		t.Fatalf("re-flag with live item: want 0 (no dup), got %d (err=%v)", n, err)
	}
	if got := countMemoryDisputeItems(t, d); got != 1 {
		t.Errorf("want exactly 1 dispute item (no duplicate), got %d", got)
	}
	if got := countDisputeFlags(t, d); got != 0 {
		t.Errorf("flag should be cleared even when no dup is minted, %d remain", got)
	}
}

// TestWatchtowerDetector_DisputeMintErrorLeavesFlag proves mint+clear are one
// transaction: a colliding inbox item makes the dispute INSERT fail on the
// UNIQUE(channel_id, message_ts) constraint, so the flag must NOT be cleared —
// the dispute survives for a later cycle rather than being lost.
func TestWatchtowerDetector_DisputeMintErrorLeavesFlag(t *testing.T) {
	d := newTestDB(t)
	seedDisputeBelief(t, d, "bel_release", "The release is on track")
	// A pre-existing row at the same (channel_id, message_ts) but a different
	// trigger_type slips past the decision_made dedup check and collides on the
	// UNIQUE index when the dispute INSERT runs.
	if _, err := d.Exec(`INSERT INTO inbox_items
		(channel_id, message_ts, sender_user_id, trigger_type, snippet, status, priority, item_class)
		VALUES ('memory','dispute:bel_release','watchtower','briefing_ready','collision','pending','low','ambient')`); err != nil {
		t.Fatalf("seeding collision row: %v", err)
	}

	_, err := detectMemoryDisputes(d, true)
	if err == nil {
		t.Fatal("want an error when the dispute mint collides")
	}
	// The DELETE rode the same rolled-back tx, so the flag must survive.
	if got := countDisputeFlags(t, d); got != 1 {
		t.Errorf("flag must survive a failed mint (atomic tx), %d remain", got)
	}
}
