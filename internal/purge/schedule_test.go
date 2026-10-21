package purge

import (
	"testing"
	"time"

	"watchtower/internal/db"
)

var t0 = time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC)

func ts(t time.Time) string { return t.UTC().Format(time.RFC3339) }

func acct(source string, id int64, status string, okAt time.Time) db.PurgeAccount {
	a := db.PurgeAccount{Source: source, ID: id, Status: status, Enabled: true}
	if !okAt.IsZero() {
		a.AccessOKAt = ts(okAt)
	}
	return a
}

func row(id int64, source string, accountID int64, reason, state string, due time.Time) db.AccountPurge {
	return db.AccountPurge{ID: id, Source: source, AccountID: accountID, Reason: reason, State: state, DueAt: ts(due)}
}

func TestPurge01_RevokedSchedulesAtRevokedPlusGrace(t *testing.T) {
	a := acct("slack", 1, "revoked", t0.Add(-time.Hour))
	a.RevokedAt = ts(t0)
	got := Plan([]db.PurgeAccount{a}, nil, true, t0)
	if len(got.Schedule) != 1 {
		t.Fatalf("want one schedule, got %+v", got)
	}
	s := got.Schedule[0]
	if s.Reason != ReasonRevoked || !s.DueAt.Equal(t0.Add(Grace)) {
		t.Fatalf("schedule = %+v, want revoked at revoked_at + 72h", s)
	}

	// Revoked long ago (the purge turned on later): the notice still gets
	// the full grace period from scheduling.
	a.RevokedAt = ts(t0.Add(-30 * 24 * time.Hour))
	got = Plan([]db.PurgeAccount{a}, nil, true, t0)
	if len(got.Schedule) != 1 || !got.Schedule[0].DueAt.Equal(t0.Add(Grace)) {
		t.Fatalf("an old revocation must be due Grace after scheduling, got %+v", got.Schedule)
	}

	// Off: nothing scheduled.
	if got := Plan([]db.PurgeAccount{a}, nil, false, t0); len(got.Schedule) != 0 {
		t.Fatalf("off must schedule nothing, got %+v", got.Schedule)
	}
}

func TestPurge01_ReconnectCancels(t *testing.T) {
	a := acct("linear", 1, "ok", t0)
	open := []db.AccountPurge{row(7, "linear", 1, ReasonRevoked, "scheduled", t0.Add(time.Hour))}
	got := Plan([]db.PurgeAccount{a}, open, true, t0)
	if len(got.Cancel) != 1 || got.Cancel[0] != 7 || len(got.Due) != 0 || len(got.Schedule) != 0 {
		t.Fatalf("ok must cancel the revoked row, got %+v", got)
	}
}

func TestPurge01_ErrorStatusWaits(t *testing.T) {
	a := acct("jira", 1, "error", t0.Add(-time.Hour))
	open := []db.AccountPurge{row(3, "jira", 1, ReasonRevoked, "scheduled", t0.Add(-time.Minute))}
	got := Plan([]db.PurgeAccount{a}, open, true, t0)
	if len(got.Due) != 0 || len(got.Cancel) != 0 || len(got.Schedule) != 0 {
		t.Fatalf("due + error must wait, got %+v", got)
	}
	a.Status = "revoked"
	got = Plan([]db.PurgeAccount{a}, open, true, t0)
	if len(got.Due) != 1 || got.Due[0].ID != 3 {
		t.Fatalf("due + still revoked must run, got %+v", got)
	}
	got = Plan([]db.PurgeAccount{a}, open, true, t0.Add(-2*time.Minute))
	if len(got.Due) != 0 {
		t.Fatalf("not yet due must not run, got %+v", got)
	}
}

