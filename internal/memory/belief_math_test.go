package memory

import (
	"math"
	"testing"

	"github.com/stretchr/testify/assert"
)

func approx(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

// TestOwnerRankWeight pins the owner rank's decay curve — exponential
// half-life since 2026-07-26 (curve C, owner-approved): no eternal floor,
// the protection window (ownerFreshWindowDays) is a separate knob.
func TestOwnerRankWeight(t *testing.T) {
	cases := []struct {
		ageDays float64
		want    float64
	}{
		{0, 1.0},
		{180, 0.5},
		{360, 0.25},
		{-5, 1.0}, // future-dated / clock skew clamps to fresh
	}
	for _, c := range cases {
		got := evidenceWeight(rankOwner, c.ageDays)
		assert.Truef(t, approx(got, c.want), "evidenceWeight(owner, %v) = %v, want %v", c.ageDays, got, c.want)
	}
}

// TestEvidenceWeightRankOrder asserts the rank ordering owner > observed >
// inferred holds for fresh evidence.
func TestEvidenceWeightRankOrder(t *testing.T) {
	owner := evidenceWeight(rankOwner, 0)
	observed := evidenceWeight(rankObserved, 0)
	inferred := evidenceWeight(rankInferred, 0)
	assert.Greater(t, owner, observed, "owner outranks observed")
	assert.Greater(t, observed, inferred, "observed outranks inferred")
	// Since 2026-07-26 (curve C) every rank decays on the same shared
	// half-life, so observed weight is no longer age-invariant: at 365 days
	// (~2.03 half-lives) it is 0.6 × 2^(-365/180) ≈ 0.147, well below fresh.
	assert.Less(t, evidenceWeight(rankObserved, 365), observed, "observed weight now decays with age (curve C)")
}

// TestApplyOpShakeAlwaysTransitions: a direct contradiction (shake) always
// moves an active belief to shaken, bypassing accumulation and regardless of
// owner support (owner beliefs can be shaken, just never auto-retired).
func TestApplyOpShakeAlwaysTransitions(t *testing.T) {
	freshOwner := []evidence{{Rank: rankOwner, AgeDays: 1, Support: true}}
	for _, ev := range [][]evidence{nil, freshOwner} {
		s := beliefState{Confidence: 0.7, Stability: 5, Status: statusActive}
		got, dec := applyOp(s, opShake, ev)
		assert.Equal(t, statusShaken, got.Status)
		assert.Equal(t, opAllowed, dec)
		assert.Equal(t, 0.7, got.Confidence, "shake leaves confidence untouched")
	}
}

// TestApplyOpConfirmFromShakenBumpsStability: confirm exits the shaken buffer
// back to active and increments stability.
func TestApplyOpConfirmFromShakenBumpsStability(t *testing.T) {
	s := beliefState{Confidence: 0.5, Stability: 2, Status: statusShaken}
	got, dec := applyOp(s, opConfirm, nil)
	assert.Equal(t, statusActive, got.Status)
	assert.Equal(t, 3, got.Stability)
	assert.Equal(t, opAllowed, dec)
	assert.Truef(t, approx(got.Confidence, 0.6), "confirm nudges confidence up one step")
}

// TestApplyOpWeakenLowersConfidence: weaken drops confidence one 0.1 step and
// leaves status alone.
func TestApplyOpWeakenLowersConfidence(t *testing.T) {
	s := beliefState{Confidence: 0.5, Stability: 2, Status: statusActive}
	got, dec := applyOp(s, opWeaken, nil)
	assert.Equal(t, statusActive, got.Status)
	assert.Equal(t, 2, got.Stability)
	assert.Equal(t, opAllowed, dec)
	assert.Truef(t, approx(got.Confidence, 0.4), "weaken lowers confidence one step")

	// Floor: confidence never goes negative.
	got, _ = applyOp(beliefState{Confidence: 0, Status: statusActive}, opWeaken, nil)
	assert.GreaterOrEqual(t, got.Confidence, 0.0)
}

// TestApplyOpRetireRejectedByFreshOwnerSupport is the MEM-06 kernel: a retire
// against a belief with non-decayed owner support is downgraded to shaken —
// never retired/flipped by observations alone.
func TestApplyOpRetireRejectedByFreshOwnerSupport(t *testing.T) {
	ev := []evidence{
		{Rank: rankOwner, AgeDays: 10, Support: true},    // fresh owner support
		{Rank: rankObserved, AgeDays: 1, Support: false}, // contradicting observation
		{Rank: rankObserved, AgeDays: 1, Support: false}, // ...piling up
		{Rank: rankObserved, AgeDays: 1, Support: false}, // ...still cannot flip
	}
	s := beliefState{Confidence: 0.7, Stability: 1, Status: statusActive}
	got, dec := applyOp(s, opRetire, ev)
	assert.Equal(t, opDowngraded, dec, "retire against fresh owner support is downgraded")
	assert.Equal(t, statusShaken, got.Status, "belief is shaken at most, never retired")
	assert.NotEqual(t, statusRetired, got.Status)
}

// TestApplyOpRetireAllowedWhenOwnerDecayed: once the owner evidence ages past
// the 180-day threshold it stops protecting, so a well-supported retire applies.
func TestApplyOpRetireAllowedWhenOwnerDecayed(t *testing.T) {
	ev := []evidence{
		{Rank: rankOwner, AgeDays: 200, Support: true},   // decayed owner support — no protection
		{Rank: rankObserved, AgeDays: 1, Support: false}, // against
		{Rank: rankObserved, AgeDays: 1, Support: false},
		{Rank: rankObserved, AgeDays: 1, Support: false},
	}
	s := beliefState{Confidence: 0.6, Stability: 0, Status: statusShaken}
	got, dec := applyOp(s, opRetire, ev)
	assert.Equal(t, opAllowed, dec)
	assert.Equal(t, statusRetired, got.Status)
}

// TestApplyOpFlipRequiresPreponderance: without owner protection, a retire is
// gated by a stability-scaled preponderance threshold — insufficient against-
// weight is downgraded to shaken; enough clears the flip.
func TestApplyOpFlipRequiresPreponderance(t *testing.T) {
	// High stability raises the bar: one against vs one for is not enough.
	weak := []evidence{
		{Rank: rankObserved, AgeDays: 1, Support: true},
		{Rank: rankObserved, AgeDays: 1, Support: false},
	}
	got, dec := applyOp(beliefState{Stability: 4, Status: statusActive}, opRetire, weak)
	assert.Equal(t, opDowngraded, dec, "insufficient preponderance for the stability")
	assert.Equal(t, statusShaken, got.Status)

	// Overwhelming against-evidence clears even a stable belief.
	strong := []evidence{
		{Rank: rankObserved, AgeDays: 1, Support: true},
		{Rank: rankObserved, AgeDays: 1, Support: false},
		{Rank: rankObserved, AgeDays: 1, Support: false},
		{Rank: rankObserved, AgeDays: 1, Support: false},
		{Rank: rankObserved, AgeDays: 1, Support: false},
		{Rank: rankObserved, AgeDays: 1, Support: false},
	}
	got, dec = applyOp(beliefState{Stability: 1, Status: statusActive}, opRetire, strong)
	assert.Equal(t, opAllowed, dec)
	assert.Equal(t, statusRetired, got.Status)
}

// TestFlipThresholdScalesWithStability: more confirmations demand a steeper
// preponderance to flip (hysteresis).
func TestFlipThresholdScalesWithStability(t *testing.T) {
	assert.Less(t, flipThreshold(0), flipThreshold(3))
	assert.Less(t, flipThreshold(3), flipThreshold(10))
}

// TestApplyOpProposeNew mints a birth state with confidence capped at 0.6.
func TestApplyOpProposeNew(t *testing.T) {
	// Even overwhelming support births below the 0.6 ceiling.
	ev := []evidence{
		{Rank: rankOwner, AgeDays: 0, Support: true},
		{Rank: rankObserved, AgeDays: 0, Support: true},
		{Rank: rankObserved, AgeDays: 0, Support: true},
	}
	got, dec := applyOp(beliefState{}, opProposeNew, ev)
	assert.Equal(t, opAllowed, dec)
	assert.Equal(t, statusActive, got.Status)
	assert.Equal(t, 0, got.Stability)
	assert.LessOrEqual(t, got.Confidence, 0.6, "birth confidence never exceeds the 0.6 ceiling")
	assert.Greater(t, got.Confidence, 0.0)
}

// TestApplyOpShakeOnRetiredRejected: a retired belief is terminal in Phase 3;
// a shake does not resurrect it.
func TestApplyOpShakeOnRetiredRejected(t *testing.T) {
	s := beliefState{Status: statusRetired, Confidence: 0.2}
	got, dec := applyOp(s, opShake, nil)
	assert.Equal(t, opRejected, dec)
	assert.Equal(t, statusRetired, got.Status)
}

// TestDecideOpMatrix exhaustively pins the gate decision for each op against
// protected / unprotected owner support.
func TestDecideOpMatrix(t *testing.T) {
	freshOwner := []evidence{
		{Rank: rankOwner, AgeDays: 5, Support: true},
		{Rank: rankObserved, AgeDays: 1, Support: false},
		{Rank: rankObserved, AgeDays: 1, Support: false},
		{Rank: rankObserved, AgeDays: 1, Support: false},
	}
	decayedOwner := []evidence{
		{Rank: rankOwner, AgeDays: 200, Support: true},
		{Rank: rankObserved, AgeDays: 1, Support: false},
		{Rank: rankObserved, AgeDays: 1, Support: false},
		{Rank: rankObserved, AgeDays: 1, Support: false},
	}
	cases := []struct {
		name string
		s    beliefState
		op   beliefOp
		ev   []evidence
		want opDecision
	}{
		{"confirm always allowed", beliefState{Status: statusActive}, opConfirm, nil, opAllowed},
		{"weaken always allowed", beliefState{Status: statusActive}, opWeaken, nil, opAllowed},
		{"shake active allowed", beliefState{Status: statusActive}, opShake, freshOwner, opAllowed},
		{"propose-new allowed", beliefState{}, opProposeNew, nil, opAllowed},
		{"retire blocked by fresh owner", beliefState{Status: statusActive, Stability: 0}, opRetire, freshOwner, opDowngraded},
		{"retire allowed once owner decayed", beliefState{Status: statusShaken, Stability: 0}, opRetire, decayedOwner, opAllowed},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assert.Equal(t, c.want, decideOp(c.s, c.op, c.ev))
		})
	}
}

