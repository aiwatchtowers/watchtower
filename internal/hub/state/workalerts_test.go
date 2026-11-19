package state

import (
	"context"
	"database/sql"
	"testing"
	"time"
)

func TestNoteWorkAlerts_SeenThenPushedOnce(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	t0 := time.Unix(1_800_000_000, 0).UTC()

	gen, marks, err := s.NoteWorkAlerts(ctx, []string{"ask-1", "perm-2"}, nil, t0)
	if err != nil {
		t.Fatal(err)
	}
	if gen != 0 || len(marks) != 2 || marks["ask-1"].Pushed() || !marks["ask-1"].SeenAt.Equal(t0) {
		t.Fatalf("first note: gen %d marks %+v", gen, marks)
	}
	t1 := t0.Add(time.Minute)
	_, marks, err = s.NoteWorkAlerts(ctx, []string{"ask-1"}, map[string]bool{"ask-1": true}, t1)
	if err != nil {
		t.Fatal(err)
	}
	if m := marks["ask-1"]; !m.SeenAt.Equal(t0) || !m.PushedAt.Equal(t1) {
		t.Fatalf("pushed: %+v", m)
	}
	_, marks, err = s.NoteWorkAlerts(ctx, []string{"ask-1"}, map[string]bool{"ask-1": true}, t1.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if !marks["ask-1"].PushedAt.Equal(t1) {
		t.Fatalf("a pushed key never pushes again: %+v", marks["ask-1"])
	}
}

func TestPruneWorkAlertsKeepsCurrentKeys(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	t0 := time.Unix(1_800_000_000, 0).UTC()
	if _, _, err := s.NoteWorkAlerts(ctx, []string{"ask-1", "ask-2"}, nil, t0); err != nil {
		t.Fatal(err)
	}
	if err := s.PruneWorkAlerts(ctx, t0.Add(time.Second), map[string]bool{"ask-2": true}); err != nil {
		t.Fatal(err)
	}
	_, marks, err := s.NoteWorkAlerts(ctx, nil, nil, t0)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := marks["ask-1"]; ok || len(marks) != 1 {
		t.Fatalf("marks after prune: %+v", marks)
	}
}

// A rotation bumps the sync generation and moves the current generation's
// alerts with it (HubSyncState.wipeForRotation): they stay published.
func TestMoveWorkAlertsForRotation(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	t0 := time.Unix(1_800_000_000, 0).UTC()
	if _, _, err := s.NoteWorkAlerts(ctx, []string{"ask-1"}, map[string]bool{"ask-1": true}, t0); err != nil {
		t.Fatal(err)
	}
	if err := s.WithTx(ctx, func(tx *sql.Tx) error {
		if _, err := tx.Exec(`INSERT INTO work_alerts (key, seen_at, generation) VALUES ('ask-old', 0, 7)`); err != nil {
			return err
		}
		return MoveWorkAlertsForRotation(tx)
	}); err != nil {
		t.Fatal(err)
	}
	gen, marks, err := s.NoteWorkAlerts(ctx, nil, nil, t0)
	if err != nil {
		t.Fatal(err)
	}
	if gen != 1 || marks["ask-1"].Generation != 1 || marks["ask-old"].Generation != 7 {
		t.Fatalf("gen %d marks %+v", gen, marks)
	}
	if g, err := s.SyncGeneration(); err != nil || g != 1 {
		t.Fatalf("SyncGeneration = %d, %v", g, err)
	}
}

func TestEnsureMetaTimeKeepsTheFirstStampInSwiftForm(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	t0 := time.Unix(1_800_000_000, 0).UTC()
	got, err := s.EnsureMetaTime(ctx, MetaWorkAlertsAwaySince, t0)
	if err != nil || !got.Equal(t0) {
		t.Fatalf("first = %v, %v", got, err)
	}
	if raw, _, _ := s.Meta(MetaWorkAlertsAwaySince); raw != "1800000000.0" {
		t.Fatalf("stored %q, want Swift's String(Double)", raw)
	}
	got, err = s.EnsureMetaTime(ctx, MetaWorkAlertsAwaySince, t0.Add(time.Hour))
	if err != nil || !got.Equal(t0) {
		t.Fatalf("second = %v, %v", got, err)
	}
	if err := s.DeleteMeta(MetaWorkAlertsAwaySince); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := s.Meta(MetaWorkAlertsAwaySince); ok {
		t.Fatal("not deleted")
	}
	if SwiftSeconds(time.Unix(1_800_000_000, 500_000_000)) != "1800000000.5" {
		t.Fatal("fraction form")
	}
}

// twin of HubSyncStateWorkAlertsTests.testAPushNotesAnUnseenKeyAndLeavesOthersAlone.
func TestNoteWorkAlerts_APushNotesAnUnseenKeyAndLeavesOthersAlone(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	t0 := time.Unix(1_800_000_000, 0).UTC()
	if _, _, err := s.NoteWorkAlerts(ctx, []string{"ask-1"}, nil, t0); err != nil {
		t.Fatal(err)
	}
	at := t0.Add(5 * time.Second)
	_, marks, err := s.NoteWorkAlerts(ctx, []string{"ask-1", "ask-2"}, map[string]bool{"ask-2": true}, at)
	if err != nil {
		t.Fatal(err)
	}
	if m := marks["ask-2"]; !m.SeenAt.Equal(at) || !m.PushedAt.Equal(at) || m.Generation != 0 {
		t.Fatalf("ask-2 = %+v: an unseen key pushed is noted seen and pushed at once", m)
	}
	if marks["ask-1"].Pushed() {
		t.Fatalf("ask-1 = %+v: a key not named is not pushed", marks["ask-1"])
	}
}

// twin of HubSyncStateWorkAlertsTests.testAPushMovesASeenRowToTheCurrentGeneration:
// a row only seen in an earlier generation is pushed in the current one, so
// the push is published; its first sighting stays.
func TestNoteWorkAlerts_APushMovesASeenRowToTheCurrentGeneration(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	t0 := time.Unix(1_800_000_000, 0).UTC()
	if _, _, err := s.NoteWorkAlerts(ctx, []string{"stop-3-1"}, nil, t0); err != nil {
		t.Fatal(err)
	}
	// A generation bump that left the seen row behind (it outlived a reset).
	if err := s.WithTx(ctx, func(tx *sql.Tx) error { return SetMetaTx(tx, MetaSyncGeneration, "1") }); err != nil {
		t.Fatal(err)
	}
	if _, marks, err := s.NoteWorkAlerts(ctx, nil, nil, t0); err != nil || marks["stop-3-1"].Generation != 0 {
		t.Fatalf("before the push: %+v %v", marks["stop-3-1"], err)
	}
	gen, marks, err := s.NoteWorkAlerts(ctx, []string{"stop-3-1"}, map[string]bool{"stop-3-1": true}, t0.Add(9*24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if m := marks["stop-3-1"]; gen != 1 || m.Generation != 1 || !m.SeenAt.Equal(t0) || !m.Pushed() {
		t.Fatalf("gen %d stop-3-1 = %+v", gen, m)
	}
}

// twin of HubSyncStateWorkAlertsTests.testWipeBumpsGenerationAndKeepsPublishedRows
// (and of HubSyncState.wipeSyncState's token half): the CloudKit reset bumps
// the generation, keeps a published alert's row in its old generation,
// forgets an unconfirmed one of the wiped generation, wipes every
// slice_state row and the named mailboxes' tokens only, and keeps the
// ledger and hub_meta.
func TestWipeSyncStateBumpsGenerationAndKeepsPublishedRows(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	t0 := time.Unix(1_800_000_000, 0).UTC()
	if _, _, err := s.NoteWorkAlerts(ctx, []string{"ask-1", "ask-2"}, nil, t0); err != nil {
		t.Fatal(err)
	}
	// Seen before the alert lifetime's start: expired, not news after a reset.
	if _, _, err := s.NoteWorkAlerts(ctx, []string{"ask-3"}, nil, t0.Add(-2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := s.WithTx(ctx, func(tx *sql.Tx) error {
		if err := SetSliceState(tx, "ask_alert-ask-1", "w1", "h", t0); err != nil {
			return err
		}
		if err := SetSliceState(tx, "workbench-1", "w2", "h", t0); err != nil {
			return err
		}
		if err := SetZoneTokenTx(tx, "relay/r/*", 7); err != nil {
			return err
		}
		if err := SetZoneTokenTx(tx, "relay/r/phone", 9); err != nil {
			return err
		}
		if err := SetMetaTx(tx, MetaHubID, "hub-acme"); err != nil {
			return err
		}
		return MarkDone(tx, "action-1", "applied", nil, nil, t0)
	}); err != nil {
		t.Fatal(err)
	}

	if err := s.WipeSyncState(ctx, t0.Add(-time.Hour), "relay/r/*"); err != nil {
		t.Fatal(err)
	}

	if g, err := s.SyncGeneration(); err != nil || g != 1 {
		t.Fatalf("generation %d, %v", g, err)
	}
	_, marks, err := s.NoteWorkAlerts(ctx, nil, nil, t0)
	if err != nil {
		t.Fatal(err)
	}
	if m, ok := marks["ask-1"]; !ok || m.Generation != 0 {
		t.Fatalf("a published row keeps its old generation: %+v", marks)
	}
	if _, ok := marks["ask-2"]; ok {
		t.Fatalf("an unconfirmed row of the wiped generation is forgotten: %+v", marks)
	}
	if m, ok := marks["ask-3"]; !ok || m.Generation != 0 {
		t.Fatalf("a row seen before the cutoff stays: %+v", marks)
	}
	for _, kind := range []string{"ask_alert", "workbench"} {
		if h, err := s.SliceHashes(kind); err != nil || len(h) != 0 {
			t.Fatalf("%s hashes %v, %v", kind, h, err)
		}
	}
	if v, err := s.ZoneToken("relay/r/*"); err != nil || v != 0 {
		t.Fatalf("the named mailbox's token %d, %v", v, err)
	}
	if v, err := s.ZoneToken("relay/r/phone"); err != nil || v != 9 {
		t.Fatalf("another zone's token %d, %v", v, err)
	}
	if phase, _, _, err := s.Phase("action-1"); err != nil || phase != PhaseDone {
		t.Fatalf("the ledger: %q, %v", phase, err)
	}
	if v, ok, err := s.Meta(MetaHubID); err != nil || !ok || v != "hub-acme" {
		t.Fatalf("hub_id %q %v %v", v, ok, err)
	}

	// A zone deletion names no mailbox: every token stays.
	if err := s.SetZoneToken("relay/r/*", 5); err != nil {
		t.Fatal(err)
	}
	if err := s.WipeSyncState(ctx, t0); err != nil {
		t.Fatal(err)
	}
	if v, err := s.ZoneToken("relay/r/*"); err != nil || v != 5 {
		t.Fatalf("a zone reset moved the mailbox token: %d, %v", v, err)
	}
}
