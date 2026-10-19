package agentreport

import (
	"maps"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
)

// call is an api_call whose context is ctx tokens (split over the four input
// buckets) and whose output is out, think of it thinking.
func call(agent string, ctx, out, think int64) agentlogdb.AgentReportEvent {
	q := ctx / 4
	return agentlogdb.AgentReportEvent{Kind: "api_call", AgentID: agent, Name: "claude-opus-5-5",
		InputTokens: ctx - 3*q, CacheReadTokens: q, CacheWrite5mTokens: q, CacheWrite1hTokens: q,
		OutputTokens: out, ThinkingTokens: think}
}

// result is a tool call whose result measured bytes (< 0 = not measured).
func result(agent, name, target string, bytes int64) agentlogdb.AgentReportEvent {
	e := tl(name, target, sec, "ok")
	e.AgentID = agent
	if bytes >= 0 {
		e.ResultBytes = &bytes
	}
	return e
}

func ownerTurn() agentlogdb.AgentReportEvent {
	return agentlogdb.AgentReportEvent{Kind: "owner_turn", Trigger: "owner"}
}

// factsOf lists the sessions of s, every one measured (parser v3).
func factsOf(s evset) []agentlogdb.AgentReportSession {
	var out []agentlogdb.AgentReportSession
	for _, sid := range slices.Sorted(maps.Keys(s)) {
		out = append(out, agentlogdb.AgentReportSession{SessionUUID: sid, Facts: true})
	}
	return out
}

func part(sid, agent, name string, bytes int64) agentlogdb.AgentContextPart {
	return agentlogdb.AgentContextPart{SessionUUID: sid, AgentID: agent, Part: name, Bytes: bytes}
}

func growthOf(r ContextReport) map[string]int64 {
	out := map[string]int64{}
	for _, g := range r.Growth {
		out[g.Source] = g.Tokens
	}
	return out
}

func TestContext_BaselineSplitFromParts(t *testing.T) {
	s := evset{}
	s.add("s1", 0, call("", 4000, 0, 0))
	s.add("s2", 0, call("", 1000, 0, 0))
	s.add("s3", 0, call("", 500, 0, 0)) // no parts: not a baseline lane
	parts := []agentlogdb.AgentContextPart{
		part("s1", "", "instructions", 3000), part("s1", "", "skills", 1000), part("s1", "", "tools", 4000),
		part("s2", "", "instructions", 1000), part("s2", "", "tools", 1000),
		part("s3", "a1", "system", 2600), // a subagent lane with no call: bytes / defaultBytesPerToken
	}
	r := Context(factsOf(s), s, parts, "")

	// lanes 4000 and 1000 tokens: median 2500; shares over both lanes' parts
	assert.Equal(t, int64(2500), r.Baseline.Tokens)
	require.Len(t, r.Baseline.Parts, 3)
	assert.Equal(t, PartShare{Part: "tools", Tokens: 1250, Share: 0.5}, r.Baseline.Parts[0])
	assert.Equal(t, PartShare{Part: "instructions", Tokens: 1000, Share: 0.4}, r.Baseline.Parts[1])
	assert.Equal(t, "skills", r.Baseline.Parts[2].Part)
	assert.InDelta(t, 0.1, r.Baseline.Parts[2].Share, 1e-9)
	assert.Equal(t, 2, r.Baseline.lanes)

	assert.Equal(t, int64(1000), r.SubagentBaseline.Tokens)
	assert.Equal(t, []PartShare{{Part: "system", Tokens: 1000, Share: 1}}, r.SubagentBaseline.Parts)
	assert.Equal(t, 3, r.FactsSessions)
	assert.Equal(t, 3, r.Sessions)
}

