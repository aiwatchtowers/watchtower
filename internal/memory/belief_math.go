package memory

import "math"

// This file is the MEM-08 "code disposes" kernel for beliefs: the model
// (memory.revise_beliefs) only proposes ops; whether an op actually mutates a
// belief is decided here by pure rank/hysteresis/decay arithmetic. Everything
// in this file is side-effect free and exhaustively unit-tested — constants
// live in code (not config) so the math is one auditable place (spec §Beliefs).

// evidenceRank orders belief evidence by trust: an owner statement outranks an
// owner action (a mechanical interaction — authentically the owner but
// non-propositional and ambiguous), which outranks a direct observation, which
// outranks an inference.
type evidenceRank int

const (
	rankInferred evidenceRank = iota
	rankObserved
	rankOwnerAction // Phase-5 5D: a mechanical owner interaction (act: ref)
	rankOwner
)

// evidence is one for/against data point behind a belief.
type evidence struct {
	Rank    evidenceRank
	AgeDays float64
	Support bool // true = "for" the statement, false = "against" it
}

// beliefOp is a revision op proposed by the model.
type beliefOp string

const (
	opProposeNew beliefOp = "propose-new"
	opConfirm    beliefOp = "confirm"
	opWeaken     beliefOp = "weaken"
	opShake      beliefOp = "shake"
	opRetire     beliefOp = "retire"
)

// Belief-specific statuses. Beliefs are the only node type that carries
// shaken/retired (entities/episodes stay active|closed|tombstone).
const (
	statusActive  = "active"
	statusShaken  = "shaken"
	statusRetired = "retired"
)

// opDecision is the three-way gate result — the seam MEM-08 guards: the model
// proposes an op, decideOp disposes of it.
type opDecision int

const (
	opRejected   opDecision = iota // refused; belief left unchanged
	opDowngraded                   // a weaker effect applied (e.g. retire → shaken)
	opAllowed                      // applied exactly as proposed
)

// beliefState is the mutable belief frontmatter the math reads and returns.
// Owner-rank protection is NOT cached here — it is derived from the evidence
// list on every call so it can never drift out of sync with the evidence.
type beliefState struct {
	Confidence float64
	Stability  int
	Status     string
}

// Tuning constants (spec §Beliefs "constants in code, not config — tune later").
const (
	// evidenceHalfLifeDays is the shared exponential half-life of ALL evidence
	// ranks (2026-07-26 owner review, curve C): w(age) = base × 2^(−age/180d),
	// no floor — old evidence asymptotically approaches zero, and because the
	// decay multiplier is rank-independent, rank RATIOS are age-invariant by
	// construction (owner:observed stays 5:3 at every age; curves cannot cross).
	evidenceHalfLifeDays = 180.0
	// ownerFreshWindowDays is the MEM-06 protection window — deliberately a
	// SEPARATE constant from the weight curve: fresh owner support blocks
	// auto-retire/flip absolutely regardless of weight arithmetic.
	ownerFreshWindowDays = 180.0

	weightOwner = 1.0
	// weightOwnerAction sits above weightObserved and below fresh owner — an
	// owner acting on something outweighs a third-party observation but never
	// the owner's own words; it still confers NO MEM-06 protection (MEM-15).
	weightOwnerAction = 0.8
	weightObserved    = 0.6
	weightInferred    = 0.3

	confidenceStep     = 0.1 // beliefs move in coarse 0.1 steps
	confidenceFloor    = 0.0
	confidenceCeil     = 1.0
	birthConfidenceMax = 0.6 // a freshly proposed belief is never born above this

	flipThresholdBase = 1.0 // against/for ratio required to flip at stability 0
	flipStabilityStep = 0.5 // each confirmation raises the required ratio (hysteresis)
)

// baseWeight is the fresh weight of one evidence rank.
func baseWeight(rank evidenceRank) float64 {
	switch rank {
	case rankOwner:
		return weightOwner
	case rankOwnerAction:
		return weightOwnerAction
	case rankObserved:
		return weightObserved
	case rankInferred:
		return weightInferred
	default:
		return 0
	}
}

// evidenceWeight is the preponderance weight of one evidence point: the rank's
// base weight decayed by the shared exponential half-life (curve C, 2026-07-26
// — every rank ages, so a year-old observation or dismissal no longer weighs
// like yesterday's). Negative age (future-dated ref / clock skew) clamps to
// fresh; weight never exceeds base.
func evidenceWeight(rank evidenceRank, ageDays float64) float64 {
	if ageDays < 0 {
		ageDays = 0
	}
	return baseWeight(rank) * math.Exp2(-ageDays/evidenceHalfLifeDays)
}

