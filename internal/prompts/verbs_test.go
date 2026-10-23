package prompts

import "testing"

func TestCountVerbs_OnlyPlainStringVerbs(t *testing.T) {
	for _, c := range []struct {
		tmpl string
		want int
	}{
		{"", 0},
		{"no verbs", 0},
		{"%s", 1},
		{"a %s b %s", 2},
		{"%%s", 0},
		{"50%% off %s", 1},
		{"%%%s", 1},
		{"100% sure", -1},
		{"%d", -1},
		{"%s and %d", -1},
		{"% s", -1},
		{"%5s", -1},
		{"%-s", -1},
		{"%v", -1},
		{"trailing %", -1},
		{"%[1]s", -1},
	} {
		if got := CountVerbs(c.tmpl); got != c.want {
			t.Errorf("CountVerbs(%q) = %d; want %d", c.tmpl, got, c.want)
		}
	}
}

// The shipped templates the pipelines check hold only %s verbs.
func TestCountVerbs_ShippedTemplatesArePlain(t *testing.T) {
	for _, id := range []string{TracksExtractBatch, IdeasConsolidate, BriefingDaily, DayPlanGenerate} {
		if CountVerbs(Defaults[id]) <= 0 {
			t.Errorf("%s: CountVerbs = %d; want a positive count", id, CountVerbs(Defaults[id]))
		}
	}
}

func TestPlaceholderNote(t *testing.T) {
	if got := PlaceholderNote(2, 3); got != "The prompt has 2 placeholders where 3 are required — the built-in prompt was used." {
		t.Errorf("note = %q", got)
	}
	if got := PlaceholderNote(-1, 3); got != "The prompt has a % directive other than %s (write %% for a percent sign) where 3 %s placeholders are required — the built-in prompt was used." {
		t.Errorf("note = %q", got)
	}
}
