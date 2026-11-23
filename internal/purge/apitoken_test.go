package purge

import (
	"testing"
	"time"

	"watchtower/internal/db"
)

// TestPurge01_PolicyStoppedAPITokenHoldsLease (#1887 D24, POLICY-03): an
// Atlassian API-token account the policy stops (AllowAtlassianAPIToken =
// false) is not synced, so — like a forbidden source — its stale clock
// schedules no lease purge and its data stays; the OAuth account of the same
// source keeps its lease, and a revoked rule still runs.
func TestPurge01_PolicyStoppedAPITokenHoldsLease(t *testing.T) {
	stale := t0.Add(-Lease + Grace - time.Minute)
	token := acct("jira", 1, "error", stale)
	token.AuthKind = "api_token"
	oauth := acct("jira", 2, "ok", stale)
	oauth.AuthKind = "oauth"
	stopped := AccountRules(true, func(a db.PurgeAccount) bool { return a.AuthKind != "api_token" })

	got := Plan([]db.PurgeAccount{token, oauth}, nil, stopped, t0)
	if len(got.Schedule) != 1 || got.Schedule[0].AccountID != 2 {
		t.Fatalf("only the OAuth account's lease is scheduled, got %+v", got.Schedule)
	}
	if r := stopped(token); r != RuleRevokedAndRemoved {
		t.Fatalf("a stopped live account keeps the revoked rule only, got %v", r)
	}
	if got := Plan([]db.PurgeAccount{token, oauth}, nil, AccountRules(true, nil), t0); len(got.Schedule) != 2 {
		t.Fatalf("not stopped: both leases are scheduled, got %+v", got.Schedule)
	}
}

// TestPurge01_APITokenErrorIsNoRevokedPurge (D22): a dead API token leaves
// its account in 'error', which the revoked rule never schedules, with the
// purge fully on; only the 30-day lease could, once the source's access is
// stale.
func TestPurge01_APITokenErrorIsNoRevokedPurge(t *testing.T) {
	fresh := acct("jira", 1, "error", t0.Add(-time.Hour))
	fresh.AuthKind = "api_token"
	if got := Plan([]db.PurgeAccount{fresh}, nil, setting(true), t0); len(got.Schedule) != 0 {
		t.Fatalf("a dead token schedules no purge, got %+v", got.Schedule)
	}
	stale := acct("jira", 1, "error", t0.Add(-Lease+Grace-time.Minute))
	stale.AuthKind = "api_token"
	if got := Plan([]db.PurgeAccount{stale}, nil, setting(true), t0); len(got.Schedule) != 1 || got.Schedule[0].Reason != ReasonLease {
		t.Fatalf("only the 30-day lease applies, got %+v", got.Schedule)
	}
}
