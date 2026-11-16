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
	"watchtower/internal/sessionfeed"
)

// turnTextLimit caps a turn's situation and words (runes, ≤ 2 KB of text).
const turnTextLimit = 2048

// TurnSource reads the owner's own messages in the workbench's agent
// sessions: each owner entry of a session feed is a precedent whose
// situation is the agent text just before it. Ask answers and Watchtower
// lines are other feed kinds and never count. The category is left "" for
// the runner's labeller.
func TurnSource(read instructions.FeedReader) Source { return turnSource{read: read} }

type turnSource struct{ read instructions.FeedReader }

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
// newest first. The cursor is "<hi sid>:<hi idx>|<lo sid>:<lo idx>".
func (s turnSource) Next(ctx context.Context, d *db.DB, workbenchID int64, cursor string, limit int) ([]db.WatchmanPrecedent, string, bool, error) {
	hi, lo, has, err := parseTurnCursor(cursor)
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
		if rs.WorkbenchID == workbenchID {
			sessions = append(sessions, rs)
		}
	}
	sort.Slice(sessions, func(i, j int) bool { return sessions[i].ID < sessions[j].ID })

	cache := map[int64][]turnItem{}
	itemsOf := func(rs db.RecentWorkbenchSession) []turnItem {
		if items, ok := cache[rs.ID]; ok {
			return items
		}
		items := s.turnsOf(rs)
		cache[rs.ID] = items
		return items
	}
	var out []db.WatchmanPrecedent
	next := func() string { return fmt.Sprintf("%d:%d|%d:%d", hi.sid, hi.idx, lo.sid, lo.idx) }

	if has {
		for _, rs := range sessions {
			if rs.ID < hi.sid {
				continue
			}
			if err := ctx.Err(); err != nil {
				return nil, "", false, err
			}
			for _, it := range itemsOf(rs) {
				if !hi.less(it.pos) {
					continue
				}
				out, hi = append(out, it.p), it.pos
				if len(out) == limit {
					return out, next(), false, nil
				}
			}
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
		items := itemsOf(rs)
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
	return out, next(), true, nil
}

// turnsOf reads one session's feed. A session whose transcript cannot be
// read (moved, never written) has no turns; the reason is not logged, it
// may name a file.
func (s turnSource) turnsOf(rs db.RecentWorkbenchSession) []turnItem {
	entries, err := s.read(rs)
	if err != nil {
		log.Printf("watchman: turns: skipping session %d: unreadable feed", rs.ID)
		return nil
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
			agentText = e.Text
			continue
		}
		words := strings.TrimSpace(e.Text)
		if e.Kind != sessionfeed.KindOwner || words == "" {
			continue // ask answers, Watchtower lines, briefs, markers
		}
		key := e.ID
		if key == "" {
			key = "#" + strconv.Itoa(i)
		}
		items = append(items, turnItem{pos: turnPos{sid: rs.ID, idx: i}, p: db.WatchmanPrecedent{
			WorkbenchID: rs.WorkbenchID,
			Source:      "turn",
			SourceKey:   strconv.FormatInt(rs.ID, 10) + ":" + key,
			Situation:   Clip(Redact(strings.TrimSpace(agentText)), turnTextLimit),
			OwnerWords:  Clip(Redact(words), turnTextLimit),
			DecidedAt:   e.At,
			Weight:      1,
		}})
	}
	return items
}

func parseTurnCursor(c string) (hi, lo turnPos, has bool, err error) {
	if c == "" {
		return hi, lo, false, nil
	}
	h, l, ok := strings.Cut(c, "|")
	if !ok {
		return hi, lo, false, fmt.Errorf("watchman turn cursor %q: no lo mark", c)
	}
	if hi, err = parseTurnPos(h); err != nil {
		return hi, lo, false, fmt.Errorf("watchman turn cursor %q: %w", c, err)
	}
	if lo, err = parseTurnPos(l); err != nil {
		return hi, lo, false, fmt.Errorf("watchman turn cursor %q: %w", c, err)
	}
	return hi, lo, true, nil
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
