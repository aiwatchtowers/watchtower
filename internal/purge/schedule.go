package purge

import (
	"errors"
	"fmt"
	"sort"
	"strings"
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
// purges to schedule, cancel and run (PURGE-01). It reads nothing else but
// the notice (EffectiveGrace, "the grace" below); rules (Rules) says per
// account what the purge may do.
//
//   - RuleNone (the switch off, or a removed account of a source the policy
//     forbids): every scheduled row of the account is cancelled; nothing is
//     scheduled or run but a running row, which always finishes.
//   - Revoked (any other rule): a revoked account is scheduled the grace
//     after the pass that first sees it. It is cancelled once the account is no
//     longer revoked or in error (a reconnect writes ok; a removed account
//     falls under the removed lease), or once its access_ok_at is newer than
//     its revoked_at (a clean Jira/Linear pass, which never writes ok —
//     LINEAR-03); a due row runs only while the account is still revoked
//     (error waits). An empty or unreadable access_ok_at is no proof of
//     access: still revoked.
//   - Lease (live accounts under RuleFull, status not removed/purged,
//     disabled included): when every live account of a source has an
//     access_ok_at and the newest is older than Lease − Grace (the fixed 72 h
//     schedule-ahead window, whatever the managed notice), each live account
//     is scheduled, due at its deadline (newest + Lease) or the grace after
//     the pass, whichever is later. Under RuleRevokedAndRemoved a live
//     account has no lease.
//   - Lease (removed accounts, ask #477): a removed account whose own
//     access_ok_at is older than Lease is scheduled the grace after now; a
//     removed Slack account has a zero lease (#1769, A2): it is scheduled by
//     the first pass after the remove.
//   - A lease row is cancelled when its account's lease deadline moves past
//     the row's due_at (fresh access, a removed account added back, or a rule
//     that no longer gives it a lease), and runs only once that deadline has
//     passed.
//
// Every due date is at least the grace after the pass that schedules it, so
// the notice always shows for the full grace period (a grace of 0 makes the
// row due at once; the daemon still runs it only after the next cycle's
// syncs, NoNotice) — also when the purge is
// turned on for an account revoked long ago, or the daemon did not run for
// longer than the lease.
// An empty or unreadable time is no evidence: it never schedules an
// inactivity lease (a removed Slack account's zero lease needs none).
func Plan(accounts []db.PurgeAccount, open []db.AccountPurge, rules func(db.PurgeAccount) Rule, now time.Time) Actions {
	var out Actions
	byKey := make(map[accountKey]db.PurgeAccount, len(accounts))
	for _, a := range accounts {
		byKey[accountKey{a.Source, a.ID}] = a
	}
	deadlines := leaseDeadlines(accounts, rules)
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
		if !ok || a.Status == "purged" || rules(a) == RuleNone {
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
			case !ok || deadline.After(due) || (zeroLease(a, rules(a)) && accessSinceScheduled(a, p)):
				out.Cancel = append(out.Cancel, p.ID)
			case !now.Before(due) && !now.Before(deadline):
				out.Due = append(out.Due, p)
			}
		default:
			out.Cancel = append(out.Cancel, p.ID)
		}
	}
	grace := EffectiveGrace()
	floor := now.Add(grace)
	for _, a := range accounts {
		k := accountKey{a.Source, a.ID}
		if openFor[k] || a.Status == "purged" || rules(a) == RuleNone {
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
		// Scheduled once the deadline is within the fixed schedule-ahead
		// window (Grace, never the managed notice: a long PurgeGraceHours must
		// not put a notice on an account that syncs every day); due at the
		// deadline, or the grace after now when that is later. Due is never
		// before the deadline, so the cancel rule above (deadline moved past
		// due) fires only on fresh access.
		if !now.Before(deadline.Add(-Grace)) {
			due := floor
			if deadline.After(due) {
				due = deadline
			}
			out.Schedule = append(out.Schedule, ScheduleItem{a.Source, a.ID, ReasonLease, due})
		}
	}
	sort.Slice(out.Due, func(i, j int) bool { return out.Due[i].ID < out.Due[j].ID })
	return out
}

