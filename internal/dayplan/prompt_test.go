package dayplan

import (
	"strings"
	"testing"

	"watchtower/internal/config"
	"watchtower/internal/prompts"
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
