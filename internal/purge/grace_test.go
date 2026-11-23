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
// due at the pass that schedules it, the next pass hands it to Run, and a
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

	deadline := t0.Add(time.Hour)
	live := []db.PurgeAccount{acct("jira", 1, "ok", deadline.Add(-Lease))}
	if got := Plan(live, nil, setting(true), t0); len(got.Schedule) != 0 {
		t.Fatalf("before the lease deadline nothing is scheduled, got %+v", got.Schedule)
	}
	got = Plan(live, nil, setting(true), deadline)
	if len(got.Schedule) != 1 || !got.Schedule[0].DueAt.Equal(deadline) {
		t.Fatalf("at the deadline the lease is due at once, got %+v", got.Schedule)
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