func TestPurge01_LeaseSchedulesWhenAllStale(t *testing.T) {
	stale := t0.Add(-Lease + Grace - time.Minute) // 27 days + 1 min ago
	accounts := []db.PurgeAccount{
		acct("slack", 1, "ok", stale),
		acct("slack", 2, "error", stale.Add(-48*time.Hour)),
		acct("jira", 1, "ok", t0.Add(-time.Hour)),
	}
	accounts[1].Enabled = false // disabled accounts count (ask #477)
	got := Plan(accounts, nil, true, t0)
	if len(got.Schedule) != 2 {
		t.Fatalf("both slack accounts must be scheduled, got %+v", got.Schedule)
	}
	for _, s := range got.Schedule {
		// Due Grace after scheduling: newest + 30d, give or take the cycle
		// that noticed it.
		if s.Source != "slack" || s.Reason != ReasonLease || !s.DueAt.Equal(t0.Add(Grace)) {
			t.Fatalf("schedule = %+v, want slack lease due now + 72h", s)
		}
	}

	// One fresh account of the source blocks it.
	accounts[1].AccessOKAt = ts(t0.Add(-time.Hour))
	if got := Plan(accounts, nil, true, t0); len(got.Schedule) != 0 {
		t.Fatalf("one fresh account must block the lease, got %+v", got.Schedule)
	}

	// An account with no access_ok_at is no evidence: no lease.
	accounts[1].AccessOKAt = ""
	if got := Plan(accounts, nil, true, t0); len(got.Schedule) != 0 {
		t.Fatalf("an unknown clock must block the lease, got %+v", got.Schedule)
	}

	// Not yet within the grace window: nothing.
	accounts[1].AccessOKAt = ts(stale)
	if got := Plan(accounts, nil, true, t0.Add(-2*time.Minute)); len(got.Schedule) != 0 {
		t.Fatalf("too early, got %+v", got.Schedule)
	}

	// Long stale (daemon did not run): still a full grace notice.
	old := []db.PurgeAccount{acct("google", 1, "ok", t0.Add(-60*24*time.Hour))}
	got = Plan(old, nil, true, t0)
	if len(got.Schedule) != 1 || !got.Schedule[0].DueAt.Equal(t0.Add(Grace)) {
		t.Fatalf("a long-stale lease must be due Grace after scheduling, got %+v", got.Schedule)
	}
}

func TestPurge01_LeaseCancelledByFreshAccess(t *testing.T) {
	stale := t0.Add(-Lease + time.Hour)
	accounts := []db.PurgeAccount{acct("slack", 1, "ok", stale)}
	open := []db.AccountPurge{row(5, "slack", 1, ReasonLease, "scheduled", stale.Add(Lease))}
	got := Plan(accounts, open, true, t0)
	if len(got.Cancel) != 0 || len(got.Due) != 0 {
		t.Fatalf("unchanged stale lease keeps its row, got %+v", got)
	}
	got = Plan(accounts, open, true, stale.Add(Lease))
	if len(got.Due) != 1 {
		t.Fatalf("a due stale lease runs, got %+v", got)
	}
	accounts[0].AccessOKAt = ts(t0)
	got = Plan(accounts, open, true, t0)
	if len(got.Cancel) != 1 || got.Cancel[0] != 5 {
		t.Fatalf("fresh access must cancel the lease row, got %+v", got)
	}
}

func TestPurge01_OffCancelsScheduledKeepsRunning(t *testing.T) {
	accounts := []db.PurgeAccount{acct("slack", 1, "revoked", t0), acct("jira", 1, "revoked", t0)}
	open := []db.AccountPurge{
		row(1, "slack", 1, ReasonRevoked, "scheduled", t0.Add(-time.Hour)),
		row(2, "jira", 1, ReasonRevoked, "running", t0.Add(-time.Hour)),
	}
	got := Plan(accounts, open, false, t0)
	if len(got.Cancel) != 1 || got.Cancel[0] != 1 {
		t.Fatalf("off must cancel the scheduled row, got %+v", got.Cancel)
	}
	if len(got.Due) != 1 || got.Due[0].ID != 2 {
		t.Fatalf("a running row finishes even when off, got %+v", got.Due)
	}
	if len(got.Schedule) != 0 {
		t.Fatalf("off schedules nothing, got %+v", got.Schedule)
	}
}

func TestPurge01_RunningNeverCancelled(t *testing.T) {
	accounts := []db.PurgeAccount{acct("linear", 1, "ok", t0)}
	open := []db.AccountPurge{row(9, "linear", 1, ReasonRevoked, "running", t0.Add(time.Hour))}
	for _, on := range []bool{true, false} {
		got := Plan(accounts, open, on, t0)
		if len(got.Cancel) != 0 || len(got.Due) != 1 || len(got.Schedule) != 0 {
			t.Fatalf("enabled=%v: running row must resume and never cancel, got %+v", on, got)
		}
	}
}

