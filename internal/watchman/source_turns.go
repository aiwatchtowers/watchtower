package watchman

import (
	"context"
	"fmt"
	"log"
	"sort"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/instructions"
	"watchtower/internal/logredact"
	"watchtower/internal/sessionfeed"
)

const (
	// turnTextLimit caps a turn's situation and words (runes).
	turnTextLimit = 2048
	// turnReadGrace is how long after its last activity a session whose feed
	// cannot be read still stops the newer pass (it may be live and the read
	// error passing); after it the session is skipped.
	turnReadGrace = 24 * time.Hour
	// turnBackfillDone is the lo mark once the backfill has nothing older.
	turnBackfillDone = "end"
)

// TurnSource reads the owner's own messages in the workbench's agent
// sessions: each owner entry of a session feed is a precedent whose
// situation is the agent text just before it. Ask answers and Watchtower
// lines are other feed kinds and never count. App-typed start prompts are
// removed (instructions.StripAppStartPrompts); a message with nothing else,
// one holding a fenced block (a paste), and an owner line with no agent text
// before it are skipped. The words are the owner's text, redacted and
// clipped. The category is left "" for the runner's labeller. Sessions an
// automation started are left out (as the asks source leaves out their
// asks): the owner did not start them.
func TurnSource(read instructions.FeedReader) Source {
	return turnSource{read: read, now: time.Now}
}

type turnSource struct {
	read instructions.FeedReader
	now  func() time.Time
}

func (turnSource) Name() string { return "turn" }

// turnPos addresses an owner entry: session id, then entry index in its feed.
type turnPos struct {
	sid int64
	idx int
}

func (a turnPos) less(b turnPos) bool {
	return a.sid < b.sid || a.sid == b.sid && a.idx < b.idx
}

type turnItem struct {
	pos turnPos
	p   db.WatchmanPrecedent
}

// Next returns owner turns newer than the cursor's hi mark first (oldest of
// them first, so hi moves without gaps), then older than its lo mark,
// newest first. The cursor is "<hi sid>:<hi idx>|<lo sid>:<lo idx>"; the lo
// mark is "end" (turnBackfillDone) once the backfill has drained, so a done
// source reads only the sessions at or after hi — and the older sessions it
// tracks: a third part "|<sid>:<idx>,…" marks, per session below hi still
// active within turnReadGrace, the last turn read, so a new owner turn in an
// older session that is still running is read too (a session idle past the
// grace leaves the list once read to its end).
func (s turnSource) Next(ctx context.Context, d *db.DB, workbenchID int64, cursor string, limit int) ([]db.WatchmanPrecedent, string, bool, error) {
	hi, lo, loDone, has, marks, err := parseTurnCursor(cursor)
	if err != nil {
		return nil, "", false, err
	}
	if limit <= 0 {
		return nil, cursor, false, nil
	}
	all, err := d.ListWorkbenchTerminalSessionsSince(time.Time{})
	if err != nil {
		return nil, "", false, fmt.Errorf("watchman turns of workbench %d: %w", workbenchID, err)
	}
	var sessions []db.RecentWorkbenchSession // ascending id
	for _, rs := range all {
		if rs.WorkbenchID == workbenchID && !rs.ByAutomation {
			sessions = append(sessions, rs)
		}
	}
	sort.Slice(sessions, func(i, j int) bool { return sessions[i].ID < sessions[j].ID })
	recent := func(rs db.RecentWorkbenchSession) bool { return s.now().Sub(rs.LastActiveAt) < turnReadGrace }

	type feedResult struct {
		items []turnItem
		err   error
	}
	cache := map[int64]feedResult{}
	itemsOf := func(rs db.RecentWorkbenchSession) ([]turnItem, error) {
		r, ok := cache[rs.ID]
		if !ok {
			r.items, r.err = s.turnsOf(rs)
			cache[rs.ID] = r
		}
		return r.items, r.err
	}
	var out []db.WatchmanPrecedent
	next := func() string {
		c := fmt.Sprintf("%d:%d|%d:%d", hi.sid, hi.idx, lo.sid, lo.idx)
		if loDone {
			c = fmt.Sprintf("%d:%d|%s", hi.sid, hi.idx, turnBackfillDone)
		}
		return c + formatTurnMarks(marks, hi.sid)
	}

	if has {
		listed := map[int64]db.RecentWorkbenchSession{}
		for _, rs := range sessions {
			listed[rs.ID] = rs
			from, tracked := marks[rs.ID]
			switch {
			case rs.ID == hi.sid:
				from = hi.idx
			case rs.ID > hi.sid:
				from = -1
			case !tracked:
				continue
			}
			if err := ctx.Err(); err != nil {
				return nil, "", false, err
			}
			items, err := itemsOf(rs)
			if err != nil {
				// A session that may still be live can hold turns newer than
				// its mark: stop rather than move past them. A session idle
				// past the grace is skipped so it cannot stall the source.
				if recent(rs) {
					return nil, "", false, err
				}
				log.Printf("watchman: turns: skipping session %d: %v", rs.ID, err)
				delete(marks, rs.ID)
				continue
			}
			for _, it := range items {
				if it.pos.idx <= from {
					continue
				}
				out = append(out, it.p)
				switch {
				case rs.ID < hi.sid:
					marks[rs.ID] = it.pos.idx
				default:
					if rs.ID > hi.sid {
						marks[hi.sid] = hi.idx // the session hi leaves keeps its own mark
					}
					hi = it.pos
				}
				if len(out) == limit {
					return out, next(), false, nil
				}
			}
		}
		// Read to the end: an older session idle past the grace, or gone,
		// leaves the list.
		for sid := range marks {
			if rs, ok := listed[sid]; !ok || !recent(rs) {
				delete(marks, sid)
			}
		}
		if loDone {
			return out, next(), true, nil
		}
	}
	for i := len(sessions) - 1; i >= 0; i-- {
		rs := sessions[i]
		if has && rs.ID > lo.sid {
			continue
		}
		if err := ctx.Err(); err != nil {
			return nil, "", false, err
		}
		items, err := itemsOf(rs)
		if err != nil {
			// An older transcript that cannot be read is skipped so the
			// backfill does not stall on it.
			log.Printf("watchman: turns: skipping session %d: %v", rs.ID, err)
			continue
		}
		if _, tracked := marks[rs.ID]; has && rs.ID < hi.sid && !tracked && recent(rs) {
			// Still running: its later turns come after what is read here.
			marks[rs.ID] = -1
			if len(items) > 0 {
				marks[rs.ID] = items[len(items)-1].pos.idx
			}
		}
		for j := len(items) - 1; j >= 0; j-- {
			it := items[j]
			if has && !it.pos.less(lo) {
				continue
			}
			if !has {
				hi, has = it.pos, true
			}
			out, lo = append(out, it.p), it.pos
			if len(out) == limit {
				return out, next(), false, nil
			}
		}
	}
	if !has {
		return out, "", true, nil
	}
	loDone = true
	return out, next(), true, nil
}

