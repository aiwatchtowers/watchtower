package daemon

import (
	"time"

	"watchtower/internal/db"
)

// logNoOwnerOnce reports that phase skipped because the install has no owner
// identity, at most once per UTC calendar day per phase: a no-owner install
// runs every phase every cycle, and a line per cycle would bury the log. The
// memo is in memory only, so a daemon restart may print the day's line again.
func (d *Daemon) logNoOwnerOnce(now time.Time, phase string) {
	day := now.UTC().Format("2006-01-02")
	if d.noOwnerLoggedDay[phase] == day {
		return
	}
	if d.noOwnerLoggedDay == nil {
		d.noOwnerLoggedDay = make(map[string]string)
	}
	d.noOwnerLoggedDay[phase] = day
	d.logger.Printf("daemon: %s skipped: no owner identity (connect Slack, Google or Jira)", phase)
}

// dayPlanOwner is the owner the day-plan phases run for, resolved once per
// cycle. The zero Owner means skip: no DB, no owner (a benign skip, logged
// once a day) or an owner lookup error (logged — a real signal).
func (d *Daemon) dayPlanOwner(now time.Time) db.Owner {
	if d.db == nil {
		return db.Owner{}
	}
	owner, err := d.db.ResolveOwner()
	if err != nil {
		d.logger.Printf("dayplan: resolving owner: %v", err)
		return db.Owner{}
	}
	if !owner.Known() {
		d.logNoOwnerOnce(now, "day_plan")
	}
	return owner
}

// briefingHasOwner gates the briefing phase before its pipeline run is
// tracked, so a no-owner install writes no pipeline_runs row (OWNER-02): no
// owner is a benign skip, logged once per UTC day. No DB, or an owner lookup
// error, lets the run go ahead — Run resolves the owner itself and reports a
// lookup failure as the phase's error (the applyInboxOwner rule).
func (d *Daemon) briefingHasOwner(now time.Time) bool {
	if d.db == nil {
		return true
	}
	owner, err := d.db.ResolveOwner()
	if err != nil || owner.Known() {
		return true
	}
	d.logNoOwnerOnce(now, "briefing")
	return false
}
