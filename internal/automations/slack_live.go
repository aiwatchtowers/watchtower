package automations

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// Live Slack in automations (#1709, spec §4, D14/D15): a recipe with
// slack:live may run at most once an hour — its schedule is refused when
// two firings fall closer than LiveSlackMinInterval, and the executor ends a
// run of it that would start sooner than that after its previous run.

// LiveSlackMinInterval is the shortest gap between two runs of a slack:live
// recipe (D15).
const LiveSlackMinInterval = time.Hour

// LiveSlackLimitedError is the error of a run ended by the hourly limit.
const LiveSlackLimitedError = "Live Slack: at most once an hour"

// LiveSlackReadOnlyStep is the run-log step text of a Slack connector write
// the agent tried on Live (the connector is read-only in automations).
const LiveSlackReadOnlyStep = "Live Slack is read-only in automations"

// liveCadenceSpan is how far each cadence check expands a schedule.
const liveCadenceSpan = 8 * 24 * time.Hour

// Seams of the schedule check: the scheduler's zone and the clock it
// starts from (tests replace them).
var (
	liveCadenceZone = systemZone
	liveCadenceNow  = time.Now
)

// checkLiveCadence refuses a schedule that fires twice within
// LiveSlackMinInterval: the scheduler's own expansion (cronSchedule, with
// its DST rules) in the scheduler's zone, over liveCadenceSpan from now and
// around every zone transition of the next year, so a DST change that
// brings two firings closer is caught.
func checkLiveCadence(expr string) error {
	loc := liveCadenceZone()
	c, err := parseCronSchedule(expr, loc)
	if err != nil {
		return err
	}
	now := liveCadenceNow().In(loc)
	starts := []time.Time{now}
	for _, tr := range zoneTransitions(loc, now, now.AddDate(1, 0, 1)) {
		starts = append(starts, tr.Add(-2*24*time.Hour))
	}
	for _, from := range starts {
		prev := c.next(from)
		for t := prev; !t.IsZero() && t.Before(from.Add(liveCadenceSpan)); t = c.next(t) {
			if t != prev && t.Sub(prev) < LiveSlackMinInterval {
				return fmt.Errorf("a recipe with %s runs at most once an hour; trigger.schedule %q fires at %s and again at %s",
					EntrySlackLive, expr, prev.Format("Mon 15:04 MST"), t.Format("Mon 15:04 MST"))
			}
			prev = t
		}
	}
	return nil
}

// zoneTransitions lists the instants in [from, to) where loc's offset
// changes, to the hour.
func zoneTransitions(loc *time.Location, from, to time.Time) []time.Time {
	var out []time.Time
	_, off := from.Zone()
	for t := from.Add(time.Hour); t.Before(to); t = t.Add(time.Hour) {
		if _, o := t.In(loc).Zone(); o != off {
			out = append(out, t)
			off = o
		}
	}
	return out
}

// liveSlackFullTriggerError refuses a slack:live recipe whose trigger needs
// synced Slack (a slack.* event or a reaction) when no Full account exists:
// on Live only there is nothing to fire it.
func liveSlackFullTriggerError(r *Recipe, m *Manifest, fullAccount func() (bool, error)) error {
	if !m.SlackLive() || r.Trigger.Kind != TriggerEvent || r.Trigger.Event == nil ||
		!strings.HasPrefix(r.Trigger.Event.Type, "slack.") {
		return nil
	}
	ok, err := fullAccount()
	if err != nil {
		return err
	}
	if ok {
		return nil
	}
	return fmt.Errorf("trigger event %s needs a Slack workspace synced in Full; with Live only nothing fires it — "+
		"connect Slack in Full, or use a schedule", r.Trigger.Event.Type)
}

// HasFullSlackAccount reports whether an enabled, non-removed Slack
// account is signed in (status ok): Slack in Full.
func HasFullSlackAccount(d *db.DB) (bool, error) {
	accounts, err := d.ListEnabledSlackAccounts()
	if err != nil {
		return false, err
	}
	for _, a := range accounts {
		if a.Status == "ok" {
			return true, nil
		}
	}
	return false, nil
}

// AutomationSlackLive reports whether an indexed automation's permissions
// list slack:live (the executor's hourly limit and the agent's wiring).
func AutomationSlackLive(a *db.Automation) bool {
	var entries []string
	if a == nil || json.Unmarshal([]byte(a.PermissionsJSON), &entries) != nil {
		return false
	}
	for _, e := range entries {
		if p, err := ParsePermission(e); err == nil && p.String() == EntrySlackLive {
			return true
		}
	}
	return false
}

// liveSlackLimited reports whether a run of a, starting at now, comes less
// than LiveSlackMinInterval after the newest run of a that started (every
// trigger, dry runs included; runs ended by this limit never started).
func liveSlackLimited(d *db.DB, a *db.Automation, runID int64, now time.Time) (bool, error) {
	if !AutomationSlackLive(a) {
		return false, nil
	}
	last, err := d.LastLiveSlackRunStart(a.ID, runID)
	if errors.Is(err, db.ErrAutomationRunNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return now.Sub(last) < LiveSlackMinInterval, nil
}
