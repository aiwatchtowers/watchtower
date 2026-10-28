package specreview

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/prompts"
)

func TestParse_Severity(t *testing.T) {
	ag := func(status, sev string) string {
		return strings.Replace(agreementJSON("t"+status+sev, "Muting lasts twenty-four hours"), `"status":"as_agreed"`, `"status":"`+status+`","severity":"`+sev+`"`, 1)
	}
	raw := `{"summary":"s","agreements":[` + ag("differs", " BLOCKER ") + `,` + ag("missing", "Major") + `,` + ag("differs", "urgent") + `,` + ag("as_agreed", "major") + `],` +
		`"decided_alone":[{"text":"d","severity":"minor","where":{"heading":"Behaviour","quote":"Muting lasts twenty-four hours"}}],` +
		`"blind_spots":[{"text":"b","why":"w","severity":"\tmajor\n"},{"text":"b2","why":"w","severity":"high"}],` +
		`"checks":[{"chapter":"ch:1","lens":"promises","question":"q1","answer":"concern","severity":"blocker"},` +
		`{"chapter":"ch:1","lens":"promises","question":"q2","answer":"ok","severity":"blocker"},` +
		`{"chapter":"ch:1","lens":"promises","question":"q3","answer":"n/a","severity":"major"}]}`
	r := parseOne(t, raw, testSources())
	var got []string
	for _, a := range r.Agreements {
		got = append(got, a.Severity)
	}
	assert.Equal(t, []string{"blocker", "major", "", ""}, got)
	require.Len(t, r.DecidedAlone, 1)
	assert.Equal(t, "minor", r.DecidedAlone[0].Severity)
	require.Len(t, r.BlindSpots, 2)
	assert.Equal(t, "major", r.BlindSpots[0].Severity)
	assert.Equal(t, "", r.BlindSpots[1].Severity)
	require.Len(t, r.Checks, 3)
	assert.Equal(t, []string{"blocker", "", ""}, []string{r.Checks[0].Severity, r.Checks[1].Severity, r.Checks[2].Severity})

	// The key never depends on severity.
	again := parseOne(t, strings.ReplaceAll(raw, `"severity":"minor"`, `"severity":"blocker"`), testSources())
	assert.Equal(t, r.DecidedAlone[0].Key, again.DecidedAlone[0].Key)
}

func TestFindings_CopySeverity(t *testing.T) {
	r := loopResult()
	r.Agreements[1].Severity = "major"
	r.DecidedAlone[0].Severity = "minor"
	r.BlindSpots[0].Severity = "blocker"
	r.Checks[1].Severity = "major"
	got := map[string]string{}
	for _, it := range Findings(r, 1) {
		got[it.Key] = it.Severity
	}
	assert.Equal(t, map[string]string{"ag:miss": "major", "da:local": "minor", "bs:threads": "blocker", "ck:expiry": "major"}, got)
}

func TestNextRound_CarriedItemKeepsSeverity(t *testing.T) {
	it := item("bs:a", 1)
	it.Severity = "blocker"
	r := loopResult()
	r.BlindSpots = []BlindSpot{{Key: "bs:a", Text: "re-raised", Why: "w", Severity: "minor"}}
	o := NextRound(2, []AuthorItem{it}, nil, nil, r)
	require.NotEmpty(t, o.Open)
	assert.Equal(t, "bs:a", o.Open[0].Key)
	assert.Equal(t, "blocker", o.Open[0].Severity)
	o = NextRound(2, []AuthorItem{it}, nil, nil, loopResult(Verdict{Key: "bs:a", Verdict: VerdictResolved}))
	require.Len(t, o.Ledger, 1)
	assert.Equal(t, "blocker", o.Ledger[0].Severity)
}

func TestPrompt_SeverityDefinitions(t *testing.T) {
	assert.Equal(t, 3, prompts.DefaultVersions[prompts.SpecReview])
	p := prompts.Defaults[prompts.SpecReview]
	for _, lvl := range []string{`"blocker"`, `"major"`, `"minor"`, `"severity"`} {
		assert.Contains(t, p, lvl)
	}
}
