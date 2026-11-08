package specreview

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func thesisJSON(kind, text, heading, quote string) string {
	b, _ := json.Marshal(map[string]any{
		"kind": kind, "text": text, "chapter": "ch:9",
		"where": map[string]string{"heading": heading, "quote": quote},
	})
	return string(b)
}

func TestParse_ThesesValidated(t *testing.T) {
	theses := []string{
		thesisJSON(ThesisGoal, "Mute a channel for a day", "## Behaviour", "Muting lasts twenty-four hours"),
		thesisJSON(ThesisDecision, "State stays on this Mac", "Decisions", "Mute state lives in the local database"),
		thesisJSON("opinion", "An unknown kind", "Behaviour", "Muting lasts twenty-four hours"),
		// The quote is real but not in the named chapter.
		thesisJSON(ThesisRisk, "Expiry may be missed", "Decisions", "Muting lasts twenty-four hours"),
		thesisJSON(ThesisNonGoal, "Threads are out of scope", "Behaviour", "something the doc never says"),
	}
	r := parseOne(t, `{"summary":"s","theses":[`+strings.Join(theses, ",")+`]}`, testSources())
	if len(r.Theses) != 2 || r.Dropped != 3 {
		t.Fatalf("kept %+v dropped %d", r.Theses, r.Dropped)
	}
	g, d := r.Theses[0], r.Theses[1]
	if g.Kind != ThesisGoal || g.Chapter != "ch:1" || g.Where.Heading != "Behaviour" || !strings.HasPrefix(g.Key, "th:") {
		t.Errorf("goal thesis = %+v", g)
	}
	if d.Kind != ThesisDecision || d.Chapter != "ch:2" {
		t.Errorf("decision thesis = %+v", d)
	}

	var many []string
	for i := 0; i <= maxTheses; i++ {
		many = append(many, thesisJSON(ThesisOwnerChange, fmt.Sprintf("Change number %d", i), "Behaviour", "Muting lasts twenty-four hours"))
	}
	r = parseOne(t, `{"summary":"s","theses":[`+strings.Join(many, ",")+`]}`, testSources())
	if len(r.Theses) != maxTheses || r.Dropped != 1 {
		t.Errorf("cap: kept %d dropped %d", len(r.Theses), r.Dropped)
	}
}

// A thesis key is its kind and normalised text only, so a Discuss thread
// survives a re-run that quotes another passage.
func TestParse_ThesisKeyIgnoresQuote(t *testing.T) {
	a := parseOne(t, `{"summary":"s","theses":[`+thesisJSON(ThesisRisk, "Expiry  may be missed", "Behaviour", "Muting lasts twenty-four hours")+`]}`, testSources())
	b := parseOne(t, `{"summary":"s","theses":[`+thesisJSON(ThesisRisk, "Expiry may be missed", "Decisions", "Mute state lives in the local database")+`]}`, testSources())
	if len(a.Theses) != 1 || len(b.Theses) != 1 || a.Theses[0].Key != b.Theses[0].Key {
		t.Fatalf("keys differ: %+v vs %+v", a.Theses, b.Theses)
	}
	c := parseOne(t, `{"summary":"s","theses":[`+thesisJSON(ThesisGoal, "Expiry may be missed", "Behaviour", "Muting lasts twenty-four hours")+`]}`, testSources())
	if c.Theses[0].Key == a.Theses[0].Key {
		t.Errorf("another kind kept the same key %s", c.Theses[0].Key)
	}
	// Two theses of one key in one reply: the second is a duplicate.
	d := parseOne(t, `{"summary":"s","theses":[`+
		thesisJSON(ThesisRisk, "Expiry may be missed", "Behaviour", "Muting lasts twenty-four hours")+","+
		thesisJSON(ThesisRisk, "Expiry may be missed", "Decisions", "Mute state lives in the local database")+`]}`, testSources())
	if len(d.Theses) != 1 || d.Dropped != 1 {
		t.Errorf("duplicate kept: %+v dropped %d", d.Theses, d.Dropped)
	}
}

func TestParse_BriefClipped(t *testing.T) {
	long := strings.Repeat("я", maxBriefRunes+50)
	r := parseOne(t, `{"summary":"s","brief":"  `+long+`  "}`, testSources())
	if n := len([]rune(r.Brief)); n != maxBriefRunes {
		t.Errorf("brief runes = %d", n)
	}
	r = parseOne(t, `{"summary":"s","brief":"  Builds a mute.\nFor the owner.  "}`, testSources())
	if r.Brief != "Builds a mute.\nFor the owner." {
		t.Errorf("brief = %q", r.Brief)
	}
}

// A reply from before the summary existed parses as before.
func TestParse_NoBriefIsFine(t *testing.T) {
	r := parseOne(t, `{"summary":"s"}`, testSources())
	if r.Brief != "" || r.Theses == nil || len(r.Theses) != 0 || r.Dropped != 0 {
		t.Errorf("old reply: brief %q theses %#v dropped %d", r.Brief, r.Theses, r.Dropped)
	}
}
