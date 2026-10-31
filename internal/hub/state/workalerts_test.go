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