func TestContext_GrowthAttribution(t *testing.T) {
	s := evset{}
	s.add("s1", 0, ownerTurn())
	s.add("s1", sec, call("", 10000, 300, 100)) // 200 tokens of its output re-enter
	s.add("s1", 2*sec, result("", "Bash", "go test", 10*1024))
	s.add("s1", 3*sec, result("", "Read", "a.go", 2*1024))
	s.add("s1", 4*sec, call("", 11400, 50, 0)) // +1400: 200 model, 1200 over the two results
	s.add("s1", 5*sec, ownerTurn())
	s.add("s1", 6*sec, call("", 11900, 0, 0)) // +500: 50 model, 450 the owner's turn
	s.add("s1", 7*sec, call("", 12200, 0, 0)) // +300 with nothing measured: reminders
	r := Context(factsOf(s), s, nil, "")

	assert.Equal(t, map[string]int64{"Bash": 1000, "Read": 200, "model": 250, "owner": 450, "reminders": 300}, growthOf(r))
	assert.Equal(t, "Bash", r.Growth[0].Source)
	assert.InDelta(t, 1000.0/2200, r.Growth[0].Share, 1e-9)
	require.Len(t, r.TopSources, 2)
	assert.Equal(t, SourceRow{Tool: "Bash", Target: "go test", Tokens: 1000, Calls: 1, Sessions: 1, sessions: []string{"s1"}}, r.TopSources[0])
	assert.Equal(t, int64(200), r.TopSources[1].Tokens)
}

func TestContext_NegativeDeltaIsClear(t *testing.T) {
	s := evset{}
	s.add("s1", 0, call("", 5000, 0, 0))
	pre, post := int64(5000), int64(2000)
	s.add("s1", sec, agentlogdb.AgentReportEvent{Kind: "compaction", PreTokens: &pre, PostTokens: &post})
	s.add("s1", 2*sec, call("", 2000, 0, 0)) // a clear: skipped
	s.add("s1", 3*sec, call("", 2500, 0, 0))
	s.add("s2", 0, agentlogdb.AgentReportEvent{Kind: "compaction"}) // sizes not measured: counted, no median
	r := Context(factsOf(s), s, nil, "")

	assert.Equal(t, map[string]int64{"reminders": 500}, growthOf(r))
	assert.Equal(t, CompactionStats{Count: 2, MedianPreTokens: 5000, MedianPostTokens: 2000, Sessions: 2}, r.Compactions)
}

func TestContext_SubagentFallbackRatio(t *testing.T) {
	s := evset{}
	// main lane: 1000 bytes of parts for a 2000-token first call, 2 tokens a byte
	s.add("s1", 0, call("", 2000, 0, 0))
	s.add("s1", sec, result("", "Bash", "go test", 100))
	s.add("s1", 2*sec, call("", 3000, 0, 0)) // 200 measured of +1000
	// subagent lane without parts: 2.6 bytes a token
	s.add("s1", 3*sec, call("a1", 1000, 0, 0))
	s.add("s1", 4*sec, result("a1", "Bash", "ls", 2600))
	s.add("s1", 5*sec, call("a1", 4000, 0, 0)) // 1000 measured of +3000
	r := Context(factsOf(s), s, []agentlogdb.AgentContextPart{part("s1", "", "instructions", 1000)}, "")

	assert.Equal(t, map[string]int64{"Bash": 1200, "reminders": 2800}, growthOf(r))
	require.Len(t, r.TopSources, 2)
	assert.Equal(t, "ls", r.TopSources[0].Target)
	assert.Equal(t, int64(1000), r.TopSources[0].Tokens)
	assert.Equal(t, int64(200), r.TopSources[1].Tokens)
	assert.Equal(t, int64(0), r.SubagentBaseline.Tokens, "a lane without parts has no baseline")
}

