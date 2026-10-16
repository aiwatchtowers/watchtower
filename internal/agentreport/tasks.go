package agentreport

import (
	"slices"
	"strconv"
	"time"

	"watchtower/internal/db"
)

// TaskRow is one board target's calendar time by status phase and the agent
// time and cost of the sessions that worked on it. A group row sums its
// leaves; Shared marks a stretch split equally with another open target.
type TaskRow struct {
	TargetID   int64            `json:"target_id"`
	Text       string           `json:"text"`
	Status     string           `json:"status"`
	CalendarMS int64            `json:"calendar_ms"`
	Phases     map[string]int64 `json:"phases"` // in_progress, in_review, blocked, todo
	AgentMS    int64            `json:"agent_ms"`
	Time       TimeSplit        `json:"time"`
	CostUSD    float64          `json:"cost_usd"`
	Sessions   []string         `json:"sessions"`
	Shared     bool             `json:"shared"`
}

type window struct{ start, end time.Time }

func (w window) has(t time.Time) bool { return !t.Before(w.start) && t.Before(w.end) }

func parseAt(s string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339Nano, s)
	return t.UTC(), err == nil
}

func closes(status string) bool { return status == "done" || status == "dismissed" }

// phases returns the calendar time and the time per status between the first
// in_progress and the last close (now while the target is open).
func phases(history []db.StatusChange, now time.Time) (int64, map[string]int64) {
	out := map[string]int64{"in_progress": 0, "in_review": 0, "blocked": 0, "todo": 0}
	type step struct {
		to string
		at time.Time
	}
	var steps []step
	for _, h := range history {
		if at, ok := parseAt(h.At); ok {
			steps = append(steps, step{h.To, at})
		}
	}
	first := slices.IndexFunc(steps, func(s step) bool { return s.to == "in_progress" })
	if first < 0 {
		return 0, out
	}
	steps = steps[first:]
	end := now
	if last := steps[len(steps)-1]; closes(last.to) {
		end = last.at
	}
	for i, s := range steps {
		to := end
		if i+1 < len(steps) {
			to = steps[i+1].at
		}
		if _, ok := out[s.to]; ok && to.After(s.at) {
			out[s.to] += to.Sub(s.at).Milliseconds()
		}
	}
	return max(end.Sub(steps[0].at).Milliseconds(), 0), out
}

// windows are the in_progress/in_review stretches of a history, merged.
func windows(history []db.StatusChange, now time.Time) []window {
	var out []window
	for i, h := range history {
		if h.To != "in_progress" && h.To != "in_review" {
			continue
		}
		start, ok := parseAt(h.At)
		if !ok {
			continue
		}
		end := now
		if i+1 < len(history) {
			if e, ok := parseAt(history[i+1].At); ok {
				end = e
			}
		}
		if !end.After(start) {
			continue
		}
		if n := len(out); n > 0 && !start.After(out[n-1].end) {
			out[n-1].end = maxTime(out[n-1].end, end)
			continue
		}
		out = append(out, window{start, end})
	}
	return out
}

func maxTime(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}

// targetID reads the "#<id>" a workbench tool call names.
func targetID(s string) (int64, bool) {
	if len(s) < 2 || s[0] != '#' {
		return 0, false
	}
	id, err := strconv.ParseInt(s[1:], 10, 64)
	return id, err == nil
}

type taskAcc struct {
	time     TimeSplit
	cost     float64
	sessions map[string]bool
	shared   bool
}

func (a *taskAcc) merge(b *taskAcc) {
	a.time.plus(b.time)
	a.cost += b.cost
	a.shared = a.shared || b.shared
	for s := range b.sessions {
		a.sessions[s] = true
	}
}

// Tasks attributes the sessions' main-lane segments and api_call costs to the
// leaf targets they worked on (see the spec's Tasks section): inside the
// target's in_progress/in_review windows, or, with no window holding a call
// that names it, over the session's first-to-last call naming it. Where one
// session has k targets open at once, each gets 1/k of the stretch (integer
// ms, the remainder to the lowest id) and is marked Shared. Rows come by
// target id; a group row sums its leaves and has its own calendar time.
func Tasks(targets []db.AgentReportTarget, sessions map[string][]Segment, events map[string][]db.AgentReportEvent, now time.Time) []TaskRow {
	b := newTaskBoard(targets, now.UTC())
	for _, sid := range sessionIDs(sessions, events) {
		calls, apis := b.scanEvents(sid, events[sid])
		ivs, leaves := b.sessionIntervals(sid, calls)
		if len(leaves) == 0 {
			continue
		}
		b.attributeSession(ivs, leaves, sessions[sid], apis)
	}
	rows := make([]TaskRow, 0, len(targets))
	for _, t := range targets {
		rows = append(rows, b.row(t))
	}
	return rows
}

// taskBoard is the target tree and the per-target accumulators Tasks fills.
type taskBoard struct {
	targets  []db.AgentReportTarget
	now      time.Time
	byID     map[int64]db.AgentReportTarget
	children map[int64][]int64
	accs     map[int64]*taskAcc
	named    map[int64]map[string]bool // sessions that call a tool naming the target
}

func newTaskBoard(targets []db.AgentReportTarget, now time.Time) *taskBoard {
	b := &taskBoard{
		targets: targets, now: now,
		byID: map[int64]db.AgentReportTarget{}, children: map[int64][]int64{},
		accs: map[int64]*taskAcc{}, named: map[int64]map[string]bool{},
	}
	for _, t := range targets {
		b.byID[t.ID] = t
	}
	for _, t := range targets {
		if t.ParentID != nil {
			if _, ok := b.byID[*t.ParentID]; ok {
				b.children[*t.ParentID] = append(b.children[*t.ParentID], t.ID)
			}
		}
		b.accs[t.ID] = &taskAcc{sessions: map[string]bool{}}
		b.named[t.ID] = map[string]bool{}
	}
	return b
}

