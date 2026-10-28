package agentreport

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func leadFixture() (ContextReport, SkillsReport, TroubleReport) {
	c := ContextReport{FactsSessions: 3, Baseline: BaselineSplit{Tokens: 12_300, Parts: []PartShare{
		{Part: "tools", Tokens: 5_000, Share: 0.41}, {Part: "instructions", Tokens: 3_000, Share: 0.24}}}}
	s := SkillsReport{FactsSessions: 3, Listed: 40, Used: 12, ListingTokens: 2_500}
	tr := TroubleReport{
		Classes: []ErrorClassRow{{Class: "edit_no_match", Count: 5}, {Class: "exit_code", Count: 2}},
		denials: []denialAgg{{DenialRow: DenialRow{Kind: "automode-blocked", Tool: "Bash", Count: 3}}},
	}
	return c, s, tr
}

func TestLead_Context_EnRu(t *testing.T) {
	c, _, _ := leadFixture()
	assert.Equal(t, "Every session starts with 12.3k tokens; tool schemas is 41%, CLAUDE.md & rules 24%.", contextLead(English, c))
	assert.Equal(t, "Каждая сессия стартует с 12,3 тыс. токенов; схемы инструментов — 41%, CLAUDE.md и правила — 24%.", contextLead(Russian, c))
	c.FactsSessions = 0
	assert.Empty(t, contextLead(English, c))
}

func TestLead_Skills_EnRu(t *testing.T) {
	_, s, _ := leadFixture()
	assert.Equal(t, "The skill list costs 2500 tokens per session; 28 of 40 skills were not used in this period.", skillsLead(English, s))
	assert.Equal(t, "Список скиллов — 2500 токенов в каждой сессии; 28 из 40 не вызывались за период.", skillsLead(Russian, s))
	s.Listed = 0
	assert.Empty(t, skillsLead(English, s))
}

func TestLead_Trouble_EnRu(t *testing.T) {
	_, _, tr := leadFixture()
	assert.Equal(t, "7 failed calls and 3 permission denials; most of them edit_no_match.", troubleLead(English, tr))
	assert.Equal(t, "7 упавших вызовов и 3 отказа в разрешении; чаще всего — edit_no_match.", troubleLead(Russian, tr))
	tr.Classes = nil
	assert.Equal(t, "0 failed calls and 3 permission denials; most of them Bash.", troubleLead(English, tr))
	tr.Classes = []ErrorClassRow{{Count: 4}} // class stored as "": other
	assert.Equal(t, "4 failed calls and 3 permission denials; most of them other.", troubleLead(English, tr))
	tr.Classes = []ErrorClassRow{{Count: 1}}
	tr.denials = nil
	assert.Equal(t, "1 failed call and 0 permission denials; most of them other.", troubleLead(English, tr))
	assert.Empty(t, troubleLead(English, TroubleReport{}))
}

func TestAGENTLOG01_LeadHoldsNoEventText(t *testing.T) {
	const secret = "SECRET-EVENT-TEXT"
	s := evset{}
	s.add("s1", 0, failed("Bash", secret, "exit_code", sec))
	s.add("s1", sec, denied("Bash", secret, "automode-blocked", sec))
	tr := troubleOf(s)
	assert.NotEmpty(t, tr.denials)
	for _, l := range []Lang{English, Russian} {
		c, sk, _ := leadFixture()
		a, b, d := leads(l, c, sk, tr)
		for _, lead := range []string{a, b, d} {
			assert.NotContains(t, lead, secret)
		}
		assert.NotEmpty(t, d)
	}
}
