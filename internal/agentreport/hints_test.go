package agentreport

import (
	"slices"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlog"
	"watchtower/internal/db"
)

// evset builds the events of several sessions.
type evset map[string][]db.AgentReportEvent

func (s evset) add(sid string, at time.Duration, e db.AgentReportEvent) {
	e.SessionUUID = sid
	e.TS = t0.Add(at).Format(tsLayout)
	e.SrcPath = "/tmp/x/" + sid + ".jsonl"
	e.SrcOffset = int64(len(s[sid]))
	s[sid] = append(s[sid], e)
}

// tl is a tool call; dur < 0 leaves it pending.
func tl(name, target string, dur time.Duration, outcome string) db.AgentReportEvent {
	e := db.AgentReportEvent{Kind: "tool", Name: name, Target: target, Outcome: outcome}
	if dur >= 0 {
		v := dur.Milliseconds()
		e.DurationMS = &v
	}
	return e
}

func hintsOf(hs []Hint, id string) []Hint {
	var out []Hint
	for _, h := range hs {
		if h.ID == id {
			out = append(out, h)
		}
	}
	return out
}

func evidence(h Hint, kind string) []string {
	var out []string
	for _, e := range h.Evidence {
		if e.Kind == kind {
			out = append(out, e.Ref)
		}
	}
	return out
}

func eventsInput(s evset) HintInput {
	var all []db.AgentReportEvent
	for _, evs := range s {
		all = append(all, evs...)
	}
	return HintInput{Events: s, Commands: Commands(all), Models: Models(all)}
}

func TestHintH1_RepeatedHeavyCommand(t *testing.T) {
	s := evset{}
	// s1 is linked to no target: three 2-minute go test runs fire
	for i := range 3 {
		s.add("s1", time.Duration(i)*5*mn, tl("Bash", "go test", 2*mn, "ok"))
	}
	// s2 works #7 between its two update_target calls; three runs inside, one after
	s.add("s2", 0, tl("mcp__watchtower-workbench__update_target", "#7", sec, "ok"))
	for i := range 3 {
		s.add("s2", time.Duration(i+1)*5*mn, tl("Bash", "swift test", time.Duration(i+1)*mn, "ok"))
	}
	s.add("s2", 20*mn, tl("mcp__watchtower-workbench__update_target", "#7", sec, "ok"))
	s.add("s2", 30*mn, tl("Bash", "swift test", 10*mn, "ok"))
	// below the thresholds: three short runs, two long runs
	for i := range 3 {
		s.add("s3", time.Duration(i)*mn, tl("Bash", "go test", 30*sec, "ok"))
	}
	s.add("s4", 0, tl("Bash", "go build", 4*mn, "ok"))
	s.add("s4", 5*mn, tl("Bash", "go build", 4*mn, "ok"))
	in := eventsInput(s)
	in.Tasks = []TaskRow{{TargetID: 7, Text: "ship it", Sessions: []string{"s2"}}}

	hs := hintsOf(Hints(in), "H1")
	require.Len(t, hs, 2)
	byScope := map[string]Hint{}
	for _, h := range hs {
		if refs := evidence(h, "target"); len(refs) > 0 {
			byScope[refs[0]] = h
		} else {
			byScope[evidence(h, "session")[0]] = h
		}
	}
	assert.Equal(t, ms(4*mn), byScope["s1"].EstimateMS)
	assert.Equal(t, []string{"go test"}, evidence(byScope["s1"], "command"))
	assert.Equal(t, ms(5*mn), byScope["#7"].EstimateMS, "runs after the first, inside the window only")
	assert.Equal(t, []string{"s2"}, evidence(byScope["#7"], "session"))
	assert.Contains(t, byScope["#7"].Finding, "swift test")
	assert.Contains(t, byScope["#7"].Finding, "6m 0s")
}

func TestHintH2_SlowCheapCommands(t *testing.T) {
	s := evset{}
	s.add("s1", 0, tl("Read", "/tmp/x/a", 6*sec, "ok"))
	s.add("s1", mn, tl("Grep", "foo", 7*sec, "ok"))
	s.add("s1", 2*mn, tl("Bash", "git status", 9*sec, "ok"))
	s.add("s2", 0, tl("Bash", "git diff", 8*sec, "ok"))
	s.add("s2", mn, tl("Read", "/tmp/x/b", -1, "pending"))  // no time: not counted
	s.add("s2", 2*mn, tl("Bash", "git push", 60*sec, "ok")) // not cheap
	hs := hintsOf(Hints(eventsInput(s)), "H2")
	require.Len(t, hs, 1)
	assert.Equal(t, ms(6500*time.Millisecond)*4, hs[0].EstimateMS) // median 7.5s
	assert.ElementsMatch(t, []string{"Read", "Grep", "git status", "git diff"}, evidence(hs[0], "command"))
	assert.Contains(t, hs[0].Finding, "/fewer-permission-prompts")

	fast := evset{}
	fast.add("s1", 0, tl("Read", "/tmp/x/a", sec, "ok"))
	fast.add("s1", mn, tl("Read", "/tmp/x/a", 2*sec, "ok"))
	fast.add("s1", 2*mn, tl("Read", "/tmp/x/a", 9*sec, "ok"))
	assert.Empty(t, hintsOf(Hints(eventsInput(fast)), "H2"))
}

