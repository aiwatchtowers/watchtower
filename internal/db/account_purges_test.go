package db

import (
	"fmt"
	"testing"
)

func TestListPurgeAccounts_EveryStatusAndLabel(t *testing.T) {
	d := OpenTestDB(t)
	for _, q := range []string{
		`INSERT INTO slack_accounts (id, team_id, team_name, status) VALUES (1, 'T1', 'Acme', 'removed')`,
		`INSERT INTO google_accounts (id, email, calendar_enabled) VALUES (1, 'a@example.com', 1)`,
		`INSERT INTO jira_accounts (id, cloud_id, label, site_name, enabled) VALUES (1, 'c1', 'Work', 'acme', 0)`,
		`INSERT INTO linear_accounts (id, org_id, url_key, status) VALUES (1, 'o1', 'acme', 'purged')`,
	} {
		if _, err := d.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	got, err := d.ListPurgeAccounts()
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]PurgeAccount{
		"slack":  {Source: "slack", ID: 1, Label: "Acme", Status: "removed", Enabled: true},
		"google": {Source: "google", ID: 1, Label: "a@example.com", Status: "ok", Enabled: true},
		"jira":   {Source: "jira", ID: 1, Label: "Work", Status: "ok", Enabled: false},
		"linear": {Source: "linear", ID: 1, Label: "acme", Status: "purged", Enabled: true},
	}
	if len(got) != len(want) {
		t.Fatalf("got %d accounts, want %d: %+v", len(got), len(want), got)
	}
	for _, a := range got {
		if w := want[a.Source]; a != w {
			t.Errorf("%s: got %+v, want %+v", a.Source, a, w)
		}
	}
}

func TestScheduleAccountPurge_OneOpenRow(t *testing.T) {
	d := OpenTestDB(t)
	ok, err := d.ScheduleAccountPurge("slack", 1, "revoked", "2026-10-24T12:00:00Z")
	if err != nil || !ok {
		t.Fatalf("first schedule: %v %v", ok, err)
	}
	ok, err = d.ScheduleAccountPurge("slack", 1, "lease", "2026-10-25T12:00:00Z")
	if err != nil || ok {
		t.Fatalf("a second open row must be a no-op: %v %v", ok, err)
	}
	if _, err := d.ScheduleAccountPurge("slack", 2, "bogus", "x"); err == nil {
		t.Fatal("an invalid reason must error (CHECK), not be ignored")
	}
	rows, err := d.ListAccountPurges(true)
	if err != nil || len(rows) != 1 {
		t.Fatalf("open rows = %+v, %v", rows, err)
	}
	if ok, err := d.CancelAccountPurge(rows[0].ID); err != nil || !ok {
		t.Fatalf("cancel: %v %v", ok, err)
	}
	if ok, err := d.CancelAccountPurge(rows[0].ID); err != nil || ok {
		t.Fatalf("a second cancel is a no-op: %v %v", ok, err)
	}
	all, err := d.ListAccountPurges(false)
	if err != nil || len(all) != 1 || all[0].State != "cancelled" || all[0].FinishedAt == "" {
		t.Fatalf("all rows = %+v, %v", all, err)
	}
}

func ledgerState(t *testing.T, d *DB, id int64) (state, errText, finishedAt string, failures int) {
	t.Helper()
	if err := d.QueryRow(`SELECT state, error, finished_at, failures FROM account_purges WHERE id = ?`, id).
		Scan(&state, &errText, &finishedAt, &failures); err != nil {
		t.Fatal(err)
	}
	return state, errText, finishedAt, failures
}

// Review #601: a purge starts only from a still-scheduled row — a row the
// scheduler cancelled after its plan was read is never started.
func TestStartAccountPurge_OnlyFromScheduled(t *testing.T) {
	d := OpenTestDB(t)
	mustExecAll(t, d, `INSERT INTO account_purges (id, source, account_id, reason, due_at, state) VALUES
		(1, 'slack', 1, 'revoked', '2026-01-01T00:00:00Z', 'scheduled'),
		(2, 'slack', 2, 'revoked', '2026-01-01T00:00:00Z', 'cancelled')`)
	for id, want := range map[int64]bool{1: true, 2: false} {
		got, err := d.StartAccountPurge(id)
		if err != nil || got != want {
			t.Fatalf("start %d = %v, %v; want %v", id, got, err, want)
		}
	}
	if got, err := d.StartAccountPurge(1); err != nil || got {
		t.Fatalf("a running row is not started again: %v %v", got, err)
	}
	if state, _, _, _ := ledgerState(t, d, 2); state != "cancelled" {
		t.Fatalf("cancelled row changed to %s", state)
	}
}

