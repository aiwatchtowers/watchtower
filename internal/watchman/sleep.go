package watchman

import (
	"context"
	"database/sql"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"
)

// Sleep window (spec 2026-11-16-watchman-design §8.4).
const (
	// SleepWindowKey is the watchman_profile row of the learned sleep window.
	SleepWindowKey = "sleep_window"
	// sleepLookbackDays is how far back the owner's activity is read.
	sleepLookbackDays = 28
	// sleepMinActiveDays is the fewest days with activity that give a window.
	sleepMinActiveDays = 7
	// The night is the stretch from 20:00 to 12:00 the next day, local time.
	nightStartHour = 20
	nightEndHour   = 12
)

// SleepWindow learns the owner's sleep window from his activity: for every
// complete night of the last 28 days (20:00 to 12:00 next day, local time)
// with activity in it, the longest gap between his actions — the night's
// edges count as actions; the window is the median start and the median end
// of those gaps, as offsets from local midnight. Times are wall-clock, so a
// DST change neither shifts nor stretches a night's gap. ok is false with
// fewer than 7 days with activity in the last 28.
func SleepWindow(activity []time.Time, now time.Time, loc *time.Location) (start, end time.Duration, ok bool) {
	now = now.In(loc)
	from := now.AddDate(0, 0, -sleepLookbackDays)
	var times []time.Time
	days := map[string]bool{}
	for _, t := range activity {
		t = t.In(loc)
		if t.Before(from) || t.After(now) {
			continue
		}
		times = append(times, t)
		days[t.Format(time.DateOnly)] = true
	}
	if len(days) < sleepMinActiveDays {
		return 0, 0, false
	}
	sort.Slice(times, func(i, j int) bool { return times[i].Before(times[j]) })

	var starts, ends []int // minutes after 20:00 on the night's wall clock
	y, m, d := from.Date()
	for day := time.Date(y, m, d, 0, 0, 0, 0, loc); ; day = day.AddDate(0, 0, 1) {
		lo, hi := nightBounds(day, loc)
		if hi.After(now) {
			break
		}
		if lo.Before(from) {
			continue
		}
		s, e, has := nightGap(times, lo, hi)
		if !has {
			continue
		}
		starts = append(starts, nightMinutes(s))
		ends = append(ends, nightMinutes(e))
	}
	if len(starts) == 0 {
		return 0, 0, false
	}
	return fromNightMinutes(median(starts)), fromNightMinutes(median(ends)), true
}

// nightBounds is the night that starts on day: 20:00 that day to 12:00 the
// next, both on the local wall clock.
func nightBounds(day time.Time, loc *time.Location) (lo, hi time.Time) {
	y, m, d := day.Date()
	return time.Date(y, m, d, nightStartHour, 0, 0, 0, loc), time.Date(y, m, d+1, nightEndHour, 0, 0, 0, loc)
}

// nightGap is the longest gap between the actions inside [lo, hi] (sorted
// times), lo and hi counting as actions; has is false without any action
// inside the night.
func nightGap(sorted []time.Time, lo, hi time.Time) (start, end time.Time, has bool) {
	i := sort.Search(len(sorted), func(i int) bool { return !sorted[i].Before(lo) })
	prev := lo
	var best time.Duration = -1
	for ; i < len(sorted) && !sorted[i].After(hi); i++ {
		has = true
		if g := sorted[i].Sub(prev); g > best {
			best, start, end = g, prev, sorted[i]
		}
		prev = sorted[i]
	}
	if !has {
		return time.Time{}, time.Time{}, false
	}
	if g := hi.Sub(prev); g > best {
		start, end = prev, hi
	}
	return start, end, true
}

// nightMinutes is t's wall-clock minutes after 20:00 (0 … 960 in a night).
func nightMinutes(t time.Time) int {
	m := t.Hour()*60 + t.Minute() - nightStartHour*60
	if m < 0 {
		m += 24 * 60
	}
	return m
}

// fromNightMinutes turns minutes after 20:00 back into an offset from
// midnight in [0, 24h).
func fromNightMinutes(m int) time.Duration {
	return time.Duration((m+nightStartHour*60)%(24*60)) * time.Minute
}

