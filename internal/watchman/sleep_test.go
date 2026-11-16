package watchman

import (
	"context"
	"os/exec"
	"sort"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"
)

// ownerDay is a day of synthetic activity on the local wall clock: every
// half hour from back (that morning) to 20:00, then lateEvening, then bedtime
// after midnight (minutes past 00:00 of the next day).
func ownerDay(loc *time.Location, y int, m time.Month, d, backH, backM, bedMinutes int) []time.Time {
	var out []time.Time
	out = append(out, time.Date(y, m, d, backH, backM, 0, 0, loc))
	for h := backH + 1; h <= 23; h++ {
		out = append(out, time.Date(y, m, d, h, 0, 0, 0, loc))
	}
	out = append(out, time.Date(y, m, d+1, 0, bedMinutes, 0, 0, loc))
	return out
}

func TestSleepWindow_MedianOfLongestNightGap(t *testing.T) {
	loc := time.UTC
	now := time.Date(2026, 11, 16, 15, 0, 0, 0, loc)
	var acts []time.Time
	for i := 1; i <= 28; i++ {
		day := now.AddDate(0, 0, -i)
		bed, backH, backM := 30, 7, 45
		switch i {
		case 3: // a late night and a late morning: outliers the median ignores
			bed, backH, backM = 59, 10, 0
		case 9:
			bed, backH, backM = 5, 6, 30
		}
		acts = append(acts, ownerDay(loc, day.Year(), day.Month(), day.Day(), backH, backM, bed)...)
	}
	start, end, ok := SleepWindow(acts, now, loc)
	require.True(t, ok)
	assert.Equal(t, "00:30-07:45", FormatSleepWindow(start, end))
	assert.Equal(t, 30*time.Minute, start)
	assert.Equal(t, 7*time.Hour+45*time.Minute, end)
}

func TestSleepWindow_TooFewDays(t *testing.T) {
	loc := time.UTC
	now := time.Date(2026, 11, 16, 15, 0, 0, 0, loc)
	var acts []time.Time
	for i := 1; i <= 6; i++ {
		day := now.AddDate(0, 0, -i)
		acts = append(acts, time.Date(day.Year(), day.Month(), day.Day(), 10, 0, 0, 0, loc))
	}
	// Activity older than 28 days does not count.
	acts = append(acts, now.AddDate(0, 0, -40), now.AddDate(0, 0, -35))
	_, _, ok := SleepWindow(acts, now, loc)
	assert.False(t, ok, "6 active days in the last 28: no window")

	acts = append(acts, now.AddDate(0, 0, -7))
	_, _, ok = SleepWindow(acts, now, loc)
	assert.True(t, ok, "7 active days give a window")
}

// The last Sunday of October 2026 in Berlin is the 25th: 03:00 CEST becomes
// 02:00 CET. The night of the 24th has an extra hour; on the wall clock the
// owner still went to bed at 00:30 and came back at 07:45.
func TestSleepWindow_DSTWeek(t *testing.T) {
	loc, err := time.LoadLocation("Europe/Berlin")
	require.NoError(t, err)
	now := time.Date(2026, 10, 29, 15, 0, 0, 0, loc)
	var acts []time.Time
	for d := 21; d <= 28; d++ {
		acts = append(acts, ownerDay(loc, 2026, time.October, d, 7, 45, 30)...)
	}
	// The DST night alone, read through the night's wall clock.
	lo, hi := nightBounds(time.Date(2026, 10, 24, 0, 0, 0, 0, loc), loc)
	assert.Equal(t, 17*time.Hour, hi.Sub(lo), "the DST night is an hour longer")
	s, e, has := nightGap(acts, lo, hi)
	require.True(t, has)
	assert.Equal(t, 30*time.Minute, fromNightMinutes(nightMinutes(s)))
	assert.Equal(t, 7*time.Hour+45*time.Minute, fromNightMinutes(nightMinutes(e)))

	// Only the nights after the change (from the 25th on) plus the DST night:
	// a window that measured elapsed time from midnight would end at 06:45.
	var after []time.Time
	for _, a := range acts {
		if !a.Before(lo) {
			after = append(after, a)
		}
	}
	// Pad with afternoon activity (outside any night) to reach 7 active days.
	for d := 18; d <= 23; d++ {
		after = append(after, time.Date(2026, 10, d, 15, 0, 0, 0, loc))
	}
	start, end, ok := SleepWindow(after, now, loc)
	require.True(t, ok)
	assert.Equal(t, "00:30-07:45", FormatSleepWindow(start, end))
}

func TestSleepWindow_ParseAndFormat(t *testing.T) {
	s, e, err := ParseSleepWindow("23:15-07:05")
	require.NoError(t, err)
	assert.Equal(t, "23:15-07:05", FormatSleepWindow(s, e))
	for _, bad := range []string{"", "7:00-08:00", "24:00-07:00", "23:00 07:00", "23:60-07:00"} {
		_, _, err := ParseSleepWindow(bad)
		assert.Error(t, err, bad)
	}
}

