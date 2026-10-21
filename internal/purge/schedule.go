package purge

import (
	"errors"
	"fmt"
	"sort"
	"time"

	"watchtower/internal/db"
)

// Reasons a purge is scheduled for.
const (
	ReasonRevoked = "revoked"
	ReasonLease   = "lease"
)

// ScheduleItem is one purge Plan wants scheduled.
type ScheduleItem struct {
	Source    string
	AccountID int64
	Reason    string
	DueAt     time.Time
}

// Actions is what one scheduler pass decided.
type Actions struct {
	Schedule []ScheduleItem
	Cancel   []int64           // ledger ids of scheduled rows to cancel
	Due      []db.AccountPurge // rows to run now: running ones (resume) and due scheduled ones
}

type accountKey struct {
	source string
	id     int64
}

// Plan decides, from the account rows and the open ledger rows only, which
// purges to schedule, cancel and run (PURGE-01). It reads nothing else.
//
//   - Off: every scheduled row is cancelled; nothing is scheduled or run but
//     a running row, which always finishes.
//   - Revoked: a revoked account is scheduled Grace after the pass that
//     first sees it. It is cancelled once the account is no longer revoked
//     or in error (a reconnect writes ok; a removed account falls under the
//     removed lease), or once its access_ok_at is newer than its revoked_at
//     (a clean Jira/Linear pass, which never writes ok — LINEAR-03); a due
//     row runs only while the account is still revoked (error waits). An
//     empty or unreadable access_ok_at is no proof of access: still revoked.
//   - Lease (live accounts, status not removed/purged, disabled included):
//     when every live account of a source has an access_ok_at and the newest
//     is older than Lease − Grace, each live account is scheduled, due
//     Grace later — newest + Lease on a daemon that runs every cycle.
//   - Lease (removed accounts, ask #477): a removed account whose own
//     access_ok_at is older than Lease is scheduled Grace after now.
//   - A lease row is cancelled when its account's lease deadline moves past
//     the row's due_at (fresh access, or a removed account added back), and
//     runs only once that deadline has passed.
//
// Every due date is at least Grace after the pass that schedules it, so the
// notice always shows for the full grace period — also when the purge is
// turned on for an account revoked long ago, or the daemon did not run for
// longer than the lease.
// An empty or unreadable time is no evidence: it never schedules a lease.
func Plan(accounts []db.PurgeAccount, open []db.AccountPurge, enabled bool, now time.Time) Actions {
	var out Actions
	byKey := make(map[accountKey]db.PurgeAccount, len(accounts))
	for _, a := range accounts {
		byKey[accountKey{a.Source, a.ID}] = a
	}
	deadlines := leaseDeadlines(accounts)
	openFor := make(map[accountKey]bool, len(open))

	for _, p := range open {
		k := accountKey{p.Source, p.AccountID}
		openFor[k] = true
		if p.State == "running" {
			out.Due = append(out.Due, p)
			continue
		}
		if p.State != "scheduled" {
			continue
		}
		a, ok := byKey[k]
		if !enabled || !ok || a.Status == "purged" {
			out.Cancel = append(out.Cancel, p.ID)
			continue
		}
		due, err := time.Parse(time.RFC3339, p.DueAt)
		if err != nil {
			// An unreadable due date cannot be honoured; cancel and let the
			// next pass reschedule from the account facts.
			out.Cancel = append(out.Cancel, p.ID)
			continue
		}
		switch p.Reason {
		case ReasonRevoked:
			switch {
			case accessAfterRevocation(a):
				out.Cancel = append(out.Cancel, p.ID)
			case a.Status == "revoked":
				if !now.Before(due) {
					out.Due = append(out.Due, p)
				}
			case a.Status == "error":
				// Not still revoked on the latest attempt, not proof of
				// access either: wait.
			default:
				out.Cancel = append(out.Cancel, p.ID)
			}
		case ReasonLease:
			deadline, ok := deadlines[k]
			switch {
			case !ok || deadline.After(due):
				out.Cancel = append(out.Cancel, p.ID)
			case !now.Before(due) && !now.Before(deadline):
				out.Due = append(out.Due, p)
			}
		default:
			out.Cancel = append(out.Cancel, p.ID)
		}
	}
	if !enabled {
		return out
	}

	floor := now.Add(Grace)
	for _, a := range accounts {
		k := accountKey{a.Source, a.ID}
		if openFor[k] || a.Status == "purged" {
			continue
		}
		if a.Status == "revoked" {
			if !accessAfterRevocation(a) {
				out.Schedule = append(out.Schedule, ScheduleItem{a.Source, a.ID, ReasonRevoked, floor})
			}
			continue
		}
		deadline, ok := deadlines[k]
		if !ok {
			continue
		}
		if a.Status == "removed" {
			if !now.Before(deadline) {
				out.Schedule = append(out.Schedule, ScheduleItem{a.Source, a.ID, ReasonLease, floor})
			}
			continue
		}
		// Scheduled once the deadline is within Grace; due Grace from now,
		// which on a daemon that runs is the deadline itself (one cycle).
		if !now.Before(deadline.Add(-Grace)) {
			out.Schedule = append(out.Schedule, ScheduleItem{a.Source, a.ID, ReasonLease, floor})
		}
	}
	sort.Slice(out.Due, func(i, j int) bool { return out.Due[i].ID < out.Due[j].ID })
	return out
}

