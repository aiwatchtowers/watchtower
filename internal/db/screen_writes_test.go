package db

import (
	"database/sql"
	"errors"
	"strings"
	"testing"
)

// screenSeed is a row for every multi-statement screen writer: a track, two
// ideas with a mention, a plan with two items, a workbench task under a
// parent, and a ready catch-up recap with a track in its window.
var screenSeed = []string{
	`INSERT INTO tracks (id, text, updated_at, has_updates) VALUES (1, 'T', '2026-11-16T09:00:00Z', 1)`,
	`INSERT INTO ideas (id, kind, title, status) VALUES (1, 'idea', 'A', 'proposed')`,
	`INSERT INTO ideas (id, kind, title, status) VALUES (2, 'idea', 'B', 'active')`,
	`INSERT INTO idea_mentions (id, idea_id, source, quote, said_at) VALUES (1, 1, 'owner', 'q', '2026-11-15T09:00:00Z')`,
	`INSERT INTO day_plans (id, user_id, plan_date, generated_at) VALUES (1, 'U1', '2026-11-16', '2026-11-16T07:00:00Z')`,
	`INSERT INTO day_plan_items (id, day_plan_id, kind, source_type, title, status, order_index) VALUES (1, 1, 'backlog', 'manual', 'a', 'pending', 0)`,
	`INSERT INTO day_plan_items (id, day_plan_id, kind, source_type, title, status, order_index) VALUES (2, 1, 'backlog', 'manual', 'b', 'pending', 1)`,
	`INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme-faults')`,
	`INSERT INTO targets (id, text, level, custom_label, period_start, period_end, source_type, project_id) VALUES (1, 'P', 'custom', 'project', '2026-11-16', '2026-11-16', 'chat', 1)`,
	`INSERT INTO targets (id, text, level, custom_label, period_start, period_end, source_type, project_id, parent_id) VALUES (2, 'C', 'custom', 'project', '2026-11-16', '2026-11-16', 'chat', 1, 1)`,
	`INSERT INTO catchup_recaps (id, period_from, period_to, status) VALUES (1, 1794816000, 1794823200, 'ready')`,
}

func screenSnapshot(t *testing.T, d *DB) string {
	t.Helper()
	var b strings.Builder
	for _, q := range []string{
		`SELECT id, priority, COALESCE(read_at,''), has_updates FROM tracks`,
		`SELECT entity_type, entity_id, comment FROM feedback`,
		`SELECT id, status, COALESCE(merged_into_id, 0), COALESCE(converted_target_id, 0) FROM ideas`,
		`SELECT id, idea_id FROM idea_mentions`,
		`SELECT id, order_index FROM day_plan_items`,
		`SELECT id, status, snooze_until, progress FROM targets`,
		`SELECT target_id, to_status, actor FROM target_status_history`,
		`SELECT id, COALESCE(acknowledged_at,'') FROM catchup_recaps`,
	} {
		b.WriteString(dumpWriteRows(t, d, q))
	}
	return b.String()
}

// TestScreenWriters_KillBetweenStatements: each multi-statement screen
// writer failed between its statements (a process killed mid-transaction)
// leaves every row as seeded; without the fault it writes.
func TestScreenWriters_KillBetweenStatements(t *testing.T) {
	for _, w := range []struct {
		name, step string
		run        func(tx *sql.Tx) error
	}{
		{"SetTrackPriorityTx", "track.priority", func(tx *sql.Tx) error { return SetTrackPriorityTx(tx, 1, "high") }},
		{"MergeIdeaTx", "idea.merge", func(tx *sql.Tx) error { _, err := MergeIdeaTx(tx, 1, 2); return err }},
		{"ConvertIdeaToTargetTx", "idea.convert", func(tx *sql.Tx) error { _, _, err := ConvertIdeaToTargetTx(tx, 1, "2026-11-16"); return err }},
		{"DeleteIdeaTx", "idea.delete", func(tx *sql.Tx) error { _, err := DeleteIdeaTx(tx, 1); return err }},
		{"ReorderPlanItemsTx", "plan.reorder", func(tx *sql.Tx) error { return ReorderPlanItemsTx(tx, 1, []int64{2, 1}) }},
		{"SnoozeTargetOwnerTx", "target.snooze", func(tx *sql.Tx) error { _, err := SnoozeTargetOwnerTx(tx, 2, "2026-11-20"); return err }},
		{"AcknowledgeCatchupTx", "catchup.ack", func(tx *sql.Tx) error { return AcknowledgeCatchupTx(tx, 1) }},
	} {
		t.Run(w.name, func(t *testing.T) {
			d := openTestDB(t)
			for _, s := range screenSeed {
				if _, err := d.Exec(s); err != nil {
					t.Fatalf("seed %q: %v", s, err)
				}
			}
			before := screenSnapshot(t, d)
			hits := faultAt(t, w.step)
			if err := d.WithTx(w.run); !errors.Is(err, errInjected) {
				t.Fatalf("err %v, want the injected fault", err)
			}
			if *hits == 0 {
				t.Fatalf("the seam at %q never ran", w.step)
			}
			if after := screenSnapshot(t, d); after != before {
				t.Errorf("a kill between statements left a partial write:\n%s\nwant\n%s", after, before)
			}
			faultAfter = nil
			if err := d.WithTx(w.run); err != nil {
				t.Fatal(err)
			}
			if screenSnapshot(t, d) == before {
				t.Error("the writer changed nothing without the fault")
			}
		})
	}
}