func (b *taskBoard) isLeaf(id int64) bool { return len(b.children[id]) == 0 }

// sessionIDs are the sessions with segments or events, sorted.
func sessionIDs(sessions map[string][]Segment, events map[string][]db.AgentReportEvent) []string {
	ids := make([]string, 0, len(sessions)+len(events))
	for s := range sessions {
		ids = append(ids, s)
	}
	for s := range events {
		if _, ok := sessions[s]; !ok {
			ids = append(ids, s)
		}
	}
	slices.Sort(ids)
	return ids
}

// scanEvents records which targets the session's tool calls name (and when),
// and returns its api_call events.
func (b *taskBoard) scanEvents(sid string, evs []db.AgentReportEvent) (map[int64][]time.Time, []db.AgentReportEvent) {
	calls := map[int64][]time.Time{}
	var apis []db.AgentReportEvent
	for _, e := range evs {
		switch e.Kind {
		case "tool":
			id, ok := targetID(e.Target)
			if !ok || b.byID[id].ID == 0 {
				continue
			}
			b.named[id][sid] = true
			if at, ok := parseAt(e.TS); ok {
				calls[id] = append(calls[id], at)
			}
		case "api_call":
			apis = append(apis, e)
		}
	}
	return calls, apis
}

// sessionIntervals are the intervals each leaf of this session counts over,
// and those leaves sorted by id.
func (b *taskBoard) sessionIntervals(sid string, calls map[int64][]time.Time) (map[int64][]window, []int64) {
	ivs := map[int64][]window{}
	var leaves []int64
	for _, t := range b.targets {
		cs := calls[t.ID]
		if !b.isLeaf(t.ID) || len(cs) == 0 {
			continue
		}
		ws := windows(t.History, b.now)
		inside := slices.ContainsFunc(cs, func(c time.Time) bool {
			return slices.ContainsFunc(ws, func(w window) bool { return w.has(c) })
		})
		if !inside {
			ws = []window{{slices.MinFunc(cs, time.Time.Compare), slices.MaxFunc(cs, time.Time.Compare)}}
		}
		ivs[t.ID] = ws
		leaves = append(leaves, t.ID)
		b.accs[t.ID].sessions[sid] = true
	}
	slices.Sort(leaves)
	return ivs, leaves
}

// attributeSession splits the session's segments at every interval edge and
// gives each piece, and each api_call's cost, to the leaves open then.
func (b *taskBoard) attributeSession(ivs map[int64][]window, leaves []int64, segs []Segment, apis []db.AgentReportEvent) {
	open := func(at time.Time) []int64 {
		var out []int64
		for _, id := range leaves {
			if slices.ContainsFunc(ivs[id], func(w window) bool { return w.has(at) }) {
				out = append(out, id)
			}
		}
		return out
	}
	var cuts []time.Time
	for _, ws := range ivs {
		for _, w := range ws {
			cuts = append(cuts, w.start, w.end)
		}
	}
	slices.SortFunc(cuts, time.Time.Compare)
	for _, seg := range segs {
		a, ok1 := parseAt(seg.Start)
		end, ok2 := parseAt(seg.End)
		if !ok1 || !ok2 {
			continue
		}
		for _, c := range cuts {
			if c.After(a) && c.Before(end) {
				attribute(b.accs, open(a), seg, a, c)
				a = c
			}
		}
		attribute(b.accs, open(a), seg, a, end)
	}
	for _, e := range apis {
		at, ok := parseAt(e.TS)
		if !ok {
			continue
		}
		ids := open(at)
		for _, id := range ids {
			b.accs[id].cost += e.CostUSD / float64(len(ids))
			b.accs[id].shared = b.accs[id].shared || len(ids) > 1
		}
	}
}

// row sums a target's leaves (itself when it is one) into its TaskRow.
func (b *taskBoard) row(t db.AgentReportTarget) TaskRow {
	sum := &taskAcc{sessions: map[string]bool{}}
	stack, seen := []int64{t.ID}, map[int64]bool{}
	for len(stack) > 0 {
		id := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if seen[id] {
			continue
		}
		seen[id] = true
		stack = append(stack, b.children[id]...)
		for s := range b.named[id] {
			sum.sessions[s] = true
		}
		if b.isLeaf(id) {
			sum.merge(b.accs[id])
		}
	}
	cal, ph := phases(t.History, b.now)
	tm := sum.time
	tm.seal()
	sessionsOut := make([]string, 0, len(sum.sessions))
	for s := range sum.sessions {
		sessionsOut = append(sessionsOut, s)
	}
	slices.Sort(sessionsOut)
	return TaskRow{
		TargetID: t.ID, Text: t.Text, Status: t.Status, CalendarMS: cal, Phases: ph,
		AgentMS: tm.ActiveMS, Time: tm, CostUSD: sum.cost, Sessions: sessionsOut, Shared: sum.shared,
	}
}

// attribute gives [a, b) of seg to the open targets, equally.
func attribute(accs map[int64]*taskAcc, open []int64, seg Segment, a, b time.Time) {
	k := int64(len(open))
	ms := b.Sub(a).Milliseconds()
	if k == 0 || ms <= 0 {
		return
	}
	for i, id := range open {
		share := ms / k
		if i == 0 {
			share += ms % k
		}
		accs[id].time.add(seg.Category, seg.ToolClass, share)
		accs[id].shared = accs[id].shared || k > 1
	}
}