// leaseDeadlines returns each account's lease deadline: for a live account
// its source's newest access_ok_at + Lease (only when every live account of
// the source has one), for a removed account its own access_ok_at + Lease.
// Purged accounts have none.
func leaseDeadlines(accounts []db.PurgeAccount) map[accountKey]time.Time {
	type sourceClock struct {
		newest  time.Time
		unknown bool
	}
	clocks := map[string]*sourceClock{}
	for _, a := range accounts {
		if !isLive(a.Status) {
			continue
		}
		c := clocks[a.Source]
		if c == nil {
			c = &sourceClock{}
			clocks[a.Source] = c
		}
		t, ok := parseTime(a.AccessOKAt)
		if !ok {
			c.unknown = true
			continue
		}
		if t.After(c.newest) {
			c.newest = t
		}
	}
	out := map[accountKey]time.Time{}
	for _, a := range accounts {
		k := accountKey{a.Source, a.ID}
		switch {
		case a.Status == "removed":
			if t, ok := parseTime(a.AccessOKAt); ok {
				out[k] = t.Add(Lease)
			}
		case isLive(a.Status):
			if c := clocks[a.Source]; c != nil && !c.unknown {
				out[k] = c.newest.Add(Lease)
			}
		}
	}
	return out
}

// accessAfterRevocation reports whether the account's last confirmed access
// is newer than its revocation. An empty or unreadable time on either side
// is no proof: false.
func accessAfterRevocation(a db.PurgeAccount) bool {
	okAt, ok := parseTime(a.AccessOKAt)
	if !ok {
		return false
	}
	revokedAt, ok := parseTime(a.RevokedAt)
	return ok && okAt.After(revokedAt)
}

func isLive(status string) bool { return status != "removed" && status != "purged" }

func parseTime(s string) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}

// Apply reads the accounts and the open ledger rows, plans, and writes the
// cancels and schedules (each its own short statement). leases says whether
// lease rows may be scheduled: the daemon's start-of-cycle pass says no, so
// a Mac back from a long absence first lets this cycle's syncs prove access,
// and the pass after the syncs says yes. A failed write is joined into the
// returned error and the other rows are still written. It returns what it
// did — Schedule holds only the rows actually inserted, Cancel only the rows
// actually cancelled — and the Due rows for Run.
func Apply(d *db.DB, enabled, leases bool, now time.Time) (Actions, error) {
	accounts, err := d.ListPurgeAccounts()
	if err != nil {
		return Actions{}, err
	}
	open, err := d.ListAccountPurges(true)
	if err != nil {
		return Actions{}, err
	}
	plan := Plan(accounts, open, enabled, now)
	done := Actions{Due: plan.Due}
	var errs []error
	for _, id := range plan.Cancel {
		ok, err := d.CancelAccountPurge(id)
		if err != nil {
			errs = append(errs, fmt.Errorf("purge schedule: %w", err))
			continue
		}
		if ok {
			done.Cancel = append(done.Cancel, id)
		}
	}
	for _, s := range plan.Schedule {
		if s.Reason == ReasonLease && !leases {
			continue
		}
		ok, err := d.ScheduleAccountPurge(s.Source, s.AccountID, s.Reason, s.DueAt.UTC().Format(time.RFC3339))
		if err != nil {
			errs = append(errs, fmt.Errorf("purge schedule: %w", err))
			continue
		}
		if ok {
			done.Schedule = append(done.Schedule, s)
		}
	}
	return done, errors.Join(errs...)
}
