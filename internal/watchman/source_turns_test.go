package watchman

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
)

var turnT0 = time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)

func openWatchmanDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	return d
}

func addWorkbench(t *testing.T, d *db.DB, folder string) int64 {
	t.Helper()
	id, err := d.CreateWorkbench("acme", folder)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func addSession(t *testing.T, d *db.DB, wb int64, agentID string) int64 {
	t.Helper()
	id, err := d.CreateTerminalSession(context.Background(), db.NewTerminalSession{
		WorkbenchID: wb, Kind: "claude", Title: "s", FolderPath: t.TempDir(), ClaudeSessionID: agentID,
	})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// fakeFeeds serves feeds by session id; a session in fail fails to read, one
// in neither map has no transcript (no entries, like sessionfeed).
func fakeFeeds(feeds map[int64][]sessionfeed.Entry, fail ...int64) func(db.RecentWorkbenchSession) ([]sessionfeed.Entry, error) {
	return func(s db.RecentWorkbenchSession) ([]sessionfeed.Entry, error) {
		for _, id := range fail {
			if id == s.ID {
				return nil, errors.New("transcript busy")
			}
		}
		return feeds[s.ID], nil
	}
}

func entry(id string, k sessionfeed.Kind, text string, minute int) sessionfeed.Entry {
	return sessionfeed.Entry{ID: id, Kind: k, Text: text, At: turnT0.Add(time.Duration(minute) * time.Minute)}
}

func TestTurnSource_PairsOwnerWithPrecedingAgentText(t *testing.T) {
	d := openWatchmanDB(t)
	wb := addWorkbench(t, d, t.TempDir())
	other := addWorkbench(t, d, t.TempDir())
	s1 := addSession(t, d, wb, "a1")
	s2 := addSession(t, d, wb, "a2")
	sOther := addSession(t, d, other, "a3")
	feeds := map[int64][]sessionfeed.Entry{
		s1: {
			entry("u1", sessionfeed.KindOwner, "start with the parser", 0),
			entry("a1", sessionfeed.KindAgent, "Shall I add a cache? token=abc123secret", 1),
			entry("u2", sessionfeed.KindOwner, "no cache, keep it simple", 2),
		},
		s2: {
			entry("a2", sessionfeed.KindAgent, "Rename the flag to --dry?", 10),
			entry("u3", sessionfeed.KindOwner, "yes", 11),
		},
		sOther: {entry("x", sessionfeed.KindOwner, "other workbench", 20)},
	}
	src := TurnSource(fakeFeeds(feeds))
	if src.Name() != "turn" {
		t.Fatalf("name = %q", src.Name())
	}
	ps, next, done, err := src.Next(context.Background(), d, wb, "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if !done || next == "" {
		t.Fatalf("done=%v next=%q", done, next)
	}
	if len(ps) != 2 { // "start with the parser" answers no agent text
		t.Fatalf("got %d precedents, want 2: %+v", len(ps), ps)
	}
	// newest first
	if ps[0].OwnerWords != "yes" || ps[0].Situation != "Rename the flag to --dry?" {
		t.Errorf("first = %+v", ps[0])
	}
	if ps[1].OwnerWords != "no cache, keep it simple" || ps[1].Situation != "Shall I add a cache? token=[secret]" {
		t.Errorf("second = %+v", ps[1])
	}
	for _, p := range ps {
		if p.Source != "turn" || p.Category != "" || p.WorkbenchID != wb || p.SourceKey == "" || p.DecidedAt.IsZero() {
			t.Errorf("bad precedent %+v", p)
		}
	}
}

func TestTurnSource_SkipsAskAnswersAndWatchtowerLines(t *testing.T) {
	d := openWatchmanDB(t)
	wb := addWorkbench(t, d, t.TempDir())
	s1 := addSession(t, d, wb, "a1")
	feeds := map[int64][]sessionfeed.Entry{s1: {
		entry("a1", sessionfeed.KindAgent, "Which option?", 0),
		{ID: "k1", Kind: sessionfeed.KindAskAnswer, Text: "option B", AskID: 7, At: turnT0},
		{ID: "w1", Kind: sessionfeed.KindWatchtower, Text: "review sent", Via: sessionfeed.ViaReview, At: turnT0},
		{ID: "b1", Kind: sessionfeed.KindBrief, Text: "brief", At: turnT0},
		entry("u0", sessionfeed.KindOwner, "   ", 1),
		entry("u1", sessionfeed.KindOwner, "go on", 2),
	}}
	ps, _, _, err := TurnSource(fakeFeeds(feeds)).Next(context.Background(), d, wb, "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(ps) != 1 || ps[0].OwnerWords != "go on" || ps[0].Situation != "Which option?" {
		t.Fatalf("got %+v", ps)
	}
}

func TestTurnSource_CursorNewestFirst(t *testing.T) {
	d := openWatchmanDB(t)
	wb := addWorkbench(t, d, t.TempDir())
	s1 := addSession(t, d, wb, "a1")
	s2 := addSession(t, d, wb, "a2")
	addSession(t, d, wb, "a3") // no transcript yet: no turns
	ask := func(id string, m int) sessionfeed.Entry { return entry(id, sessionfeed.KindAgent, "next?", m) }
	feeds := map[int64][]sessionfeed.Entry{
		s1: {ask("a1", 0), entry("u1", sessionfeed.KindOwner, "one", 0), entry("u2", sessionfeed.KindOwner, "two", 1)},
		s2: {ask("a2", 2), entry("u3", sessionfeed.KindOwner, "three", 2)},
	}
	src := TurnSource(fakeFeeds(feeds))
	ctx := context.Background()
	words := func(ps []db.WatchmanPrecedent) []string {
		var w []string
		for _, p := range ps {
			w = append(w, p.OwnerWords)
		}
		return w
	}
	ps, c, done, err := src.Next(ctx, d, wb, "", 2)
	if err != nil || done {
		t.Fatalf("err=%v done=%v", err, done)
	}
	if got := words(ps); len(got) != 2 || got[0] != "three" || got[1] != "two" {
		t.Fatalf("page 1 = %v", got)
	}
	// A new owner turn in s2 arrives before the backfill ends: it comes first.
	feeds[s2] = append(feeds[s2], entry("u4", sessionfeed.KindOwner, "four", 3))
	ps, c, done, err = src.Next(ctx, d, wb, c, 2)
	if err != nil || done {
		t.Fatalf("err=%v done=%v", err, done)
	}
	if got := words(ps); len(got) != 2 || got[0] != "four" || got[1] != "one" {
		t.Fatalf("page 2 = %v", got)
	}
	ps, _, done, err = src.Next(ctx, d, wb, c, 2)
	if err != nil || !done || len(ps) != 0 {
		t.Fatalf("page 3: %v done=%v err=%v", words(ps), done, err)
	}
	if _, _, _, err := src.Next(ctx, d, wb, "garbage", 2); err == nil {
		t.Fatal("malformed cursor accepted")
	}
}

func TestTurnSource_SkipsAppStartPrompts(t *testing.T) {
	// A long direction (20 lines, > 500 runes) is kept whole.
	long := strings.TrimSpace(strings.Repeat("keep every exported name stable across the refactor please\n", 20))
	d := openWatchmanDB(t)
	wb := addWorkbench(t, d, t.TempDir())
	s1 := addSession(t, d, wb, "a1")
	feeds := map[int64][]sessionfeed.Entry{s1: {
		entry("a0", sessionfeed.KindAgent, "Ready.", 0),
		entry("u1", sessionfeed.KindOwner, "Work on target #12 using the watchtower-workbench skill.", 1),
		entry("u2", sessionfeed.KindOwner, "Work on group #3 using the watchtower-workbench skill.\nPlan first: put the plan on the board", 2),
		entry("u3", sessionfeed.KindOwner, "Work on target #4 using the watchtower-workbench skill.\nkeep the old flag", 3),
		entry("u4", sessionfeed.KindOwner, "look:\n```\npanic: boom\n```", 4),
		entry("u5", sessionfeed.KindOwner, long, 5),
	}}
	ps, _, _, err := TurnSource(fakeFeeds(feeds)).Next(context.Background(), d, wb, "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(ps) != 2 || ps[0].OwnerWords != long || ps[1].OwnerWords != "keep the old flag" {
		t.Fatalf("got %+v", ps)
	}
}

func setLastActive(t *testing.T, d *db.DB, id int64, at time.Time) {
	t.Helper()
	if _, err := d.Exec(`UPDATE terminal_sessions SET last_active_at = ? WHERE id = ?`, at.UTC().Format(time.RFC3339), id); err != nil {
		t.Fatal(err)
	}
}

func TestTurnSource_PermanentlyUnreadableSessionSkippedAfterGrace(t *testing.T) {
	d := openWatchmanDB(t)
	wb := addWorkbench(t, d, t.TempDir())
	now := turnT0.Add(48 * time.Hour)
	turn := func(id, words string, m int) []sessionfeed.Entry {
		return []sessionfeed.Entry{entry("a"+id, sessionfeed.KindAgent, "ok?", m), entry("u"+id, sessionfeed.KindOwner, words, m+1)}
	}
	s1 := addSession(t, d, wb, "a1")
	s2 := addSession(t, d, wb, "a2")
	s3 := addSession(t, d, wb, "a3") // never readable
	setLastActive(t, d, s3, now.Add(-time.Hour))
	feeds := map[int64][]sessionfeed.Entry{s1: turn("1", "one", 0), s2: turn("2", "two", 2)}
	src := turnSource{read: fakeFeeds(feeds, s3), now: func() time.Time { return now }}
	ctx := context.Background()

	// Backfill skips it.
	ps, c, done, err := src.Next(ctx, d, wb, "", 1)
	if err != nil || done || len(ps) != 1 || ps[0].OwnerWords != "two" {
		t.Fatalf("backfill: %+v done=%v err=%v", ps, done, err)
	}
	// Within the grace the newer pass stops on it.
	if _, _, _, err := src.Next(ctx, d, wb, c, 5); err == nil {
		t.Fatal("newer pass read error within the grace not returned")
	} else if strings.Contains(err.Error(), "transcript busy") {
		t.Errorf("error carries the read error's text: %v", err)
	}
	// After the grace it is skipped: a newer session flows and the backfill
	// goes on.
	now = now.Add(turnReadGrace)
	s4 := addSession(t, d, wb, "a4")
	setLastActive(t, d, s4, now)
	feeds[s4] = turn("4", "four", 10)
	ps, _, done, err = src.Next(ctx, d, wb, c, 5)
	if err != nil || !done || len(ps) != 2 || ps[0].OwnerWords != "four" || ps[1].OwnerWords != "one" {
		t.Fatalf("after grace: %+v done=%v err=%v", ps, done, err)
	}
}
