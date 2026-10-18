package agentreport

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"
)

func at(off time.Duration) string { return t0.Add(off).Format("2006-01-02T15:04:05Z") }

func target(id int64, parent *int64, hist ...db.StatusChange) db.AgentReportTarget {
	st := ""
	if n := len(hist); n > 0 {
		st = hist[n-1].To
	}
	return db.AgentReportTarget{ID: id, ParentID: parent, Text: "t", Status: st, History: hist}
}

func sc(to string, off time.Duration) db.StatusChange { return db.StatusChange{To: to, At: at(off)} }

func (f *fixture) apiCost(at time.Duration, cost float64) {
	f.add(agentlogdb.AgentReportEvent{Kind: "api_call", Name: "claude-opus-5-5", CostUSD: cost}, at)
}

// run feeds one fixture session to Tasks as session "s1".
func run(f *fixture, targets []db.AgentReportTarget, now time.Time) map[int64]TaskRow {
	_, segs := SessionTime(f.evs)
	rows := Tasks(targets, map[string][]Segment{"s1": segs}, map[string][]agentlogdb.AgentReportEvent{"s1": f.evs}, now)
	out := map[int64]TaskRow{}
	for _, r := range rows {
		out[r.TargetID] = r
	}
	return out
}

func TestTasks_WindowedAttribution(t *testing.T) {
	f := &fixture{}
	f.apiCost(0, 1)
	f.tool(1*mn, "mcp__wt__update_target", "#1", new(sec)) // before the window
	f.tool(3*mn, "mcp__wt__update_target", "#1", new(sec)) // inside
	f.apiCost(5*mn, 2)
	f.tool(12*mn, "mcp__wt__update_target", "#1", new(sec)) // after
	f.apiCost(20*mn, 4)
	rows := run(f, []db.AgentReportTarget{
		target(1, nil, sc("todo", -time.Hour), sc("in_progress", 2*mn), sc("done", 10*mn)),
	}, t0.Add(time.Hour))

	r := rows[1]
	assert.Equal(t, ms(8*mn), r.Time.WallMS, "only the window counts")
	assert.Equal(t, r.Time.ActiveMS, r.AgentMS)
	assert.Equal(t, ms(sec), r.Time.Tools.MCP)
	assert.InDelta(t, 2.0, r.CostUSD, 1e-9)
	assert.Equal(t, []string{"s1"}, r.Sessions)
	assert.False(t, r.Shared)
	assert.Equal(t, int64(8*60*1000), r.CalendarMS)
}

func TestTasks_EqualSplitMarksShared(t *testing.T) {
	f := &fixture{}
	f.apiCost(0, 1)
	f.tool(1*mn, "mcp__wt__update_target", "#1", new(sec))
	f.tool(2*mn, "mcp__wt__update_target", "#2", new(sec))
	f.apiCost(5*mn, 2)
	f.apiCost(20*mn, 4)
	rows := run(f, []db.AgentReportTarget{
		target(1, nil, sc("in_progress", 0), sc("done", 10*mn)),
		target(2, nil, sc("in_progress", 0), sc("done", 10*mn)),
	}, t0.Add(time.Hour))

	for _, id := range []int64{1, 2} {
		assert.Equal(t, ms(5*mn), rows[id].Time.WallMS, "target %d", id)
		assert.InDelta(t, 1.5, rows[id].CostUSD, 1e-9)
		assert.True(t, rows[id].Shared)
	}
	assert.Equal(t, 2*ms(sec), rows[1].Time.Tools.MCP+rows[2].Time.Tools.MCP, "tool time splits without loss")
	assert.Equal(t, ms(10*mn), rows[1].Time.WallMS+rows[2].Time.WallMS)
}

