# Evidence Age-Decay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Exponential 180-day half-life decay for ALL evidence ranks in the belief math (spec: `docs/superpowers/specs/2026-07-26-evidence-age-decay-design.md`).

**Architecture:** One formula replaces the linear-owner-only decay: `evidenceWeight = baseWeight(rank) × 2^(−ageDays/180)`, no floors; the MEM-06 protection window becomes an explicitly separate constant (`ownerFreshWindowDays`, same 180.0). Pure `belief_math.go` change + owner-approved guard-assert rewrites + inventory wording.

**Tech Stack:** Go 1.25, stdlib `math`, plain `go test`.

## Global Constraints

- Branch: `feature/memory-phase5` (verify `git branch --show-current` before committing).
- **Owner-approved guard-assert rewrites are LIMITED to arithmetic:** `TestOwnerRankWeight` (linear curve → exponential), `TestOwnerActionWeightOrder`'s age-invariance clause, and numeric weight expectations inside `TestApplyOp*` fixtures IF the suite surfaces them. Protection-SEMANTICS assertions (retire blocked by fresh owner support, allowed when decayed past the window, shake always allowed, owner-action never protects) must NOT change — the 180-day window is untouched. No guard test may be deleted or renamed. Any failure that cannot be fixed by updating a numeric weight expectation → STOP, report BLOCKED.
- Base weights unchanged: inferred 0.3, observed 0.6, owner-action 0.8, owner 1.0.
- No config, no migration, no prompt change.
- Never pipe verification output through tail — `> /tmp/x.log 2>&1; echo exit=$?`.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH
  ```

---

### Task 1: The exponential decay + test rewrites

**Files:**
- Modify: `internal/memory/belief_math.go:69-121` (constants block, `ownerRankWeight`, `evidenceWeight`, `hasFreshOwnerSupport`)
- Test: `internal/memory/belief_math_test.go`

**Interfaces:**
- Consumes: existing `evidence{Rank, AgeDays, Support}`, `evidenceRank` constants.
- Produces: `evidenceWeight(rank evidenceRank, ageDays float64) float64` (same signature, exponential semantics); `baseWeight(rank evidenceRank) float64` (new, unexported); constants `evidenceHalfLifeDays = 180.0`, `ownerFreshWindowDays = 180.0`, `weightOwner = 1.0`. REMOVED: `ownerRankWeight`, `ownerDecayDays`, `ownerWeightFresh`, `ownerWeightFloor`.

- [ ] **Step 1: Write the new failing test**

Append to `internal/memory/belief_math_test.go`:

```go
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
```

- [ ] **Step 2: Run to verify red**

Run: `go test ./internal/memory/ -run TestEvidenceWeightHalfLife -v`
Expected: FAIL — at age 180 the current code returns owner 0.4 (linear floor) not 0.5, owner-action 0.8 (no decay) not 0.4, observed 0.6 not 0.3.

- [ ] **Step 3: Implement the curve**

In `internal/memory/belief_math.go`:

1. Replace the tuning-constants block's decay-related lines (keep `confidenceStep`…`flipStabilityStep` untouched):

```go
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
```

2. DELETE `ownerRankWeight` entirely. Replace `evidenceWeight` with:

```go
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
```

3. In `hasFreshOwnerSupport`, replace `ownerDecayDays` with `ownerFreshWindowDays` and update its doc comment's "(age < 180d)" parenthetical to say "(age < ownerFreshWindowDays — a window deliberately independent of the weight curve)".

4. Add `"math"` to the file's imports.

- [ ] **Step 4: Run the math suite; rewrite ONLY sanctioned assertions**

Run: `go test ./internal/memory/ -run 'TestEvidenceWeight|TestOwnerRankWeight|TestOwnerActionWeightOrder|TestApplyOp' -v > /tmp/decay1.log 2>&1; echo exit=$?` — read the log and fix, within the sanctioned scope:

1. `TestOwnerRankWeight` (belief_math_test.go:14-29): the function it calls is gone. Rewrite the body to pin the OWNER exponential curve via `evidenceWeight` — keep the test NAME (it is cited by MEM-06's guard list):

```go
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
```

2. `TestOwnerActionWeightOrder` (belief_math_test.go:237-245): replace ONLY the final age-invariance assertion (line ~244) with:

```go
	assert.Less(t, evidenceWeight(rankOwnerAction, 365), ownerAction,
		"owner-action decays with age since 2026-07-26 (curve C) — a stale dismissal no longer weighs like a fresh one")
```

3. Any `TestApplyOp*` failure: fixtures use aged evidence — update ONLY numeric weight-sum expectations to the exponential values (show the arithmetic in a comment). If a PROTECTION assertion fails (a retire suddenly allowed inside the 180-day window, or blocked outside it), that is a bug in your implementation, not a test to update — STOP and fix the code. `TestApplyOpRetireAllowedWhenOwnerDecayed` / `TestApplyOpRetireRejectedByFreshOwnerSupport` boundary semantics must pass with their window fixtures unmodified.

- [ ] **Step 5: Full package green**

Run: `go test ./internal/memory/ > /tmp/decay2.log 2>&1; echo exit=$?` → exit=0. `beliefs_test.go` (MEM-06/08 guards) must pass; if `TestMemory06_OwnerRankBeliefNeverAutoFlipped` fails, that is a protection regression — STOP, BLOCKED.

- [ ] **Step 6: Commit**

```bash
git add internal/memory/belief_math.go internal/memory/belief_math_test.go
git commit -m "feat(memory): exponential 180d half-life decay for ALL evidence ranks (curve C)