// leaseDeadlines returns each account's lease deadline: for a live account
// under RuleFull its source's newest access_ok_at + Lease (only when every
// live account of the source has one); for a removed account its own
// access_ok_at + Lease, or — a removed Slack account, zero lease (A2) — its
// access_ok_at itself (the zero time when it has none: the remove, not an
// inactivity clock, is the evidence). Purged accounts, accounts under
// RuleNone and live accounts under RuleRevokedAndRemoved have none.
func leaseDeadlines(accounts []db.PurgeAccount, rules func(db.PurgeAccount) Rule) map[accountKey]time.Time {
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
		r := rules(a)
		if r == RuleNone {
			continue
		}
		k := accountKey{a.Source, a.ID}
		switch {
		case zeroLease(a, r):
			t, _ := parseTime(a.AccessOKAt)
			out[k] = t
		case a.Status == "removed":
			if t, ok := parseTime(a.AccessOKAt); ok {
				out[k] = t.Add(Lease)
			}
		case isLive(a.Status) && r == RuleFull:
			if c := clocks[a.Source]; c != nil && !c.unknown {
				out[k] = c.newest.Add(Lease)
			}
		}
	}
	return out
}

// accessSinceScheduled reports whether the account confirmed access after
// the row was scheduled (#1769 fix round 1): a removed Slack account added
// back and removed again before the next pass keeps its old zero-lease row,
// whose due date then gives less than the full notice — the row is
// cancelled and the next pass schedules a fresh one. An empty or unreadable
// time on either side is no evidence: false.
//
// The clocks have second precision; a tie counts as access since.
func accessSinceScheduled(a db.PurgeAccount, p db.AccountPurge) bool {
	okAt, ok := parseTime(a.AccessOKAt)
	if !ok {
		return false
	}
	scheduledAt, ok := parseTime(p.ScheduledAt)
	return ok && !okAt.Before(scheduledAt) // a same-second tie keeps the data
}

// VerifyHeld returns whether an account is held after a failed verify count
// (#1769, spec §9 "the account stays held"): an account that does not sync
// anyway (revoked or removed) whose newest ledger row is failed with rows
// left (verifyLeftPrefix) and which has confirmed no access since that row
// finished (a same-second tie releases). Such an account is not scheduled
// again on its own — a leftover the steps cannot delete would otherwise give
// a new notice every grace period forever — and the sync phases skip it; the failed
// row stays visible. A Re-login or adding a removed account back confirms
// access and releases it. A live account is never held: a verify failure of
// its lease purge releases it like a chunk failure (MaxChunkFailures) does,
// and it is scheduled again with a new notice. The caller applies the hold
// only with the purge on.
func VerifyHeld(accounts []db.PurgeAccount, rows []db.AccountPurge) func(source string, id int64) bool {
	newest := map[accountKey]db.AccountPurge{}
	for _, r := range rows {
		k := accountKey{r.Source, r.AccountID}
		if cur, ok := newest[k]; !ok || r.ID > cur.ID {
			newest[k] = r
		}
	}
	held := map[accountKey]bool{}
	for _, a := range accounts {
		k := accountKey{a.Source, a.ID}
		r, ok := newest[k]
		if !ok || (a.Status != "revoked" && a.Status != "removed") ||
			r.State != "failed" || !strings.HasPrefix(r.Error, verifyLeftPrefix) {
			continue
		}
		okAt, hasAccess := parseTime(a.AccessOKAt)
		finishedAt, hasFinish := parseTime(r.FinishedAt)
		if hasAccess && hasFinish && !okAt.Before(finishedAt) {
			continue
		}
		held[k] = true
	}
	return func(source string, id int64) bool { return held[accountKey{source, id}] }
}

