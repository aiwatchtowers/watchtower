package agentreport

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
)

func skillEv(name, trigger string) agentlogdb.AgentReportEvent {
	return agentlogdb.AgentReportEvent{Kind: "skill", Name: name, Trigger: trigger}
}

func listed(sid, skill string, bytes int64) agentlogdb.AgentSkillListed {
	return agentlogdb.AgentSkillListed{SessionUUID: sid, Skill: skill, Bytes: bytes}
}

// spanned lists sessions s0..s(n-1), one every other day from t0, each an
// hour long.
func spanned(n int, facts bool) []agentlogdb.AgentReportSession {
	var out []agentlogdb.AgentReportSession
	for i := range n {
		start := t0.Add(time.Duration(i) * 48 * time.Hour)
		out = append(out, agentlogdb.AgentReportSession{SessionUUID: fmt.Sprintf("s%d", i), Facts: facts,
			StartedAt: start.Format(tsLayout), EndedAt: start.Add(time.Hour).Format(tsLayout)})
	}
	return out
}

func rowOf(r SkillsReport, name string) (SkillRow, bool) {
	for _, row := range r.Rows {
		if row.Name == name {
			return row, true
		}
	}
	return SkillRow{}, false
}

func unusedNames(r SkillsReport) []string {
	out := []string{}
	for _, u := range r.NeverUsed {
		out = append(out, u.Name)
	}
	return out
}

func TestSkills_ListedVsUsed(t *testing.T) {
	s := evset{}
	s.add("s1", 0, skillEv("review", "proactive"))
	s.add("s1", sec, skillEv("review", "proactive"))
	s.add("s1", 2*sec, skillEv("deploy", "slash"))
	s.add("s2", 0, skillEv("review", "slash"))
	s.add("s2", sec, skillEv("notes", "read")) // a SKILL.md read is a use too
	listing := []agentlogdb.AgentSkillListed{
		listed("s1", "deploy", 100), listed("s1", "idle", 100), listed("s1", "notes", 100), listed("s1", "review", 100),
		listed("s2", "idle", 100), listed("s2", "review", 100),
	}
	r := Skills(factsOf(s), s, nil, listing)

	assert.Equal(t, 2, r.FactsSessions)
	assert.Equal(t, 4, r.Listed)
	assert.Equal(t, 3, r.Used)
	require.Len(t, r.Rows, 3)
	assert.Equal(t, "review", r.Rows[0].Name, "by invocations, most first")
	assert.Equal(t, 3, r.Rows[0].Invocations)
	assert.Equal(t, 2, r.Rows[0].Sessions)
	assert.Equal(t, map[string]int{"proactive": 2, "slash": 1, "read": 0}, r.Rows[0].ByTrigger)
	deploy, ok := rowOf(r, "deploy")
	require.True(t, ok)
	assert.Equal(t, map[string]int{"proactive": 0, "slash": 1, "read": 0}, deploy.ByTrigger)
	notes, ok := rowOf(r, "notes")
	require.True(t, ok)
	assert.Equal(t, 1, notes.ByTrigger["read"])
	assert.Equal(t, []string{"idle"}, unusedNames(r))
}

func TestSkills_CostByAttribution(t *testing.T) {
	s := evset{}
	s.add("s1", 0, skillEv("review", "proactive"))
	a := call("", 1000, 10, 0)
	a.CostUSD, a.Skill = 1.25, "review"
	s.add("s1", sec, a)
	b := call("a1", 1000, 10, 0) // a subagent's call under the skill counts too
	b.CostUSD, b.Skill = 0.5, "review"
	s.add("s1", 2*sec, b)
	c := call("", 1000, 10, 0) // no skill: not a skill's cost
	c.CostUSD = 9
	s.add("s1", 3*sec, c)
	r := Skills(factsOf(s), s, nil, nil)
	require.Len(t, r.Rows, 1)
	assert.InDelta(t, 1.75, r.Rows[0].CostUSD, 1e-9)
}

