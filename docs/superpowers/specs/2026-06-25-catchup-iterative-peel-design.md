# Catch-up: iterative peel-off outline — design

**Date:** 2026-06-25
**Branch:** feature/catch-up-summarizer
**Owner:** @Vadym
**Module:** `internal/catchup/` (+ `internal/config`, `internal/db`, `internal/digest`/`internal/codex` model routing)

## Problem

Today the catch-up outline is a **single** AI call that clusters every gathered
unread item into themes under hard prompt pressure: *"Merge aggressively; prefer
3-8 strong themes over a long shallow list."* (`internal/catchup/prompt.go:16`).

This produces four felt problems (all confirmed by the owner):

1. **Themes too coarse** — aggressive merge slams unrelated storylines into one
   theme, losing detail.
2. **Items get lost** — the 3-8 ceiling + "merge aggressively" leaves some unread
   items unclustered / invisible.
3. **The "8" is artificial** — the operator wants *as many themes as there are
   real storylines*, no ceiling.
4. **Clustering quality** — one big call reasons worse than focusing on one theme
   at a time.

The input `caps` (40/20/30/5) compound #2: anything beyond the cap never even
reaches the model.

## Approach: iterative peel-off

Replace the single `outline` clustering call with a **sequential peel-off loop**:
each round the model picks the *single most important coherent theme* from the
remaining pool, we remove its items, and repeat until the model says only noise
is left. The existing per-theme `expand` ("экстракт") pass is reused unchanged
and is dispatched concurrently as themes are peeled.

This was chosen over a single non-merging call because the owner explicitly wants
"one by one" extraction for clustering quality. Batched (1-3 per round) was
offered and declined in favour of strict one-at-a-time.

### Pipeline shape

```
gather (raised caps)
  → peel loop  [sequential, cheap model]
       round K: remaining-pool → AI → one theme {title, priority, refs} | {done}
                persist skeleton, remove refs from pool
                ── dispatch expand(theme) ──┐  (concurrent, bounded)
       repeat until done | safety cap        │
  → wait for all expands ──────────────────┘
  → leftover handling (see below)
  → session active
```

`peel` is sequential (round K depends on K-1's removal); `expand` overlaps it so
narrative latency hides behind the loop. Net wall-clock ≈ sum of peel rounds.

### Components

**1. `gather` — unchanged logic, raised caps.**
Caps move from 40/20/30/5 to **150/80/120/20** (digests/tracks/inbox/briefings).
Defaults in `internal/config/config.go` (`SetDefault("catchup.caps.*", …)`).
Rationale: peel handles a large pool fine (it chunks via themes), so the input
cap should stop dropping real unread items. `max_age_days` still bounds the
window.

**2. `peel` loop — replaces `outline`.**
- Maintains `remaining` (the `byRef` map / sections minus already-claimed items).
- New `peelSystemPrompt`: from the remaining unread items, return the SINGLE most
  important coherent cross-source theme as `{title, priority, refs:[{area,id,label}]}`.
  If what's left is only noise/trivia not worth a theme, return `{"done": true}`.
  Same ref rules as today (only ids present in input; never invent).
- Each round: validate refs against `remaining` (reuse `validateRefs`), persist
  skeleton theme with incrementing `OrderIdx`, remove claimed refs from `remaining`,
  dispatch `expandOne` on the shared bounded-concurrency semaphore.
- **Safety cap** `maxPeelRounds` (constant, e.g. 25) guards against runaway. Not
  a theme ceiling — a defensive bound. Primary stop is the `done` signal.
- Model: new source tag `catchup.peel` routed to the **light** tier
  (`ModelHaiku` / `ModelLightweight`) in BOTH `internal/digest/models.go` and
  `internal/codex/models.go` — it is a cheap call run many times. (`expand` stays
  default/Sonnet for narrative quality.)
- Must route through `withLanguage` (CATCHUP-02).

**3. `expand` — unchanged.** Per-theme narrative, per-theme failure isolation
(CATCHUP-03) preserved. Now fed incrementally from the peel loop instead of after
a completed outline.

**4. Leftover handling.**
- Loop exited via **`done`** → the items still in `remaining` are model-judged
  noise → **mark them read** (digests/tracks/inbox/briefings, best-effort,
  reusing the same `MarkXRead` calls as the ack cascade, incl. digest-decision
  cascade for digests). This keeps catch-up's "clear the backlog" promise.
- Loop exited via **safety cap** (not `done`) → leftover is *unprocessed, not
  noise* → **leave untouched** (still unread). Safe rule.

### Error handling (preserve CATCHUP-03 spirit)

- A single peel-round failure (AI error / unparseable JSON) → **stop the loop,
  keep themes already discovered** (partial > all-or-nothing), proceed to expand
  those. Do NOT mark leftover read in this case (treat like safety-cap exit).
- Only if **zero** themes were discovered before the failure → session `failed`
  (matches today's "outline is mandatory" behaviour when there's nothing to show).
- Expand fan-out keeps per-theme `gen_state='failed'` isolation unchanged.

## Inventory contracts (owner approval required — owner is driving this change)

- **CATCHUP-01** (ack cascade over snapshot refs + decisions): unchanged — themes
  still carry refs; cascade logic untouched. The new leftover-noise mark-read is a
  *separate* path; it reuses the same `MarkXRead` primitives (so digest-decision
  cascade still holds) and gets its own test. Existing guard tests unaffected.
- **CATCHUP-02** (every catch-up AI call carries the language directive): the new
  `peelSystemPrompt` MUST route through `withLanguage`. Guard test
  `TestCatchup13_PromptsCarryLanguageDirective` is **extended** to assert the peel
  prompt carries the directive — strengthening, not weakening.
- **CATCHUP-03** (one bad theme never sinks the run): preserved for expand; peel
  failure rule above defines new partial-result behaviour and gets a test.

## Tests (TDD)

New / changed (Go, `internal/catchup/pipeline_test.go` unless noted):
- Peel loop discovers N>8 themes when N storylines exist (no artificial ceiling).
- Peel loop stops on `done`; leftover items marked read (incl. a digest's
  decisions) — and verify items the model claimed are NOT double-handled.
- Peel loop hits safety cap → leftover left **unread**.
- Single peel-round parse error mid-loop → earlier themes survive + expand;
  session stays usable (not `failed`).
- Zero themes before failure → session `failed`.
- `TestCatchup13` extended: peel prompt carries language directive.
- Model routing: `catchup.peel` → light tier in both `digest` and `codex`
  `models_test.go`.
- Expand reused unchanged — existing CATCHUP-03 guard still green.

## Out of scope

- Desktop UI (`CatchUpView`/`CatchUpReviewPane`) — already streams themes via
  observation; no change needed. (The earlier toolbar/header fix is separate.)
- The feedback/learn interpreter (`learn.go`) — unchanged.
- Batched peel, conversational/multi-turn peel — explicitly declined.

## Cost note

Strict one-by-one = up to `maxPeelRounds` **sequential** light-model calls (each
re-sends the shrinking remaining pool) + N concurrent expand calls hidden behind
the loop. Light tier (Haiku/mini) keeps the per-round cost low. Token cost grows
~O(rounds × pool); acceptable for an on-demand surface, bounded by caps + safety
cap.
