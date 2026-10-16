package agentreport

import (
	"cmp"
	"slices"
	"time"

	"watchtower/internal/db"
)

// tsLayout is the stored event ts layout: UTC, RFC 3339, milliseconds.
const tsLayout = "2006-01-02T15:04:05.000Z"

type timedEvent struct {
	db.AgentReportEvent
	at time.Time
}

// sortEvents keeps the events keep accepts, parses their ts (an unparseable
// one is dropped) and orders them by (ts, src_path, src_offset).
func sortEvents(events []db.AgentReportEvent, keep func(db.AgentReportEvent) bool) []timedEvent {
	var out []timedEvent
	for _, e := range events {
		if !keep(e) {
			continue
		}
		at, err := time.Parse(time.RFC3339Nano, e.TS)
		if err != nil {
			continue
		}
		out = append(out, timedEvent{e, at.UTC().Truncate(time.Millisecond)})
	}
	slices.SortStableFunc(out, func(a, b timedEvent) int {
		return cmp.Or(a.at.Compare(b.at), cmp.Compare(a.SrcPath, b.SrcPath), cmp.Compare(a.SrcOffset, b.SrcOffset))
	})
	return out
}

type span struct{ start, end time.Time }

// piece is one stretch of a lane; src tells tool calls apart (-1 = no tool).
type piece struct {
	start, end       time.Time
	cat, class, verb string
	src              int
}

type toolInterval struct {
	start, end  time.Time
	class, verb string
	idx         int
}

// walk splits [first, last event] of one lane into pieces. A gap goes to the
// earliest-started open tool call while one is open; otherwise, with waits on,
// a gap of a wait (see waitStarts) is background where a background span
// covers it, else owner up to AwayAfter per wait, then away; anything else is
// model.
func walk(evs []timedEvent, bg []span, waits bool) []piece {
	var out []piece
	emit := func(p piece) {
		if !p.end.After(p.start) {
			return
		}
		if n := len(out); n > 0 {
			l := &out[n-1]
			if l.end.Equal(p.start) && l.cat == p.cat && l.class == p.class && l.verb == p.verb && l.src == p.src {
				l.end = p.end
				return
			}
		}
		out = append(out, p)
	}
	var active []toolInterval
	var starts []int
	if waits {
		starts = waitStarts(evs)
	}
	wait := -1 // the wait whose owner time ownerUsed counts
	var ownerUsed time.Duration
	for i := 0; i+1 < len(evs); i++ {
		if e := evs[i]; e.Kind == "tool" {
			active = append(active, toolInterval{start: e.at, end: toolEnd(evs, i), class: eventClass(e.AgentReportEvent), verb: verb(e.AgentReportEvent), idx: i})
		}
		a, b := evs[i].at, evs[i+1].at
		active = slices.DeleteFunc(active, func(t toolInterval) bool { return !t.end.After(a) })
		if !b.After(a) {
			continue
		}
		cuts := []time.Time{a, b}
		for _, t := range active {
			if t.end.Before(b) {
				cuts = append(cuts, t.end)
			}
		}
		slices.SortFunc(cuts, func(x, y time.Time) int { return x.Compare(y) })
		cuts = slices.CompactFunc(cuts, func(x, y time.Time) bool { return x.Equal(y) })
		isWait := waits && starts[i] >= 0
		if isWait && starts[i] != wait {
			wait, ownerUsed = starts[i], 0
		}
		for k := 0; k+1 < len(cuts); k++ {
			p, q := cuts[k], cuts[k+1]
			if t, ok := earliestOpen(active, p); ok {
				emit(piece{start: p, end: q, cat: CatTool, class: t.class, verb: t.verb, src: t.idx})
				continue
			}
			if !isWait {
				emit(piece{start: p, end: q, cat: CatModel, src: -1})
				continue
			}
			for _, w := range cutBySpans(p, q, bg) {
				if w.cat == CatBackground {
					emit(w)
					continue
				}
				left := AwayAfter - ownerUsed
				mid := w.end
				if d := w.end.Sub(w.start); d > left {
					mid = w.start.Add(max(left, 0))
				}
				ownerUsed += mid.Sub(w.start)
				emit(piece{start: w.start, end: mid, cat: CatOwner, src: -1})
				emit(piece{start: mid, end: w.end, cat: CatAway, src: -1})
			}
		}
	}
	return out
}

