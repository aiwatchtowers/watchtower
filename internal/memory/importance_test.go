package memory

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestComputeImportance: pure-math cases for the importance formula extracted
// from RetentionScore (Slice A of the memory-importance-score redesign,
// docs/superpowers/specs/2026-07-18-memory-importance-score-design.md). Each
// case mirrors one of evict_test.go's pre-existing RetentionScore assertions,
// retargeted at the importance half directly — no recency factor here.
func TestComputeImportance(t *testing.T) {
	// A cold, unreferenced, un-touched, un-engaged node scores 0.
	assert.Zero(t, ComputeImportance(ImportanceInputs{}))

	// Links-in lift the score linearly.
	assert.Equal(t, 3.0, ComputeImportance(ImportanceInputs{LinksIn: 3}))

	// Situation-origin adds its own bonus; owner-touch outweighs it.
	situation := ComputeImportance(ImportanceInputs{SituationOrigin: true})
	owner := ComputeImportance(ImportanceInputs{OwnerTouched: true})
	assert.Equal(t, importanceSituationBonus, situation)
	assert.Equal(t, importanceOwnerBonus, owner)
	assert.Greater(t, owner, situation)
}

// TestComputeImportanceFocus pins the 2026-07-26 salience multiplier (owner
// verdict A): focus multiplies the COMPUTED importance — now ×2, cooled ×0.5,
// unmatched ×1 — proportional to organic importance, so a barely-linked node
// never outranks an org-central one just by being mentioned in focus.
func TestComputeImportanceFocus(t *testing.T) {
	base := ImportanceInputs{LinksIn: 3, SituationOrigin: true} // computed 4.0
	assert.InDelta(t, 4.0, ComputeImportance(base), 1e-9)
	now := base
	now.Focus = "now"
	assert.InDelta(t, 8.0, ComputeImportance(now), 1e-9)
	cooled := base
	cooled.Focus = "cooled"
	assert.InDelta(t, 2.0, ComputeImportance(cooled), 1e-9)
}

// TestComputeImportanceEngagement: positive net owner-engagement raises
// importance; zero or negative net adds no bonus and never lowers the score
// below the un-engaged baseline; the net is clamped in both directions
// (retargeted from evict_test.go's TestRetentionScoreEngagement).
func TestComputeImportanceEngagement(t *testing.T) {
	base := ImportanceInputs{LinksIn: 1}
	engaged := base
	engaged.Engagement = 2
	assert.Greater(t, ComputeImportance(engaged), ComputeImportance(base), "engagement raises importance")

	zero := base
	zero.Engagement = 0
	assert.Equal(t, ComputeImportance(base), ComputeImportance(zero), "zero net adds no bonus")

	negative := base
	negative.Engagement = -5
	assert.Equal(t, ComputeImportance(base), ComputeImportance(negative),
		"a net-dismissed entity never scores below the un-engaged baseline")

	more := base
	more.Engagement = 4
	assert.Greater(t, ComputeImportance(more), ComputeImportance(engaged), "score rises with engagement")

	// The clamp bounds the contribution: net beyond ±engagementNetClamp scores
	// the same as exactly the clamp value.
	atClamp := base
	atClamp.Engagement = engagementNetClamp
	beyondClamp := base
	beyondClamp.Engagement = engagementNetClamp + 10
	assert.Equal(t, ComputeImportance(atClamp), ComputeImportance(beyondClamp),
		"net beyond the clamp scores the same as the clamp")
}
