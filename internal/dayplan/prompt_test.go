package dayplan

import (
	"strings"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/prompts"

	"github.com/stretchr/testify/assert"
)

// promptCfg returns a config that exercises the language directive path.
func promptCfg(lang string) *config.Config {
	c := pipeTestCfg()
	c.Digest = config.DigestConfig{Language: lang}
	return c
}

func newPromptPipeline(lang string) *Pipeline { return &Pipeline{cfg: promptCfg(lang)} }

func minimalInputs() *promptInputs {
	return &promptInputs{
		Date:              "2026-04-27",
		Weekday:           "Monday",
		NowLocal:          "09:00",
		UserRole:          "engineer",
		WorkingHoursStart: "09:00",
		WorkingHoursEnd:   "19:00",
		CalendarEvents:    "(none)",
		Targets:           "(none)",
		Briefing:          "(none)",
		Jira:              "(none)",
		People:            "(none)",
		Manual:            "(none)",
		Previous:          "(none)",
		Feedback:          "(initial generation)",
	}
}

// TestBuildPrompt_AlwaysHasLanguageDirective enforces the architectural
// invariant that the day-plan system prompt must carry a language directive.
func TestBuildPrompt_AlwaysHasLanguageDirective(t *testing.T) {
	cases := []struct {
		name string
		lang string
		want string // language token expected in the directive
	}{
		{"explicit Russian", "Russian", "Russian"},
		{"explicit English", "English", "English"},
		{"explicit Spanish", "Spanish", "Spanish"},
		{"empty falls back to default", "", prompts.DefaultLanguage},
		{"whitespace falls back to default", "   ", prompts.DefaultLanguage},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p := newPromptPipeline(tc.lang)
			got, _ := p.buildPrompt(minimalInputs())
			if !prompts.HasDirective(got) {
				t.Fatalf("system prompt missing language directive\n%s", got)
			}
			if !strings.Contains(got, tc.want) {
				t.Fatalf("expected directive to contain %q; prompt:\n%s", tc.want, got)
			}
		})
	}
}

// TestFormatCalendarSection_RendersLocalTimeConsistentWithValidation guards
// against the day-plan prompt showing calendar events in UTC while NowLocal,
// working hours, and the merge.go overlap check all use time.Local. For a
// non-UTC user this mismatch makes the AI believe a meeting is at a
// different hour than it validates against, so its timeblocks get silently
// dropped as "overlapping" a slot the AI never saw as busy.
func TestFormatCalendarSection_RendersLocalTimeConsistentWithValidation(t *testing.T) {
	orig := time.Local
	loc := time.FixedZone("UTC+3", 3*60*60)
	time.Local = loc
	defer func() { time.Local = orig }()

	// Stored instant is 11:00 UTC, i.e. 14:00 in the user's UTC+3 local zone.
	ev := db.CalendarEvent{
		ID:        "e1",
		Title:     "Standup",
		StartTime: "2026-04-27T11:00:00Z",
		EndTime:   "2026-04-27T11:30:00Z",
	}

	got := formatCalendarSection([]db.CalendarEvent{ev})

	assert.Contains(t, got, "14:00", "should render in the same local zone used for now/validation")
	assert.NotContains(t, got, "11:00", "must not leak the raw UTC wall-clock time")
}
