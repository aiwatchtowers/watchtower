package inbox

import (
	"context"
	"log"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/digest"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// countingGen is a digest.Generator that records how many times it was
// invoked, so tests can prove the interpreter is (not) called.
type countingGen struct {
	response string
	calls    int
}

func (g *countingGen) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls++
	return g.response, &digest.Usage{}, "", nil
}

// seedSituationWithSignal creates one open situation linked to one inbox item
// from the given sender/channel and returns the situation id.
func seedSituationWithSignal(t *testing.T, d *db.DB, senderID, channelID string) int {
	t.Helper()
	itemID := seedInboxItem(t, d, senderID, channelID, "mention")
	sitID, err := d.CreateSituation(db.DashboardSituation{
		Title: "test situation", Kind: "external", Status: "open",
		Priority: "medium", CardStatus: "none",
	})
	require.NoError(t, err)
	require.NoError(t, d.AddSituationSignals(int(sitID), []int{int(itemID)}))
	return int(sitID)
}

func newFeedbackPipeline(t *testing.T) (*db.DB, *Pipeline, *countingGen) {
	t.Helper()
	d := newTestDB(t)
	gen := &countingGen{}
	return d, New(d, testConfig(), gen, log.Default()), gen
}

func TestDash04_CommentlessFeedbackNeverInvokesInterpreter(t *testing.T) {
	// BEHAVIOR DASH-04 — see docs/inventory/dashboard.md
	// A bare 👎 (no comment) mutes the member-signal channels locally and MUST
	// NOT invoke the AI learning interpreter. Do not weaken or remove without
	// explicit owner approval.
	d, p, gen := newFeedbackPipeline(t)
	sitID := seedSituationWithSignal(t, d, "U1", "C1")

	require.NoError(t, p.SubmitSituationFeedback(context.Background(), sitID, -1, "   "))

	assert.Equal(t, 0, gen.calls, "comment-less feedback must not call the generator")
	r, err := d.GetLearnedRule("source_mute", "channel:C1")
	require.NoError(t, err)
	assert.Equal(t, -1.0, r.Weight)
	assert.Equal(t, "user_rule", r.Source)
}

func TestSituationFeedback_RatingOnlyUpIsNoOp(t *testing.T) {
	d, p, gen := newFeedbackPipeline(t)
	sitID := seedSituationWithSignal(t, d, "U1", "C1")

	require.NoError(t, p.SubmitSituationFeedback(context.Background(), sitID, 1, ""))

	assert.Equal(t, 0, gen.calls)
	_, err := d.GetLearnedRule("source_mute", "channel:C1")
	assert.Error(t, err, "👍 without comment must not create rules")
}

func TestSituationFeedback_CommentDerivesUserRules(t *testing.T) {
	d, p, gen := newFeedbackPipeline(t)
	sitID := seedSituationWithSignal(t, d, "U2", "C2")
	gen.response = `{"rules": [{"rule_type": "source_boost", "scope_key": "sender:U2", "weight": 0.8, "reason": "always show Jane"}]}`

	require.NoError(t, p.SubmitSituationFeedback(context.Background(), sitID, 1, "always show me anything from Jane"))

	assert.Equal(t, 1, gen.calls)
	r, err := d.GetLearnedRule("source_boost", "sender:U2")
	require.NoError(t, err)
	assert.Equal(t, 0.8, r.Weight)
	assert.Equal(t, "user_rule", r.Source)
}

func TestSituationFeedback_MalformedRuleSkippedValidApplied(t *testing.T) {
	d, p, gen := newFeedbackPipeline(t)
	sitID := seedSituationWithSignal(t, d, "U3", "C3")
	gen.response = `{"rules": [
		{"rule_type": "made_up_type", "scope_key": "sender:U3", "weight": -1.0, "reason": "bad"},
		{"rule_type": "source_mute", "scope_key": "", "weight": -1.0, "reason": "bad"},
		{"rule_type": "source_mute", "scope_key": "channel:C3", "weight": -0.9, "reason": "noise"}
	]}`

	require.NoError(t, p.SubmitSituationFeedback(context.Background(), sitID, -1, "this channel is noise"))

	r, err := d.GetLearnedRule("source_mute", "channel:C3")
	require.NoError(t, err)
	assert.Equal(t, -0.9, r.Weight)
	_, err = d.GetLearnedRule("made_up_type", "sender:U3")
	assert.Error(t, err, "invalid rule_type must be skipped")
}

func TestSituationFeedback_WeightClampedToUnitRange(t *testing.T) {
	d, p, gen := newFeedbackPipeline(t)
	sitID := seedSituationWithSignal(t, d, "U4", "C4")
	gen.response = `{"rules": [{"rule_type": "source_boost", "scope_key": "sender:U4", "weight": 999, "reason": "way too confident"}]}`

	require.NoError(t, p.SubmitSituationFeedback(context.Background(), sitID, 1, "always show me anything from U4"))

	r, err := d.GetLearnedRule("source_boost", "sender:U4")
	require.NoError(t, err)
	assert.Equal(t, 1.0, r.Weight, "weight must be clamped to the [-1,1] range the prompt asks for")
}

func TestSituationFeedback_UnknownSituationErrors(t *testing.T) {
	d, p, gen := newFeedbackPipeline(t)
	_ = d

	err := p.SubmitSituationFeedback(context.Background(), 9999, -1, "whatever")

	assert.Error(t, err)
	assert.Equal(t, 0, gen.calls, "validation must happen before any AI call")
}