func TestPurge01_RemovedAccountLease(t *testing.T) {
	accounts := []db.PurgeAccount{
		acct("slack", 1, "removed", t0.Add(-Lease-time.Minute)), // stale removed
		acct("slack", 2, "removed", t0.Add(-Lease+time.Hour)),   // fresh enough removed
		acct("slack", 3, "ok", t0.Add(-time.Hour)),              // live, fresh
	}
	got := Plan(accounts, nil, true, t0)
	if len(got.Schedule) != 1 {
		t.Fatalf("only the stale removed account is scheduled, got %+v", got.Schedule)
	}
	s := got.Schedule[0]
	if s.AccountID != 1 || s.Reason != ReasonLease || !s.DueAt.Equal(t0.Add(Grace)) {
		t.Fatalf("schedule = %+v, want account 1 lease due now + 72h", s)
	}

	// A removed account never blocks or joins its source's live lease: the
	// live account alone decides.
	live := []db.PurgeAccount{
		acct("jira", 1, "removed", t0.Add(-time.Hour)), // fresh removed
		acct("jira", 2, "ok", t0.Add(-Lease+Grace-time.Minute)),
	}
	got = Plan(live, nil, true, t0)
	if len(got.Schedule) != 1 || got.Schedule[0].AccountID != 2 {
		t.Fatalf("the fresh removed account must not block the live lease, got %+v", got.Schedule)
	}

	// A removed account's lease is off when the purge is off.
	if got := Plan(accounts, nil, false, t0); len(got.Schedule) != 0 {
		t.Fatalf("off schedules nothing, got %+v", got.Schedule)
	}
	// A purged account is never scheduled.
	purged := []db.PurgeAccount{acct("slack", 1, "purged", t0.Add(-90*24*time.Hour))}
	if got := Plan(purged, nil, true, t0); len(got.Schedule) != 0 {
		t.Fatalf("purged schedules nothing, got %+v", got.Schedule)
	}
}

func TestPurge01_RemovedLeaseCancelledWhenReadded(t *testing.T) {
	okAt := t0.Add(-Lease - time.Hour)
	open := []db.AccountPurge{row(4, "linear", 1, ReasonLease, "scheduled", t0.Add(Grace))}
	removed := []db.PurgeAccount{acct("linear", 1, "removed", okAt)}
	if got := Plan(removed, open, true, t0); len(got.Cancel) != 0 {
		t.Fatalf("a still-removed stale account keeps its row, got %+v", got.Cancel)
	}
	if got := Plan(removed, open, true, t0.Add(Grace)); len(got.Due) != 1 {
		t.Fatalf("a due removed lease runs, got %+v", got.Due)
	}
	readded := []db.PurgeAccount{acct("linear", 1, "ok", t0)}
	got := Plan(readded, open, true, t0)
	if len(got.Cancel) != 1 || got.Cancel[0] != 4 {
		t.Fatalf("an account added back must cancel its removed lease row, got %+v", got)
	}
}

func TestApply_WritesScheduleAndCancel(t *testing.T) {
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	if _, err := d.Exec(`INSERT INTO slack_accounts (id, team_id, status, revoked_at, access_ok_at) VALUES (1, 'T1', 'revoked', ?, ?)`, ts(t0), ts(t0)); err != nil {
		t.Fatal(err)
	}
	got, err := Apply(d, true, t0)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Schedule) != 1 {
		t.Fatalf("want one inserted schedule, got %+v", got)
	}
	again, err := Apply(d, true, t0)
	if err != nil {
		t.Fatal(err)
	}
	if len(again.Schedule) != 0 || len(again.Cancel) != 0 {
		t.Fatalf("a second pass must change nothing, got %+v", again)
	}
	rows, err := d.ListAccountPurges(true)
	if err != nil || len(rows) != 1 || rows[0].DueAt != ts(t0.Add(Grace)) || rows[0].State != "scheduled" {
		t.Fatalf("ledger = %+v, %v", rows, err)
	}
	if err := d.SetSlackAccountAuthState(1, "ok", ""); err != nil {
		t.Fatal(err)
	}
	got, err = Apply(d, true, t0)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Cancel) != 1 {
		t.Fatalf("a reconnect must cancel, got %+v", got)
	}
	if rows, _ := d.ListAccountPurges(true); len(rows) != 0 {
		t.Fatalf("no open rows after the cancel, got %+v", rows)
	}
}
