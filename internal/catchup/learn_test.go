package catchup

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/prompts"
)

// seedReadyRecap persists a 'ready' recap whose single topic cites the given
// digest, so per-topic feedback has a concrete target to learn from.
func seedReadyRecap(t *testing.T, d *db.DB, digestID int64) int64 {
	t.Helper()
	id, err := d.InsertCatchupRecap(1000, 2000, 0)
	require.NoError(t, err)
	body := fmt.Sprintf(`{"topics":[{"title":"Noise from #eng","narrative":"deploy chatter all day","priority":"low","refs":[{"area":"digests","id":%d,"label":"#eng"}]}],"decisions":[],"meetings":[],"needs_you":[]}`, digestID)
	require.NoError(t, d.FinishCatchupRecap(id, "quiet day", body, `{"topup":"skipped"}`, "", 0, 0, 0))
	return id
}

// learnMuteRule is what the interpreter returns for "this channel is noise":
// one digest-pipeline rule keyed on the channel id the scope hints supplied.
const learnMuteRule = `{"rules":[{"pipeline":"digest","rule_type":"source_mute","scope_key":"digest:channel:1:C1","weight":-1,"reason":"noise"}],"regenerate":false}`

// allRulePipelines is every pipeline a catch-up rule can be addressed to.
var allRulePipelines = []string{"inbox", "digest", "tracks", "briefing", "catchup"}

func TestSubmitTopicFeedback_BareRatingWritesNoRuleAndNoAICall(t *testing.T) {
	gen := &mockGenerator{}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	recapID := seedReadyRecap(t, d, seedDigest(t, d, 1500, 1900))

	regen, err := p.SubmitTopicFeedback(context.Background(), recapID, 0, 1, "")
	require.NoError(t, err)
	assert.Zero(t, regen, "a bare rating regenerates nothing")

	fb, err := d.GetFeedback(db.FeedbackFilter{EntityType: "catchup_theme"})
	require.NoError(t, err)
	require.Len(t, fb, 1, "the raw signal is always recorded")
	assert.Equal(t, fmt.Sprintf("%d:0", recapID), fb[0].EntityID)
	assert.Equal(t, 1, fb[0].Rating)
	assert.Empty(t, fb[0].Comment)

	// A whitespace-only comment is a bare rating too.
	regen, err = p.SubmitTopicFeedback(context.Background(), recapID, 0, -1, "   ")
	require.NoError(t, err)
	assert.Zero(t, regen)

	assert.False(t, gen.called, "no comment to interpret → no AI call")
	for _, pipeline := range allRulePipelines {
		rules, rerr := d.ListLearnedRulesByPipeline(pipeline, 10)
		require.NoError(t, rerr)
		assert.Empty(t, rules, "a bare rating derived a rule under %q", pipeline)
	}
}

func TestSubmitTopicFeedback_CommentDerivesTargetedRule(t *testing.T) {
	var learnSystem, learnUser string
	gen := &mockGenerator{fn: func(system, user string) string {
		if !strings.HasPrefix(system, learnSystemPrompt) {
			t.Errorf("unexpected AI call with system prompt %q", system)
			return ""
		}
		learnSystem, learnUser = system, user
		return learnMuteRule
	}}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	recapID := seedReadyRecap(t, d, seedDigest(t, d, 1500, 1900))

	regen, err := p.SubmitTopicFeedback(context.Background(), recapID, 0, -1, "this channel is noise")
	require.NoError(t, err)
	assert.Zero(t, regen, "regenerate:false → no new recap")

	rules, err := d.ListLearnedRulesByPipeline("digest", 10)
	require.NoError(t, err)
	require.Len(t, rules, 1)
	assert.Equal(t, "source_mute", rules[0].RuleType)
	assert.Equal(t, "digest:channel:1:C1", rules[0].ScopeKey)
	assert.Equal(t, -1.0, rules[0].Weight)
	assert.Equal(t, "explicit_feedback", rules[0].Source)
	assert.Equal(t, 1, rules[0].EvidenceCount)

	inboxRules, err := d.ListLearnedRulesByPipeline("inbox", 10)
	require.NoError(t, err)
	assert.Empty(t, inboxRules, "a digest rule must not leak into the inbox pipeline")

	assert.Contains(t, learnUser, "channel_id=1:C1", "the resolved scope hint reaches the interpreter")
	assert.Contains(t, learnUser, "this channel is noise")
	assert.Contains(t, learnSystem, prompts.Directive("Russian"))
	assert.Equal(t, "catchup.learn", gen.source, "the learn call must carry its tier tag")
}