// TestParseEvidenceRank maps the model's evidence-rank strings, rejecting junk.
func TestParseEvidenceRank(t *testing.T) {
	for s, want := range map[string]evidenceRank{
		"owner": rankOwner, "observed": rankObserved, "inferred": rankInferred,
		"owner-action": rankOwnerAction,
	} {
		got, ok := parseEvidenceRank(s)
		assert.True(t, ok, s)
		assert.Equal(t, want, got, s)
	}
	_, ok := parseEvidenceRank("guessed")
	assert.False(t, ok)
}

// TestRankNameRoundTrip: rankName is the inverse of parseEvidenceRank for every
// rank, including owner-action (the Slice-1 addition).
func TestRankNameRoundTrip(t *testing.T) {
	for _, r := range []evidenceRank{rankInferred, rankObserved, rankOwnerAction, rankOwner} {
		got, ok := parseEvidenceRank(rankName(r))
		assert.True(t, ok, rankName(r))
		assert.Equal(t, r, got, rankName(r))
	}
}

// TestOwnerActionWeightOrder: owner-action sits strictly between observed (0.6)
// and fresh owner (1.0) at a fixed 0.8 with NO age decay in Slice 1 (resolved
// ambiguity #4).
func TestOwnerActionWeightOrder(t *testing.T) {
	observed := evidenceWeight(rankObserved, 0)
	ownerAction := evidenceWeight(rankOwnerAction, 0)
	ownerFresh := evidenceWeight(rankOwner, 0)
	assert.Greater(t, ownerAction, observed, "owner-action outweighs observed")
	assert.Greater(t, ownerFresh, ownerAction, "fresh owner outweighs owner-action")
	assert.InDelta(t, 0.8, ownerAction, 1e-9)
	assert.Less(t, evidenceWeight(rankOwnerAction, 365), ownerAction,
		"owner-action decays with age since 2026-07-26 (curve C) — a stale dismissal no longer weighs like a fresh one")
}

