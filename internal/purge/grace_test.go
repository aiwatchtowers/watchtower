package purge

import (
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"
)

// TestPurge01_ManagedGraceSetsTheNotice pins that the organization's
// PurgeGraceHours replaces the 72 h notice of every row a pass schedules,
// whatever turned the purge on, and that a value the policy refuses (negative,
// over 720, not an integer) leaves the 72 h notice.
func TestPurge01_ManagedGraceSetsTheNotice(t *testing.T) {
	revoked := acct("slack", 1, "revoked", t0.Add(-time.Hour))
	revoked.RevokedAt = ts(t0)
	for _, c := range []struct {
		name string
		raw  map[string]any
		want time.Duration
	}{
		{"not set", nil, Grace},
		{"24 hours", map[string]any{"PurgeGraceHours": int64(24)}, 24 * time.Hour},
		{"720 hours", map[string]any{"PurgeGraceHours": int64(720)}, 720 * time.Hour},
		{"negative", map[string]any{"PurgeGraceHours": int64(-1)}, Grace},
		{"over 720", map[string]any{"PurgeGraceHours": int64(721)}, Grace},
		{"a fraction", map[string]any{"PurgeGraceHours": 1.5}, Grace},
		{"a string", map[string]any{"PurgeGraceHours": "24"}, Grace},
		{"with the switch forced on", map[string]any{"PurgeRevokedData": true, "PurgeGraceHours": int64(6)}, 6 * time.Hour},
	} {
		t.Run(c.name, func(t *testing.T) {
			policytest.Set(t, c.raw)
			if got := EffectiveGrace(); got != c.want {
				t.Fatalf("EffectiveGrace = %s, want %s", got, c.want)
			}
			got := Plan([]db.PurgeAccount{revoked}, nil, setting(true), t0)
			if len(got.Schedule) != 1 || !got.Schedule[0].DueAt.Equal(t0.Add(c.want)) {
				t.Fatalf("want one row due %s after the pass, got %+v", c.want, got.Schedule)
			}
		})
	}
}

// TestPurge01_ZeroGraceRunsOnTheNextPass pins PurgeGraceHours = 0: the row is
// due at the pass that schedules it, the next pass hands it to Run (the
// daemon runs it only after a later cycle's syncs: NoNotice), and a
// live account's lease is still scheduled only once its deadline has passed.
func TestPurge01_ZeroGraceRunsOnTheNextPass(t *testing.T) {
	policytest.Set(t, map[string]any{"PurgeGraceHours": int64(0)})
	d := openPurgeDB(t)
	if _, err := d.Exec(`INSERT INTO slack_accounts (id, team_id, status, revoked_at, access_ok_at) VALUES (1, 'T1', 'revoked', ?, ?)`,
		ts(t0), ts(t0.Add(-time.Hour))); err != nil {
		t.Fatal(err)
	}
	got, err := Apply(d, setting(true), true, t0)
	if err != nil || len(got.Schedule) != 1 || len(got.Due) != 0 {
		t.Fatalf("first pass = %+v, %v; want one row scheduled, nothing due yet", got, err)
	}
	rows, err := d.ListAccountPurges(true)
	if err != nil || len(rows) != 1 || rows[0].DueAt != ts(t0) {
		t.Fatalf("ledger = %+v, %v; want one row due at the scheduling pass", rows, err)
	}
	got, err = Apply(d, setting(true), true, t0.Add(time.Minute))
	if err != nil || len(got.Due) != 1 || got.Due[0].ID != rows[0].ID {
		t.Fatalf("next pass = %+v, %v; want the row due", got, err)
	}

	// A live lease is scheduled in the fixed 72 h window before its deadline
	// and due at the deadline (ask #862); past the deadline (a daemon that
	// was off) a zero grace makes it due at the pass.
	deadline := t0.Add(time.Hour)
	live := []db.PurgeAccount{acct("jira", 1, "ok", deadline.Add(-Lease))}
	if got := Plan(live, nil, setting(true), deadline.Add(-Grace-time.Minute)); len(got.Schedule) != 0 {
		t.Fatalf("before the schedule-ahead window nothing is scheduled, got %+v", got.Schedule)
	}
	got = Plan(live, nil, setting(true), t0)
	if len(got.Schedule) != 1 || !got.Schedule[0].DueAt.Equal(deadline) {
		t.Fatalf("within the window the lease is due at its deadline, got %+v", got.Schedule)
	}
	late := deadline.Add(time.Hour)
	got = Plan(live, nil, setting(true), late)
	if len(got.Schedule) != 1 || !got.Schedule[0].DueAt.Equal(late) {
		t.Fatalf("past the deadline the lease is due at the pass, got %+v", got.Schedule)
	}
}