func TestContext_RepeatedReads(t *testing.T) {
	s := evset{}
	reads := func(sid, file string, n int) {
		at := time.Duration(len(s[sid])) * sec
		ctx := int64(1000)
		s.add(sid, at, call("", ctx, 0, 0))
		for i := range n {
			ctx += 1000
			s.add(sid, at+time.Duration(2*i+1)*sec, result("", "Read", file, 2600)) // 1000 tokens each
			s.add(sid, at+time.Duration(2*i+2)*sec, call("", ctx, 0, 0))
		}
	}
	reads("s1", "a.go", 3)
	reads("s1", "b.go", 2) // under RepeatReadsMin
	reads("s2", "a.go", 4)
	reads("s3", "<outside>", 5) // reads outside the folder share one target: not one file
	r := Context(factsOf(s), s, nil, "")

	require.Len(t, r.RepeatedReads, 1)
	row := r.RepeatedReads[0]
	assert.Equal(t, RepeatRow{Target: "a.go", Reads: 4, Session: "s2", Tokens: 2000 + 3000},
		RepeatRow{Target: row.Target, Reads: row.Reads, Session: row.Session, Tokens: row.Tokens})
	assert.Equal(t, []sessionTokens{{"s1", 2000}, {"s2", 3000}}, row.sessions)
}

// A read after an edit of the file checks the edit: it starts a new run.
func TestContext_ReadAfterEditIsNotARepeat(t *testing.T) {
	s := evset{}
	s.add("s1", 0, call("", 1000, 0, 0))
	s.add("s1", sec, result("", "Read", "a.go", 2600))
	s.add("s1", 2*sec, result("", "Edit", "a.go", 10))
	s.add("s1", 3*sec, call("", 2000, 0, 0))
	s.add("s1", 4*sec, result("", "Read", "a.go", 2600))
	s.add("s1", 5*sec, call("", 3000, 0, 0))
	s.add("s1", 6*sec, result("", "Read", "a.go", 2600))
	s.add("s1", 7*sec, call("", 4000, 0, 0))
	assert.Empty(t, Context(factsOf(s), s, nil, "").RepeatedReads, "two runs of 1 and 2 reads")

	s.add("s1", 8*sec, result("", "Read", "a.go", 2600)) // the second run reaches 3
	s.add("s1", 9*sec, call("", 5000, 0, 0))
	r := Context(factsOf(s), s, nil, "")
	require.Len(t, r.RepeatedReads, 1)
	assert.Equal(t, 3, r.RepeatedReads[0].Reads)
	assert.Equal(t, int64(2000), r.RepeatedReads[0].Tokens)
}

// An owner turn and a measured result that explains only part of the rest
// share a gap: the result takes its size, the owner the remainder.
func TestContext_OwnerTakesTheRemainder(t *testing.T) {
	s := evset{}
	s.add("s1", 0, call("", 1000, 0, 0))
	s.add("s1", sec, result("", "Bash", "ls", 260)) // 100 tokens
	s.add("s1", 2*sec, ownerTurn())
	s.add("s1", 3*sec, call("", 2000, 0, 0))
	r := Context(factsOf(s), s, nil, "")
	assert.Equal(t, map[string]int64{"Bash": 100, "owner": 900}, growthOf(r))
}

func TestContext_OldRowsNotMeasured(t *testing.T) {
	s := evset{}
	s.add("s1", 0, call("", 1000, 0, 0))
	s.add("s1", sec, result("", "Bash", "go test", 1e6))
	s.add("s1", 2*sec, call("", 900000, 0, 0))
	sessions := []agentlogdb.AgentReportSession{{SessionUUID: "s1"}, {SessionUUID: "s2", OldFormat: true}}
	r := Context(sessions, s, []agentlogdb.AgentContextPart{part("s1", "", "instructions", 1e6)}, "")

	assert.Equal(t, 0, r.FactsSessions)
	assert.Equal(t, 2, r.Sessions)
	assert.Empty(t, r.Growth)
	assert.NotNil(t, r.Growth)
	assert.NotNil(t, r.TopSources)
	assert.NotNil(t, r.RepeatedReads)
	assert.NotNil(t, r.Baseline.Parts)
	assert.Zero(t, r.Baseline.Tokens)

	in := eventsInput(s)
	in.Context = r
	for _, id := range []string{"C1", "C2", "C3"} {
		assert.Empty(t, hintsOf(Hints(in), id))
	}
}