// toolEnd is when the tool call at i closes: ts + duration, or, while it is
// pending, the next event of the lane with a later ts (itself when none, or
// when the owner's turn comes next).
func toolEnd(evs []timedEvent, i int) time.Time {
	e := evs[i]
	if e.DurationMS != nil {
		return e.at.Add(time.Duration(max(*e.DurationMS, 0)) * time.Millisecond)
	}
	if j := nextLater(evs, i); j >= 0 && evs[j].Kind == "owner_turn" {
		return e.at // the owner answered: the gap is a wait, not tool time
	}
	for j := i + 1; j < len(evs); j++ {
		if evs[j].at.After(e.at) {
			return evs[j].at
		}
	}
	return e.at
}

// nextLater is the index of the first event after i with a later ts that is
// not see-through, or -1.
func nextLater(evs []timedEvent, i int) int {
	for j := i + 1; j < len(evs); j++ {
		if evs[j].at.After(evs[i].at) && !seeThrough(evs[j].Kind) {
			return j
		}
	}
	return -1
}

// seeThrough events neither start nor end a wait; time across them keeps
// the wait's category.
func seeThrough(kind string) bool {
	return kind == "compaction" || kind == "pr_link" || kind == "skill"
}

// waitStarts maps each gap start i to the index of the turn-ending event of
// the wait the gap [i, i+1) belongs to, or -1. A turn ends on an api_call, an
// api_error or a pending tool the owner answered; the wait runs from there,
// across see-through events only, to the next owner_turn.
func waitStarts(evs []timedEvent) []int {
	out := make([]int, len(evs))
	last := -1 // last non-see-through event at or before i
	for i := range evs {
		out[i] = -1
		if !seeThrough(evs[i].Kind) {
			last = i
		}
		if last < 0 || !turnEnds(evs, last) {
			continue
		}
		j := i + 1
		for j < len(evs) && seeThrough(evs[j].Kind) {
			j++
		}
		if j < len(evs) && evs[j].Kind == "owner_turn" {
			out[i] = last
		}
	}
	return out
}

func turnEnds(evs []timedEvent, i int) bool {
	switch e := evs[i]; e.Kind {
	case "api_call", "api_error":
		return true
	case "tool":
		if e.DurationMS != nil {
			return false
		}
		j := nextLater(evs, i)
		return j >= 0 && evs[j].Kind == "owner_turn"
	}
	return false
}

func earliestOpen(active []toolInterval, at time.Time) (toolInterval, bool) {
	for _, t := range active { // in start order
		if t.end.After(at) {
			return t, true
		}
	}
	return toolInterval{}, false
}

// cutBySpans splits [p, q) into background pieces (covered by a span) and
// uncovered pieces (cat "").
func cutBySpans(p, q time.Time, bg []span) []piece {
	cuts := []time.Time{p, q}
	for _, s := range bg {
		for _, c := range []time.Time{s.start, s.end} {
			if c.After(p) && c.Before(q) {
				cuts = append(cuts, c)
			}
		}
	}
	slices.SortFunc(cuts, func(x, y time.Time) int { return x.Compare(y) })
	cuts = slices.CompactFunc(cuts, func(x, y time.Time) bool { return x.Equal(y) })
	var out []piece
	for k := 0; k+1 < len(cuts); k++ {
		w := piece{start: cuts[k], end: cuts[k+1], src: -1}
		for _, s := range bg {
			if !s.start.After(w.start) && s.end.After(w.start) {
				w.cat = CatBackground
				break
			}
		}
		out = append(out, w)
	}
	return out
}

func segments(pieces []piece) []Segment {
	out := make([]Segment, 0, len(pieces))
	for _, p := range pieces {
		out = append(out, Segment{Start: p.start.Format(tsLayout), End: p.end.Format(tsLayout),
			Category: p.cat, ToolClass: p.class, Verb: p.verb})
	}
	return out
}

func isMain(e db.AgentReportEvent) bool { return e.AgentID == "" }

