package agentreport

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
)

// failed is a tool call that failed with class (dur < 0 = no duration).
func failed(name, target, class string, dur time.Duration) agentlogdb.AgentReportEvent {
	e := tl(name, target, dur, "error")
	e.ErrorClass = class
	return e
}

// denied is a tool call denied with kind.
func denied(name, target, kind string, dur time.Duration) agentlogdb.AgentReportEvent {
	e := tl(name, target, dur, "denied")
	e.ErrorClass = kind
	return e
}

func interrupt() agentlogdb.AgentReportEvent {
	return agentlogdb.AgentReportEvent{Kind: "owner_turn", Trigger: "interrupt"}
}

func troubleOf(s evset) TroubleReport { return Trouble(factsOf(s), s, nil, t0.Add(2*time.Hour)) }

func TestTrouble_ClassesBySessions(t *testing.T) {
	s := evset{}
	for i := range 3 {
		s.add("s1", time.Duration(i)*sec, failed("Edit", "a.go", "edit_no_match", 2*sec))
	}
	s.add("s2", 0, failed("Edit", "b.go", "edit_no_match", sec))
	s.add("s2", sec, failed("MultiEdit", "b.go", "edit_no_match", sec))
	s.add("s2", 2*sec, failed("Edit", "b.go", "edit_no_match", sec))
	s.add("s1", 10*sec, failed("Bash", "go test", "exit_code", sec))
	s.add("s1", 11*sec, failed("Bash", "ls", "", sec)) // no class stored: other
	s.add("s1", 12*sec, tl("Read", "a.go", sec, "ok"))
	sessions := append(factsOf(s), agentlogdb.AgentReportSession{SessionUUID: "s9"}) // parser v2: not measured
	s.add("s9", 0, failed("Edit", "c.go", "edit_no_match", sec))

	r := Trouble(sessions, s, nil, t0)
	assert.Equal(t, 2, r.FactsSessions)
	require.Len(t, r.Classes, 3)
	assert.Equal(t, ErrorClassRow{Class: "edit_no_match", Tool: "Edit", Count: 6,
		Sessions: []SessionCount{{"s1", 3}, {"s2", 3}}, ms: ms(15 * sec), nSessions: 2}, r.Classes[0],
		"s1: 2s, 2s, then 8s to the next event; s2: 1s each")
	assert.Equal(t, "exit_code", r.Classes[1].Class)
	assert.Equal(t, "other", r.Classes[2].Class)
	assert.Equal(t, "Bash", r.Classes[2].Tool)
}

func TestTrouble_DenialsAndRules(t *testing.T) {
	s := evset{}
	s.add("s1", 0, denied("Bash", "rm", "automode-blocked", sec))
	s.add("s1", sec, denied("Bash", "rm", "automode-blocked", sec))
	s.add("s2", 0, denied("Bash", "", "permission-rule", sec))
	s.add("s2", sec, denied("Read", "/tmp/x/a", "user-rejected", sec)) // a rejection, not a denial

	r := troubleOf(s)
	require.Len(t, r.Denials, 2)
	assert.Equal(t, []DenialRow{{Kind: "automode-blocked", Tool: "Bash", Target: "rm", Count: 2},
		{Kind: "permission-rule", Tool: "Bash", Target: "", Count: 1}}, r.Denials)
	require.Len(t, r.denials, 2)
	assert.Equal(t, "rm", r.denials[0].verb)
	assert.Equal(t, "Bash", r.denials[1].verb, "an empty target uses the tool name")
	assert.Equal(t, 1, r.Rejections)
}

func TestTrouble_InterruptsAndRejections(t *testing.T) {
	s := evset{}
	s.add("s1", 0, call("", 1000, 0, 0))
	s.add("s1", 2*mn, interrupt())                                   // the turn since 0: 2m lost
	s.add("s1", 3*mn, ownerTurn())                                   // a new turn
	s.add("s1", 5*mn, denied("Bash", "rm", "user-rejected", 10*sec)) // 2m10s lost, the turn goes on from 5m10s
	s.add("s1", 5*mn+10*sec, interrupt())                            // right after the rejection: nothing more
	s.add("s2", 0, call("", 1000, 0, 0))
	s.add("s2", mn, interrupt())

	r := troubleOf(s)
	assert.Equal(t, 3, r.Interrupts)
	assert.Equal(t, 1, r.Rejections)
	assert.Equal(t, []SessionCount{{"s1", 3}, {"s2", 1}}, r.InterruptSessions)
	assert.Equal(t, []sessionTrouble{{sid: "s1", count: 3, ms: ms(4*mn + 10*sec)}, {sid: "s2", count: 1, ms: ms(mn)}}, r.interrupts)
}