// TestPurge01_GraceChangeKeepsScheduledRows pins that a PurgeGraceHours change
// applies only to rows scheduled after it: a row already scheduled keeps its
// due_at, shortened or lengthened, and a row scheduled later takes the new
// notice.
func TestPurge01_GraceChangeKeepsScheduledRows(t *testing.T) {
	d := openPurgeDB(t)
	if _, err := d.Exec(`INSERT INTO slack_accounts (id, team_id, status, revoked_at, access_ok_at) VALUES (1, 'T1', 'revoked', ?, ?)`,
		ts(t0), ts(t0.Add(-time.Hour))); err != nil {
		t.Fatal(err)
	}
	policytest.Set(t, nil)
	if _, err := Apply(d, setting(true), true, t0); err != nil {
		t.Fatal(err)
	}
	for _, raw := range []map[string]any{{"PurgeGraceHours": int64(0)}, {"PurgeGraceHours": int64(720)}} {
		policytest.Set(t, raw)
		got, err := Apply(d, setting(true), true, t0.Add(time.Hour))
		if err != nil || len(got.Schedule) != 0 || len(got.Due) != 0 {
			t.Fatalf("%v: pass = %+v, %v; want nothing scheduled or due", raw, got, err)
		}
		rows, err := d.ListAccountPurges(true)
		if err != nil || len(rows) != 1 || rows[0].DueAt != ts(t0.Add(Grace)) {
			t.Fatalf("%v: ledger = %+v, %v; want the row still due the 72 h notice after scheduling", raw, rows, err)
		}
	}

	if _, err := d.Exec(`INSERT INTO slack_accounts (id, team_id, status, revoked_at, access_ok_at) VALUES (2, 'T2', 'revoked', ?, ?)`,
		ts(t0), ts(t0.Add(-time.Hour))); err != nil {
		t.Fatal(err)
	}
	policytest.Set(t, map[string]any{"PurgeGraceHours": int64(24)})
	later := t0.Add(2 * time.Hour)
	got, err := Apply(d, setting(true), true, later)
	if err != nil || len(got.Schedule) != 1 || got.Schedule[0].AccountID != 2 || !got.Schedule[0].DueAt.Equal(later.Add(24*time.Hour)) {
		t.Fatalf("new row = %+v, %v; want account 2 due 24 h after its pass", got.Schedule, err)
	}
}

// TestPurge01_LiveLeaseWindowIgnoresTheManagedGrace pins ask #862: a live
// account's lease is scheduled only within the fixed 72 h window before its
// deadline, whatever PurgeGraceHours says, and due at the deadline or the
// grace after the pass, whichever is later — so a long grace neither puts a
// notice on an account that syncs every day nor churns rows as its access
// advances.
func TestPurge01_LiveLeaseWindowIgnoresTheManagedGrace(t *testing.T) {
	for _, hours := range []int64{720, 600} {
		policytest.Set(t, map[string]any{"PurgeGraceHours": hours})
		fresh := []db.PurgeAccount{acct("jira", 1, "ok", t0.Add(-time.Hour))}
		if got := Plan(fresh, nil, setting(true), t0); len(got.Schedule) != 0 {
			t.Fatalf("grace %d: an account synced an hour ago got %+v", hours, got.Schedule)
		}
	}

	policytest.Set(t, map[string]any{"PurgeGraceHours": int64(720)})
	d := openPurgeDB(t)
	execAll(t, d, `INSERT INTO jira_accounts (id, cloud_id, status) VALUES (1, 'c1', 'ok')`)
	for i, at := range []time.Time{t0, t0.Add(time.Hour), t0.Add(2 * time.Hour)} {
		if _, err := d.Exec(`UPDATE jira_accounts SET access_ok_at = ? WHERE id = 1`, ts(at.Add(-time.Hour))); err != nil {
			t.Fatal(err)
		}
		if _, err := Apply(d, setting(true), true, at); err != nil {
			t.Fatal(err)
		}
		if rows, err := d.ListAccountPurges(false); err != nil || len(rows) != 0 {
			t.Fatalf("pass %d: ledger = %+v, %v; want no rows while access advances", i, rows, err)
		}
	}

	// Idle about 30 days: scheduled at deadline − 72 h, due the 720 h grace later.
	idle := []db.PurgeAccount{acct("jira", 1, "ok", t0.Add(-Lease+Grace))}
	got := Plan(idle, nil, setting(true), t0)
	if len(got.Schedule) != 1 || !got.Schedule[0].DueAt.Equal(t0.Add(720*time.Hour)) {
		t.Fatalf("idle account: want one row due 720 h after the pass, got %+v", got.Schedule)
	}
	if got := Plan(idle, nil, setting(true), t0.Add(-time.Minute)); len(got.Schedule) != 0 {
		t.Fatalf("idle account before the window: got %+v", got.Schedule)
	}
}

// TestPurge01_NoNoticeWaitsForASync pins the zero-notice hold (ask #862): a
// scheduled row due less than an hour after scheduling has no notice and
// runs only after syncs that started after it was scheduled, in a later
// second (the ledger clock's precision); a row with a notice, or a running
// one, is not held.
func TestPurge01_NoNoticeWaitsForASync(t *testing.T) {
	at := t0
	row := func(due time.Time, state string) db.AccountPurge {
		return db.AccountPurge{State: state, ScheduledAt: ts(at), DueAt: ts(due)}
	}
	for _, c := range []struct {
		name string
		p    db.AccountPurge
		want bool
	}{
		{"grace 0", row(at, "scheduled"), true},
		{"a lease past its deadline", row(at.Add(30*time.Minute), "scheduled"), true},
		{"an hour's notice", row(at.Add(time.Hour), "scheduled"), false},
		{"72 h", row(at.Add(Grace), "scheduled"), false},
		{"running", row(at, "running"), false},
		{"unreadable", db.AccountPurge{State: "scheduled", ScheduledAt: "x", DueAt: ts(at)}, true},
	} {
		if got := NoNotice(c.p); got != c.want {
			t.Errorf("%s: NoNotice = %v, want %v", c.name, got, c.want)
		}
	}
	p := row(at, "scheduled")
	for _, c := range []struct {
		name      string
		syncStart time.Time
		want      bool
	}{
		{"no sync yet", time.Time{}, false},
		{"before scheduling", at.Add(-time.Minute), false},
		{"the same second", at.Add(500 * time.Millisecond), false},
		{"a later second", at.Add(time.Second), true},
	} {
		if got := SyncedSince(p, c.syncStart); got != c.want {
			t.Errorf("%s: SyncedSince = %v, want %v", c.name, got, c.want)
		}
	}
}