// SessionTime splits one session's wall time (first to last main-agent
// event) into categories and returns the main agent's lane.
func SessionTime(events []db.AgentReportEvent) (TimeSplit, []Segment) {
	evs := sortEvents(events, isMain)
	if len(evs) < 2 {
		return TimeSplit{}, []Segment{}
	}
	var bg []span
	for _, s := range subagentSpans(events) {
		if s.background {
			bg = append(bg, s.span)
		}
	}
	pieces := walk(evs, bg, true)
	var ts TimeSplit
	for _, p := range pieces {
		ms := p.end.Sub(p.start).Milliseconds()
		switch p.cat {
		case CatTool:
			ts.Tools.add(p.class, ms)
		case CatBackground:
			ts.BackgroundMS += ms
		case CatOwner:
			ts.OwnerMS += ms
		case CatAway:
			ts.AwayMS += ms
		default:
			ts.ModelMS += ms
		}
	}
	ts.WallMS = evs[len(evs)-1].at.Sub(evs[0].at).Milliseconds()
	ts.ActiveMS = ts.WallMS - ts.AwayMS
	return ts, segments(pieces)
}

type subagentSpan struct {
	span
	agentID, subagentType string
	background            bool
	events                []timedEvent
}

// subagentSpans returns each subagent's span (first to last ts of its
// agent_id) in start order; background and type come from the Agent/Task call
// that spawned it (none found = foreground).
func subagentSpans(events []db.AgentReportEvent) []subagentSpan {
	spawns := map[string]db.AgentReportEvent{}
	for _, e := range events {
		if e.Kind == "tool" && isAgentTool(e.Name) && e.SpawnedAgentID != "" {
			if _, seen := spawns[e.SpawnedAgentID]; !seen {
				spawns[e.SpawnedAgentID] = e
			}
		}
	}
	by := map[string]*subagentSpan{}
	var out []*subagentSpan
	for _, e := range sortEvents(events, func(e db.AgentReportEvent) bool { return !isMain(e) }) {
		s := by[e.AgentID]
		if s == nil {
			sp := spawns[e.AgentID]
			s = &subagentSpan{span: span{e.at, e.at}, agentID: e.AgentID, subagentType: sp.Target, background: sp.Background}
			by[e.AgentID] = s
			out = append(out, s)
		}
		s.end = e.at
		s.events = append(s.events, e)
	}
	res := make([]subagentSpan, len(out))
	for i, s := range out {
		res[i] = *s
	}
	slices.SortStableFunc(res, func(a, b subagentSpan) int {
		return cmp.Or(a.start.Compare(b.start), cmp.Compare(a.agentID, b.agentID))
	})
	return res
}

// SessionSubagents measures one session's subagent overlap and returns a
// lane per subagent (no waits inside a subagent: its untooled time is model).
func SessionSubagents(events []db.AgentReportEvent) (Subagents, []Lane) {
	spans := subagentSpans(events)
	lanes := make([]Lane, 0, len(spans))
	if len(spans) == 0 {
		return Subagents{}, lanes
	}
	var sa Subagents
	type edge struct {
		at    time.Time
		order int // a span's end before another's start; a zero-length span's own end after its start
		delta int
	}
	var edges []edge
	for _, s := range spans {
		sa.Count++
		if s.background {
			sa.Background++
		} else {
			sa.Foreground++
		}
		sa.BusyMS += s.end.Sub(s.start).Milliseconds()
		endOrder := 0
		if s.end.Equal(s.start) {
			endOrder = 2
		}
		edges = append(edges, edge{s.start, 1, 1}, edge{s.end, endOrder, -1})
		lanes = append(lanes, Lane{AgentID: s.agentID, SubagentType: s.subagentType, Background: s.background,
			Segments: segments(walk(s.events, nil, false))})
	}
	slices.SortStableFunc(edges, func(a, b edge) int { return cmp.Or(a.at.Compare(b.at), cmp.Compare(a.order, b.order)) })
	open := 0
	for _, e := range edges {
		open += e.delta
		sa.Peak = max(sa.Peak, open)
	}
	var cur span // spans are in start order
	for i, s := range spans {
		switch {
		case i == 0:
			cur = s.span
		case s.start.After(cur.end):
			sa.UnionMS += cur.end.Sub(cur.start).Milliseconds()
			cur = s.span
		case s.end.After(cur.end):
			cur.end = s.end
		}
	}
	sa.UnionMS += cur.end.Sub(cur.start).Milliseconds()
	for _, s := range spans {
		if !s.background && !slices.ContainsFunc(spans, func(o subagentSpan) bool {
			return o.agentID != s.agentID && o.start.Before(s.end) && s.start.Before(o.end)
		}) {
			sa.Serial++
		}
	}
	if sa.UnionMS > 0 {
		sa.AvgParallel = float64(sa.BusyMS) / float64(sa.UnionMS)
	}
	split, _ := SessionTime(events)
	sa.BlockedMS = split.Tools.SubagentsFG
	return sa, lanes
}
