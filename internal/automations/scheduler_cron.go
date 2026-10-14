package automations

import (
	"fmt"
	"strings"
	"time"

	"github.com/robfig/cron/v3"
)

// dstProbe bounds how far from a wall-clock time a zone offset change is
// looked for; every real DST shift is well under it.
const dstProbe = 3 * time.Hour

// maxWallSkips bounds the wall-clock times next skips because their instant
// already passed (at most the due times of one repeated fall-back hour).
const maxWallSkips = 10000

// cronSchedule is a recipe's 5-field cron expression in a time zone (spec
// §7.2), with cron's daylight-saving rules:
//
//   - An expression whose hour field holds a '*' (every hour, every n hours)
//     follows elapsed time: during a fall-back it fires in both passes of the
//     repeated hour, and the skipped spring-forward hour simply has no due
//     times.
//   - An expression with fixed hours is a wall-clock appointment: a time that
//     occurs twice on a fall-back day is due once (its first occurrence), and
//     a time inside the skipped spring-forward hour is due once, at the
//     instant the hour is skipped (02:30 → 03:00 on that day).
//
// This follows Vixie cron's DST handling with two deliberate differences:
// Vixie calls a job "wildcard" when its minute OR hour field is a wildcard,
// while here only the hour field decides ("* 2 * * *" is a wall-clock
// appointment: on a fall-back day it fires through the first 02:xx hour
// only, not through both); and Vixie infers a DST change from the size of a
// wall-clock jump, while here the zone database's transitions are used, so a
// real clock jump is never taken for one (the missed-run rules handle it).
type cronSchedule struct {
	loc     *time.Location
	elapsed cron.Schedule // hour field with '*': robfig instants in loc
	wall    cron.Schedule // fixed hours: the expression on a zone-less wall clock
}

// parseCronSchedule parses expr (5 fields, robfig's standard parser) for loc.
func parseCronSchedule(expr string, loc *time.Location) (*cronSchedule, error) {
	fields := strings.Fields(expr)
	if len(fields) != 5 {
		return nil, fmt.Errorf("schedule %q is not a 5-field cron expression", expr)
	}
	c := &cronSchedule{loc: loc}
	var err error
	if strings.Contains(fields[1], "*") {
		c.elapsed, err = cron.ParseStandard(expr)
		if spec, ok := c.elapsed.(*cron.SpecSchedule); ok {
			spec.Location = loc
		}
	} else {
		c.wall, err = cron.ParseStandard("TZ=UTC " + expr)
	}
	if err != nil {
		return nil, fmt.Errorf("schedule %q: %w", expr, err)
	}
	return c, nil
}

// next returns the first due instant strictly after t, or the zero time when
// none is found (robfig gives up five years out, e.g. "0 0 30 2 *").
func (c *cronSchedule) next(t time.Time) time.Time {
	if c.elapsed != nil {
		return c.elapsed.Next(t.In(c.loc))
	}
	w := floatingWall(t.In(c.loc))
	for range maxWallSkips {
		w = c.wall.Next(w)
		if w.IsZero() {
			return time.Time{}
		}
		if inst := wallInstant(w, c.loc); inst.After(t) {
			return inst
		}
	}
	return time.Time{}
}

// latestDue returns the latest due instant in (after, upTo], or the zero time
// when there is none. It looks back from upTo in growing windows, so a long
// gap (a Mac asleep for weeks, a clock jump of years) costs a handful of
// steps instead of one per missed due time.
func (c *cronSchedule) latestDue(after, upTo time.Time) time.Time {
	for _, back := range []time.Duration{ScheduleGrace, time.Hour, 24 * time.Hour, 32 * 24 * time.Hour, 367 * 24 * time.Hour} {
		start := upTo.Add(-back)
		if !start.After(after) {
			break
		}
		if t := c.latestIn(start, upTo); !t.IsZero() {
			return t
		}
	}
	return c.latestIn(after, upTo)
}

func (c *cronSchedule) latestIn(after, upTo time.Time) time.Time {
	var latest time.Time
	for t := c.next(after); !t.IsZero() && !t.After(upTo); t = c.next(t) {
		latest = t
	}
	return latest
}

// floatingWall is t's wall clock as a UTC time (the zone dropped).
func floatingWall(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), t.Day(), t.Hour(), t.Minute(), t.Second(), 0, time.UTC)
}

func sameWall(inst, w time.Time) bool {
	return floatingWall(inst).Equal(w)
}

// wallInstant maps a wall-clock time (w's fields, read as UTC) to the
// earliest instant in loc that shows it; a wall time inside a spring-forward
// gap maps to the instant the gap starts.
func wallInstant(w time.Time, loc *time.Location) time.Time {
	guess := time.Date(w.Year(), w.Month(), w.Day(), w.Hour(), w.Minute(), w.Second(), 0, loc)
	var best time.Time
	for _, probe := range []time.Time{guess.Add(-dstProbe), guess, guess.Add(dstProbe)} {
		_, off := probe.Zone()
		inst := time.Unix(w.Unix()-int64(off), 0).In(loc)
		if sameWall(inst, w) && (best.IsZero() || inst.Before(best)) {
			best = inst
		}
	}
	if !best.IsZero() {
		return best
	}
	return zoneShift(guess.Add(-dstProbe), guess.Add(dstProbe), loc)
}

// zoneShift returns the first second in (lo, hi] whose zone offset differs
// from lo's. Without a change in the range it returns hi.
func zoneShift(lo, hi time.Time, loc *time.Location) time.Time {
	offsetAt := func(s int64) int {
		_, off := time.Unix(s, 0).In(loc).Zone()
		return off
	}
	loS, hiS := lo.Unix(), hi.Unix()
	offLo := offsetAt(loS)
	for hiS-loS > 1 {
		mid := loS + (hiS-loS)/2
		if offsetAt(mid) == offLo {
			loS = mid
		} else {
			hiS = mid
		}
	}
	return time.Unix(hiS, 0).In(loc)
}
