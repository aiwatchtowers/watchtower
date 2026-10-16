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

func (a *taskAcc) addMS(cat, class string, ms int64) {
	switch cat {
	case CatTool:
		a.time.Tools.add(class, ms)
	case CatBackground:
		a.time.BackgroundMS += ms
	case CatOwner:
		a.time.OwnerMS += ms
	case CatAway:
		a.time.AwayMS += ms
	default:
		a.time.ModelMS += ms
	}
}

func (a *taskAcc) merge(b *taskAcc) {
	t, u := &a.time, b.time
	t.ModelMS += u.ModelMS
	t.Tools.BuildTest += u.Tools.BuildTest
	t.Tools.Git += u.Tools.Git
	t.Tools.ReadSearch += u.Tools.ReadSearch
	t.Tools.Edit += u.Tools.Edit
	t.Tools.MCP += u.Tools.MCP
	t.Tools.SubagentsFG += u.Tools.SubagentsFG
	t.Tools.Other += u.Tools.Other
	t.BackgroundMS += u.BackgroundMS
	t.OwnerMS += u.OwnerMS
	t.AwayMS += u.AwayMS
	a.cost += b.cost
	a.shared = a.shared || b.shared
	for s := range b.sessions {
		a.sessions[s] = true
	}
}

func (a *taskAcc) finish() TimeSplit {
	t := a.time
	t.WallMS = t.ModelMS + t.Tools.BuildTest + t.Tools.Git + t.Tools.ReadSearch + t.Tools.Edit +
		t.Tools.MCP + t.Tools.SubagentsFG + t.Tools.Other + t.BackgroundMS + t.OwnerMS + t.AwayMS
	t.ActiveMS = t.WallMS - t.AwayMS
	return t
}

// Tasks attributes the sessions' main-lane segments and api_call costs to the
// leaf targets they worked on (see the spec's Tasks section): inside the
// target's in_progress/in_review windows, or, with no window holding a call
// that names it, over the session's first-to-last call naming it. Where one
// session has k targets open at once, each gets 1/k of the stretch (integer
// ms, the remainder to the lowest id) and is marked Shared. Rows come by
// target id; a group row sums its leaves and has its own calendar time.
func Tasks(targets []db.AgentReportTarget, sessions map[string][]Segment, events map[string][]db.AgentReportEvent, now time.Time) []TaskRow {
	now = now.UTC()
	children := map[int64][]int64{}
	byID := map[int64]db.AgentReportTarget{}
	for _, t := range targets {
		byID[t.ID] = t
	}
	for _, t := range targets {
		if t.ParentID != nil {
			if _, ok := byID[*t.ParentID]; ok {
				children[*t.ParentID] = append(children[*t.ParentID], t.ID)
			}
		}
	}
	isLeaf := func(id int64) bool { return len(children[id]) == 0 }

	accs := map[int64]*taskAcc{}
	named := map[int64]map[string]bool{} // sessions that call a tool naming the target
	for _, t := range targets {
		accs[t.ID] = &taskAcc{sessions: map[string]bool{}}
		named[t.ID] = map[string]bool{}
	}

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
	for _, sid := range ids {
		calls := map[int64][]time.Time{}
		var apis []db.AgentReportEvent
		for _, e := range events[sid] {
			switch e.Kind {
			case "tool":
				id, ok := targetID(e.Target)
				if !ok || byID[id].ID == 0 {
					continue
				}
				named[id][sid] = true
				if at, ok := parseAt(e.TS); ok {
					calls[id] = append(calls[id], at)
				}
			case "api_call":
				apis = append(apis, e)
			}
		}
		// the intervals each leaf of this session counts over
		ivs := map[int64][]window{}
		var leaves []int64
		for _, t := range targets {
			cs := calls[t.ID]
			if !isLeaf(t.ID) || len(cs) == 0 {
				continue
			}
			ws := windows(t.History, now)
			inside := slices.ContainsFunc(cs, func(c time.Time) bool {
				return slices.ContainsFunc(ws, func(w window) bool { return w.has(c) })
			})
			if !inside {
				ws = []window{{slices.MinFunc(cs, time.Time.Compare), slices.MaxFunc(cs, time.Time.Compare)}}
			}
			ivs[t.ID] = ws
			leaves = append(leaves, t.ID)
			accs[t.ID].sessions[sid] = true
		}
		if len(leaves) == 0 {
			continue
		}
		slices.Sort(leaves)
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
		for _, seg := range sessions[sid] {
			a, ok1 := parseAt(seg.Start)
			b, ok2 := parseAt(seg.End)
			if !ok1 || !ok2 {
				continue
			}
			for _, c := range cuts {
				if c.After(a) && c.Before(b) {
					attribute(accs, open(a), seg, a, c)
					a = c
				}
			}
			attribute(accs, open(a), seg, a, b)
		}
		for _, e := range apis {
			at, ok := parseAt(e.TS)
			if !ok {
				continue
			}
			ids := open(at)
			for _, id := range ids {
				accs[id].cost += e.CostUSD / float64(len(ids))
			}
		}
	}

	rows := make([]TaskRow, 0, len(targets))
	for _, t := range targets {
		sum := &taskAcc{sessions: map[string]bool{}}
		stack, seen := []int64{t.ID}, map[int64]bool{}
		for len(stack) > 0 {
			id := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			if seen[id] {
				continue
			}
			seen[id] = true
			stack = append(stack, children[id]...)
			for s := range named[id] {
				sum.sessions[s] = true
			}
			if isLeaf(id) {
				sum.merge(accs[id])
			}
		}
		cal, ph := phases(t.History, now)
		tm := sum.finish()
		sessionsOut := make([]string, 0, len(sum.sessions))
		for s := range sum.sessions {
			sessionsOut = append(sessionsOut, s)
		}
		slices.Sort(sessionsOut)
		rows = append(rows, TaskRow{
			TargetID: t.ID, Text: t.Text, Status: t.Status, CalendarMS: cal, Phases: ph,
			AgentMS: tm.ActiveMS, Time: tm, CostUSD: sum.cost, Sessions: sessionsOut, Shared: sum.shared,
		})
	}
	return rows
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
		accs[id].addMS(seg.Category, seg.ToolClass, share)
		accs[id].shared = accs[id].shared || k > 1
	}
}