// Review #601: finishing requires a running row; a cancelled one is refused
// and the account is left alone.
func TestFinishAccountPurge_RequiresRunning(t *testing.T) {
	d := OpenTestDB(t)
	mustExecAll(t, d,
		`INSERT INTO linear_accounts (id, org_id, status) VALUES (1, 'o1', 'revoked')`,
		`INSERT INTO account_purges (id, source, account_id, reason, due_at, state) VALUES (1, 'linear', 1, 'revoked', '2026-01-01T00:00:00Z', 'cancelled')`)
	if _, err := d.FinishAccountPurge(1, "linear", 1); err == nil {
		t.Fatal("finishing a cancelled row must fail")
	}
	if got := count(t, d, `SELECT COUNT(*) FROM linear_accounts WHERE status = 'revoked' AND enabled = 1`); got != 1 {
		t.Fatal("the account must be left alone")
	}
	if state, _, _, _ := ledgerState(t, d, 1); state != "cancelled" {
		t.Fatalf("ledger row changed to %s", state)
	}
}

// Review #601: access confirmed after the purge started (a Re-login during
// the run) keeps the account: no purged status, still enabled, its sync
// clocks reset so it starts over; the ledger row is done with a note.
func TestFinishAccountPurge_AccessBackKeepsAccount(t *testing.T) {
	d := OpenTestDB(t)
	mustExecAll(t, d,
		`INSERT INTO linear_accounts (id, org_id, status, moved_watermark, access_ok_at) VALUES (1, 'o1', 'ok', 'w', '2026-01-02T00:00:00Z')`,
		`INSERT INTO account_purges (id, source, account_id, reason, due_at, state, started_at) VALUES
			(1, 'linear', 1, 'revoked', '2026-01-01T00:00:00Z', 'running', '2026-01-01T12:00:00Z')`)
	back, err := d.PurgeAccessReturned(1)
	if err != nil || !back {
		t.Fatalf("access returned = %v, %v", back, err)
	}
	kept, err := d.FinishAccountPurge(1, "linear", 1)
	if err != nil || !kept {
		t.Fatalf("finish = %v, %v; want kept", kept, err)
	}
	var status, watermark string
	var enabled int
	if err := d.QueryRow(`SELECT status, enabled, moved_watermark FROM linear_accounts WHERE id = 1`).Scan(&status, &enabled, &watermark); err != nil {
		t.Fatal(err)
	}
	if status != "ok" || enabled != 1 || watermark != "" {
		t.Fatalf("account after a finish with access back: %s %d %q", status, enabled, watermark)
	}
	state, note, finished, _ := ledgerState(t, d, 1)
	if state != "done" || note == "" || finished == "" {
		t.Fatalf("ledger: %s %q %q", state, note, finished)
	}
	// No access since the start: not returned.
	mustExecAll(t, d, `UPDATE linear_accounts SET access_ok_at = '2026-01-01T11:00:00Z'`)
	if back, err := d.PurgeAccessReturned(1); err != nil || back {
		t.Fatalf("old access must not count: %v %v", back, err)
	}
}

// PURGE-02 (review #601): three chunk failures in a row end the purge in
// failed; a chunk that deletes rows resets the count.
func TestPurge02_FailureCapEndsFailed(t *testing.T) {
	d := OpenTestDB(t)
	mustExecAll(t, d, `INSERT INTO account_purges (id, source, account_id, reason, due_at, state) VALUES
		(1, 'slack', 1, 'revoked', '2026-01-01T00:00:00Z', 'running')`)
	for i := 1; i <= 2; i++ {
		failed, err := d.FailAccountPurge(1, "boom", 3)
		if err != nil || failed {
			t.Fatalf("failure %d = %v, %v", i, failed, err)
		}
	}
	if err := d.AddPurgeRows(1, 5); err != nil {
		t.Fatal(err)
	}
	if _, _, _, n := ledgerState(t, d, 1); n != 0 {
		t.Fatalf("progress must reset the count, got %d", n)
	}
	for i := 1; i <= 3; i++ {
		failed, err := d.FailAccountPurge(1, fmt.Sprintf("boom %d", i), 3)
		if err != nil || failed != (i == 3) {
			t.Fatalf("failure %d = %v, %v", i, failed, err)
		}
	}
	state, errText, finished, _ := ledgerState(t, d, 1)
	if state != "failed" || errText != "boom 3" || finished == "" {
		t.Fatalf("after the cap: %s %q %q", state, errText, finished)
	}
	open, err := d.ListAccountPurges(true)
	if err != nil || len(open) != 0 {
		t.Fatalf("a failed row is not open: %+v %v", open, err)
	}
}