func TestActivityTimes_AllSources(t *testing.T) {
	d := openWatchmanDB(t)
	repo := newTestRepo(t)
	repo.git(gitT0, "config", "user.email", "owner@example.com")
	wb := addWorkbench(t, d, repo.dir)
	t0 := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	since := t0.Add(-24 * time.Hour)

	// Ask answers: one in range, one older.
	_, err := d.Exec(`INSERT INTO owner_asks (project_id, kind, title, status, answer, answered_at) VALUES
		(?, 'question', 'a', 'answered', '{}', '2026-11-10T09:00:00Z'),
		(?, 'question', 'b', 'answered', '{}', '2026-11-01T09:00:00Z')`, wb, wb)
	require.NoError(t, err)
	// A review comment of the owner and a carried copy.
	res, err := d.Exec(`INSERT INTO review_rounds (project_id, folder_root, base_sha, base_label, tree_sha, status)
		VALUES (?, '/tmp/acme', 'b0', 'main', 't0', 'sent')`, wb)
	require.NoError(t, err)
	round, _ := res.LastInsertId()
	res, err = d.Exec(`INSERT INTO review_comments (round_id, body, status, created_at) VALUES (?, 'x', 'sent', '2026-11-10T10:00:00Z')`, round)
	require.NoError(t, err)
	orig, _ := res.LastInsertId()
	_, err = d.Exec(`INSERT INTO review_comments (round_id, body, status, carried_from, created_at) VALUES (?, 'x', 'carried', ?, '2026-11-10T11:00:00Z')`, round, orig)
	require.NoError(t, err)

	// Commits: the owner's, an agent's, a colleague's.
	repo.commit(t0.Add(3*time.Hour+15*time.Minute), "owner work", "a.go")
	repo.commit(t0.Add(4*time.Hour), "agent work"+claudeTrailer, "b.go")
	cmd := exec.Command("git", "-C", repo.dir, "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty",
		"--author=Colleague <colleague@example.com>", "-m", "colleague work")
	cmd.Env = append(cmd.Environ(), "GIT_AUTHOR_DATE="+t0.Add(5*time.Hour).Format(time.RFC3339),
		"GIT_COMMITTER_DATE="+t0.Add(5*time.Hour).Format(time.RFC3339), "GIT_COMMITTER_NAME=Owner", "GIT_COMMITTER_EMAIL=owner@example.com")
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, string(out))

	// Owner turns in agentlog.db: an owner turn, a hook turn, another workbench's.
	al, err := agentlogdb.Open(t.TempDir() + "/agentlog.db")
	require.NoError(t, err)
	t.Cleanup(func() { _ = al.Close() })
	_, err = al.Exec(`INSERT INTO agent_log_sessions (session_uuid, agent, project_id, folder_path, home_cwd, source_path, started_at, ended_at)
		VALUES ('s1', 'claude', ?, '/tmp/acme', '/tmp/acme', 's1.jsonl', '', ''), ('s2', 'claude', ?, '/tmp/acme', '/tmp/acme', 's2.jsonl', '', '')`, wb, wb+1)
	require.NoError(t, err)
	_, err = al.Exec(`INSERT INTO agent_log_events (session_uuid, key, kind, ts, trigger, src_path, src_offset) VALUES
		('s1', 'k1', 'owner_turn', '2026-11-10T12:00:00.500Z', 'owner', 's1.jsonl', 0),
		('s1', 'k2', 'owner_turn', '2026-11-10T12:30:00Z', 'hook', 's1.jsonl', 1),
		('s2', 'k3', 'owner_turn', '2026-11-10T13:00:00Z', 'owner', 's2.jsonl', 0)`)
	require.NoError(t, err)

	acts, err := ActivityTimes(context.Background(), d, al.DB, wb, since)
	require.NoError(t, err)
	assert.Equal(t, []string{"09:00", "10:00", "12:00", "12:15"}, hhmm(acts),
		"ask answer, own review comment, owner turn, own commit")

	// Without agentlog.db the turns are left out.
	acts, err = ActivityTimes(context.Background(), d, nil, wb, since)
	require.NoError(t, err)
	assert.Len(t, acts, 3)
}

func hhmm(ts []time.Time) []string {
	var out []string
	for _, t := range ts {
		out = append(out, t.UTC().Format("15:04"))
	}
	sort.Strings(out)
	return out
}

func TestUpdateSleepWindow_PinnedKept(t *testing.T) {
	d := openWatchmanDB(t)
	wb := addWorkbench(t, d, t.TempDir())
	now := time.Date(2026, 11, 16, 15, 0, 0, 0, time.UTC)

	saved, err := UpdateSleepWindow(context.Background(), d, nil, wb, now, time.UTC)
	require.NoError(t, err)
	assert.True(t, saved)
	assert.Equal(t, "", profileText(t, d, wb, SleepWindowKey), "no activity: no window")

	require.NoError(t, d.PinWatchmanProfile(wb, SleepWindowKey, "23:00-07:00", now))
	saved, err = UpdateSleepWindow(context.Background(), d, nil, wb, now, time.UTC)
	require.NoError(t, err)
	assert.False(t, saved)
	assert.Equal(t, "23:00-07:00", profileText(t, d, wb, SleepWindowKey))
}

func profileText(t *testing.T, d *db.DB, wb int64, key string) string {
	t.Helper()
	ps, err := d.WatchmanProfiles(wb)
	require.NoError(t, err)
	for _, p := range ps {
		if p.Key == key {
			return p.Text
		}
	}
	t.Fatalf("no profile row %q", key)
	return ""
}
