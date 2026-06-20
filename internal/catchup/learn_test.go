package catchup

import (
	"context"
	"strings"
	"testing"

	"watchtower/internal/db"
)

// seedReadyTheme creates an active session with one ready theme referencing the
// seeded digest, so feedback has a concrete target to learn from.
func seedReadyTheme(t *testing.T, d *db.DB) (sessionID, themeID int64) {
	t.Helper()
	seedUnreadDigest(t, d)
	var err error
	sessionID, err = d.CreateCatchupSession("")
	if err != nil {
		t.Fatal(err)
	}
	themeID, err = d.InsertCatchupTheme(db.CatchupTheme{
		SessionID: sessionID,
		OrderIdx:  0,
		Title:     "Noise from #random",
		Priority:  "low",
		RefsJSON:  `[{"area":"digests","id":1,"label":"#random digest"}]`,
		GenState:  "skeleton",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := d.UpdateCatchupThemeExpansion(themeID, "Some narrative.", "low", false, "", "ready"); err != nil {
		t.Fatal(err)
	}
	return sessionID, themeID
}

func TestCatchup30_CommentFeedbackDerivesPipelineRule(t *testing.T) {
	d := db.OpenTestDB(t)
	_, themeID := seedReadyTheme(t, d)

	gen := &mockGenerator{fn: func(system, _ string) string {
		if system == learnSystemPrompt {
			return `{"rules":[{"pipeline":"digest","rule_type":"source_mute","scope_key":"digest:channel:Crandom","weight":-1.0,"reason":"channel is noise"}],"regenerate":false}`
		}
		t.Fatalf("unexpected AI call with system prompt: %q", system)
		return ""
	}}

	p := New(d, newCfg(), gen, testLogger())
	if err := p.SubmitThemeFeedback(context.Background(), themeID, -1, "this channel is noise"); err != nil {
		t.Fatal(err)
	}

	// A feedback row is always written.
	fb, err := d.GetFeedback(db.FeedbackFilter{EntityType: "catchup_theme"})
	if err != nil {
		t.Fatal(err)
	}
	if len(fb) != 1 {
		t.Fatalf("got %d feedback rows, want 1", len(fb))
	}
	if fb[0].Rating != -1 || fb[0].Comment != "this channel is noise" {
		t.Fatalf("feedback row = %+v", fb[0])
	}

	// The derived rule is addressed to the digest pipeline with explicit source.
	rules, err := d.ListLearnedRulesByPipeline("digest", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(rules) != 1 {
		t.Fatalf("got %d digest rules, want 1 (%+v)", len(rules), rules)
	}
	r := rules[0]
	if r.RuleType != "source_mute" || r.ScopeKey != "digest:channel:Crandom" {
		t.Fatalf("rule = %+v", r)
	}
	if r.Weight != -1.0 {
		t.Fatalf("rule weight = %v, want -1.0", r.Weight)
	}
	if r.Source != "explicit_feedback" {
		t.Fatalf("rule source = %q, want explicit_feedback", r.Source)
	}

	// The rule is NOT visible under the inbox pipeline.
	inboxRules, err := d.ListLearnedRulesByPipeline("inbox", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(inboxRules) != 0 {
		t.Fatalf("digest rule leaked into inbox pipeline: %+v", inboxRules)
	}
}

func TestCatchup31_BareFeedbackWritesNoRuleAndNoAICall(t *testing.T) {
	d := db.OpenTestDB(t)
	_, themeID := seedReadyTheme(t, d)

	gen := &mockGenerator{fn: func(string, string) string {
		t.Fatal("learning interpreter must not be invoked for a comment-less feedback")
		return ""
	}}

	p := New(d, newCfg(), gen, testLogger())
	if err := p.SubmitThemeFeedback(context.Background(), themeID, 1, ""); err != nil {
		t.Fatal(err)
	}

	if gen.called {
		t.Fatal("generator was called for a bare like/dislike")
	}

	fb, err := d.GetFeedback(db.FeedbackFilter{EntityType: "catchup_theme"})
	if err != nil {
		t.Fatal(err)
	}
	if len(fb) != 1 {
		t.Fatalf("got %d feedback rows, want 1", len(fb))
	}
	if fb[0].Rating != 1 || fb[0].Comment != "" {
		t.Fatalf("feedback row = %+v", fb[0])
	}

	for _, pipeline := range []string{"inbox", "digest", "tracks", "briefing", "catchup"} {
		rules, err := d.ListLearnedRulesByPipeline(pipeline, 10)
		if err != nil {
			t.Fatal(err)
		}
		if len(rules) != 0 {
			t.Fatalf("bare feedback derived a rule under %q: %+v", pipeline, rules)
		}
	}
}

func TestCatchup32_PresentationCorrectionTriggersRegen(t *testing.T) {
	d := db.OpenTestDB(t)
	_, themeID := seedReadyTheme(t, d)

	gen := &mockGenerator{fn: func(system, user string) string {
		if system == learnSystemPrompt {
			return `{"rules":[],"regenerate":true}`
		}
		if system == expandSystemPrompt {
			if !strings.Contains(user, "OPERATOR CORRECTION") {
				t.Fatalf("regen expand call missing operator correction: %q", user)
			}
			return `{"narrative":"regenerated narrative","priority":"low","needs_you":false,"suggested_action":""}`
		}
		t.Fatalf("unexpected system prompt: %q", system)
		return ""
	}}

	p := New(d, newCfg(), gen, testLogger())
	if err := p.SubmitThemeFeedback(context.Background(), themeID, -1, "the title is misleading"); err != nil {
		t.Fatal(err)
	}

	got, err := d.GetCatchupTheme(themeID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Narrative != "regenerated narrative" {
		t.Fatalf("narrative = %q, want regenerated narrative (regen should have run)", got.Narrative)
	}
}