func TestContext_DiskSizes(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "CLAUDE.md"), []byte("a\nb\nc\n"), 0o644))
	require.NoError(t, os.MkdirAll(filepath.Join(dir, ".claude", "rules", "sub"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".claude", "rules", "x.md"), []byte("0123456789"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".claude", "rules", "sub", "y.md"), []byte("01234"), 0o644))

	r := Context(nil, nil, nil, dir)
	assert.Equal(t, DiskSizes{ClaudeMDBytes: 6, ClaudeMDLines: 3, RulesBytes: 15}, r.Disk)

	assert.Equal(t, DiskSizes{}, Context(nil, nil, nil, filepath.Join(dir, "missing")).Disk)
	assert.Equal(t, DiskSizes{}, Context(nil, nil, nil, "").Disk)
}

func TestHintC1_InstructionsHeavy(t *testing.T) {
	in := HintInput{Events: evset{"s1": nil, "s2": nil}}
	in.Context.Disk.ClaudeMDBytes = 100
	in.Context.Baseline = BaselineSplit{Tokens: 10000, lanes: 4, sessions: []string{"s2", "s1"},
		Parts: []PartShare{{Part: "tools", Tokens: 7000, Share: 0.7}, {Part: "instructions", Tokens: 3000, Share: 0.3}}}
	hs := hintsOf(Hints(in), "C1")
	require.Len(t, hs, 1)
	assert.Equal(t, int64(12000), hs[0].EstimateTokens)
	assert.Equal(t, &Fix{Kind: FixOpenFile, Ref: "CLAUDE.md"}, hs[0].Fix)
	assert.Equal(t, []string{"s2", "s1"}, evidence(hs[0], "session"))
	assert.Contains(t, hs[0].Finding, "30%")
	assert.NotContains(t, hs[0].Finding, "subagent")

	in.Context.SubagentBaseline = BaselineSplit{Tokens: 1000, lanes: 2, Parts: []PartShare{{Part: "instructions", Tokens: 600, Share: 0.6}}}
	hs = hintsOf(Hints(in), "C1")
	require.Len(t, hs, 1)
	assert.Contains(t, hs[0].Finding, "60% of a subagent's")

	in.Context.Disk.ClaudeMDBytes = 0 // no CLAUDE.md in the folder: nothing to open
	hs = hintsOf(Hints(in), "C1")
	require.Len(t, hs, 1)
	assert.Nil(t, hs[0].Fix)
	assert.NotEmpty(t, hs[0].Action)

	in.Context.Baseline.Parts[1].Share = 0.2
	assert.Empty(t, hintsOf(Hints(in), "C1"), "at the line, not above it")
}

func TestHintC2_BigSource(t *testing.T) {
	in := HintInput{Events: evset{"s1": nil, "s2": nil}}
	in.Context.Growth = []GrowthRow{{Source: "Bash", Tokens: 200000}, {Source: "Read", Tokens: 150000}, {Source: "model", Tokens: 150000}}
	in.Context.TopSources = []SourceRow{
		{Tool: "Bash", Target: "go test", Tokens: 120000, Calls: 3, Sessions: 1, sessions: []string{"s1"}},
		{Tool: "Read", Target: "big.go", Tokens: 60000, Calls: 2, Sessions: 1, sessions: []string{"s1"}},
		{Tool: "Read", Target: "other.go", Tokens: 55000, Calls: 1, Sessions: 2, sessions: []string{"s1", "s2"}},
		{Tool: "mcp__srv__q", Target: "x", Tokens: 51000, Calls: 1, Sessions: 1, sessions: []string{"s1"}},
		{Tool: "Bash", Target: "ls", Tokens: 49000, Calls: 9, Sessions: 1, sessions: []string{"s1"}}, // under SourceTokensMin
	}
	hs := hintsOf(Hints(in), "C2")
	require.Len(t, hs, 3, "one hint per tool")
	assert.Equal(t, []int64{120000, 115000, 51000}, []int64{hs[0].EstimateTokens, hs[1].EstimateTokens, hs[2].EstimateTokens}, "ranked by tokens")
	assert.Equal(t, []string{"go test"}, evidence(hs[0], "command"))
	assert.Equal(t, []string{"Read"}, evidence(hs[1], "command"), "one command item per verb")
	assert.Equal(t, []string{"s1", "s2"}, evidence(hs[1], "session"))
	assert.Equal(t, "Read added 115.0k tokens to the context over 3 calls, 23% of its growth: big.go, other.go", hs[1].Finding)
	assert.Contains(t, hs[0].Action, "head")
	assert.Contains(t, hs[1].Action, "offset/limit")
	assert.Equal(t, msgs["c2.action.other"][English], hs[2].Action)

	// the same tokens under SourceShareMin of a larger growth
	in.Context.Growth = append(in.Context.Growth, GrowthRow{Source: "reminders", Tokens: 2e6})
	assert.Empty(t, hintsOf(Hints(in), "C2"))
}

