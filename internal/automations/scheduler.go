package automations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/fsutil"
)

// clockBackwardsReprime is how far an automation's last_scheduled_for may lie
// ahead of now before the scheduler restarts that schedule from now. Any
// smaller step back (an NTP correction, a clock set back a few hours) just
// waits: nothing fires until the clock passes last_scheduled_for again, so no
// due time fires twice. A schedule point more than a day ahead was set under
// a bogus future clock, and waiting for the clock to catch up would stall it.
const clockBackwardsReprime = 24 * time.Hour

// Scheduler turns cron schedules into queued runs (spec §7.2). It only
// inserts rows (AUTO-09); the executor runs them. Each tick it rescans the
// personal folder and every unprotected workbench's recipe folder when they
// changed (rescanWorkbenches), then for every runnable schedule
// automation looks at the due times in (last_scheduled_for, now]: the latest
// one within ScheduleGrace of now is on time and queues a `schedule` run
// (older missed ones are folded into it); otherwise `missed: run_once` queues
// one `catch_up` run for the latest missed time and `missed: skip` queues
// none (AUTO-10). last_scheduled_for advances to that latest due time in the
// same transaction as the insert, so a crash or restart never repeats it.
type Scheduler struct {
	db     *db.DB
	ix     *Indexer
	clock  Clock
	wake   func()
	wakeCh chan struct{}
	logger *log.Logger
	// zone resolves the local time zone at each tick (systemZone), so a time
	// zone change takes effect without a restart; tests replace it.
	zone func() *time.Location
	// protected is the privacy-protected folder rule (fsutil.PrivacyProtected);
	// tests replace it.
	protected func(string) bool
	// beforeWrite, when set (tests), runs between reading a row and writing
	// its schedule.
	beforeWrite func(db.Automation)
}

// NewScheduler returns a scheduler over d. ix rescans the personal and
// workbench folders; a nil ix skips rescans. wake, when not nil, is called
// after a tick that inserted a run (the executor's wake).
func NewScheduler(d *db.DB, ix *Indexer, clock Clock, wake func()) *Scheduler {
	return &Scheduler{
		db: d, ix: ix, clock: clock, wake: wake, wakeCh: make(chan struct{}, 1),
		logger: log.Default(), zone: systemZone, protected: fsutil.PrivacyProtected,
	}
}

// SetLogger sets where Run reports tick errors (the daemon's logger);
// log.Default() until called. Call it before Run.
func (s *Scheduler) SetLogger(l *log.Logger) {
	if l != nil {
		s.logger = l
	}
}

// Wake asks Run for a tick now (e.g. after a recipe was saved); it never
// blocks, and wakes that arrive before the tick are coalesced.
func (s *Scheduler) Wake() {
	select {
	case s.wakeCh <- struct{}{}:
	default:
	}
}

// Run ticks at once, then at every minute boundary and on Wake, until ctx is
// done; it then returns nil. A tick's error is logged and the loop goes on.
func (s *Scheduler) Run(ctx context.Context) error {
	for {
		if err := s.Tick(ctx, s.clock.Now()); err != nil && ctx.Err() == nil {
			s.logger.Printf("automations: scheduler tick: %v", err)
		}
		now := s.clock.Now()
		select {
		case <-ctx.Done():
			return nil
		case <-s.clock.After(now.Truncate(time.Minute).Add(time.Minute).Sub(now)):
		case <-s.wakeCh:
		}
	}
}

// Tick is one scheduler pass at now (the test seam). One automation's
// failure does not stop the others; every failure is returned, joined.
func (s *Scheduler) Tick(ctx context.Context, now time.Time) error {
	var errs []error
	if s.ix != nil {
		if s.ix.Changed(PersonalDir(s.ix.workspaceDir)) {
			if _, err := s.ix.RescanPersonal(ctx); err != nil {
				errs = append(errs, err)
			}
		}
		errs = append(errs, s.rescanWorkbenches(ctx)...)
	}
	list, err := s.db.ListAutomations(db.AutomationFilter{TriggerKind: string(TriggerSchedule), RunnableOnly: true})
	if err != nil {
		return errors.Join(append(errs, fmt.Errorf("scheduler tick: %w", err))...)
	}
	loc := s.zone()
	inserted := false
	for _, a := range list {
		if err := ctx.Err(); err != nil {
			errs = append(errs, err)
			break
		}
		ins, err := s.scheduleOne(a, loc, now)
		if err != nil {
			errs = append(errs, fmt.Errorf("scheduling automation %d (%s): %w", a.ID, a.Slug, err))
		}
		inserted = inserted || ins
	}
	if inserted && s.wake != nil {
		s.wake()
	}
	return errors.Join(errs...)
}

