# Memory focus: owner-steerable salience on the importance axis

**Date:** 2026-07-26
**Status:** approved by owner (design review in session; verdicts: A vault `focus.md` + Desktop editor on top; format A — fixed `## Now`/`## Cooled` sections, free-text bullets; math A — multiplier on the computed arm)
**Scope:** `internal/memory/` (focus parser/matcher, `ImportanceInputs.Focus`, fingerprint sweep), `internal/db/` (one workspace column, migration 00031), `internal/config` (gate), `WatchtowerDesktop` Memory tab (Focus editor section). Extends **MEM-16** (no new contract number — this design session is the explicit owner ask). This is sub-project **3b** of the 2026-07-20 MEM-review design task; age-decay (3a) shipped 2026-07-26.

## Problem

The owner has no way to tell memory "this matters right now / this doesn't burn". `secretary_profile` steers only inbox triage; `importance_override` (Slice A/D) is per-node, absolute, and eternal. Current salience — topical, temporary, subject-scoped — has no input. The 2026-07-20 owner review adjudicated the axis explicitly: salience lands on IMPORTANCE (`ComputeImportance`, MEM-16), never on evidence rank (credibility and current salience are independent axes).

## Docking with Slice D (concurrent work, same branch)

Slice D (importance-ordered rendering + override UX) exposes and hand-pins the existing merged score; it adds no new importance input. Focus is the new input. Interaction rules settled here:

- The focus multiplier applies to the COMPUTED arm only; `importance_override` remains the absolute winner (an explicit per-node pin beats a topical boost).
- Because focus feeds `ComputeImportance` → `importance_score`, every Slice D surface (map.md ranking, Desktop "Important" sort), MEM-17 retrieval, and eviction breathe focus automatically — zero changes on their side.
- File overlap: none (worldmap.go/Swift vs importance.go + new focus files); inventory changelog merges trivially.

## Design

### 1. The file: `focus.md` at the vault root

Owner-editable markdown next to `map.md`/`index.md`:

```markdown
# Focus

## Now
- payment webhooks, hashbank integration
- CEX-7413

## Cooled
- preview environments
```

Fixed section headings `## Now` and `## Cooled`; each bullet is free text. Owner edits (Obsidian or the Desktop Focus editor) land as ordinary `memory(owner-edit)` commits — MEM-03 gives attribution and a browsable history of past focus for free. The file is part of the vault: survives reindex, portable (MEM-02-native). A missing or empty file means no directives (never an error).

### 2. Parsing + matching (mechanical, no AI)

Once per consolidation run (gate on): parse `focus.md` → directives; for each bullet, resolve mechanically:
- alias resolution of the bullet's phrases/tokens against `memory_aliases` (`CEX`, `U1ALICE`, `target:19`, channel names — the existing resolver grammar);
- case-insensitive title match against `memory_nodes.title` (one SQL pass per bullet).

The result is two node-id sets (`now`, `cooled`), threaded to every `computeNodeImportance` call site AND to `RetentionScore`'s eviction path — so eviction breathes focus too (Now nodes resist compression; Cooled nodes go earlier). A bullet matching nothing is logged, never an error. A node matched by both sections counts as `now` (the stronger claim wins; logged). V1 matches directly-named nodes only; one-hop propagation (episodes of a focused entity) is a documented future extension. (Implementation note, plan-stage decision: the sets persist in a memory-owned memory_focus_matches table rewritten on fingerprint change, and computeNodeImportance reads FocusState(nodeID) with one point SELECT — threading sets through the ~17 call sites would have churned every signature for no gain.)

### 3. The math

`ImportanceInputs` gains `Focus` (tri-state: none/now/cooled). `ComputeImportance` multiplies the COMPUTED value: `now` × 2.0, `cooled` × 0.5 (code constants `focusBoostFactor`/`focusCooledFactor`, the belief-math precedent). Semantics: "among the important, the focused first" — the boost is proportional to organic importance, so a barely-linked node never outranks an org-central one just by being mentioned in focus. `importance_override` bypasses the multiplier entirely (merge stays override-or-computed).

### 4. Score staleness: the fingerprint sweep

`importance_score` refreshes only for touched nodes (MEM-16 mechanics); a focus edit touches no node files, so scores would go stale. Fix: a fingerprint of the PARSED directive set (sorted, hashed) persists in a workspace column (`memory_focus_fingerprint TEXT`, migration 00031 — runtime state, MEM-02-exempt like the watermarks). When the current fingerprint differs from the stored one, that run performs a refine pass over ALL indexed nodes' importance (reusing the MEM-16 phase-B refinement machinery) and then stores the new fingerprint — only after the sweep succeeded (freeze-on-error discipline: a failed sweep leaves the old fingerprint so the next run retries).

Directives never auto-expire: the file is small and visible; the owner edits it when focus changes. A "focus not updated in a month" reflection reminder is a documented future, not v1 (YAGNI).

### 5. Desktop: the Focus editor (C on top of A)

The Memory tab gains a "Focus" section: a plain text editor over `focus.md`'s content with Save — reusing the existing raw-editor/Slice-D write path verbatim (non-blocking `flock` on `memory.lock`, lock-busy surfaced inline, atomic write, refresh from written bytes). No per-bullet UI. The Desktop write is the owner's hand (the same class as the existing raw whole-file editor), not a machine surface — MEM-14's read-surface rule is not implicated.

### 6. Gate

`memory.focus.enabled` (default **false**). Off → the file is never parsed, `Focus` is always none (multiplier 1.0), the fingerprint column is never read or written — a gates-off run is byte-identical. The Desktop Focus section stays visible regardless (editing a file the pipeline ignores is harmless and lets the owner prepare focus before enabling).

## Contracts + inventory

- **MEM-16 extended:** a new input to `ComputeImportance`, seen by both consumers (snapshot + live retention) by construction; the fingerprint sweep extends the refresh semantics. Owner ask = this session; no new number (header rule).
- MEM-02: `focus.md` is a vault file (in-scope for reindex-equivalence trivially — it carries no index rows); the fingerprint column is runtime state, exempt like watermarks.
- MEM-03: owner focus edits are owner-edit commits — no new machinery.
- MEM-05: the pipeline writes nothing new outside vault/memory-owned state (the fingerprint column is workspace memory-state, the watermark precedent).
- Changelog entry + a known-limitations bullet (no auto-expiry; direct-match-only v1; both-sections → now; gate-off leaves Desktop editor visible).

## Test plan (TDD)

- Parser: both sections, missing file, empty sections, unknown headings ignored, bullet trimming.
- Matcher: alias hit, title hit (case-insensitive), no-match logged-empty, both-sections → now.
- Math: `TestComputeImportanceFocus` — now ×2, cooled ×0.5, none ×1, override bypasses multiplier; `RetentionScore` sees the same effect.
- Fingerprint: changed focus → an untouched node's persisted score refreshes that run; unchanged focus → no sweep; sweep failure → fingerprint not advanced (retry).
- Gate-off: full run byte-identical (no parse, no fingerprint write).
- Swift: Focus section save path (patch/write/refresh; lock-busy inline error) — mirroring the Slice D override-editor test shape.

## Non-goals

- No AI anywhere in the loop (matching is mechanical; a semantic "what does this bullet mean" pass is out).
- No auto-expiry, no reminder (future).
- No one-hop propagation to linked episodes (future, documented).
- No per-bullet Desktop UI; no persistence of the editor's UI state.
- No change to `importance_override` semantics or Slice D's surfaces.