func TestSkills_NeverUsedSortedByListing(t *testing.T) {
	s := evset{}
	s.add("s1", 0, call("", 2000, 0, 0))
	s.add("s2", 0, call("", 1000, 0, 0))
	s.add("s2", sec, skillEv("used", "proactive"))
	parts := []agentlogdb.AgentContextPart{part("s1", "", "skills", 1000), part("s1", "", "tools", 1000)} // s1: 1 token a byte
	listing := []agentlogdb.AgentSkillListed{
		listed("s1", "big", 400), listed("s1", "small", 100), listed("s1", "used", 500),
		listed("s2", "big", 260), listed("s2", "mid", 520), listed("s2", "small", 26), listed("s2", "used", 26),
	}
	r := Skills(factsOf(s), s, parts, listing)

	// s1 at its own ratio (1 token a byte), s2 with no parts at 2.6 bytes a token
	assert.Equal(t, []string{"big", "mid", "small"}, unusedNames(r))
	assert.Equal(t, int64(250), r.NeverUsed[0].ListingTokens, "median of 400 and 100 tokens")
	assert.Equal(t, int64(200), r.NeverUsed[1].ListingTokens, "listed in s2 only")
	assert.Equal(t, int64(55), r.NeverUsed[2].ListingTokens, "median of 100 and 10 tokens")
	assert.Equal(t, int64(660), r.ListingTokens, "median of the sessions' listings: 1000 and 320 tokens")
	assert.Equal(t, int64(400+100+100+200+10), r.NeverUsed[0].total+r.NeverUsed[1].total+r.NeverUsed[2].total)
}

func TestSkills_OldRowsNotMeasured(t *testing.T) {
	s := evset{}
	s.add("old", 0, skillEv("review", "proactive"))
	s.add("new", 0, skillEv("notes", "slash"))
	sessions := []agentlogdb.AgentReportSession{{SessionUUID: "new", Facts: true}, {SessionUUID: "old"}}
	r := Skills(sessions, s, nil, []agentlogdb.AgentSkillListed{listed("new", "notes", 10)})
	assert.Equal(t, 1, r.FactsSessions)
	assert.Equal(t, 1, r.Used)
	_, ok := rowOf(r, "review")
	assert.False(t, ok, "a v2 session's skill calls are not measured")

	none := Skills([]agentlogdb.AgentReportSession{{SessionUUID: "old"}}, s, nil, nil)
	assert.Equal(t, 0, none.FactsSessions)
	assert.NotNil(t, none.Rows)
	assert.NotNil(t, none.NeverUsed)
}

// skillsRulesInput lists three skills in each of n measured sessions, every
// other day; one is used. At UnusedMinSessions it fires S1 once.
func skillsRulesInput(n int) HintInput {
	s := evset{}
	var listing []agentlogdb.AgentSkillListed
	sessions := spanned(n, true)
	for _, ss := range sessions {
		sid := ss.SessionUUID
		s.add(sid, 0, call("", 1000, 0, 0))
		listing = append(listing, listed(sid, "idle", 2600), listed(sid, "rare", 260), listed(sid, "review", 260))
	}
	s.add("s0", sec, skillEv("review", "proactive"))
	in := eventsInput(s)
	in.Skills = Skills(sessions, s, nil, listing)
	return in
}

func TestHintS1_UnusedSkills(t *testing.T) {
	in := skillsRulesInput(UnusedMinSessions)
	hs := hintsOf(Hints(in), "S1")
	require.Len(t, hs, 1)
	h := hs[0]
	assert.Equal(t, int64((1000+100)*UnusedMinSessions), h.EstimateTokens, "their listing tokens x sessions")
	assert.Equal(t, []string{"idle", "rare"}, evidence(h, "skill"), "the largest listing first")
	assert.Equal(t, "2 of 3 listed skills were never used; listing them took 5.5k tokens in 5 sessions", h.Finding)
	assert.NotEmpty(t, h.Action)
	for _, e := range h.Evidence {
		assert.Contains(t, append(unusedNames(in.Skills), "review"), e.Ref)
	}

	assert.Empty(t, hintsOf(Hints(skillsRulesInput(UnusedMinSessions-1)), "S1"), "4 sessions")

	short := skillsRulesInput(UnusedMinSessions)
	short.Skills.span = UnusedMinDays*24*time.Hour - time.Minute
	assert.Empty(t, hintsOf(Hints(short), "S1"), "under 7 days")
}