func TestSubmitTopicFeedback_PresentationCorrectionRegeneratesRecap(t *testing.T) {
	gen := &mockGenerator{}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	digestID := seedDigest(t, d, 1500, 1900)
	recapID := seedReadyRecap(t, d, digestID)
	var composeUser string
	gen.fn = func(system, user string) string {
		if strings.HasPrefix(system, learnSystemPrompt) {
			return `{"rules":[],"regenerate":true}`
		}
		composeUser = user
		return fmt.Sprintf(composeOK, digestID)
	}

	newID, err := p.SubmitTopicFeedback(context.Background(), recapID, 0, -1, "the title is misleading")
	require.NoError(t, err)
	require.Greater(t, newID, int64(0), "a presentation correction regenerates the recap")
	assert.NotEqual(t, recapID, newID)

	r, err := d.GetCatchupRecap(newID)
	require.NoError(t, err)
	assert.Equal(t, recapID, r.RegenOfID, "the regen links back to the recap it corrects")
	assert.Equal(t, "ready", r.Status)
	assert.Contains(t, composeUser, "OPERATOR CORRECTION: the title is misleading")
}

// The regen is a second AI call that can fail on its own. It fails the way any
// compose failure does — a persisted 'failed' row and NO Go error — so the
// caller still gets the new recap's id and can report what it became (the CLI's
// "Regenerated as recap N — failed: …" line).
func TestSubmitTopicFeedback_FailedRegenerationStillReportsItsRecap(t *testing.T) {
	gen := &mockGenerator{}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	recapID := seedReadyRecap(t, d, seedDigest(t, d, 1500, 1900))
	gen.fn = func(system, _ string) string {
		if strings.HasPrefix(system, learnSystemPrompt) {
			return `{"rules":[],"regenerate":true}`
		}
		return "not json"
	}

	newID, err := p.SubmitTopicFeedback(context.Background(), recapID, 0, -1, "the title is misleading")
	require.NoError(t, err, "a failed compose is persisted, not returned")
	require.Greater(t, newID, int64(0), "the operator is still told which recap to look at")

	r, err := d.GetCatchupRecap(newID)
	require.NoError(t, err)
	assert.Equal(t, "failed", r.Status)
	assert.NotEmpty(t, r.Error)
}

// Everything that would leave a feedback row pointing at nothing is rejected
// before the first write.
func TestSubmitTopicFeedback_InvalidTargetWritesNothing(t *testing.T) {
	gen := &mockGenerator{}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	recapID := seedReadyRecap(t, d, seedDigest(t, d, 1500, 1900))
	building, err := d.InsertCatchupRecap(1000, 2000, 0)
	require.NoError(t, err)

	cases := []struct {
		name     string
		recapID  int64
		topicIdx int
	}{
		{"topic past the end", recapID, 5},
		{"negative topic", recapID, -1},
		{"missing recap", 999, 0},
		{"unfinished recap", building, 0},
	}
	for _, c := range cases {
		_, err := p.SubmitTopicFeedback(context.Background(), c.recapID, c.topicIdx, -1, "this channel is noise")
		assert.Error(t, err, c.name)
	}

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM feedback`).Scan(&n))
	assert.Equal(t, 0, n, "a rejected target must not leave a feedback row")
	assert.False(t, gen.called)
}