// rescanWorkbenches rescans the recipe folder of every workbench whose folder
// is not privacy-protected, when it changed. A protected folder is skipped
// before any filesystem call — the daemon never stats, lists or reads it (a
// background read there raises a macOS privacy prompt attributed to
// Watchtower, a dead network mount can block it); its rows stay as the
// Desktop indexed them. A workbench whose folder is gone is skipped quietly,
// its rows kept.
func (s *Scheduler) rescanWorkbenches(ctx context.Context) []error {
	wbs, err := s.db.ListWorkbenches()
	if err != nil {
		return []error{fmt.Errorf("scheduler tick: %w", err)}
	}
	var errs []error
	for _, wb := range wbs {
		if ctx.Err() != nil {
			break // the schedule loop reports ctx's end
		}
		if s.protected(wb.FolderPath) || s.ix.folderMissing(wb.FolderPath) {
			continue
		}
		dir := WorkbenchDir(wb.FolderPath)
		if !s.ix.Changed(dir) {
			continue
		}
		if _, err := s.ix.RescanFolder(ctx, Scope{Kind: ScopeWorkbench, WorkbenchID: wb.ID}, dir); err != nil {
			errs = append(errs, fmt.Errorf("workbench %d: %w", wb.ID, err))
		}
	}
	return errs
}

// scheduleOne applies the schedule decision for one runnable automation and
// reports whether it inserted a run. Every write is a compare-and-set against
// the last_scheduled_for read with the row: when another writer (a confirm,
// an enable, the indexer) moved it meanwhile, the row is skipped this tick —
// nothing written, no run — and the next tick decides from the new value.
func (s *Scheduler) scheduleOne(a db.Automation, loc *time.Location, now time.Time) (bool, error) {
	var spec triggerSpec
	if err := json.Unmarshal([]byte(a.TriggerSpec), &spec); err != nil {
		return false, fmt.Errorf("decoding trigger_spec: %w", err)
	}
	cs, err := parseCronSchedule(spec.Schedule, loc)
	if err != nil {
		return false, err
	}
	dec := planSchedule(cs, a.LastScheduledFor, MissedPolicy(a.MissedPolicy), now)
	last := a.LastScheduledFor
	if dec.advanceTo != nil {
		last = dec.advanceTo
	}
	if dec.trigger == "" && sameInstant(last, a.LastScheduledFor) && sameInstant(dec.nextRunAt, a.NextRunAt) {
		return false, nil
	}
	if s.beforeWrite != nil {
		s.beforeWrite(a)
	}
	inserted := false
	if dec.trigger != "" {
		var coalesced bool
		_, coalesced, err = s.db.EnqueueAutomationRun(db.EnqueueRequest{
			AutomationID: a.ID, Trigger: dec.trigger, ScheduledFor: &dec.scheduledFor,
			AdvanceScheduleTo: dec.advanceTo, NextRunAt: dec.nextRunAt,
			ExpectLastScheduledFor: a.LastScheduledFor, Now: now,
		})
		inserted = err == nil && !coalesced
	} else {
		err = s.db.CompareAndSetAutomationSchedule(a.ID, a.LastScheduledFor, last, dec.nextRunAt)
	}
	if errors.Is(err, db.ErrScheduleChanged) {
		return false, nil
	}
	return inserted, err
}

// scheduleDecision is what one tick does to one automation.
type scheduleDecision struct {
	trigger      string // db.TriggerSchedule, db.TriggerCatchUp, or "" for no run
	scheduledFor time.Time
	advanceTo    *time.Time // new last_scheduled_for; nil keeps it
	nextRunAt    *time.Time // nil = no due time ahead
}

// planSchedule decides one automation's tick at now from its schedule point.
func planSchedule(cs *cronSchedule, last *time.Time, missed MissedPolicy, now time.Time) scheduleDecision {
	if last == nil || last.Sub(now) > clockBackwardsReprime {
		// No schedule point yet, or one far ahead of a clock that went back:
		// start from now, with no catch-up.
		return scheduleDecision{advanceTo: &now, nextRunAt: timePtr(cs.next(now))}
	}
	if !now.After(*last) {
		return scheduleDecision{nextRunAt: timePtr(cs.next(*last))}
	}
	dec := scheduleDecision{nextRunAt: timePtr(cs.next(now))}
	latest := cs.latestDue(*last, now)
	if latest.IsZero() {
		return dec
	}
	dec.advanceTo, dec.scheduledFor = &latest, latest
	switch {
	case now.Sub(latest) <= ScheduleGrace:
		dec.trigger = db.TriggerSchedule
	case missed != MissedSkip:
		dec.trigger = db.TriggerCatchUp
	}
	return dec
}

func timePtr(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}

// sameInstant compares two optional times at the store's one-second precision.
func sameInstant(a, b *time.Time) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return a.Unix() == b.Unix()
}

// systemZone is the machine's time zone as of now. Go reads the zone once at
// start (time.Local), so a zone change in System Settings would otherwise
// need a daemon restart: the zone is read from the /etc/localtime symlink
// (…/zoneinfo/<Area>/<City>) each tick. With TZ set in the environment, or
// when the link cannot be read or names an unknown zone (no symlink on some
// Linux installs), time.Local is the answer, as for every other Go time.
func systemZone() *time.Location {
	if _, set := os.LookupEnv("TZ"); set {
		return time.Local
	}
	target, err := os.Readlink("/etc/localtime")
	if err != nil {
		return time.Local
	}
	name, ok := zoneNameFromLink(target)
	if !ok {
		return time.Local
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		return time.Local
	}
	return loc
}

// zoneNameFromLink extracts the IANA name from a zoneinfo path such as
// /var/db/timezone/zoneinfo/Europe/Berlin.
func zoneNameFromLink(target string) (string, bool) {
	const marker = "zoneinfo/"
	i := strings.LastIndex(target, marker)
	if i < 0 {
		return "", false
	}
	name := target[i+len(marker):]
	return name, name != ""
}