// TestApplyOpOwnerActionDoesNotProtectRetire is the MEM-06 non-protection
// guard (resolved ambiguity #4): owner-action support carries real weight but
// does NOT confer fresh-owner retire-protection — a well-supported retire
// against it is ALLOWED, whereas the identical shape with owner rank is
// downgraded to shaken. hasFreshOwnerSupport keys on rankOwner exactly.
func TestApplyOpOwnerActionDoesNotProtectRetire(t *testing.T) {
	against := []evidence{
		{Rank: rankObserved, AgeDays: 1, Support: false},
		{Rank: rankObserved, AgeDays: 1, Support: false},
		{Rank: rankObserved, AgeDays: 1, Support: false},
	}

	ownerAction := append([]evidence{{Rank: rankOwnerAction, AgeDays: 1, Support: true}}, against...)
	got, dec := applyOp(beliefState{Confidence: 0.6, Stability: 0, Status: statusActive}, opRetire, ownerAction)
	assert.Equal(t, opAllowed, dec, "owner-action confers no MEM-06 protection")
	assert.Equal(t, statusRetired, got.Status)

	owner := append([]evidence{{Rank: rankOwner, AgeDays: 1, Support: true}}, against...)
	got, dec = applyOp(beliefState{Confidence: 0.6, Stability: 0, Status: statusActive}, opRetire, owner)
	assert.Equal(t, opDowngraded, dec, "owner rank still protects (MEM-06)")
	assert.Equal(t, statusShaken, got.Status)
}