// S1 lists the never-used skills as evidence up to the cap and counts the rest.
func TestHintS1_EvidenceCapped(t *testing.T) {
	sessions := spanned(8, true)
	s := evset{}
	var listing []agentlogdb.AgentSkillListed
	for _, ss := range sessions {
		for k := range 8 {
			listing = append(listing, listed(ss.SessionUUID, fmt.Sprintf("k%d", k), int64(100*(k+1))))
		}
	}
	in := eventsInput(s)
	in.Skills = Skills(sessions, s, nil, listing)
	hs := hintsOf(Hints(in), "S1")
	require.Len(t, hs, 1)
	assert.Equal(t, []string{"k7", "k6", "k5", "k4", "k3"}, evidence(hs[0], "skill"))
	assert.Equal(t, 3, hs[0].MoreEvidence)
	assert.Len(t, in.Skills.NeverUsed, 8, "the block lists them all")
}

// The row and never-used keys the Desktop decodes (the cmd fixture has no skills).
func TestSkills_JSONKeys(t *testing.T) {
	s := evset{}
	s.add("s1", 0, skillEv("review", "slash"))
	r := Skills(factsOf(s), s, nil, []agentlogdb.AgentSkillListed{listed("s1", "idle", 26), listed("s1", "review", 26)})
	b, err := json.Marshal(r)
	require.NoError(t, err)
	assert.JSONEq(t, `{"facts_sessions":1,"listed":2,"used":1,"listing_tokens":20,
		"rows":[{"name":"review","invocations":1,"by_trigger":{"proactive":0,"slash":1,"read":0},"cost_usd":0,"sessions":1}],
		"never_used":[{"name":"idle","listing_tokens":10}]}`, string(b))
}

// A SKILL.md read gives the bare folder name; the listing namespaces plugin
// skills. One listed "<plugin>:<name>" match takes the use, several take none.
func TestSkills_BareNameMatchesNamespacedListing(t *testing.T) {
	s := evset{}
	s.add("s1", 0, skillEv("brainstorming", "read"))
	s.add("s1", sec, skillEv("review", "read"))
	listing := []agentlogdb.AgentSkillListed{listed("s1", "plug:brainstorming", 10),
		listed("s1", "a:review", 10), listed("s1", "b:review", 10)}
	r := Skills(factsOf(s), s, nil, listing)
	row, ok := rowOf(r, "plug:brainstorming")
	require.True(t, ok)
	assert.Equal(t, 1, row.ByTrigger["read"])
	_, ok = rowOf(r, "review")
	assert.True(t, ok, "ambiguous: the bare name stays")
	assert.Equal(t, []string{"a:review", "b:review"}, unusedNames(r))
	assert.Equal(t, 1, r.Used, "the unlisted bare review is not counted as used")
	assert.Equal(t, 3, r.Listed)
}

// AGENTLOG-07 rule over an input firing S1 only.
func TestHintsS_CiteEvidence(t *testing.T) {
	in := skillsRulesInput(UnusedMinSessions)
	hs := Hints(in)
	ids := map[string]bool{}
	for _, h := range hs {
		ids[h.ID] = true
		assert.Positive(t, h.EstimateTokens, h.ID)
		require.NotEmpty(t, h.Evidence, h.ID)
		for _, e := range h.Evidence {
			assert.Equal(t, "skill", e.Kind, h.ID)
			assert.Contains(t, unusedNames(in.Skills), e.Ref, h.ID)
		}
	}
	assert.Equal(t, map[string]bool{"S1": true}, ids)
}

func TestHintS1_RussianOneUnused(t *testing.T) {
	in := skillsRulesInput(UnusedMinSessions)
	in.Lang = Russian
	in.Skills.NeverUsed = in.Skills.NeverUsed[:1]
	hs := hintsOf(Hints(in), "S1")
	require.Len(t, hs, 1)
	assert.Equal(t, "1 из 3 навыков в списке ни разу не использовался; их описания заняли 5,0 тыс. токенов в 5 сессиях", hs[0].Finding)
	in.Lang = English
	assert.Equal(t, "1 of 3 listed skills was never used; listing them took 5.0k tokens in 5 sessions", hintsOf(Hints(in), "S1")[0].Finding)
}