func TestTrouble_UnfinishedSubagents(t *testing.T) {
	now := t0.Add(5 * time.Hour)
	yes, no := true, false
	sessions := []agentlogdb.AgentReportSession{
		{SessionUUID: "s1", Facts: true, EndedAt: now.Add(-2 * time.Hour).Format(tsLayout)},
		{SessionUUID: "s2", Facts: true, EndedAt: now.Add(-10 * time.Minute).Format(tsLayout)},
	}
	subs := []agentlogdb.AgentSubagent{
		{SessionUUID: "s1", AgentID: "a", Finished: &yes},
		{SessionUUID: "s1", AgentID: "b", Finished: &no},
		{SessionUUID: "s1", AgentID: "c"},                // no flag: unknown, never unfinished
		{SessionUUID: "s2", AgentID: "d"},                // unknown, the session ended 10m ago: may still run
		{SessionUUID: "s2", AgentID: "e", Finished: &no}, // not yet, the session ended 10m ago: may still run
		{SessionUUID: "s9", AgentID: "f", Finished: &no}, // not a session of the period
	}
	r := Trouble(sessions, evset{}, subs, now)
	assert.Equal(t, 1, r.UnfinishedSubagents, "b only")
}

func TestTrouble_RateLimited(t *testing.T) {
	s := evset{}
	s.add("s1", 0, agentlogdb.AgentReportEvent{Kind: "api_error", ErrorClass: "429"})
	s.add("s1", sec, agentlogdb.AgentReportEvent{Kind: "api_error", ErrorClass: "429"})
	s.add("s2", 0, agentlogdb.AgentReportEvent{Kind: "api_error", ErrorClass: "500"})
	r := troubleOf(s)
	assert.Equal(t, 2, r.RateLimited)
	assert.NotNil(t, r.Classes)
	assert.NotNil(t, r.Denials)
	assert.NotNil(t, r.InterruptSessions)
}

func troubleInput(s evset) HintInput {
	in := eventsInput(s)
	in.Trouble = troubleOf(s)
	return in
}

func TestHintT1_PerClassAction(t *testing.T) {
	s := evset{}
	add := func(sid, name, class string, n int, dur time.Duration) {
		for range n {
			s.add(sid, time.Duration(len(s[sid]))*sec, failed(name, "x", class, dur))
		}
	}
	add("s1", "Edit", "edit_no_match", 2, 2*sec)
	add("s2", "Edit", "edit_no_match", 3, 2*sec) // s2 has the most
	add("s1", "Read", "too_large", 6, sec)
	add("s1", "Bash", "exit_code", 9, sec)      // H5's
	add("s1", "Bash", "other", 7, sec)          // no action
	add("s1", "Read", "not_found", 8, sec)      // no action
	add("s1", "Agent", "input_invalid", 4, sec) // under ClassMin
	add("s1", "Agent", "agent_limit", 5, -1)    // no duration: the time to the next event

	hs := hintsOf(Hints(troubleInput(s)), "T1")
	require.Len(t, hs, 3)
	edit, large, limit := hs[0], hs[1], hs[2]
	assert.Equal(t, ms(10*sec), edit.EstimateMS)
	assert.Equal(t, "Re-read before editing; give more context in old_string.", edit.Action)
	assert.Equal(t, &Fix{Kind: FixOpenSession, Ref: "s2"}, edit.Fix)
	assert.Equal(t, []string{"s2", "s1"}, evidence(edit, "session"))
	assert.Equal(t, "Edit found no match for old_string: 5 times, mostly from Edit, in 2 sessions; the failed calls took 10s", edit.Finding)
	assert.Equal(t, ms(6*sec), large.EstimateMS)
	assert.Equal(t, "Read large files with offset/limit.", large.Action)
	assert.Equal(t, ms(4*sec), limit.EstimateMS, "four calls 1s before the next, the last has no next and no duration")

	for class, action := range map[string]string{
		"isolation_block":  "Add the rule to the folder's workflow so agents stay in their worktree.",
		"unknown_agent":    "Fix the skill or agent definition that names it.",
		"no_such_tool":     "Fix the skill or agent definition that names it.",
		"input_invalid":    "The tool's arguments are wrong — check the skill that calls it.",
		"edit_multi_match": "Re-read before editing; give more context in old_string.",
		"stale_read":       "Re-read before editing; give more context in old_string.",
		"sleep_blocked":    "Use background tasks and notifications instead of sleep.",
		"agent_limit":      "Start fewer subagents at once.",
	} {
		one := evset{}
		for i := range ClassMin {
			one.add("s1", time.Duration(i)*sec, failed("Bash", "x", class, sec))
		}
		got := hintsOf(Hints(troubleInput(one)), "T1")
		require.Len(t, got, 1, class)
		assert.Equal(t, action, got[0].Action, class)
	}
}