// TestEvidenceWeightHalfLife pins the 2026-07-26 curve-C decay: every rank
// shares one 180-day exponential half-life (w = base × 2^(−age/180), no
// floor), so rank RATIOS are age-invariant and curves can never cross.
func TestEvidenceWeightHalfLife(t *testing.T) {
	ranks := []struct {
		rank evidenceRank
		base float64
	}{
		{rankInferred, 0.3},
		{rankObserved, 0.6},
		{rankOwnerAction, 0.8},
		{rankOwner, 1.0},
	}
	for _, r := range ranks {
		assert.InDeltaf(t, r.base, evidenceWeight(r.rank, 0), 1e-9, "rank %v fresh", r.rank)
		assert.InDeltaf(t, r.base/2, evidenceWeight(r.rank, 180), 1e-9, "rank %v at one half-life", r.rank)
		assert.InDeltaf(t, r.base/4, evidenceWeight(r.rank, 360), 1e-9, "rank %v at two half-lives", r.rank)
		assert.InDeltaf(t, r.base, evidenceWeight(r.rank, -5), 1e-9, "rank %v future-dated clamps to fresh", r.rank)
	}
	// Ordering holds at every age; ratios are age-invariant.
	for _, age := range []float64{0, 180, 400} {
		assert.Less(t, evidenceWeight(rankInferred, age), evidenceWeight(rankObserved, age))
		assert.Less(t, evidenceWeight(rankObserved, age), evidenceWeight(rankOwnerAction, age))
		assert.Less(t, evidenceWeight(rankOwnerAction, age), evidenceWeight(rankOwner, age))
	}
	assert.InDelta(t, 1.0/0.8,
		evidenceWeight(rankOwner, 365)/evidenceWeight(rankOwnerAction, 365), 1e-9,
		"owner:owner-action ratio is age-invariant")
}