// holdRules is rules with every account held reports at RuleNone.
func holdRules(rules func(db.PurgeAccount) Rule, held func(string, int64) bool) func(db.PurgeAccount) Rule {
	return func(a db.PurgeAccount) Rule {
		if held(a.Source, a.ID) {
			return RuleNone
		}
		return rules(a)
	}
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

// Apply reads the accounts and the ledger, plans the open rows with rules —
// an account VerifyHeld reports at RuleNone — (built
// by the caller from Enabled and policy.SourceAllowed), and writes the
// cancels and schedules (each its own short statement). leases says whether
// lease rows may be scheduled: the daemon's start-of-cycle pass says no, so
// a Mac back from a long absence first lets this cycle's syncs prove access,
// and the pass after the syncs says yes. A failed write is joined into the
// returned error and the other rows are still written. It returns what it
// did — Schedule holds only the rows actually inserted, Cancel only the rows
// actually cancelled — and the Due rows for Run.
func Apply(d *db.DB, rules func(db.PurgeAccount) Rule, leases bool, now time.Time) (Actions, error) {
	accounts, err := d.ListPurgeAccounts()
	if err != nil {
		return Actions{}, err
	}
	ledger, err := d.ListAccountPurges(false)
	if err != nil {
		return Actions{}, err
	}
	var open []db.AccountPurge
	for _, p := range ledger {
		if p.State == "scheduled" || p.State == "running" {
			open = append(open, p)
		}
	}
	plan := Plan(accounts, open, holdRules(rules, VerifyHeld(accounts, ledger)), now)
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

// LeaseDeadlines returns the lease deadline of each of source's accounts that
// has one under rules (leaseDeadlines): the day PURGE-01 would delete it when
// nothing confirms access before. The Desktop's dead-token note (#1887 §6.3)
// shows it, so it never keeps a copy of the rule.
func LeaseDeadlines(accounts []db.PurgeAccount, rules func(db.PurgeAccount) Rule, source string) map[int64]time.Time {
	out := map[int64]time.Time{}
	for k, t := range leaseDeadlines(accounts, rules) {
		if k.source == source && !t.IsZero() {
			out[k.id] = t
		}
	}
	return out
}

// noNoticeBelow is where NoNotice draws the line: half the smallest non-zero
// notice (one hour). due_at comes from Go's clock and scheduled_at from
// SQLite's a moment later, each truncated to the second, so a one-hour row
// can read as due a second short of an hour after scheduling; the margin
// keeps it a row with a notice.
const noNoticeBelow = 30 * time.Minute

// NoNotice reports whether a scheduled row was given no notice: due less than
// 30 minutes after it was scheduled (a PurgeGraceHours of 0, or under it a
// lease already past its deadline). Such a row is deleted only after the next sync
// cycle (owner decision 2026-11-23, ask #862): the daemon's start-of-cycle
// pass never runs it, and the pass after a cycle's syncs runs it only when
// those syncs started after it was scheduled (SyncedSince), so a sync that
// proves access cancels it first. A running row, or one with a notice, is
// not held. An unreadable time counts as no notice (it waits).
func NoNotice(p db.AccountPurge) bool {
	if p.State != "scheduled" {
		return false
	}
	due, okDue := parseTime(p.DueAt)
	scheduled, okScheduled := parseTime(p.ScheduledAt)
	return !okDue || !okScheduled || due.Before(scheduled.Add(noNoticeBelow))
}

// SyncedSince reports whether a cycle's syncs that started at syncStart began
// after the row was scheduled. The ledger clock has second precision, so a
// sync started in the row's own second does not count; the zero syncStart (no
// sync started in this process yet) never does.
func SyncedSince(p db.AccountPurge, syncStart time.Time) bool {
	scheduled, ok := parseTime(p.ScheduledAt)
	return ok && !syncStart.IsZero() && scheduled.Before(syncStart.Truncate(time.Second))
}