func TestHintH3_SerialSubagents(t *testing.T) {
	s := evset{}
	for i, span := range [][2]time.Duration{{0, 2 * mn}, {3 * mn, 6 * mn}, {7 * mn, 8 * mn}} {
		id := string(rune('a' + i))
		s.add("s1", span[0], apiEv(id, "claude-opus-5-5", 0, 0, 0, 0, 0))
		s.add("s1", span[1], apiEv(id, "claude-opus-5-5", 0, 0, 0, 0, 0))
	}
	in := eventsInput(s)
	in.Sessions = map[string]SessionView{"s1": {UUID: "s1", Subagents: Subagents{Foreground: 3, AvgParallel: 1}}}
	hs := hintsOf(Hints(in), "H3")
	require.Len(t, hs, 1)
	assert.Equal(t, ms(3*mn), hs[0].EstimateMS) // 6m of runs minus the longest 3m
	assert.Equal(t, []string{"s1"}, evidence(hs[0], "session"))
	assert.Contains(t, hs[0].Finding, "up to")

	for _, sa := range []Subagents{{Foreground: 3, AvgParallel: 1.5}, {Foreground: 2, AvgParallel: 1}} {
		in.Sessions = map[string]SessionView{"s1": {UUID: "s1", Subagents: sa}}
		assert.Empty(t, hintsOf(Hints(in), "H3"), "%+v", sa)
	}
}

func TestHintH4_OwnerShare(t *testing.T) {
	in := HintInput{
		Sessions: map[string]SessionView{
			"s1": {UUID: "s1", Time: TimeSplit{OwnerMS: ms(40 * mn), ActiveMS: ms(100 * mn)}},
			"s2": {UUID: "s2", Time: TimeSplit{OwnerMS: ms(10 * mn), ActiveMS: ms(100 * mn)}},
		},
		Tasks: []TaskRow{
			{TargetID: 3, Text: "t", Sessions: []string{"s1"}, Time: TimeSplit{OwnerMS: ms(20 * mn), ActiveMS: ms(50 * mn)}},
			{TargetID: 4, Text: "t", Sessions: []string{"s2"}, Time: TimeSplit{OwnerMS: ms(5 * mn), ActiveMS: ms(50 * mn)}},
		},
	}
	hs := hintsOf(Hints(in), "H4")
	require.Len(t, hs, 1)
	assert.Equal(t, ms(40*mn), hs[0].EstimateMS)
	assert.Equal(t, []string{"s1"}, evidence(hs[0], "session"))
	assert.Equal(t, []string{"#3"}, evidence(hs[0], "target"))

	// only a task over the line: its waiting time
	in.Sessions["s1"] = SessionView{UUID: "s1", Time: TimeSplit{OwnerMS: ms(20 * mn), ActiveMS: ms(100 * mn)}}
	hs = hintsOf(Hints(in), "H4")
	require.Len(t, hs, 1)
	assert.Equal(t, ms(20*mn), hs[0].EstimateMS)

	in.Tasks = in.Tasks[1:]
	assert.Empty(t, hintsOf(Hints(in), "H4"))
}

func TestHintH5_FailingToolLoop(t *testing.T) {
	s := evset{}
	s.add("s1", 0, tl("Bash", "go test", sec, "error"))
	s.add("s1", mn, tl("Edit", "/tmp/x/a", sec, "ok")) // another verb does not break the run
	s.add("s1", 2*mn, tl("Bash", "go test", 2*sec, "error"))
	s.add("s1", 3*mn, tl("Bash", "go test", 3*sec, "error"))
	s.add("s2", 0, tl("Bash", "go vet", sec, "error"))
	s.add("s2", mn, tl("Bash", "go vet", sec, "error"))
	s.add("s2", 2*mn, tl("Bash", "go vet", sec, "ok"))
	s.add("s2", 3*mn, tl("Bash", "go vet", sec, "error"))
	hs := hintsOf(Hints(eventsInput(s)), "H5")
	require.Len(t, hs, 1)
	assert.Equal(t, ms(6*sec), hs[0].EstimateMS)
	assert.Equal(t, []string{"s1"}, evidence(hs[0], "session"))
	assert.Equal(t, []string{"go test"}, evidence(hs[0], "command"))
}

func TestHintH6_ExpensiveContext(t *testing.T) {
	in := HintInput{Sessions: map[string]SessionView{
		"s1": {UUID: "s1", CostUSD: 8, CacheReadShare: 0.4},
		"s2": {UUID: "s2", CostUSD: 8, CacheReadShare: 0.6},
		"s3": {UUID: "s3", CostUSD: 1, CacheReadShare: 0.9, Compactions: 2},
		"s4": {UUID: "s4", CostUSD: 4, CacheReadShare: 0.1, Compactions: 1},
	}}
	hs := hintsOf(Hints(in), "H6")
	require.Len(t, hs, 2)
	got := map[string]float64{}
	for _, h := range hs {
		got[evidence(h, "session")[0]] = h.EstimateUSD
	}
	assert.Equal(t, map[string]float64{"s1": 8, "s3": 1}, got)
}

