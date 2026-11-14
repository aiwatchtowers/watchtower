package automations

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/robfig/cron/v3"

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

// liveCadenceSpan is how far each DST window expands a schedule.
const liveCadenceSpan = 8 * 24 * time.Hour

// liveCadenceRefYear is the fixed year whose zone transitions the DST check
// expands around, so a recipe's verdict never depends on today's date.
const liveCadenceRefYear = 2025

// liveCadenceZone is the schedule check's zone: the scheduler's (tests
// replace it).
var liveCadenceZone = systemZone

// checkLiveCadence refuses a schedule that can fire twice within
// LiveSlackMinInterval. First the time of day alone: the firings its minute
// and hour fields allow in one day, two neighbours — the last of a day and
// the first of the next included — must be an hour apart, whatever the day,
// month and weekday fields say. Then DST: the scheduler's own expansion
// (cronSchedule, with its DST rules) in the scheduler's zone, around every
// zone transition of liveCadenceRefYear, since a clock change can bring two
// firings closer.
func checkLiveCadence(expr string) error {
	refuse := func(a, b string) error {
		return fmt.Errorf("a recipe with %s runs at most once an hour; trigger.schedule %q fires at %s and again at %s",
			EntrySlackLive, expr, a, b)
	}
	sched, err := cron.ParseStandard(expr)
	if err != nil {
		return err
	}
	spec, ok := sched.(*cron.SpecSchedule)
	if !ok {
		return fmt.Errorf("trigger.schedule %q: not a 5-field schedule", expr)
	}
	var day []int // minutes of the day, ascending
	for h := range 24 {
		for m := range 60 {
			if spec.Hour&(1<<uint(h)) != 0 && spec.Minute&(1<<uint(m)) != 0 {
				day = append(day, h*60+m)
			}
		}
	}
	clock := func(m int) string { return fmt.Sprintf("%02d:%02d", m/60%24, m%60) }
	for i := 1; i < len(day); i++ {
		if day[i]-day[i-1] < int(LiveSlackMinInterval/time.Minute) {
			return refuse(clock(day[i-1]), clock(day[i]))
		}
	}
	if n := len(day); n > 1 && day[0]+24*60-day[n-1] < int(LiveSlackMinInterval/time.Minute) {
		return refuse(clock(day[n-1]), clock(day[0])+" the next day")
	}
	loc := liveCadenceZone()
	c, err := parseCronSchedule(expr, loc)
	if err != nil {
		return err
	}
	from := time.Date(liveCadenceRefYear, 1, 1, 0, 0, 0, 0, loc)
	for _, tr := range zoneTransitions(loc, from, from.AddDate(1, 0, 0)) {
		start := tr.Add(-2 * 24 * time.Hour)
		prev := c.next(start)
		for t := prev; !t.IsZero() && t.Before(start.Add(liveCadenceSpan)); t = c.next(t) {
			if t != prev && t.Sub(prev) < LiveSlackMinInterval {
				return refuse(prev.Format("Mon 15:04 MST"), t.Format("Mon 15:04 MST")+" (a clock change)")
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

// liveSlackStartTolerance is how much earlier than LiveSlackMinInterval a
// run may start after the previous one when the gap is measured between
// start times (claim jitter).
const liveSlackStartTolerance = 2 * time.Minute

// liveSlackLimited reports whether run r of a, starting at now, comes too
// soon after the newest started run of a (every trigger, dry runs included;
// runs ended by this limit never started). A schedule or catch-up run with
// a scheduled_for is compared by scheduled_for with a previous run that has
// one — the schedule check already keeps firings an hour apart, so claim
// jitter and a late catch-up never cancel a valid hourly schedule. Any other
// pair is compared by start times, allowing liveSlackStartTolerance.
func liveSlackLimited(d *db.DB, a *db.Automation, r *db.AutomationRun, now time.Time) (bool, error) {
	if !AutomationSlackLive(a) {
		return false, nil
	}
	started, prevScheduled, err := d.LastLiveSlackRunStart(a.ID, r.ID)
	if errors.Is(err, db.ErrAutomationRunNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	scheduledRun := r.Trigger == db.TriggerSchedule || r.Trigger == db.TriggerCatchUp
	if scheduledRun && r.ScheduledFor != nil && prevScheduled != nil {
		return r.ScheduledFor.Sub(*prevScheduled) < LiveSlackMinInterval, nil
	}
	return now.Sub(started) < LiveSlackMinInterval-liveSlackStartTolerance, nil
}
