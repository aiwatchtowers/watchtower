package hub

import (
	"context"
	"database/sql"
	"slices"
	"testing"
	"time"

	"watchtower/internal/db"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/sessionstate"
)

// #1945: a queue or a reveal of the spec review author loop writes only
// spec_reviews, yet moves the session between ready to check and spec
// review. The data_version watch sees the table and the lane sees the
// change, so the phone's terminal_session follows without an owner_asks
// write.
func TestSpecLoopWritesAloneMoveTheSessionState(t *testing.T) {
	for _, k := range []hubslices.Kind{"workbench", "workbench_target", "terminal_session", "session_timeline"} {
		if !slices.Contains(sources.ChangeTables["spec_reviews"], k) {
			t.Errorf("spec_reviews does not feed %s: %v", k, sources.ChangeTables["spec_reviews"])
		}
	}

	d := db.OpenTestDB(t)
	exec := func(q string, args ...any) sql.Result {
		t.Helper()
		res, err := d.Exec(q, args...)
		if err != nil {
			t.Fatal(err)
		}
		return res
	}
	exec(`INSERT INTO projects(id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')`)
	exec(`INSERT INTO terminal_sessions(id, project_id, kind, title, folder_path, claude_session_id, agent_state, agent_state_at)
VALUES (7, 1, 'claude', 't', '/tmp/acme', 'sid-7', 'waiting', '2026-10-31T10:00:00.000Z')`)
	ask, _ := exec(`INSERT INTO owner_asks (project_id, session_id, kind, title, payload, doc_path, status)
VALUES (1, 7, 'review', 'Spec', '{}', 'docs/spec.md', 'open')`).LastInsertId()

	state := func() sessionstate.State {
		t.Helper()
		r, err := sessionstate.Load(context.Background(), d.DB, 7)
		if err != nil {
			t.Fatal(err)
		}
		r.RunStartedAt = "2026-10-31T09:00:00.000Z"
		return sessionstate.Resolve(r, time.Now())
	}
	var changed []int64
	var nudged [][]hubslices.Kind
	l := newStateLane(d.DB, time.Now)
	l.changed = []func(int64){func(wb int64) { changed = append(changed, wb) }}
	l.nudge = func(k ...hubslices.Kind) { nudged = append(nudged, k) }
	ctx := context.Background()

	l.once(ctx) // the baseline: the filing window, the ask still visible
	if got := state(); got != sessionstate.StateReadyToCheck {
		t.Fatalf("before the queue: %s", got)
	}

	if err := d.WithTx(func(tx *sql.Tx) error {
		return d.QueueSpecReview(tx, ask, time.Now(), &db.SpecLoopStart{Round: 1})
	}); err != nil {
		t.Fatal(err)
	}
	l.once(ctx)
	if got := state(); got != sessionstate.StateSpecReview {
		t.Fatalf("after the queue: %s", got)
	}
	if !slices.Equal(changed, []int64{1}) || len(nudged) != 1 || !slices.Contains(nudged[0], "terminal_session") {
		t.Fatalf("the queue alone told changed=%v nudged=%v", changed, nudged)
	}

	if ok, err := d.RevealSpecLoop(ask, "converged", "", time.Now()); err != nil || !ok {
		t.Fatalf("RevealSpecLoop = %v, %v", ok, err)
	}
	l.once(ctx)
	if got := state(); got != sessionstate.StateReadyToCheck {
		t.Fatalf("after the reveal: %s", got)
	}
	if !slices.Equal(changed, []int64{1, 1}) || len(nudged) != 2 || !slices.Contains(nudged[1], "terminal_session") {
		t.Fatalf("the reveal alone told changed=%v nudged=%v", changed, nudged)
	}
}