// median of non-empty xs: the middle value, or the mean of the two middle
// values (truncated to a minute).
func median(xs []int) int {
	s := append([]int(nil), xs...)
	sort.Ints(s)
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

// FormatSleepWindow renders a window as the profile row's "HH:MM-HH:MM".
func FormatSleepWindow(start, end time.Duration) string {
	hm := func(d time.Duration) string {
		m := int(d / time.Minute)
		return fmt.Sprintf("%02d:%02d", m/60, m%60)
	}
	return hm(start) + "-" + hm(end)
}

var sleepWindowRe = regexp.MustCompile(`^([01]\d|2[0-3]):([0-5]\d)-([01]\d|2[0-3]):([0-5]\d)$`)

// ParseSleepWindow reads "HH:MM-HH:MM" (24-hour clock) into offsets from
// midnight.
func ParseSleepWindow(s string) (start, end time.Duration, err error) {
	m := sleepWindowRe.FindStringSubmatch(strings.TrimSpace(s))
	if m == nil {
		return 0, 0, fmt.Errorf("watchman: sleep window %q is not HH:MM-HH:MM", s)
	}
	// The regexp admits only two-digit numbers, so Atoi cannot fail.
	n := func(i int) int { v, _ := strconv.Atoi(m[i]); return v }
	return time.Duration(n(1)*60+n(2)) * time.Minute, time.Duration(n(3)*60+n(4)) * time.Minute, nil
}

// ActivityTimes collects when the owner acted on a workbench at or after
// since: his own turns in its agent sessions (only when agentLog is non-nil:
// Agent analytics may be off), his ask answers and review comments, and the
// author times of his own commits (no agent trailer, isAgentCommit) in the
// workbench folder.
func ActivityTimes(ctx context.Context, d *db.DB, agentLog *sql.DB, workbenchID int64, since time.Time) ([]time.Time, error) {
	return activityTimes(ctx, d, agentLog, workbenchID, since, ExecGit)
}

func activityTimes(ctx context.Context, d *db.DB, agentLog *sql.DB, workbenchID int64, since time.Time, git GitRunner) ([]time.Time, error) {
	out, err := d.WatchmanOwnerActivity(workbenchID, since)
	if err != nil {
		return nil, fmt.Errorf("watchman activity: %w", err)
	}
	if agentLog != nil {
		turns, err := (&agentlogdb.DB{DB: agentLog}).OwnerTurnTimes(workbenchID, since)
		if err != nil {
			return nil, fmt.Errorf("watchman activity: %w", err)
		}
		out = append(out, turns...)
	}
	commits, err := ownerCommitTimes(ctx, d, workbenchID, since, git)
	if err != nil {
		return nil, err
	}
	return append(out, commits...), nil
}

// ownerCommitTimes is the author times of the owner's commits since since:
// commits by the folder's configured user.email (all authors when none is
// set) without an agent trailer. A folder that is not a git repository has
// none.
func ownerCommitTimes(ctx context.Context, d *db.DB, workbenchID int64, since time.Time, git GitRunner) ([]time.Time, error) {
	wb, err := d.GetWorkbench(workbenchID)
	if err != nil {
		return nil, fmt.Errorf("watchman activity: %w", err)
	}
	if wb.FolderPath == "" {
		return nil, nil
	}
	if out, err := git(ctx, wb.FolderPath, "rev-parse", "--is-inside-work-tree"); err != nil || strings.TrimSpace(string(out)) != "true" {
		if cerr := ctx.Err(); cerr != nil {
			return nil, cerr
		}
		return nil, nil // not a git repository
	}
	commits, err := gitSource{git: git}.commits(ctx, wb.FolderPath, "--since="+since.UTC().Format(time.RFC3339))
	if err != nil {
		return nil, fmt.Errorf("watchman activity: %w", err)
	}
	owner := gitOwnerEmail(ctx, git, wb.FolderPath)
	var out []time.Time
	for _, c := range commits {
		if c.byOwner(owner) && !c.at.Before(since) {
			out = append(out, c.at)
		}
	}
	return out, nil
}

// UpdateSleepWindow relearns the workbench's sleep window from the last 28
// days of the owner's activity into the sleep_window profile row ("" when
// there are too few days); a pinned row is left as it is. saved reports a
// write.
func UpdateSleepWindow(ctx context.Context, d *db.DB, agentLog *sql.DB, workbenchID int64, now time.Time, loc *time.Location) (saved bool, err error) {
	acts, err := ActivityTimes(ctx, d, agentLog, workbenchID, now.AddDate(0, 0, -sleepLookbackDays-1))
	if err != nil {
		return false, err
	}
	text := ""
	if start, end, ok := SleepWindow(acts, now, loc); ok {
		text = FormatSleepWindow(start, end)
	}
	return d.SaveLearnedWatchmanProfile(workbenchID, SleepWindowKey, text, now)
}
