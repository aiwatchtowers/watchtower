package agentreport

import (
	"slices"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

var t0 = time.Date(2026, 10, 1, 10, 0, 0, 0, time.UTC)

// fixture builds one session's events; offsets keep the order stable on ties.
type fixture struct{ evs []db.AgentReportEvent }

func (f *fixture) add(e db.AgentReportEvent, at time.Duration) *db.AgentReportEvent {
	e.SessionUUID = "s1"
	e.TS = t0.Add(at).Format(tsLayout)
	if e.SrcPath == "" {
		e.SrcPath = "/tmp/x/s1.jsonl"
	}
	e.SrcOffset = int64(len(f.evs))
	f.evs = append(f.evs, e)
	return &f.evs[len(f.evs)-1]
}

func (f *fixture) owner(at time.Duration) {
	f.add(db.AgentReportEvent{Kind: "owner_turn", Trigger: "owner"}, at)
}
func (f *fixture) api(at time.Duration) {
	f.add(db.AgentReportEvent{Kind: "api_call", Name: "claude-opus-5-5"}, at)
}

func (f *fixture) tool(at time.Duration, name, target string, dur *time.Duration) *db.AgentReportEvent {
	e := db.AgentReportEvent{Kind: "tool", Name: name, Target: target, Outcome: "pending"}
	if dur != nil {
		ms := dur.Milliseconds()
		e.DurationMS, e.Outcome = &ms, "ok"
	}
	return f.add(e, at)
}

func (f *fixture) sub(agentID string, at time.Duration) {
	f.add(db.AgentReportEvent{Kind: "api_call", Name: "claude-opus-5-5", AgentID: agentID}, at)
}

func sum(ts TimeSplit) int64 {
	t := ts.Tools
	return ts.ModelMS + t.BuildTest + t.Git + t.ReadSearch + t.Edit + t.MCP + t.SubagentsFG + t.Other +
		ts.BackgroundMS + ts.OwnerMS + ts.AwayMS
}

func segSum(t *testing.T, segs []Segment) int64 {
	t.Helper()
	var n int64
	for _, s := range segs {
		a, err := time.Parse(tsLayout, s.Start)
		require.NoError(t, err)
		b, err := time.Parse(tsLayout, s.End)
		require.NoError(t, err)
		require.True(t, b.After(a), "zero or negative segment %+v", s)
		n += b.Sub(a).Milliseconds()
	}
	return n
}

const (
	sec = time.Second
	mn  = time.Minute
)

func ms(v time.Duration) int64 { return v.Milliseconds() }

// AGENTLOG-06 guard: every category is exercised and they add up to wall time.
func TestTimeModel_EveryCategorySumsToWall(t *testing.T) {
	var f fixture
	f.owner(0)
	f.api(10 * sec)
	f.tool(10*sec, "Bash", "go test", new(60*sec))
	f.api(75 * sec)
	t1 := 75*sec + 20*mn // owner answers after a 20 min wait
	f.owner(t1)
	f.api(t1 + 10*sec)
	spawn := f.tool(t1+10*sec, "Agent", "general-purpose", new(2*sec))
	spawn.Background, spawn.SpawnedAgentID = true, "a1"
	f.api(t1 + 15*sec)
	s := t1 + 15*sec // background subagent runs [s, s+15m]
	f.sub("a1", s)
	f.tool(s+1*mn, "Read", "main.go", new(10*sec)).AgentID = "a1"
	f.sub("a1", s+15*mn)
	f.owner(s + 5*mn) // owner writes while the subagent still runs
	f.api(s + 5*mn + 10*sec)
	f.owner(s + 60*mn) // 45 min after the subagent ended
	f.api(s + 60*mn + 10*sec)

	split, segs := SessionTime(f.evs)
	assert.Equal(t, ms(48*sec), split.ModelMS)
	assert.Equal(t, ToolTimes{BuildTest: ms(60 * sec), Other: ms(2 * sec)}, split.Tools)
	assert.Equal(t, ms(5*mn+9*mn+50*sec), split.BackgroundMS, "the overlapped 5 min are background, not owner")
	assert.Equal(t, ms(20*mn+30*mn), split.OwnerMS)
	assert.Equal(t, ms(15*mn), split.AwayMS)
	assert.Equal(t, ms(s+60*mn+10*sec), split.WallMS)
	assert.Equal(t, split.WallMS-split.AwayMS, split.ActiveMS)
	assert.Equal(t, split.WallMS, sum(split))
	assert.Equal(t, split.WallMS, segSum(t, segs))

	var cats []string
	for _, sg := range segs {
		cats = append(cats, sg.Category)
	}
	assert.Equal(t, []string{"model", "tool", "model", "owner", "model", "tool", "model",
		"background", "model", "background", "owner", "away", "model"}, cats)
	assert.Equal(t, Segment{Start: t0.Add(10 * sec).Format(tsLayout), End: t0.Add(70 * sec).Format(tsLayout),
		Category: "tool", ToolClass: "build_test", Verb: "go test"}, segs[1])
	assert.Equal(t, "2026-10-01T10:00:10.000Z", segs[1].Start)
}

// AGENTLOG-06 guard: the trigger of the turn closing a wait decides it. A
// notification closes background work even with no subagent span stored; a
// hook record answers at once, so its gap is model; only the owner's turn
// (or a v1 row's empty trigger) makes "waiting for you".
func TestTimeModel_WaitClosedByTrigger(t *testing.T) {
	var f fixture
	f.owner(0)
	f.api(10 * sec)
	f.add(db.AgentReportEvent{Kind: "owner_turn", Trigger: "notification"}, 10*sec+5*mn)
	f.api(20*sec + 5*mn)
	f.add(db.AgentReportEvent{Kind: "owner_turn", Trigger: "hook"}, 50*sec+5*mn)
	f.api(6 * mn)
	f.add(db.AgentReportEvent{Kind: "owner_turn", Trigger: ""}, 6*mn+40*mn)
	f.api(46*mn + 5*sec)

	split, segs := SessionTime(f.evs)
	assert.Equal(t, ms(5*mn), split.BackgroundMS, "a notification-closed wait is background work")
	assert.Equal(t, ms(10*sec+10*sec+30*sec+10*sec+5*sec), split.ModelMS, "a hook-closed gap is model")
	assert.Equal(t, ms(30*mn), split.OwnerMS)
	assert.Equal(t, ms(10*mn), split.AwayMS)
	assert.Equal(t, ms(46*mn+5*sec), split.WallMS)
	assert.Equal(t, split.WallMS-split.AwayMS, split.ActiveMS)
	assert.Equal(t, split.WallMS, sum(split))
	assert.Equal(t, split.WallMS, segSum(t, segs))
}

func TestTimeModel_OverlappingToolsCountedOnce(t *testing.T) {
	var f fixture
	f.owner(0)
	f.api(5 * sec)
	f.tool(5*sec, "Read", "a.go", new(20*sec))
	f.tool(5*sec, "Bash", "go test", new(60*sec))
	f.api(70 * sec)

	split, segs := SessionTime(f.evs)
	assert.Equal(t, ms(20*sec), split.Tools.ReadSearch, "overlap goes to the earliest open tool")
	assert.Equal(t, ms(40*sec), split.Tools.BuildTest)
	assert.Equal(t, ms(10*sec), split.ModelMS)
	assert.Equal(t, ms(70*sec), split.WallMS)
	assert.Equal(t, split.WallMS, sum(split))
	assert.Equal(t, split.WallMS, segSum(t, segs))
}

func TestTimeModel_PendingToolClosesAtNextEvent(t *testing.T) {
	var f fixture
	f.owner(0)
	f.api(5 * sec)
	f.tool(5*sec, "Bash", "go test", nil)
	f.api(5 * sec) // same record, same ts: not the closing event
	f.api(35 * sec)
	f.owner(2 * time.Hour)
	f.api(2*time.Hour + 5*sec)
	f.tool(2*time.Hour+5*sec, "Bash", "make test", nil) // pending, then the owner answers: a wait
	f.owner(3 * time.Hour)
	f.api(3*time.Hour + 5*sec)
	f.tool(3*time.Hour+5*sec, "Bash", "make lint", nil) // pending as the last event

	split, _ := SessionTime(f.evs)
	assert.Equal(t, ms(30*sec), split.Tools.BuildTest)
	assert.Equal(t, ms(60*mn), split.OwnerMS)
	assert.Equal(t, ms(2*time.Hour-35*sec-30*mn+29*mn+55*sec), split.AwayMS)
	assert.Equal(t, ms(15*sec), split.ModelMS)
	assert.Equal(t, split.WallMS, sum(split))
}

func TestTimeModel_WaitEndsOnAPIErrorAndSeesThrough(t *testing.T) {
	for _, c := range []struct {
		name               string
		build              func(f *fixture)
		owner, away, model time.Duration
	}{
		{"api_error ends the turn", func(f *fixture) {
			f.owner(0)
			f.add(db.AgentReportEvent{Kind: "api_error"}, 10*sec)
			f.owner(10*sec + 40*mn)
			f.api(10*sec + 40*mn + 5*sec)
		}, 30 * mn, 10 * mn, 15 * sec},
		{"compaction inside a wait", func(f *fixture) {
			f.owner(0)
			f.api(10 * sec)
			f.add(db.AgentReportEvent{Kind: "compaction"}, 10*sec+20*mn)
			f.owner(10*sec + 50*mn)
			f.api(10*sec + 50*mn + 5*sec)
		}, 30 * mn, 20 * mn, 15 * sec},
		{"pr_link inside a wait", func(f *fixture) {
			f.owner(0)
			f.api(10 * sec)
			f.add(db.AgentReportEvent{Kind: "pr_link"}, 11*sec)
			f.owner(10*sec + 10*mn)
			f.api(10*sec + 10*mn + 5*sec)
		}, 10 * mn, 0, 15 * sec},
	} {
		t.Run(c.name, func(t *testing.T) {
			var f fixture
			c.build(&f)
			split, segs := SessionTime(f.evs)
			assert.Equal(t, ms(c.owner), split.OwnerMS)
			assert.Equal(t, ms(c.away), split.AwayMS)
			assert.Equal(t, ms(c.model), split.ModelMS)
			assert.Equal(t, split.WallMS, sum(split))
			assert.Equal(t, split.WallMS, segSum(t, segs))
		})
	}
}

func TestTimeModel_SingleEvent(t *testing.T) {
	var f fixture
	f.owner(0)
	for _, evs := range [][]db.AgentReportEvent{nil, f.evs} {
		split, segs := SessionTime(evs)
		assert.Equal(t, TimeSplit{}, split)
		assert.Empty(t, segs)
		sa, lanes := SessionSubagents(evs)
		assert.Equal(t, Subagents{}, sa)
		assert.Empty(t, lanes)
	}
}

func TestTimeModel_TiesAndOrder(t *testing.T) {
	var f fixture
	f.owner(0)
	f.add(db.AgentReportEvent{Kind: "api_call", SrcPath: "/tmp/x/b.jsonl"}, 10*sec)
	tool := f.tool(10*sec, "Bash", "ls", new(time.Second))
	tool.SrcPath = "/tmp/x/a.jsonl"
	tool.TS = "2026-10-01T10:00:10Z" // a stored ts without milliseconds
	f.api(10*sec + 500*time.Millisecond)
	f.api(10*sec + 500*time.Millisecond)

	want, wantSegs := SessionTime(f.evs)
	rev := slices.Clone(f.evs)
	slices.Reverse(rev)
	got, gotSegs := SessionTime(rev)
	assert.Equal(t, want, got)
	assert.Equal(t, wantSegs, gotSegs)
	assert.Equal(t, ms(10*sec), got.ModelMS)
	assert.Equal(t, int64(500), got.Tools.ReadSearch)
	assert.Equal(t, ms(10*sec+500*time.Millisecond), got.WallMS)
	assert.Equal(t, got.WallMS, segSum(t, gotSegs), "zero-length gaps add no segment")
}

func TestSubagents_Parallelism(t *testing.T) {
	var f fixture
	f.owner(0)
	fg := f.tool(0, "Agent", "Explore", new(10*mn))
	fg.SpawnedAgentID = "a1"
	bg := f.tool(0, "Task", "general-purpose", new(time.Second))
	bg.SpawnedAgentID, bg.Background = "a2", true
	f.api(10 * mn)
	f.sub("a1", 0)
	f.sub("a1", 10*mn)
	f.sub("a2", 5*mn)
	f.sub("a2", 15*mn)
	f.sub("a3", 20*mn) // no spawning event found: foreground
	f.sub("a3", 30*mn)

	sa, lanes := SessionSubagents(f.evs)
	assert.Equal(t, 3, sa.Count)
	assert.Equal(t, 2, sa.Foreground)
	assert.Equal(t, 1, sa.Background)
	assert.Equal(t, 2, sa.Peak)
	assert.Equal(t, 1, sa.Serial, "only a3 runs alone; a1 overlaps a2")
	assert.Equal(t, ms(30*mn), sa.BusyMS)
	assert.Equal(t, ms(25*mn), sa.UnionMS)
	assert.InDelta(t, 1.2, sa.AvgParallel, 1e-9)
	assert.Equal(t, ms(10*mn), sa.BlockedMS)

	require.Len(t, lanes, 3)
	assert.Equal(t, "a1", lanes[0].AgentID)
	assert.Equal(t, "Explore", lanes[0].SubagentType)
	assert.False(t, lanes[0].Background)
	assert.Equal(t, "a2", lanes[1].AgentID)
	assert.True(t, lanes[1].Background)
	assert.Equal(t, []Segment{{Start: t0.Format(tsLayout), End: t0.Add(10 * mn).Format(tsLayout), Category: "model"}}, lanes[0].Segments)
}

func TestToolClass(t *testing.T) {
	for _, c := range []struct{ name, target, want string }{
		{"Bash", "go test", "build_test"},
		{"Bash", "go build", "build_test"},
		{"Bash", "make test-swift", "build_test"},
		{"Bash", "make", "build_test"},
		{"Bash", "swift build", "build_test"},
		{"Bash", "npm test", "build_test"},
		{"Bash", "xcodebuild", "build_test"},
		{"Bash", "git status", "git"},
		{"Bash", "gh pr", "git"},
		{"Read", "a.go", "read_search"},
		{"Grep", "", "read_search"},
		{"Bash", "cat", "read_search"},
		{"Bash", "rg", "read_search"},
		{"Edit", "a.go", "edit"},
		{"MultiEdit", "a.go", "edit"},
		{"mcp__x__y", "#12", "mcp"},
		{"Agent", "Explore", "subagents_fg"},
		{"Task", "general-purpose", "subagents_fg"},
		{"Bash", "go vet", "other"},
		{"Bash", "bash dev-health.sh", "other"},
		{"WebFetch", "", "other"},
	} {
		assert.Equal(t, c.want, ToolClass(c.name, c.target), "%s %q", c.name, c.target)
	}
}
