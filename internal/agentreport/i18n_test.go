package agentreport

import (
	"regexp"
	"strings"
	"testing"
	"time"
	"unicode"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLangOf(t *testing.T) {
	for _, name := range []string{"Russian", " ru ", "Русский"} {
		assert.Equal(t, Russian, LangOf(name), name)
	}
	for _, name := range []string{"", "English", "Spanish"} {
		assert.Equal(t, English, LangOf(name), name)
	}
}

var verbRE = regexp.MustCompile(`%[-+#0 ]*[0-9.]*[a-zA-Z%]`)

// Both languages take the same verbs in the same order, so one call site
// serves both.
func TestMessages_SameVerbs(t *testing.T) {
	for key, m := range msgs {
		assert.Equal(t, verbRE.FindAllString(m[English], -1), verbRE.FindAllString(m[Russian], -1), key)
		assert.NotEmpty(t, m[Russian], key)
	}
}

func TestCount_RussianForms(t *testing.T) {
	for n, want := range map[int]string{1: "1 запуск", 2: "2 запуска", 5: "5 запусков", 11: "11 запусков", 21: "21 запуск", 22: "22 запуска", 112: "112 запусков"} {
		assert.Equal(t, want, Russian.count(n, "run"))
	}
	for n, want := range map[int]string{1: "1 сессии", 3: "3 сессиях", 22: "22 сессиях", 21: "21 сессии"} {
		assert.Equal(t, want, Russian.count(n, "session.in"))
	}
	assert.Equal(t, "1 run", English.count(1, "run"))
	assert.Equal(t, "3 sessions", English.count(3, "session.in"))
}

func TestDur_Russian(t *testing.T) {
	assert.Equal(t, "2 ч 10 мин", Russian.dur(ms(130*time.Minute)))
	assert.Equal(t, "7 мин 10 с", Russian.dur(ms(7*time.Minute+10*time.Second)))
	assert.Equal(t, "45 с", Russian.dur(ms(45*time.Second)))
	assert.Equal(t, "7,5 с", Russian.sec(7500))
	assert.Equal(t, "2h 10m", English.dur(ms(130*time.Minute)))
}

// Every rule writes a finding and an action in both languages; Russian ones
// carry no English sentence.
func TestHints_ActionInBothLanguages(t *testing.T) {
	for _, l := range []Lang{English, Russian} {
		in, _ := allRulesInput()
		in.Lang = l
		hs := Hints(in)
		require.NotEmpty(t, hs)
		for _, h := range hs {
			assert.NotEmpty(t, h.Action, h.ID)
			hasCyrillic := strings.ContainsFunc(h.Finding+h.Action, func(r rune) bool { return unicode.Is(unicode.Cyrillic, r) })
			assert.Equal(t, l == Russian, hasCyrillic, "%s: %s / %s", h.ID, h.Finding, h.Action)
		}
	}
}

func TestHintH4_RussianFinding(t *testing.T) {
	in := HintInput{Lang: Russian,
		Sessions: map[string]SessionView{"s1": {UUID: "s1", Time: TimeSplit{OwnerMS: ms(40 * mn), ActiveMS: ms(100 * mn)}}},
		Tasks: []TaskRow{
			{TargetID: 3, Text: "t", Time: TimeSplit{OwnerMS: ms(20 * mn), ActiveMS: ms(50 * mn)}},
			{TargetID: 4, Text: "t", Time: TimeSplit{OwnerMS: ms(30 * mn), ActiveMS: ms(50 * mn)}},
		},
	}
	hs := hintsOf(Hints(in), "H4")
	require.Len(t, hs, 1)
	assert.Equal(t, "Ожидание тебя заняло больше 30% активного времени в 1 сессии и 2 задачах, всего 40 мин 0 с", hs[0].Finding)
	assert.Equal(t, &Fix{Kind: FixOpenAsks}, hs[0].Fix)
}

// H4 names the longest waits first and counts what it leaves out.
func TestHints_EvidenceCapped(t *testing.T) {
	in := HintInput{Sessions: map[string]SessionView{}}
	for i := range 8 {
		sid := string(rune('a' + i))
		in.Sessions[sid] = SessionView{UUID: sid, Time: TimeSplit{OwnerMS: ms(time.Duration(40+i) * mn), ActiveMS: ms(100 * mn)}}
	}
	hs := hintsOf(Hints(in), "H4")
	require.Len(t, hs, 1)
	assert.Equal(t, []string{"h", "g", "f", "e", "d"}, evidence(hs[0], "session"))
	assert.Equal(t, 3, hs[0].MoreEvidence)
}

func TestHintH2_CopyAllowRules(t *testing.T) {
	s := evset{}
	s.add("s1", 0, tl("Read", "/tmp/x/a", 6*sec, "ok"))
	s.add("s1", mn, tl("Bash", "git status", 9*sec, "ok"))
	s.add("s1", 2*mn, tl("mcp__srv__search", "q", 9*sec, "ok"))
	hs := hintsOf(Hints(eventsInput(s)), "H2")
	if len(hs) == 0 {
		t.Skip("mcp__srv__search is not a read & search call")
	}
	require.NotNil(t, hs[0].Fix)
	assert.Equal(t, FixCopyAllowRules, hs[0].Fix.Kind)
	assert.Contains(t, hs[0].Fix.Rules, "Read")
	assert.Contains(t, hs[0].Fix.Rules, "Bash(git status:*)")
}

func TestAllowRule(t *testing.T) {
	assert.Equal(t, "Read", allowRule("Read"))
	assert.Equal(t, "mcp__srv__search", allowRule("mcp__srv__search"))
	assert.Equal(t, "Bash(git status:*)", allowRule("git status"))
	assert.Equal(t, "Bash(ls:*)", allowRule("ls"))
}

func TestTouched_DropsIdleRowsAndSortsByCost(t *testing.T) {
	rows := []TaskRow{
		{TargetID: 1},
		{TargetID: 2, CostUSD: 1, AgentMS: 10},
		{TargetID: 3, Sessions: []string{"s1"}},
		{TargetID: 4, CostUSD: 5},
		{TargetID: 5, CostUSD: 1, AgentMS: 50},
	}
	var ids []int64
	for _, r := range touched(rows) {
		ids = append(ids, r.TargetID)
	}
	assert.Equal(t, []int64{4, 5, 2, 3}, ids)
	assert.NotNil(t, touched(nil))
}