func TestTasks_NoWindowFallsBackToCallSpan(t *testing.T) {
	f := &fixture{}
	f.apiCost(0, 1)
	f.tool(3*mn, "mcp__wt__update_target", "#1", new(sec))
	f.apiCost(5*mn, 2)
	f.tool(9*mn, "mcp__wt__update_target", "#1", new(sec))
	f.apiCost(20*mn, 4)
	// moved straight to done long before the session: no window at all.
	rows := run(f, []db.AgentReportTarget{
		target(1, nil, sc("todo", -2*time.Hour), sc("done", -time.Hour)),
	}, t0.Add(time.Hour))
	assert.Equal(t, ms(6*mn), rows[1].Time.WallMS)
	assert.InDelta(t, 2.0, rows[1].CostUSD, 1e-9)
	assert.Equal(t, int64(0), rows[1].CalendarMS, "no in_progress: no calendar time")
	assert.Equal(t, map[string]int64{"in_progress": 0, "in_review": 0, "blocked": 0, "todo": 0}, rows[1].Phases)

	// calls outside every window fall back as well.
	rows = run(f, []db.AgentReportTarget{
		target(1, nil, sc("in_progress", 15*mn), sc("done", 18*mn)),
	}, t0.Add(time.Hour))
	assert.Equal(t, ms(6*mn), rows[1].Time.WallMS)
}

func TestTasks_ReopenedTarget(t *testing.T) {
	f := &fixture{}
	f.apiCost(0, 1)
	f.tool(2*mn, "mcp__wt__update_target", "#1", new(sec))
	f.apiCost(3*mn, 2)
	f.apiCost(7*mn, 4)
	f.apiCost(12*mn, 8)
	f.tool(13*mn, "mcp__wt__update_target", "#1", new(sec))
	f.apiCost(20*mn, 16)
	rows := run(f, []db.AgentReportTarget{
		target(1, nil, sc("todo", -time.Hour), sc("in_progress", 1*mn), sc("done", 4*mn),
			sc("in_progress", 10*mn), sc("done", 14*mn)),
	}, t0.Add(time.Hour))
	r := rows[1]
	assert.Equal(t, ms(13*mn), r.CalendarMS, "first in_progress to the last close")
	assert.Equal(t, ms(7*mn), r.Phases["in_progress"])
	assert.Equal(t, ms(7*mn), r.Time.WallMS, "both stretches count")
	assert.InDelta(t, 2.0+8.0, r.CostUSD, 1e-9)
}

func TestTasks_PhasesAndOpenTarget(t *testing.T) {
	now := t0.Add(30 * mn)
	rows := run(&fixture{}, []db.AgentReportTarget{
		target(1, nil, sc("in_progress", 0), sc("blocked", 5*mn), sc("in_progress", 8*mn),
			sc("in_review", 10*mn), sc("todo", 15*mn), sc("in_progress", 20*mn)),
	}, now)
	r := rows[1]
	assert.Equal(t, ms(30*mn), r.CalendarMS)
	assert.Equal(t, map[string]int64{
		"in_progress": ms(5*mn + 2*mn + 10*mn), "in_review": ms(5 * mn), "blocked": ms(3 * mn), "todo": ms(5 * mn),
	}, r.Phases)
}

func TestTasks_GroupSumsLeaves(t *testing.T) {
	f := &fixture{}
	f.apiCost(0, 1)
	f.tool(1*mn, "mcp__wt__update_target", "#11", new(sec))
	f.apiCost(2*mn, 2)
	f.tool(6*mn, "mcp__wt__update_target", "#12", new(sec))
	f.apiCost(7*mn, 4)
	f.apiCost(20*mn, 8)
	p := int64(10)
	rows := run(f, []db.AgentReportTarget{
		target(10, nil, sc("in_progress", -mn), sc("done", 12*mn)),
		target(11, &p, sc("in_progress", 0), sc("done", 5*mn)),
		target(12, &p, sc("in_progress", 5*mn), sc("done", 10*mn)),
	}, t0.Add(time.Hour))
	g := rows[10]
	assert.Equal(t, ms(13*mn), g.CalendarMS, "own history")
	assert.Equal(t, ms(10*mn), g.Time.WallMS)
	assert.Equal(t, rows[11].Time.WallMS+rows[12].Time.WallMS, g.Time.WallMS)
	assert.Equal(t, g.Time.ActiveMS, g.AgentMS)
	assert.InDelta(t, 7.0, g.CostUSD, 1e-9)
	assert.Equal(t, []string{"s1"}, g.Sessions)
	assert.False(t, g.Shared)
}