func TestHintH7_TopModelOnSubagents(t *testing.T) {
	top, next := agentlog.ModelTiers()[0], "claude-opus-4-6"
	s := evset{}
	sub := apiEv("a1", top, 40, 1e6, 0, 0, 0)
	sub.OutputTokens = 1e6
	s.add("s1", 0, sub)
	s.add("s1", mn, apiEv("", "claude-opus-5-5", 60, 0, 0, 0, 0))
	hs := hintsOf(Hints(eventsInput(s)), "H7")
	require.Len(t, hs, 1)
	repriced, ok := agentlog.Cost(next, "", 1e6, 1e6, 0, 0, 0)
	require.True(t, ok)
	assert.InDelta(t, 40-repriced, hs[0].EstimateUSD, 1e-9)
	assert.Equal(t, []string{"s1"}, evidence(hs[0], "session"))
	assert.Contains(t, hs[0].Finding, next)

	low := evset{}
	low.add("s1", 0, apiEv("a1", top, 20, 1e6, 0, 0, 0))
	low.add("s1", mn, apiEv("", "claude-opus-5-5", 80, 0, 0, 0, 0))
	assert.Empty(t, hintsOf(Hints(eventsInput(low)), "H7"))
}

// AGENTLOG-07 guard: every hint cites at least one evidence item that resolves
// to a session, target or command of the input; the list is ranked.
func TestHints_CiteEvidence(t *testing.T) {
	s := evset{}
	s.add("s1", 0, tl("mcp__watchtower-workbench__update_target", "#7", sec, "ok"))
	for i := range 4 {
		s.add("s1", time.Duration(i+1)*5*mn, tl("Bash", "go test", 3*mn, "error"))
	}
	s.add("s1", 30*mn, tl("mcp__watchtower-workbench__update_target", "#7", sec, "ok"))
	s.add("s1", 31*mn, tl("Read", "/tmp/x/a", 9*sec, "ok"))
	s.add("s1", 32*mn, tl("Bash", "git log", 9*sec, "ok"))
	for i := range 3 {
		id := string(rune('a' + i))
		s.add("s2", time.Duration(i)*10*mn, apiEv(id, agentlog.ModelTiers()[0], 30, 1e6, 0, 0, 0))
		s.add("s2", time.Duration(i)*10*mn+5*mn, apiEv(id, agentlog.ModelTiers()[0], 0, 0, 0, 0, 0))
	}
	s.add("s2", 40*mn, apiEv("", "claude-opus-5-5", 10, 0, 0, 0, 0))
	in := eventsInput(s)
	in.Tasks = []TaskRow{{TargetID: 7, Text: "t", Sessions: []string{"s1"},
		Time: TimeSplit{OwnerMS: ms(30 * mn), ActiveMS: ms(60 * mn)}}}
	in.Sessions = map[string]SessionView{
		"s1": {UUID: "s1", Time: TimeSplit{OwnerMS: ms(30 * mn), ActiveMS: ms(60 * mn)}, Compactions: 3, CostUSD: 2},
		"s2": {UUID: "s2", Subagents: Subagents{Foreground: 3, AvgParallel: 1}, CostUSD: 100, CacheReadShare: 0.1},
	}
	hs := Hints(in)
	ids := map[string]bool{}
	for _, h := range hs {
		ids[h.ID] = true
	}
	assert.Equal(t, map[string]bool{"H1": true, "H2": true, "H3": true, "H4": true, "H5": true, "H6": true, "H7": true}, ids)

	verbs := map[string]bool{}
	for _, c := range in.Commands {
		verbs[c.Verb] = true
	}
	for _, h := range hs {
		require.NotEmpty(t, h.Evidence, h.ID)
		assert.NotEmpty(t, h.Finding)
		assert.NotContains(t, h.Finding, "\n")
		for _, e := range h.Evidence {
			switch e.Kind {
			case "session":
				_, inSessions := in.Sessions[e.Ref]
				_, inEvents := in.Events[e.Ref]
				assert.True(t, inSessions || inEvents, "%s cites unknown session %q", h.ID, e.Ref)
			case "target":
				assert.True(t, slices.ContainsFunc(in.Tasks, func(r TaskRow) bool { return "#"+strconv.FormatInt(r.TargetID, 10) == e.Ref }),
					"%s cites unknown target %q", h.ID, e.Ref)
			case "command":
				assert.True(t, verbs[e.Ref], "%s cites unknown command %q", h.ID, e.Ref)
			default:
				t.Errorf("%s: unknown evidence kind %q", h.ID, e.Kind)
			}
		}
	}
	for i := 1; i < len(hs); i++ {
		a, b := hs[i-1], hs[i]
		assert.True(t, a.EstimateMS > b.EstimateMS || a.EstimateMS == b.EstimateMS && a.EstimateUSD >= b.EstimateUSD,
			"not ranked: %s before %s", a.ID, b.ID)
	}
}