Replaces the linear owner-only decay: w = base × 2^(−age/180d), no
floors, rank ratios age-invariant by construction. The MEM-06 protection
window is untouched and now its own constant (ownerFreshWindowDays).
Guard-assert arithmetic rewrites owner-approved 2026-07-26.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH"
```

---

### Task 2: Inventory wording + full sweep

**Files:**
- Modify: `docs/inventory/memory.md` (MEM-06 Observable, MEM-15 rank table + its known-limitation bullet, changelog)

**Interfaces:** none (docs + verification).

- [ ] **Step 1: MEM-06 Observable**

In the MEM-06 section, replace the sentence `Owner weight decays linearly `1.0 → 0.4` over 180 days; only once it drops below the threshold does a retire apply.` with:

```markdown
Since 2026-07-26 every rank's weight decays with a shared exponential half-life (`w = base × 2^(−age/180d)`, no floor — curve C, owner-approved); the PROTECTION window is a separate 180-day constant (`ownerFreshWindowDays`), so fresh owner support blocks retirement absolutely regardless of weight arithmetic, and only once the support ages past the window does a retire apply.
```

(Anchor on the actual current sentence — if its wording drifted, replace the sentence that describes the linear owner decay.)

- [ ] **Step 2: MEM-15 rank table + limitation bullet**

1. In MEM-15's rank-weight reference sentence (added 2026-07-20: "Rank weights for reference (`belief_math.go`; code constants, not config): `inferred` 0.3, `observed` 0.6, `owner-action` 0.8 (fixed, no age decay), `owner` 1.0 fresh decaying linearly to 0.4 at 180 days."), replace with:

```markdown
Rank weights for reference (`belief_math.go`; code constants, not config): base `inferred` 0.3, `observed` 0.6, `owner-action` 0.8, `owner` 1.0 — since 2026-07-26 ALL ranks decay with a shared 180-day exponential half-life (`w = base × 2^(−age/180d)`, no floors), so rank ratios are age-invariant and curves never cross.
```

2. In MEM-15's Future paragraph (the 2026-07-20 design-task note), mark part (a) delivered: replace `(a) age-decay for ALL ranks, not just owner — today a year-old observation or dismissal weighs like yesterday's;` with `(a) **delivered 2026-07-26** — age-decay for ALL ranks (shared exponential half-life, curve C);`.

3. In the known-limitations bullet starting `**`owner-action` weight is a fixed 0.8 with no decay in Slice 1, and is non-protecting.**`, replace the whole bullet with:

```markdown
- **`owner-action` decays like every rank since 2026-07-26, and is still non-protecting.** The rank orders `observed (0.6) < owner-action (0.8) < owner-fresh (1.0)` at every age (shared half-life preserves ratios); `owner-action` never confers MEM-06 fresh-owner protection (MEM-15).
```

- [ ] **Step 3: Changelog entry**

Insert at the top of `## Changelog` (blank-line separated):

```markdown
- 2026-07-26 (evidence age-decay, spec `docs/superpowers/specs/2026-07-26-evidence-age-decay-design.md`, owner curve verdict C): ALL evidence ranks now decay with one shared exponential half-life — `w(age) = base × 2^(−age/180d)`, no floors (the owner rank's linear `1.0→0.4`-with-floor curve is replaced; a two-year-old owner statement weighs ≈0.06 — memory forgets proportionally). Rank ratios are age-invariant by construction, so ordering can never invert. The MEM-06 protection window is UNTOUCHED and now its own constant (`ownerFreshWindowDays` = 180d, renamed from the weight-curve role of `ownerDecayDays`): fresh owner support still blocks auto-retire/flip absolutely. Guard-assert arithmetic rewrites (`TestOwnerRankWeight` → exponential points, `TestOwnerActionWeightOrder`'s age-invariance clause → decay assertion) explicitly owner-approved; no guard deleted/renamed, protection-semantics assertions byte-unchanged. No config, no migration.
```

- [ ] **Step 4: Full sweep**

```bash
gofmt -l internal/ | tee /tmp/fmt.log            # expect empty
go vet ./... > /tmp/vet.log 2>&1; echo exit=$?
go build ./... > /tmp/build.log 2>&1; echo exit=$?
go test ./internal/memory/ ./internal/db/ ./internal/inbox/ ./internal/briefing/ > /tmp/sweep.log 2>&1; echo exit=$?
```
All exit=0 / empty gofmt.

- [ ] **Step 5: Commit**

```bash
git add docs/inventory/memory.md
git commit -m "docs(memory): inventory — exponential evidence decay (MEM-06/15 wording, changelog)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH"
```