func TestHintT2_CopyRules(t *testing.T) {
	s := evset{}
	for i := range 3 {
		s.add("s1", time.Duration(i)*10*sec, denied("Bash", "go test", "automode-blocked", sec)) // 10s, 10s, then 1s: 21s
	}
	for i := range 3 {
		s.add("s2", time.Duration(i)*sec, denied("mcp__srv__q", "q", "permission-rule", sec))
	}
	for i := range 3 {
		s.add("s2", time.Duration(i+3)*sec, denied("Bash", "rm", "automode-blocked", sec))
	}
	for i := range 4 {
		s.add("s2", time.Duration(i+6)*sec, denied("Bash", "", "permission-rule", 2*sec))
	}
	for i := range 5 {
		s.add("s3", time.Duration(i)*sec, denied("WebFetch", "", "automode-unavailable", sec)) // not a rule's to fix
	}
	s.add("s3", 10*sec, denied("Read", "a.go", "automode-blocked", sec)) // under DenialMin
	s.add("s3", 11*sec, denied("Read", "b.go", "user-rejected", sec))

	hs := hintsOf(Hints(troubleInput(s)), "T2")
	require.Len(t, hs, 1, "one hint")
	h := hs[0]
	assert.Equal(t, &Fix{Kind: FixCopyAllowRules, Rules: []string{"Bash(go test:*)", "mcp__srv__q"}}, h.Fix,
		"no rule for a bare Bash or for rm")
	assert.Equal(t, ms(35*sec), h.EstimateMS)
	assert.Equal(t, "Allow them in .claude/settings.json.", h.Action)
	assert.Equal(t, []string{"Bash", "go test", "mcp__srv__q", "rm"}, evidence(h, "command"))
	assert.Equal(t, []string{"s2"}, evidence(h, "session"), "cut to evidenceMax")
	assert.Equal(t, 1, h.MoreEvidence)
	assert.Equal(t, "Auto mode or a permission rule blocked 13 calls of 4 commands, 35s in all: Bash, go test, mcp__srv__q, rm", h.Finding)
}

// A Bash denial with no target and an rm denial get no allow rule: the hint
// has no fix and asks to review them.
func TestHintT2_NoRuleForUnsafeCommands(t *testing.T) {
	s := evset{}
	for i := range 3 {
		s.add("s1", time.Duration(2*i)*sec, denied("Bash", "", "permission-rule", sec))
		s.add("s1", time.Duration(2*i+1)*sec, denied("Bash", "rm", "automode-blocked", sec))
	}
	hs := hintsOf(Hints(troubleInput(s)), "T2")
	require.Len(t, hs, 1)
	assert.Nil(t, hs[0].Fix)
	assert.Equal(t, "Review the blocked commands: change how the agent runs them, or allow the safe ones in .claude/settings.json yourself.",
		hs[0].Action)
	assert.Equal(t, []string{"Bash", "rm"}, evidence(hs[0], "command"))
}