// formatTurnMarks is the cursor's third part for the tracked sessions below
// hi ("" when none), in id order.
func formatTurnMarks(marks map[int64]int, hiSID int64) string {
	var sids []int64
	for sid := range marks {
		if sid < hiSID {
			sids = append(sids, sid)
		}
	}
	if len(sids) == 0 {
		return ""
	}
	sort.Slice(sids, func(i, j int) bool { return sids[i] < sids[j] })
	parts := make([]string, len(sids))
	for i, sid := range sids {
		parts[i] = fmt.Sprintf("%d:%d", sid, marks[sid])
	}
	return "|" + strings.Join(parts, ",")
}

// turnsOf reads one session's owner turns. A missing transcript reads as
// no entries (sessionfeed); any other read error is returned with its text
// as a fingerprint only (it may name a transcript file, FILES-01).
func (s turnSource) turnsOf(rs db.RecentWorkbenchSession) ([]turnItem, error) {
	entries, err := s.read(rs)
	if err != nil {
		return nil, logredact.Errorf("watchman turns of session %d: %s", rs.ID, logredact.Text(err.Error()))
	}
	var items []turnItem
	agentText, conv := "", ""
	for i, e := range entries {
		if e.Conversation != conv {
			agentText, conv = "", e.Conversation
		}
		if e.Kind == sessionfeed.KindSeparator {
			agentText = ""
			continue
		}
		if e.Kind == sessionfeed.KindAgent {
			agentText = strings.TrimSpace(e.Text)
			continue
		}
		if e.Kind != sessionfeed.KindOwner || agentText == "" {
			continue // ask answers, Watchtower lines, briefs, markers; an owner line with no agent text before it answers nothing
		}
		// App-typed start prompts and pasted blocks are not the owner's words.
		words := instructions.StripAppStartPrompts(e.Text)
		if words == "" || strings.Contains(words, "```") {
			continue
		}
		key := e.ID
		if key == "" {
			key = "#" + strconv.Itoa(i)
		}
		items = append(items, turnItem{pos: turnPos{sid: rs.ID, idx: i}, p: db.WatchmanPrecedent{
			WorkbenchID: rs.WorkbenchID,
			Source:      "turn",
			SourceKey:   strconv.FormatInt(rs.ID, 10) + ":" + key,
			Situation:   Clip(Redact(agentText), turnTextLimit),
			OwnerWords:  Clip(Redact(words), turnTextLimit),
			DecidedAt:   e.At,
			Weight:      1,
		}})
	}
	return items, nil
}

func parseTurnCursor(c string) (hi, lo turnPos, loDone, has bool, marks map[int64]int, err error) {
	marks = map[int64]int{}
	if c == "" {
		return hi, lo, false, false, marks, nil
	}
	parts := strings.Split(c, "|")
	if len(parts) < 2 || len(parts) > 3 {
		return hi, lo, false, false, nil, fmt.Errorf("watchman turn cursor %q: want <hi>|<lo>[|<marks>]", c)
	}
	if hi, err = parseTurnPos(parts[0]); err != nil {
		return hi, lo, false, false, nil, fmt.Errorf("watchman turn cursor %q: %w", c, err)
	}
	if len(parts) == 3 {
		for _, m := range strings.Split(parts[2], ",") {
			pos, err := parseTurnPos(m)
			if err != nil {
				return hi, lo, false, false, nil, fmt.Errorf("watchman turn cursor %q: %w", c, err)
			}
			marks[pos.sid] = pos.idx
		}
	}
	if parts[1] == turnBackfillDone {
		return hi, lo, true, true, marks, nil
	}
	if lo, err = parseTurnPos(parts[1]); err != nil {
		return hi, lo, false, false, nil, fmt.Errorf("watchman turn cursor %q: %w", c, err)
	}
	return hi, lo, false, true, marks, nil
}

func parseTurnPos(s string) (turnPos, error) {
	a, b, ok := strings.Cut(s, ":")
	if !ok {
		return turnPos{}, fmt.Errorf("mark %q is not <session>:<index>", s)
	}
	sid, err := strconv.ParseInt(a, 10, 64)
	if err != nil {
		return turnPos{}, fmt.Errorf("mark %q: %w", s, err)
	}
	idx, err := strconv.Atoi(b)
	if err != nil {
		return turnPos{}, fmt.Errorf("mark %q: %w", s, err)
	}
	return turnPos{sid: sid, idx: idx}, nil
}