func TestTasks_OddMSSplitRemainderToLowestID(t *testing.T) {
	f := &fixture{}
	f.apiCost(time.Millisecond, 0)
	f.tool(1*mn, "mcp__wt__update_target", "#1", new(sec))
	f.tool(2*mn, "mcp__wt__update_target", "#2", new(sec))
	f.apiCost(20*mn, 0)
	rows := run(f, []db.AgentReportTarget{
		target(2, nil, sc("in_progress", 0), sc("done", 10*mn)),
		target(1, nil, sc("in_progress", 0), sc("done", 10*mn)),
	}, t0.Add(time.Hour))
	assert.Equal(t, ms(10*mn)-1, rows[1].Time.WallMS+rows[2].Time.WallMS)
	assert.Equal(t, ms(5*mn), rows[1].Time.WallMS, "the odd ms goes to the lowest id")
	assert.Equal(t, ms(5*mn)-1, rows[2].Time.WallMS)
}

func TestTasks_GroupCallLinksSessionOnly(t *testing.T) {
	f := &fixture{}
	f.apiCost(0, 1)
	f.tool(3*mn, "mcp__wt__update_target", "#10", new(sec))
	f.apiCost(20*mn, 2)
	p := int64(10)
	rows := run(f, []db.AgentReportTarget{
		target(10, nil, sc("in_progress", 0), sc("done", 10*mn)),
		target(11, &p, sc("in_progress", 0), sc("done", 10*mn)),
	}, t0.Add(time.Hour))
	assert.Equal(t, []string{"s1"}, rows[10].Sessions)
	assert.Equal(t, int64(0), rows[10].Time.WallMS)
	assert.Zero(t, rows[10].CostUSD)
	assert.Empty(t, rows[11].Sessions)
}

func TestTasks_GrandchildCallLinksAncestors(t *testing.T) {
	f := &fixture{}
	f.apiCost(0, 1)
	f.tool(3*mn, "mcp__wt__update_target", "#12", new(sec))
	f.apiCost(20*mn, 2)
	g, c := int64(10), int64(11)
	rows := run(f, []db.AgentReportTarget{
		target(10, nil, sc("in_progress", 0), sc("done", 10*mn)),
		target(11, &g, sc("in_progress", 0), sc("done", 10*mn)),
		target(12, &c, sc("in_progress", 0), sc("done", 10*mn)),
	}, t0.Add(time.Hour))
	for _, id := range []int64{10, 11, 12} {
		assert.Equal(t, []string{"s1"}, rows[id].Sessions, "target %d", id)
	}
	assert.Equal(t, ms(10*mn), rows[10].Time.WallMS)
}

func TestTasks_SingleCallFallbackIsZero(t *testing.T) {
	f := &fixture{}
	f.apiCost(0, 1)
	f.tool(3*mn, "mcp__wt__update_target", "#1", new(sec))
	f.apiCost(20*mn, 2)
	rows := run(f, []db.AgentReportTarget{target(1, nil, sc("done", -time.Hour))}, t0.Add(time.Hour))
	assert.Equal(t, []string{"s1"}, rows[1].Sessions)
	assert.Zero(t, rows[1].Time.WallMS)
	assert.Zero(t, rows[1].CostUSD)
}

func TestTasks_CostOnlySplit(t *testing.T) {
	evs := []agentlogdb.AgentReportEvent{
		{Kind: "tool", Name: "mcp__wt__update_target", Target: "#1", TS: t0.Add(mn).Format(tsLayout)},
		{Kind: "tool", Name: "mcp__wt__update_target", Target: "#2", TS: t0.Add(mn).Format(tsLayout)},
		{Kind: "api_call", CostUSD: 3, TS: t0.Add(2 * mn).Format(tsLayout)},
	}
	rows := Tasks([]db.AgentReportTarget{
		target(1, nil, sc("in_progress", 0), sc("done", 10*mn)),
		target(2, nil, sc("in_progress", 0), sc("done", 10*mn)),
	}, nil, map[string][]agentlogdb.AgentReportEvent{"s1": evs}, t0.Add(time.Hour))
	assert.InDelta(t, 1.5, rows[0].CostUSD, 1e-9)
	assert.InDelta(t, 1.5, rows[1].CostUSD, 1e-9)
	assert.True(t, rows[0].Shared && rows[1].Shared)
}
