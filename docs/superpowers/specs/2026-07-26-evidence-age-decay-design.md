# Evidence age-decay: exponential half-life for all ranks

**Date:** 2026-07-26
**Status:** approved by owner (design review in session; curve verdict "C — exponential, including owner"; explicit owner approval for rewriting the affected guard-test assertions)
**Scope:** `internal/memory/belief_math.go` (+ its tests) and inventory text (MEM-06/MEM-15 wording). No config, no migration, no prompt change, no Swift change. This is sub-project **3a** of the 2026-07-20 MEM-review design task; owner-steerable salience (3b) is a separate spec.

## Problem

Only owner evidence ages today (linear 1.0 → 0.4 over 180 days, then a 0.4 floor). `observed` 0.6, `owner-action` 0.8, and `inferred` 0.3 are age-invariant: a year-old observation or dismissal weighs exactly like yesterday's. The 2026-07-20 owner review called the static weights inadequate ("вес должен меняться... со временем"), and MEM-15's own limitation note had scheduled this revisit for "when preference beliefs land" — they landed in Phase-5 slice 4.

## Owner decisions

- **Curve C: pure exponential half-life, all four ranks, owner included.** `w(age) = baseWeight(rank) × 2^(−ageDays/180)`. One constant, no floors — old evidence asymptotically approaches zero ("память забывает всё, но пропорционально").
- Base weights unchanged: `inferred` 0.3, `observed` 0.6, `owner-action` 0.8, `owner` 1.0.
- **Guard-assert rewrite approved:** the linear owner curve is pinned by `TestOwnerRankWeight` and exercised by weight-sensitive `TestApplyOp*` cases; their assertions are rewritten to the exponential values. No guard test is deleted, renamed, or weakened — the MEM-06 protection semantics they guard are untouched (see Invariants).

## Design

### The math (`internal/memory/belief_math.go`)

- New constant `evidenceHalfLifeDays = 180.0` replaces the weight-curve role of `ownerDecayDays`; `ownerWeightFresh`/`ownerWeightFloor` and `ownerRankWeight` are removed.
- `evidenceWeight(rank, ageDays)` becomes, for every rank: `baseWeight(rank) * math.Exp2(-ageDays/evidenceHalfLifeDays)` where `baseWeight` returns the four constants above. Negative ageDays (clock skew) clamps to 0 before the exponent (weight never exceeds base).
- Decay is direction-agnostic: for and against evidence age identically (`forAgainstWeight` unchanged structurally).
- **Rank ratios are age-invariant by construction** — the decay multiplier is rank-independent, so owner:observed stays 5:3 at every age and no curve crossing is possible. This is the property that makes C simpler than per-rank horizons.
- Reference points (tested): age 0 → base; 180d → base/2; 360d → base/4. Owner at 360d = 0.25 (below today's 0.4 floor — deliberate philosophy change: no eternal floor), at ~2y ≈ 0.06.

### MEM-06 protection — untouched

`hasFreshOwnerSupport` keys on `rankOwner && AgeDays < <window>`; the window constant is RENAMED `ownerDecayDays` → `ownerFreshWindowDays` (same value 180.0) to make explicit that the protection window and the weight curve are now independent knobs. Fresh owner support still blocks auto-retire/flip absolutely, regardless of weight arithmetic. Birth-cap 0.6, stability hysteresis, `shake`-always-allowed — all unchanged. MEM-15 (owner-action confers no protection) and MEM-09 (code-minted ranks) untouched.

### Behavioral blast radius

Confidence/status of an existing belief changes only when the belief pass actually lands an op on it — there is no background recompute, so no retro wave of retires. The intended effect: an old belief's decayed support makes it easier to flip *when challenged*, and stale owner-actions (dismissals) stop outweighing fresh observations forever.

## Inventory updates

- MEM-06 Observable: "Owner weight decays linearly `1.0 → 0.4` over 180 days" → exponential wording (`w = base × 2^(−age/180d)`, no floor; the protection window is a separate 180-day constant, `ownerFreshWindowDays`).
- MEM-15's rank-weight reference table: add the shared half-life column/sentence ("all ranks decay with a shared 180-day half-life; ratios age-invariant") and delete the "fixed, no age decay" clause of `owner-action` and the corresponding known-limitation sentence ("A dismissal's staleness is unmodeled…" bullet updated).
- Changelog entry naming the owner's curve verdict and the approved guard-assert rewrite.

## Test plan (TDD)

- `TestEvidenceWeightHalfLife`: for each rank — age 0 → base, 180 → base/2, 360 → base/4; negative age → base; ordering `inferred < observed < owner-action < owner` at 0d, 180d, 400d.
- `TestOwnerRankWeight` rewritten to the exponential curve (owner-approved), keeping the same guard role: pins the owner curve's exact shape.
- `TestApplyOpRetireAllowedWhenOwnerDecayed` / `TestApplyOpRetireRejectedByFreshOwnerSupport`: fixtures re-checked — protection boundary cases at 179/181 days must behave exactly as before (window untouched); any weight-sum assertions updated to exponential values.
- Full `belief_math_test.go` + `beliefs_test.go` (MEM-06/08 guards) green; every other memory guard unmodified.

## Non-goals

- No per-rank horizons (rejected option B), no floors (rejected within C), no config knob for the half-life (code const, the belief-math precedent).
- No change to the MEM-06 protection window's length or keying.
- Salience/importance (3b) — separate spec.