// hasFreshOwnerSupport reports whether any *supporting* evidence is owner-rank
// and still within the non-decayed window (age < ownerFreshWindowDays — a
// window deliberately independent of the weight curve). This is the MEM-06
// protection predicate: while it holds, observations may shake but never
// retire/flip the belief.
func hasFreshOwnerSupport(ev []evidence) bool {
	for _, e := range ev {
		if e.Support && e.Rank == rankOwner && e.AgeDays < ownerFreshWindowDays {
			return true
		}
	}
	return false
}

// forAgainstWeight sums the weighted for- and against-evidence.
func forAgainstWeight(ev []evidence) (forW, againstW float64) {
	for _, e := range ev {
		w := evidenceWeight(e.Rank, e.AgeDays)
		if e.Support {
			forW += w
		} else {
			againstW += w
		}
	}
	return forW, againstW
}

// flipThreshold is the against/for preponderance ratio required to flip a
// belief of the given stability — higher stability demands stronger evidence.
func flipThreshold(stability int) float64 {
	if stability < 0 {
		stability = 0
	}
	return flipThresholdBase + float64(stability)*flipStabilityStep
}

// flipSupported reports whether the against-evidence preponderates over the
// for-evidence by at least the stability-scaled threshold.
func flipSupported(s beliefState, ev []evidence) bool {
	forW, againstW := forAgainstWeight(ev)
	if againstW <= 0 {
		return false
	}
	if forW <= 0 {
		return true // any against-evidence with no support flips
	}
	return againstW/forW >= flipThreshold(s.Stability)
}

// birthConfidence is a proposed belief's starting confidence, scaled by its
// supporting evidence but hard-capped at 0.6 (spec: "confidence ≤ 0.6 at
// birth"), snapped to the 0.1 grid.
func birthConfidence(ev []evidence) float64 {
	forW, _ := forAgainstWeight(ev)
	c := 0.3 + 0.1*forW
	if c > birthConfidenceMax {
		c = birthConfidenceMax
	}
	return roundToStep(c)
}

// decideOp is the pure gate: given the current belief, a proposed op, and the
// evidence, it returns whether the op is allowed, downgraded, or rejected. No
// state is mutated (that is applyOp's job).
func decideOp(s beliefState, op beliefOp, ev []evidence) opDecision {
	switch op {
	case opProposeNew, opConfirm, opWeaken:
		return opAllowed
	case opShake:
		if s.Status == statusRetired {
			return opRejected // retired beliefs are terminal in Phase 3
		}
		return opAllowed
	case opRetire:
		if hasFreshOwnerSupport(ev) {
			return opDowngraded // MEM-06: owner-rank belief can only be shaken
		}
		if !flipSupported(s, ev) {
			return opDowngraded // insufficient preponderance for the stability
		}
		return opAllowed
	default:
		return opRejected
	}
}

// applyOp resolves a proposed op against the belief and returns the new state
// plus the gate decision. A downgraded retire becomes a shake; a rejected op
// leaves the state untouched. applyOp is the single point where a model op can
// change a belief.
func applyOp(s beliefState, op beliefOp, ev []evidence) (beliefState, opDecision) {
	d := decideOp(s, op, ev)
	switch op {
	case opProposeNew:
		return beliefState{Confidence: birthConfidence(ev), Stability: 0, Status: statusActive}, d
	case opConfirm:
		s.Status = statusActive
		s.Stability++
		s.Confidence = clampConfidence(s.Confidence + confidenceStep)
		return s, d
	case opWeaken:
		s.Confidence = clampConfidence(s.Confidence - confidenceStep)
		return s, d
	case opShake:
		if d == opAllowed {
			s.Status = statusShaken
		}
		return s, d
	case opRetire:
		switch d {
		case opAllowed:
			s.Status = statusRetired
		case opDowngraded:
			if s.Status != statusRetired {
				s.Status = statusShaken
			}
		case opRejected:
			// unreachable for opRetire (decideOp never rejects it) — left
			// untouched to keep the switch exhaustive.
		}
		return s, d
	default:
		return s, opRejected
	}
}

// parseEvidenceRank maps the model's evidence-rank string to a rank, rejecting
// anything outside the enum (MEM-08: unknown model output never enters the math).
func parseEvidenceRank(s string) (evidenceRank, bool) {
	switch s {
	case "owner":
		return rankOwner, true
	case "owner-action":
		return rankOwnerAction, true
	case "observed":
		return rankObserved, true
	case "inferred":
		return rankInferred, true
	default:
		return 0, false
	}
}

// clampConfidence keeps confidence on the [0,1] range and snapped to the 0.1
// grid so repeated steps do not accumulate float drift.
func clampConfidence(c float64) float64 {
	c = roundToStep(c)
	if c < confidenceFloor {
		return confidenceFloor
	}
	if c > confidenceCeil {
		return confidenceCeil
	}
	return c
}

// roundToStep snaps a value to the nearest 0.1.
func roundToStep(c float64) float64 {
	return math.Round(c/confidenceStep) * confidenceStep
}
