package purge

import (
	"testing"
	"time"

	"watchtower/internal/db"
)

// TestPurge01_PolicyStoppedOwnGoogleHoldsLease (#1887 D24, POLICY-03): a
// Google account on an own project the policy stops (AllowOwnGoogleProject
// = false) is not synced, so its stale clock schedules no lease purge and an
// open lease row of it is cancelled; its data stays. The company account of
// the same source keeps its lease.
func TestPurge01_PolicyStoppedOwnGoogleHoldsLease(t *testing.T) {
	stale := t0.Add(-Lease + Grace - time.Minute)
	own, work := acct("google", 1, "ok", stale), acct("google", 2, "ok", stale)
	stopped := AccountRules(true, func(a db.PurgeAccount) bool { return !(a.Source == "google" && a.ID == 1) })

	got := Plan([]db.PurgeAccount{own, work}, nil, stopped, t0)
	if len(got.Schedule) != 1 || got.Schedule[0].AccountID != 2 {
		t.Fatalf("only the company account's lease is scheduled, got %+v", got.Schedule)
	}
	open := []db.AccountPurge{{ID: 7, Source: "google", AccountID: 1, Reason: ReasonLease, State: "scheduled", DueAt: ts(t0.Add(Grace))}}
	if got := Plan([]db.PurgeAccount{own}, open, stopped, t0); len(got.Cancel) != 1 || got.Cancel[0] != 7 {
		t.Fatalf("an open lease row of a stopped account is cancelled, got %+v", got)
	}
}
