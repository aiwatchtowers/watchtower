# Secretary Memory Phase 4 — Surfaces: Design Spec

> Date: 2026-07-16. Branch: `feature/memory-phase4` (stacked on `feature/memory-phase3`; merges into `feature/secretary-memory`, PR #36 draft).
> Background: `docs/specs/memory-design-notes.md` (the surface concepts were designed in the original brainstorm: working-memory injection, revision journal in briefings, lazy in-context questions, the arguing secretary via inbox, reflection), `docs/superpowers/specs/2026-07-15-memory-phase3-semantic-tier-design.md` (beliefs/map this phase surfaces), `docs/inventory/memory.md` (MEM-01..08), `docs/inventory/inbox-pulse.md` + `dashboard.md` (INBOX/DASH contracts this phase must not break).

## Context

Phases 0–3 built a memory that fills itself: episodes with validated provenance, entity pages rewritten by the strong tier, falsifiable beliefs behind rank math, a 2 KB hot map. Nothing reads it yet on behalf of the owner. Phase 4 wires the four surfaces from the design notes: the Discuss chat gets working memory and writes owner statements back; the briefing carries the revision journal; serious disagreements arrive as dashboard situations ("the arguing secretary"); reflection watches the memory's own history. The one-line rule from the brainstorm governs everything here: **never ask before a revision; always show after, when the change is notable.**

## Goals

1. **Discuss chat injection + agentic depth**: the situation chat's system prompt gains a MEMORY block (hot `map.md` + beliefs/entities relevant to the situation), and the prompt's tool list advertises `memory_map` / `memory_open` / `memory_recall` (already registered on the same MCP server the chat uses).
2. **Owner-rank write-back from chat**: what the owner literally typed in Discuss becomes owner-rank evidence in the belief system — the highest-trust memory input from the original design.
3. **Briefing revision journal**: notable belief changes since the last briefing appear as a short "Memory revisions" block — transparency without interruption.
4. **The arguing secretary**: a belief that consolidation shook against owner-rank evidence (or that stayed shaken too long on an important subject) surfaces as a dashboard situation through the standard inbox pipeline, with evidence links; the owner's reply resolves the conflict.
5. **Reflection**: a periodic strong-tier pass over the vault's own git history — flapping/unstable areas become briefing lines and dispute candidates.

## Non-Goals

- Injecting memory into triage/compose or any non-chat pipeline prompt (INBOX-01..09 untouched; a Phase 5 decision at most).
- Unsolicited proactive pings. All surfaces are pull (chat, briefing) or standard-inbox-flow (disputes).
- Embeddings/semantic recall; multi-workspace memory.
- Desktop memory-management UI beyond what the existing tabs already show (vault stays file-first).

## Design

### 1. Discuss chat injection (Swift) + tools

`SituationChatViewModel.buildSystemPrompt` (the existing Swift-side prompt builder) gains a MEMORY section between the owner brief and the tools block:

- **Hot map**: contents of `WorkspaceDir()/memory/map.md` (≤2 KB by MEM-cap) read from disk; omitted with a one-line note when absent.
- **Relevant memory**: via GRDB against the shared index — entities whose aliases match the situation's channel id or member user ids (≤5), plus active/shaken beliefs whose `subject` is one of those entities (≤5, statement + confidence + status only). Pure index reads; no vault file parsing in Swift beyond `map.md`.
- **Tools line**: extend the existing tools paragraph with `memory_recall` / `memory_open` / `memory_map` and one usage hint ("check what the secretary already knows before asking the user").
- Shaken beliefs render with an explicit `(uncertain — evidence conflicts)` marker: this implements the brainstorm's "lazy questions in context" — the model sees the doubt and may raise it conversationally; nothing forces it.

Gate: `memory.surfaces.chat` (config, default false; Swift reads config the same way other feature flags are read). Prompt-size guard: the whole MEMORY section is capped at 4 KB code-side.

### 2. Owner write-back from chat (Go, consolidation input)

Chat turns already persist in `chat_conversations` (`context_type='situation'`). A new consolidation sub-step **`ingestChatStatements`** (mechanical, cheap tier NOT involved — see below) runs before the belief pass:

- Scans owner-authored turns (`role='user'`) in situation conversations since a `workspace.memory_chat_turn_floor` watermark (same floor pattern as ingest).
- Each turn becomes **owner-rank evidence available to the belief pass**: the revise-beliefs prompt input gains an "OWNER SAID (verbatim, ranked owner)" block for beliefs whose subject entities alias the conversation's situation channel/members. The model may cite these as evidence; the code mints the evidence line as `- owner <for|against> chat:<conversation_id> <turn_ts>`.
- **Canonical evidence grammar extension**: `parseBeliefEvidence` accepts `chat:<conversation_id>` in the channel field; validation resolves against `chat_conversations` (MEM-01 discipline — a chat ref that doesn't resolve is dropped and counted). Rank `owner` is minted **only** by code for turns whose `role='user'` — the model still cannot mint owner rank (MEM-08 extension).
- No AI call of its own: the sub-step only stages verbatim statements; interpretation stays inside the existing revise-beliefs pass.

This is deliberately narrower than the brainstorm's "everything the owner says becomes memory": v1 scopes owner statements to belief evidence for situation-related subjects. A general "remember this" chat command is Phase 5.

### 3. Briefing revision journal (Go)

`internal/briefing` input gains a **Memory revisions** block: belief transitions since the previous briefing's `generated_at` — read from the index (`memory_nodes` beliefs whose files changed; change detail from the `## History` tail lines) rather than git archaeology. Notability filter in code: status transitions (→shaken, →retired, propose-new applied) always qualify; confidence moves qualify at ≥0.2 delta. Cap 5 lines, each `belief title — what changed — because <evidence digest>`. The briefing prompt template gets the placeholder (version bump per add-ai-prompt); when the block is empty the placeholder renders "(no notable revisions)" and the model is instructed not to mention memory at all.

Gate: same `memory.surfaces.chat`? No — separate `memory.surfaces.briefing` (default false): the two surfaces have different blast radii.

### 4. The arguing secretary (dispute situations)

**MEM-05 is preserved** — the memory pipeline never writes inbox tables. The flow is split:

- Consolidation (belief pass / reflection) marks dispute-worthy beliefs in the **index**: a new `memory_nodes.dispute_pending` flag (migration) set when (a) an op on an owner-rank-protected belief was downgraded to shaken (the secretary disagrees with the boss), or (b) a belief has been shaken ≥7 days with importance above threshold (links-in on its subject).
- The **inbox pipeline's** existing `watchtower` detector (which already runs inside `internal/inbox`) gains a reader: `dispute_pending` beliefs become trigger items (`trigger_type` — reuse the watchtower type; item text = belief statement + "evidence conflicts" summary + vault refs), then the flag is cleared (consumed) in the same inbox transaction. From there the standard pipeline applies — triage may rank it, compose merges it into situations, the dashboard shows it with the secretary card; INBOX-01 (no upgrade) and the watermark contracts are untouched because this is an ordinary detector item.
- The owner's response in the situation (feedback/Discuss) flows back through surface 2 (owner-rank evidence) — closing the loop the brainstorm designed: "настоял на своём → закрепление свежим owner-рангом; согласился → переворот".

Gate: `memory.surfaces.disputes` (default false). Caps: ≤2 dispute items per inbox cycle.

### 5. Reflection (Go, strong tier, weekly)

A consolidation sub-step on a 7-day stagger (like entity rewrites): reads the vault git log window via go-git (commit subjects only: counts of memory(beliefs)/memory(rewrite)/memory(owner-edit) per subject entity) plus belief History churn, and produces via `memory.reflect` (strong tier, new prompt): ≤3 meta-observations. Each observation is applied by code as either (a) a briefing journal line, (b) a `dispute_pending` flag on a flapping belief, or (c) a note appended to the affected entity page's `## Current`. No new node type; no self-modifying thresholds in v1 (the brainstorm's "raise hysteresis automatically" is deferred — code constants stay code).

Gate: `memory.surfaces.reflection` (default false). Budget: shares the semantic output budget.

## Contract candidates (→ docs/inventory/memory.md)

- **MEM-09 (owner rank is authored, never inferred)**: owner-rank evidence is minted exclusively by code from verbatim owner-authored records (chat turns with `role='user'`, owner vault edits); no model output can introduce or upgrade evidence to owner rank. Guard: `TestMemory09_OwnerRankOnlyFromAuthoredTurns`.
- **MEM-10 (disputes ride the standard inbox)**: the memory pipeline never writes inbox tables (MEM-05 restated across phases); dispute items are created only by the inbox pipeline's detector from `dispute_pending` flags, and are subject to all INBOX contracts. Guard: `TestMemory10_DisputeFlagsNeverTouchInboxFromMemory`.
- **MEM-11 (surfaces are read-only over history)**: briefing journal and reflection read vault/index state; they never mutate beliefs directly — all mutations still flow through the belief pass's rank math. Guard: `TestMemory11_SurfacesDontMutateBeliefs`.

## Implementation shape (for the plan)

Go: migration (dispute_pending + chat floor), evidence-grammar extension, ingestChatStatements, briefing block + prompt bump, watchtower-detector reader (internal/inbox — READ docs/inventory/inbox-pulse.md first; touching this package requires the inventory read per CLAUDE.md), reflection step + prompt, config flags + knownConfigKeys. Swift: buildSystemPrompt MEMORY section + config flag read (add-desktop-feature skill; GRDB queries against memory_nodes/memory_aliases). Tests: Swift prompt-builder unit tests (fixture DB), Go guards MEM-09..11, inbox detector tests against INBOX guard suite.

## Validation (→ final-validation-task Section 2)

Staged-disagreement drill: tell the secretary in Discuss something contradicting an existing belief → next consolidation: owner evidence lands (chat ref), belief updates per rank math; force the reverse (secretary's evidence against owner statement) → dispute situation appears on the dashboard with working links; briefing next morning carries the revision line; reflection produces a sane weekly note. Full protocol written into `docs/specs/memory-final-validation-task.md` Section 2 when this phase lands.

## Open questions (documented defaults, not blockers)

- Dispute importance threshold (links-in ≥3 to start) and the 7-day shaken window — tune at final validation.
- Whether `memory.surfaces.chat` should eventually default on once validated — owner call at merge time.
- General "remember this" chat command — Phase 5 with the standing-orders concept from the design notes.