// The file-writing tools never get an allow rule, whoever blocked them.
func TestHintT2_NoRuleForFileWrites(t *testing.T) {
	s := evset{}
	for i, tool := range []string{"Write", "Edit", "MultiEdit", "NotebookEdit"} {
		for j := range 3 {
			s.add("s1", time.Duration(10*i+j)*sec, denied(tool, "a.go", "automode-blocked", sec))
		}
	}
	hs := hintsOf(Hints(troubleInput(s)), "T2")
	require.Len(t, hs, 1)
	assert.Nil(t, hs[0].Fix, "no copy rule for a file write")
}

// Failed edits of a T1 class are T1's, not an H5 loop; rows with no class
// (parser v2) still make one.
func TestHintT1_NotAnH5Loop(t *testing.T) {
	for _, tc := range []struct {
		class  string
		t1, h5 int
	}{{"edit_no_match", 1, 0}, {"", 0, 1}} {
		s := evset{}
		for i := range 5 {
			s.add("s1", time.Duration(i)*sec, failed("Edit", "a.go", tc.class, sec))
		}
		hs := Hints(troubleInput(s))
		assert.Len(t, hintsOf(hs, "T1"), tc.t1, tc.class)
		assert.Len(t, hintsOf(hs, "H5"), tc.h5, tc.class)
	}
}

func TestHintT3_Interrupts(t *testing.T) {
	s := evset{}
	s.add("s1", 0, call("", 1000, 0, 0))
	s.add("s1", 2*mn, interrupt())
	s.add("s1", 3*mn, ownerTurn())
	s.add("s1", 5*mn, denied("Bash", "rm", "user-rejected", 10*sec))
	s.add("s1", 5*mn+10*sec, interrupt())
	s.add("s2", 0, call("", 1000, 0, 0))
	s.add("s2", mn, interrupt()) // one: under InterruptMin
	s.add("s3", 0, call("", 1000, 0, 0))
	for i := range 4 {
		s.add("s3", time.Duration(i+1)*mn, interrupt())
	}

	hs := hintsOf(Hints(troubleInput(s)), "T3")
	require.Len(t, hs, 1, "one hint for every session over the line")
	h := hs[0]
	assert.Equal(t, ms(4*mn+10*sec+4*mn), h.EstimateMS)
	assert.Equal(t, []string{"s3", "s1"}, evidence(h, "session"), "the most interrupts first")
	assert.Equal(t, &Fix{Kind: FixOpenSession, Ref: "s3"}, h.Fix)
	assert.Equal(t, "Write the expectation into the folder rules or agree a plan before the agent starts.", h.Action)
	assert.Equal(t, "You stopped or rejected the agent 3+ times in 2 sessions (7 times in all); the stopped work took 8m 10s", h.Finding)
}

// The trouble rules cite sessions and commands of the input only (the
// AGENTLOG-07 rule, over troubleRulesInput).
func TestHintsT_CiteEvidence(t *testing.T) {
	in := troubleRulesInput()
	verbs := map[string]bool{}
	for _, evs := range in.Events {
		for _, e := range evs {
			if e.Kind == "tool" {
				verbs[verb(e)], verbs[e.Name] = true, true
			}
		}
	}
	ids := map[string]bool{}
	for _, h := range Hints(in) {
		ids[h.ID] = true
		require.NotEmpty(t, h.Evidence, h.ID)
		for _, e := range h.Evidence {
			switch e.Kind {
			case "session":
				_, ok := in.Events[e.Ref]
				assert.True(t, ok, "%s cites unknown session %q", h.ID, e.Ref)
			case "command":
				assert.True(t, verbs[e.Ref], "%s cites unknown command %q", h.ID, e.Ref)
			default:
				t.Errorf("%s: unexpected evidence kind %q", h.ID, e.Kind)
			}
		}
	}
	assert.Equal(t, map[string]bool{"T1": true, "T2": true, "T3": true}, ids)
}

// troubleRulesInput fires T1–T3 once each.
func troubleRulesInput() HintInput {
	s := evset{}
	for i := range ClassMin {
		s.add("s1", time.Duration(i)*sec, failed("Edit", "a.go", "edit_no_match", sec))
	}
	for i := range DenialMin {
		s.add("s1", time.Duration(10+i)*sec, denied("Bash", "go test", "automode-blocked", sec))
	}
	for i := range InterruptMin {
		s.add("s2", time.Duration(i+1)*mn, interrupt())
	}
	return troubleInput(s)
}