func TestHintC3_RepeatedReads(t *testing.T) {
	in := HintInput{Events: evset{"s1": nil, "s2": nil}}
	in.Context.RepeatedReads = []RepeatRow{
		{Target: "a.go", Reads: 4, Session: "s2", Tokens: 30000, sessions: []sessionTokens{{"s1", 5000}, {"s2", 25000}}},
		{Target: "b.go", Reads: 3, Session: "s1", Tokens: 8000, sessions: []sessionTokens{{"s1", 8000}}},
		{Target: "c.go", Reads: 3, Session: "s1", sessions: []sessionTokens{{"s1", 0}}}, // not measured
	}
	hs := hintsOf(Hints(in), "C3")
	require.Len(t, hs, 1, "one combined hint")
	assert.Equal(t, int64(38000), hs[0].EstimateTokens)
	assert.Equal(t, &Fix{Kind: FixOpenSession, Ref: "s2"}, hs[0].Fix)
	assert.Equal(t, []string{"s2", "s1"}, evidence(hs[0], "session"), "by repeat tokens: s2 25k, s1 13k")
	assert.Equal(t, "Re-reads of 2 files (3+ times in one session) added 38.0k tokens; the most: a.go, read 4 times in session s2", hs[0].Finding)

	in.Context.RepeatedReads = in.Context.RepeatedReads[1:] // 8k: under RepeatTokensMin
	assert.Empty(t, hintsOf(Hints(in), "C3"))
}

// The context rules cite sessions and commands of the input only (the
// AGENTLOG-07 rule, over contextRulesInput).
func TestHintsC_CiteEvidence(t *testing.T) {
	in := contextRulesInput()
	hs := Hints(in)
	ids := map[string]bool{}
	for _, h := range hs {
		ids[h.ID] = true
		require.NotEmpty(t, h.Evidence, h.ID)
		for _, e := range h.Evidence {
			switch e.Kind {
			case "session":
				_, ok := in.Events[e.Ref]
				assert.True(t, ok, "%s cites unknown session %q", h.ID, e.Ref)
			case "command":
				assert.Contains(t, []string{"go test", "Read"}, e.Ref, h.ID)
			default:
				t.Errorf("%s: unexpected evidence kind %q", h.ID, e.Kind)
			}
		}
	}
	assert.Equal(t, map[string]bool{"C1": true, "C2": true, "C3": true}, ids)
}

// contextRulesInput fires C1–C3 once each, from stored-shaped rows.
func contextRulesInput() HintInput {
	s := evset{}
	s.add("s1", 0, call("", 10000, 0, 0))
	s.add("s1", sec, result("", "Bash", "go test", 400000))
	s.add("s1", 2*sec, call("", 160000, 0, 0))
	ctx := int64(160000)
	for i := range 3 {
		ctx += 30000
		s.add("s1", time.Duration(2*i+3)*sec, result("", "Read", "a.go", 78000))
		s.add("s1", time.Duration(2*i+4)*sec, call("", ctx, 0, 0))
	}
	parts := []agentlogdb.AgentContextPart{part("s1", "", "instructions", 4000), part("s1", "", "tools", 6000)}
	in := eventsInput(s)
	in.Context = Context(factsOf(s), s, parts, "")
	return in
}
