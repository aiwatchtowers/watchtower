# Secretary Memory Phase 4 — Surfaces: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task is sized for one focused agent session; obey the stated dependencies. Read `docs/superpowers/specs/2026-07-16-memory-phase4-surfaces-design.md` first.

**Goal:** Wire the four Phase-4 memory *surfaces* on top of the Phase-3 semantic tier, per the design spec: (1) the Discuss chat's system prompt gains a MEMORY block + tools line (Swift); (2) owner statements typed in Discuss become owner-rank belief evidence (`chat:<id>` grammar + `ingestChatStatements`); (3) the daily briefing carries a *Memory revisions* journal; (4) serious belief disagreements ride the standard inbox pipeline as dashboard situations ("the arguing secretary"); (5) a weekly strong-tier *reflection* pass watches the vault's own git history. New contracts **MEM-09/10/11**. Every surface is **dark by default** behind its own gate: `memory.surfaces.{chat,briefing,disputes,reflection}`.

**Architecture (extends the Phase-3 pipeline; nothing in the Phase-0–3 order changes):**
- `internal/memory.Pipeline.runSemantic` gains, at its head, one mechanical sub-step **`ingestChatStatements`** (before the belief pass) that stages verbatim owner chat turns as owner-rank evidence input, and, near its tail, one strong-tier sub-step **`Reflect`** (weekly-staggered) that reads the vault git log + belief History and applies observations as `dispute_pending` flags / entity `## Current` notes only.
- Consolidation (belief pass + reflection) marks dispute-worthy beliefs by inserting into the **`memory_dispute_flags`** side table (runtime state, memory_node_stats precedent). **MEM-05 holds** — memory never writes an inbox table. The **inbox pipeline's existing watchtower detector** reads that flag, mints an ordinary trigger item, and clears the flag in the same inbox transaction.
- `internal/briefing` gains a *Memory revisions* input block, read from the index (belief `## History` tail) with a code-side notability filter; the `briefing.daily` template gets one new positional placeholder (version bump).
- Swift `SituationChatViewModel.buildSystemPrompt` gains a MEMORY section (hot `map.md` from disk + GRDB index reads for relevant entities/beliefs + a tools line), 4 KB-capped, behind `memory.surfaces.chat` read nonisolated from `config.yaml`.

**Tech stack:** unchanged. Go 1.25, `modernc.org/sqlite`, `go-git/v5`, goose migrations, `digest.Generator` (mocked in tests). SwiftUI + GRDB (MVVM). Strong tier = the default model route: a source tag **absent** from the light-tier switch (`internal/digest/models.go` / `internal/codex/models.go`) routes to Sonnet / `gpt-5.4` automatically — so `memory.reflect` needs NO switch edit (a models test asserts the strong route, inverted, mirroring Phase 3 Task 6).

## Precondition (do not start until it lands)

All Phase-3 code is merged on `feature/memory-phase4` (belief math, `beliefs.go`, `rewrite.go`, `dedupe.go`, `evict.go`, `worldmap.go`, migration 00018, MEM-06/07/08 guards). Confirm `go test ./internal/memory/ ./internal/db/ ./internal/inbox/ ./internal/briefing/` is green on this branch before Task 1. The Phase-3 belief pass (`ReviseBeliefs`/`applyBeliefOp`/`newEvidenceLines`/`parseBeliefEvidence`) is the seam Tasks 3–4 extend — read `internal/memory/beliefs.go` and `belief_math.go` in full first.

## Global Constraints

- Module path `watchtower`, Go 1.25. Before each commit: `gofmt -l`, `go vet ./...`, `go build ./...`, and the affected package tests green; `golangci-lint run` clean before PR; daemon coverage floor (70) satisfied; sentrux baseline refreshed only intentionally. Swift work (Task 8): `swift build` + SwiftLint clean, MVVM/GRDB house patterns (see `.claude/skills/add-desktop-feature/SKILL.md`).
- **Never weaken a guard.** MEM-01..08, INBOX-01..09, DASH-01..07 stay exactly as they read today — including MEM-02, which is NOT touched: **orchestrator decision (autonomy protocol, conservative default): dispute flags live in a side table `memory_dispute_flags(node_id PRIMARY KEY, flagged_at, reason)`**, the exact `memory_node_stats` precedent (runtime state, already outside MEM-02's dump). No `TestMemoryNN_` edit, no owner gate. `subject`/`confidence` stay as `memory_nodes` columns (file-derived from frontmatter → MEM-02-clean by construction, covered by the existing equivalence dump). New guards follow the `TestMemoryNN_...` / `TestInboxNN_...` naming convention.
- **MEM-05 preserved (restated for Phase 4).** The memory pipeline never writes `inbox_items` / `situations` / `situation_signals` and never moves `inbox_last_processed_ts`. Dispute items are created **only** by the inbox pipeline's watchtower detector (`internal/inbox`), reading the `dispute_pending` flag. The chat-turn floor and any Phase-4 bookkeeping live in `workspace` scalars or on `memory_nodes` — never on inbox tables. `ingestChatStatements` and `Reflect` are pure readers of `chat_*` (Swift-owned) tables and the git log.
- **Owner rank is authored, never inferred (MEM-09).** Owner-rank evidence (`- owner <for|against> chat:<id> <ts>`) is minted **exclusively by code** from records whose `role='user'` (Discuss turns) or from `memory(owner-edit)` vault commits. No model output may introduce or upgrade evidence to owner rank — the belief pass model still only cites refs; the code elevates a `chat:` ref to owner rank iff it resolves to a `role='user'` turn.
- **Surfaces are read-only over history (MEM-11).** The briefing journal and reflection read vault/index state; they never mutate a belief's confidence/status directly. All belief mutations still flow through `applyBeliefOp`/`applyOp` (the Phase-3 rank math). Reflection's only writes are `dispute_pending` flags and dated `## Current` notes on entity pages (ordinary vault commits).
- **All surfaces dark by default.** `memory.surfaces.chat|briefing|disputes|reflection` all default `false`. Each gated code path is a no-op when its flag is off; the four flags have independent blast radii.
- **All vault writes flow through the Phase-0–3 commit discipline** (`Vault.WriteNodes` / `Vault.WriteFile` after `CommitOwnerEdits`; index mirrored via `upsertIndexNode`). No step writes files outside the vault helpers.
- **Frame vault text as model-mediated hearsay** (memory.md known-limitation "Phase 4 must frame vault text as model-mediated"): the Swift MEMORY block and the briefing journal must present vault content as "memory notes derived from Slack/Jira," never "the owner wrote." Only `chat:` owner evidence and `memory(owner-edit)` commits are owner-asserted.
- English docs. Every new AI step gets a fake-`Generator` fixture test; the chat-ref grammar/validation and MEM-09 minting are pure-function / seam tested.

## File Structure

- `internal/db/migrations/00019_memory_surfaces.sql` (+ mirror in `internal/db/schema.sql`, golden snapshot, `TestAllTablesExist` unaffected — no new tables) — new table `memory_dispute_flags(node_id TEXT PRIMARY KEY REFERENCES memory_nodes(id), flagged_at TEXT NOT NULL, reason TEXT NOT NULL DEFAULT '')` (runtime, MEM-02-exempt like memory_node_stats; ADD to TestAllTablesExist); `memory_nodes` gains `subject TEXT NOT NULL DEFAULT ''` and `confidence REAL NOT NULL DEFAULT 0` (belief-derived from frontmatter, for the Swift index read); `workspace.memory_chat_turn_floor INTEGER NOT NULL DEFAULT 0`.
- `internal/db/memory.go` (+`_test.go`) — extend `MemoryNodeRow`/`UpsertMemoryNode`/`GetMemoryNode`/`ListMemoryNodes` to carry `Subject`/`Confidence`/`DisputePending`; `MemoryChatTurnFloor()`/`SetMemoryChatTurnFloor(id)`; `ListDisputePendingBeliefs(limit)` + `ClearDisputePending(ids)`; `SetDisputePending(id)`.
- `internal/memory/index.go` — populate `Subject`/`Confidence` on the `MemoryNodeRow` from the parsed node (`n.Subject`/`n.Confidence`) in `reconcilePass.file` and in `upsertIndexNode` (merge.go); leave `dispute_pending` untouched by reconcile (runtime, not file-derived).
- `internal/memory/beliefs.go` (+`beliefs_test.go`) — chat-ref validation in the marker/ref validator (MEM-01 discipline, table-absence tolerant); MEM-09 owner-rank minting in `newEvidenceLines` for `chat:` refs backed by a `role='user'` turn; the "OWNER SAID" prompt block.
- `internal/memory/chat_ingest.go` (+`chat_ingest_test.go`) — `ingestChatStatements` sub-step (floor-driven scan of `chat_messages` `role='user'` → verbatim owner statements + validated `chat:` ref set for the belief pass; advances the floor; table-absence → no-op).
- `internal/memory/reflect.go` (+`reflect_test.go`) — `Reflect` step: weekly stagger, git-log + belief-History read, `memory.reflect` strong-tier call, apply as `dispute_pending` / entity `## Current` note (code disposes; MEM-11).
- `internal/memory/vault.go` (+`vault_test.go`) — `LogMemoryCommits(since)` helper (commit subject + node ids + time; sibling of `OwnerEdited`) for reflection's history read.
- `internal/memory/pipeline.go` — wire `ingestChatStatements` (head of `runSemantic`, gated `memory.surfaces.chat`) and `Reflect` (tail, gated `memory.surfaces.reflection`); `RunStats` gains `ChatTurnsIngested`, `Reflections`, `DisputesFlagged`.
- `internal/prompts/store.go`, `internal/prompts/defaults.go` — register `memory.reflect` (const + `Defaults` + `AllIDs` + `DefaultVersions` + `Descriptions`); bump `DefaultVersions[BriefingDaily]` 5→6 and edit `defaultBriefingDaily` for the journal placeholder.
- `internal/briefing/pipeline.go` (+`pipeline_test.go`) — `gatherMemoryRevisions()` block, notability filter, new positional `%s` arg in the `fmt.Sprintf`, gated `memory.surfaces.briefing`.
- `internal/inbox/watchtower_detector.go` (+`watchtower_detector_test.go`) — dispute reader: `dispute_pending` beliefs → trigger items (reuse `decision_made` type), cleared in the same inbox tx, cap ≤2, gated `memory.surfaces.disputes`. READ `docs/inventory/inbox-pulse.md` + `dashboard.md` FIRST.
- `internal/config/config.go` — `MemoryConfig.Surfaces MemorySurfacesConfig`; `SetDefault` per flag. `cmd/config.go` — four keys in `knownConfigKeys` (+ cmd test). The inbox/briefing pipelines already carry `*config.Config`; thread the flags through where the detector/briefing run.
- `WatchtowerDesktop/Sources/ViewModels/SituationChatViewModel.swift` (+`Tests/SituationChatViewModelTests.swift`) — MEMORY block in `buildSystemPrompt`; nonisolated config read + `map.md` disk read + GRDB index queries.
- `WatchtowerDesktop/Sources/Utilities/Constants.swift` (or `ConfigService.swift`) — nonisolated static `memorySurfacesChatEnabled()` YAML reader (mirror of `activeWorkspaceDir()`); `memoryVaultDir()`.
- `docs/inventory/memory.md` (+ changelog), `docs/inventory/inbox-pulse.md` (dispute-detector note), `CLAUDE.md`, `docs/app-guide.md`, `docs/specs/memory-final-validation-task.md` (Section 2).

---

## Task 1: Migration 00019 — dispute flag, index belief columns, chat-turn floor

**Depends on:** nothing. **Blocks:** Tasks 2–8. **Owner gate:** the MEM-02 normalization touch (below) needs @Vadym sign-off before commit.

**Files:** new `internal/db/migrations/00019_memory_surfaces.sql`; modify `internal/db/schema.sql`, the golden snapshot, `internal/db/memory.go` (+`_test.go`), `internal/memory/index.go`, `internal/memory/merge.go` (`upsertIndexNode`), `internal/memory/index_test.go` (MEM-02). Follow `.claude/skills/add-migration`.

Four changes (all additive `ALTER TABLE ... ADD COLUMN` — no table recreation, no CHECK change, so no `foreign_keys=OFF` dance):
1. `memory_nodes.dispute_pending INTEGER NOT NULL DEFAULT 0` — **runtime** flag set by the belief pass/reflection, cleared by the inbox detector. Not derivable from files.
2. `memory_nodes.subject TEXT NOT NULL DEFAULT ''` — belief subject entity id (empty for non-beliefs). **File-derived** (from `Node.Subject`); enables the Swift index-only belief→entity join.
3. `memory_nodes.confidence REAL NOT NULL DEFAULT 0` — belief confidence (0 for non-beliefs). **File-derived** (from `Node.Confidence`); the Swift block shows it.
4. `workspace.memory_chat_turn_floor INTEGER NOT NULL DEFAULT 0` — the owner-chat ingest floor (Task 4). A `workspace` scalar (MEM-05).

Down: drop all four added columns (SQLite ≥ 3.35 supports `DROP COLUMN`; precedent 00017's Down).

**Index wiring:** in `reconcilePass.file` (index.go) and `upsertIndexNode` (merge.go), set `row.Subject = n.Subject`, `row.Confidence = n.Confidence`. Do **not** touch `dispute_pending` from reconcile — it is runtime state (a reindex resets it to 0; the next belief pass re-flags a still-conflicting belief, so it is self-healing). Extend `MemoryNodeRow` + `UpsertMemoryNode` + `GetMemoryNode` + `ListMemoryNodes` accordingly.

**MEM-02 (owner-gated):** `TestMemory02_ReindexEquivalence` compares full `memory_nodes` dumps ignoring `indexed_at`. Subject/confidence are file-derived → both paths produce identical values → MEM-02 stays green with no change. `dispute_pending` is runtime → add it to the dump-normalization ignore set alongside `indexed_at`. Record the reason in the memory.md known-limitations (Task 9) and in the test comment.

- [ ] **Step 1: failing tests** — `internal/db/memory_test.go`: a `memory_nodes` row round-trips `subject`/`confidence`/`dispute_pending`; `MemoryChatTurnFloor` defaults 0 and `SetMemoryChatTurnFloor` persists; `ListDisputePendingBeliefs`/`SetDisputePending`/`ClearDisputePending` behave. Column-presence assertions for all four. `index_test.go`: after a belief is indexed, its row carries `subject`/`confidence` from the file; MEM-02 equivalence still holds with the extended ignore set.
- [ ] **Step 2:** `go test ./internal/db/ ./internal/memory/ -run 'Migration|Memory02|MemoryNode|ChatTurnFloor|Dispute'` → FAIL.
- [ ] **Step 3:** implement the goose Up/Down, schema.sql mirror, db helpers, index population.
- [ ] **Step 4:** regenerate `go test ./internal/db/ -run TestSchemaGolden -update`; full `go test ./internal/db/ ./internal/memory/` green.
- [ ] **Step 5:** get @Vadym sign-off on the MEM-02 normalization touch. Commit `feat(db): memory dispute flag + belief index columns + chat-turn floor (00019)`.

## Task 2: Config — four surface gates

**Depends on:** nothing (parallel with Task 1). **Blocks:** Tasks 4, 5, 6, 7, 8.

**Files:** `internal/config/config.go`, `cmd/config.go` (+`_test.go`).

Add `type MemorySurfacesConfig struct { Chat, Briefing, Disputes, Reflection bool }` (mapstructure `chat`/`briefing`/`disputes`/`reflection`) and `Surfaces MemorySurfacesConfig \`mapstructure:"surfaces"\`` on `MemoryConfig`. Add `v.SetDefault("memory.surfaces.chat", false)` and the other three (in the `memory.*` block ~config.go:299). Register all four in `knownConfigKeys` (cmd/config.go:~203, next to the `memory.semantic.*` keys) with a cmd test extension.

- [ ] **Step 1: failing tests** — config test: the four `memory.surfaces.*` defaults are present and false; cmd test: `watchtower config set memory.surfaces.chat true` is accepted (not warned as unknown).
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/config/ ./cmd/ -run 'Config|Memory'` green; commit `feat(config): memory.surfaces.{chat,briefing,disputes,reflection} gates (default false)`.

## Task 3: Chat evidence grammar + MEM-09 owner-rank minting

**Depends on:** Task 1. **Blocks:** Task 4, Task 9.

**Files:** `internal/memory/beliefs.go` (+`beliefs_test.go`); a small `chat:` ref validator (belief-pass ref set). Read `parseBeliefEvidence`, `newEvidenceLines`, `validateMarkers`, `episodeRefSet`, and `belief_math.go`'s `rankOwner` first.

The canonical evidence line is `- <rank> <for|against> <channel_id> <ts>`. A chat ref stores `channel_id = "chat:<conversation_id>"`, so `parseBeliefEvidence` already parses it structurally (4 fields) and `rankName(rankOwner)` already renders `owner` — **no parser change needed**; add tests pinning that a `- owner for chat:42 1720000000` line round-trips through `parseBeliefEvidence` as `{Rank: rankOwner, Support: true, ChannelID: "chat:42", TS: "1720000000"}`.

Two behavior additions:
1. **Chat-ref validation (MEM-01 discipline).** Extend the ref validator so a model-cited ref whose `channel_id` has prefix `chat:` resolves against the Swift-owned chat tables: `SELECT 1 FROM chat_messages m JOIN chat_conversations c ON c.id = m.conversation_id WHERE c.id=? AND c.context_type='situation' AND m.role='user' AND CAST(m.created_at AS INTEGER)=?` (turn ts is `chat_messages.created_at`, a REAL unix second). A `chat:` ref that does not resolve is **dropped and counted** like a hallucinated message ref. **Table-absence is tolerant:** if `chat_conversations`/`chat_messages` do not exist (headless daemon, no Desktop app has created them), treat every `chat:` ref as unresolved-and-dropped (never error the run) — add a `chatTablesPresent(db)` guard.
2. **MEM-09 owner-rank minting.** In `newEvidenceLines`, a validated `chat:` ref is minted at `rankObserved` today; change it to mint **`rankOwner`** iff the ref is a `chat:` ref (it only reaches here after passing the `role='user'` validation above). Support direction still follows the op (`confirm`/`propose-new` → for, else against). The model never names a rank; the code elevates chat refs to owner rank. Non-chat (episode) refs stay `rankObserved`. This is the MEM-09 seam.

- [ ] **Step 1: failing tests** (`beliefs_test.go`) — `- owner for chat:42 <ts>` parses correctly; a `chat:` ref resolving to a `role='user'` turn mints an `owner` evidence line; a `chat:` ref with no matching turn (or `role='assistant'`, or a non-situation conversation) is dropped and counted; `chat:` validation with the tables absent drops-and-counts without error; an episode ref still mints `observed`; MEM-09: no code path lets a model-supplied rank string reach `rankOwner` (the model's `beliefOpJSON` has no rank field — assert the op schema carries none).
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/memory/ -run 'Belief|Evidence|Chat|Memory09'` green; commit `feat(memory): chat:<id> owner evidence grammar + MEM-09 code-minted owner rank`.

## Task 4: `ingestChatStatements` consolidation sub-step

**Depends on:** Tasks 1, 2, 3. **Blocks:** Task 9.

**Files:** new `internal/memory/chat_ingest.go` (+`chat_ingest_test.go`); wire into `internal/memory/pipeline.go` `runSemantic` (head, before dedupe) gated `memory.surfaces.chat`; extend `ReviseBeliefs` input assembly to carry the owner block + chat ref set.

Mechanical, **no AI call of its own** (interpretation stays in the existing `memory.revise_beliefs` pass):
- `ingestChatStatements(db, floor) (statements []ownerStatement, newFloor int64, err error)`: scan `chat_messages` `role='user'` with `id > floor`, joined to `chat_conversations` where `context_type='situation'`, ordered by `id`. Each row → an `ownerStatement{conversationID, situationID (context_id), turnTS (created_at), text}`. Table-absence → `(nil, floor, nil)` no-op. Advance `newFloor` to the max `chat_messages.id` scanned; persist via `SetMemoryChatTurnFloor` only after the belief pass commits (same "floor advances after success" discipline as ingest — a failed belief pass re-scans the same turns next run).
- **Subject scoping:** map each statement's situation to subject entities by resolving the situation's channel id / member user ids against `memory_aliases` (reuse `Resolve`/alias lookups). A statement contributes to the belief pass only for beliefs whose `subject` is one of those entities.
- **Owner block in the prompt:** `buildReviseBeliefsPrompt` gains an `OWNER SAID (verbatim, ranked owner)` section listing the in-scope statements as `chat:<conversation_id> <turn_ts>: <text>` so the model may cite them. The staged `chat:` refs are added to the belief pass `inputSet` so a cited `chat:` ref validates (Task 3) instead of being dropped as invented.
- **Direction is the model's to propose, rank is the code's to mint:** the model emits e.g. `{op:"retire", evidence:[{channel_id:"chat:42", ts:"..."}]}`; `applyBeliefOp` validates the ref (owner, role='user'), `newEvidenceLines` mints `- owner against chat:42 ...`, and `applyOp` disposes per the rank math (an owner-`for` line then protects the belief per MEM-06; an owner-`against` line can retire it once no fresh owner support remains).

Gate: run only when `p.cfg.Surfaces.Chat`. `RunStats.ChatTurnsIngested += len(statements)`; one `pipeline_steps` row.

- [ ] **Step 1: failing tests** (`chat_ingest_test.go`, fixture DB with `chat_*` tables + a belief) — a `role='user'` turn contradicting a belief whose subject aliases the situation's channel lands as an `owner against` evidence line after the belief pass and the belief updates per rank math; `role='assistant'` turns are ignored; a turn below the floor is not re-scanned; the floor advances only after the belief pass commits (a forced belief-pass error leaves the floor unmoved — turns re-scanned next run); tables absent → no-op, floor unchanged; MEM-05: `situations`/`inbox_items` byte-identical across the sub-step (dump compare).
- [ ] **Step 2:** run → FAIL. **Step 3:** implement + wire (gated). **Step 4:** `go test ./internal/memory/ -run 'ChatIngest|Belief|Memory05'` green; daemon coverage floor holds; commit `feat(memory): ingestChatStatements — owner Discuss turns feed the belief pass (behind memory.surfaces.chat)`.

## Task 5: Briefing revision journal

**Depends on:** Tasks 1, 2. **Blocks:** Task 9. Follow `.claude/skills/add-ai-prompt` for the version bump.

**Files:** `internal/briefing/pipeline.go` (+`pipeline_test.go`); `internal/prompts/defaults.go` (`defaultBriefingDaily` + `DefaultVersions`).

- `gatherMemoryRevisions() (string, bool)`: read belief nodes from the index (`ListMemoryNodes` filtered `type='belief'`) whose file changed since the previous briefing's `generated_at` (use the existing dedup read: `GetBriefing(user, prevDate)`; fall back to a 24h window when none). Change detail comes from each belief's `## History` tail line (read via `ReadNode` — the briefing is a Go pipeline, so vault reads are fine here; this is not the Swift "index-only" constraint). **Notability filter (code):** status transitions (`→shaken`, `→retired`, a `propose-new` applied) always qualify; a confidence move qualifies at `≥0.2` delta. Cap 5 lines, each `belief title — what changed — because <evidence digest>`, framed as model-mediated memory notes.
- **Prompt placeholder:** add one positional `%s` slot to `defaultBriefingDaily` (a *Memory revisions* section) and a matching arg to the `fmt.Sprintf` in `RunForDate`. When the block is empty, render `(no notable revisions)` and instruct the model not to mention memory. **Bump `DefaultVersions[BriefingDaily]` 5→6** so user DBs auto-upgrade (per add-ai-prompt: editing a shipped template without bumping the version leaves customized DBs on the old arg count). `briefing.daily` is a single provider-agnostic template (routes strong on both claude/codex via one `Generate`); no per-provider or light-tier switch change.

Gate: assemble the block only when `p.cfg.Memory.Surfaces.Briefing`; otherwise pass the empty-placeholder string so the arg count still matches.

- [ ] **Step 1: failing tests** (`briefing/pipeline_test.go`, fake generator) — with the gate on and a belief that went `active→shaken` since the last briefing, the prompt carries a *Memory revisions* line naming it; a sub-0.2 confidence wiggle produces no line; >5 changes cap at 5; gate off → placeholder renders `(no notable revisions)` and the arg count still matches (no `%!s(MISSING)`); `DefaultVersions[BriefingDaily]==6`.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/briefing/ ./internal/prompts/` green; commit `feat(briefing): memory revision journal block (behind memory.surfaces.briefing; briefing.daily v6)`.

## Task 6: Inbox watchtower detector — dispute reader

**Depends on:** Tasks 1, 2. **Blocks:** Task 9. **READ `docs/inventory/inbox-pulse.md` + `docs/inventory/dashboard.md` FIRST** (CLAUDE.md requires it for any `internal/inbox/` change).

**Files:** `internal/inbox/watchtower_detector.go` (+`watchtower_detector_test.go`); thread `cfg` into the detector call in `internal/inbox/pipeline.go` `detectAll`.

Add a Phase to `DetectWatchtowerInternal` (or a sibling `detectMemoryDisputes`, called from the same `includeWatchtower` branch): read `dispute_pending` beliefs (`ListDisputePendingBeliefs(cap)`, cap ≤2 per cycle), and for each create an inbox item and **clear its flag in the same DB transaction** so a dispute is surfaced exactly once. Item shape (reuse the existing `decision_made` watchtower trigger_type — see Resolved ambiguity #4, no `trigger_type` CHECK migration): `channel_id="memory"`, `message_ts="dispute:<belief_id>"`, `sender_user_id="watchtower"`, `snippet = belief statement + " — evidence conflicts" + vault refs`, `ItemClass=DefaultItemClass("decision_made")`, dedup via `wtExistsInboxItem`. From there the standard pipeline owns it: triage may rank/downgrade it (**INBOX-01**: never upgraded, never dropped), compose merges it into a situation (**DASH-01**), the dashboard shows it. Because this is an ordinary detector item created before triage, **INBOX-09** (watermark) and **DASH-02** are structurally untouched.

Gate: the dispute branch runs only when `cfg.Memory.Surfaces.Disputes`. **MEM-05/MEM-10:** the flag is *read and cleared* by the inbox package (which legitimately owns `inbox_items`); the memory package never touches inbox tables.

- [ ] **Step 1: failing tests** (`watchtower_detector_test.go`) — a `dispute_pending` belief yields one `decision_made` item with the statement snippet and the flag cleared in the same run; a second run creates nothing (flag already cleared, dedup holds); the cap bounds items per cycle to ≤2; gate off → no items, flag untouched; run the existing INBOX-01/09 + DASH-01/02 guard suites (`go test ./internal/inbox/`) and assert all green.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/inbox/` fully green; commit `feat(inbox): watchtower detector surfaces memory disputes (behind memory.surfaces.disputes)`.

## Task 7: Reflection step + `memory.reflect` prompt

**Depends on:** Tasks 1, 2. **Blocks:** Task 9. Follow `.claude/skills/add-ai-prompt`.

**Files:** new `internal/memory/reflect.go` (+`reflect_test.go`); `internal/memory/vault.go` (`LogMemoryCommits`); `internal/prompts/store.go` + `defaults.go` (register `memory.reflect`); wire into `runSemantic` (tail, after eviction) gated `memory.surfaces.reflection`.

- **Register `MemoryReflect = "memory.reflect"`** at v1 (const + `Defaults`/`AllIDs`/`DefaultVersions`/`Descriptions`). Strong tier by **absence** from the light-tier switch; add a models test asserting the strong route (mirror Phase-3 Task 6). Template opens with the `%s` language-directive slot and must NOT start the user message with a `-`/`--` line (claude-CLI argv gotcha; reuse `TestBuildExtractPromptsNeverStartWithDash` shape).
- **`LogMemoryCommits(since time.Time) ([]MemoryCommit, error)`** (vault.go): walk `repo.Log`, return `{Subject, NodeIDs, When}` for `memory(beliefs)` / `memory(rewrite)` / `memory(owner-edit)` commits since `since` (sibling of `OwnerEdited`; commit subjects + `Nodes:` line only, no diff).
- **`Reflect(ctx, p, now) (n int, usage, err)`**: run at most once per 7 days via a **deterministic weekly stagger keyed on the workspace id** (mirror `dueForRewrite`/`rewriteStaggerOffset`; no new watermark column). Input = per-subject-entity commit-subject counts (from `LogMemoryCommits` over a 7-day window) + belief `## History` churn (from the index). Call `memory.reflect` (strong) for ≤3 meta-observations. **Apply each observation by code only (MEM-11, MEM-08):** a flapping belief (churn above a code constant) → `SetDisputePending(belief_id)`; a flapping entity → append a dated bullet to its `## Current` section via `WriteNodes` (an ordinary `memory(reflect)` commit, mirrored to index). Reflection **never** mutates a belief's confidence/status directly. Budget: shares the semantic output budget (skip when `outputBudgetExceeded`). `RunStats.Reflections`/`DisputesFlagged`; one `pipeline_steps` row.

- [ ] **Step 1: failing tests** — `models_test.go` (digest+codex): `memory.reflect` routes strong. `reflect_test.go` (fake generator): a belief that churned ≥N times in the window gets `dispute_pending` set (not its confidence changed — MEM-11); an entity observation appends a `## Current` note without touching any belief; the weekly stagger skips a non-due day; a model failure leaves beliefs/entities untouched and never fails the run (isolation); budget-exceeded → skipped row. `vault_test.go`: `LogMemoryCommits` returns only the three op subjects since the window.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement + wire (gated). **Step 4:** `go test ./internal/memory/ ./internal/prompts/ ./internal/digest/ ./internal/codex/ -run 'Reflect|Memory|Model|Log'` green; commit `feat(memory): weekly reflection pass over vault history (behind memory.surfaces.reflection)`.

## Task 8: Swift — MEMORY block in `buildSystemPrompt`

**Depends on:** Tasks 1, 2. **Blocks:** Task 9. Follow `.claude/skills/add-desktop-feature`.

**Files:** `WatchtowerDesktop/Sources/ViewModels/SituationChatViewModel.swift`; `WatchtowerDesktop/Sources/Utilities/Constants.swift` (nonisolated helpers); `WatchtowerDesktop/Tests/SituationChatViewModelTests.swift`.

Add a MEMORY section to `buildSystemPrompt` **between the owner brief and the TOOLS block**, behind `memory.surfaces.chat`:
- **Config read (nonisolated):** add `Constants.memorySurfacesChatEnabled() -> Bool` and `Constants.memoryVaultDir() -> String?` (mirror `activeWorkspaceDir()`'s Yams parse of `config.yaml` → `memory.surfaces.chat` and `<activeWorkspaceDir>/memory`). `buildSystemPrompt` is a `nonisolated static` func, so pass `memoryChatEnabled: Bool = Constants.memorySurfacesChatEnabled()` as a defaulted param — production reads the flag; tests inject it explicitly. Off → emit nothing (byte-identical to today's prompt).
- **Hot map:** read `<memoryVaultDir>/map.md` from disk; include verbatim, **4 KB code-side cap** (truncate at a line boundary). Absent → a one-line note; do not fail.
- **Relevant memory (pure GRDB index reads — no vault file parsing beyond map.md):** query `memory_aliases`⋈`memory_nodes` for `type='entity'` nodes whose `alias` matches the situation's `channelID` or any member `senderUserID` (≤5); then `SELECT title, confidence, status FROM memory_nodes WHERE type='belief' AND status IN ('active','shaken') AND subject IN (<entity ids>)` (≤5). This is exactly why Task 1 added `subject`/`confidence` to the index. Render beliefs as `statement (confidence, status)`; a `shaken` belief renders with an explicit `(uncertain — evidence conflicts)` marker (the brainstorm's "lazy questions in context").
- **Framing:** label the block "MEMORY (notes the secretary has built from Slack/Jira — model-mediated, not the owner's own words)" per the memory.md Phase-4 framing limitation.
- **Tools line:** extend the existing TOOLS paragraph with `memory_recall` / `memory_open` / `memory_map` (already registered on the same MCP server the chat uses) and the hint "check what the secretary already knows before asking the user."

Add fixture-DB unit tests per add-desktop-feature (MVVM/GRDB): seed `memory_nodes`/`memory_aliases` in a temp GRDB DB and a temp `map.md`.

- [ ] **Step 1: failing tests** (`SituationChatViewModelTests.swift`) — gate on: an entity aliasing the situation channel + an active belief appear in the prompt, a `shaken` belief carries `(uncertain — evidence conflicts)`, the tools line advertises the three memory tools; a 6 KB `map.md` is truncated to ≤4 KB; gate off: the prompt is byte-identical to the pre-Phase-4 output (no MEMORY section); absent `map.md` / no matching entities: the block degrades to a one-line note without crashing.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `swift build` + SwiftLint clean; `swift test --filter SituationChatViewModelTests` green; commit `feat(desktop): MEMORY block in situation Discuss prompt (behind memory.surfaces.chat)`.

## Task 9: MEM-09/10/11 guards + inventory + final-validation Section 2

**Depends on:** Tasks 3, 4 (MEM-09), 6 (MEM-10), 5, 7, 8 (MEM-11). **Blocks:** Task 10.

Add the three guard tests exactly as named in the spec; do NOT weaken MEM-01..08 / INBOX / DASH.
- **`TestMemory09_OwnerRankOnlyFromAuthoredTurns`** (`beliefs_test.go` / `chat_ingest_test.go`): owner-rank evidence is minted only for `chat:` refs backed by a `role='user'` turn (and `memory(owner-edit)` commits); a model op that names/forges owner rank, or cites a `role='assistant'` / non-existent chat turn, never yields an `owner` evidence line.
- **`TestMemory10_DisputeFlagsNeverTouchInboxFromMemory`** (`internal/memory/…_test.go`): across a full semantic run with `dispute_pending` flags set, `inbox_items`/`situations`/`situation_signals` are byte-identical (dump compare) — the memory pipeline sets the flag but never creates the item; only the inbox detector (Task 6) does.
- **`TestMemory11_SurfacesDontMutateBeliefs`** (`reflect_test.go` + `briefing/pipeline_test.go`): the briefing journal read and a reflection pass leave every belief's confidence/status/stability unchanged (reflection writes only `dispute_pending` + entity `## Current` notes).

Docs:
- [ ] Append **MEM-09/10/11** to `docs/inventory/memory.md` (Status/Observable/Why-locked/Test-guards/Locked-since 2026-07-16) with a changelog entry; add the `dispute_pending` runtime-column note (MEM-02 ignore, self-healing on reindex) and the `chat:` evidence-grammar note to Known-limitations; resolve the existing "Phase 4 must frame vault text as model-mediated" limitation into a shipped behavior note.
- [ ] Add a short cross-reference in `docs/inventory/inbox-pulse.md` (changelog): the watchtower detector now also surfaces memory disputes as `decision_made` items behind `memory.surfaces.disputes` — INBOX-01/09 + DASH-01/02 unchanged (ordinary detector item).
- [ ] Write `docs/specs/memory-final-validation-task.md` **Section 2** — the concrete staged-disagreement drill (spec §Validation): tell the secretary in Discuss something contradicting a belief → next consolidation: owner `chat:` evidence lands, belief updates per rank math; force the reverse (secretary evidence against an owner statement, owner support decayed/absent) → dispute situation appears on the dashboard with working vault links; next-morning briefing carries the revision line; reflection produces a sane weekly note.
- [ ] Commit `docs(memory): MEM-09/10/11 contracts + Phase-4 validation drill`.

## Task 10: Docs — CLAUDE.md + app-guide

**Depends on:** Tasks 3–8. **Blocks:** nothing.

- [ ] Refresh `CLAUDE.md`'s memory feature note: the four Phase-4 surfaces, each behind `memory.surfaces.*` (default false); owner rank minted only by code from `role='user'` turns / owner-edit commits (MEM-09); disputes ride the inbox detector, not a memory write (MEM-05/10); surfaces are read-only over history (MEM-11).
- [ ] Refresh `docs/app-guide.md`: the Discuss chat now sees a MEMORY block + memory tools; the briefing may carry *Memory revisions*; serious disagreements appear as dashboard situations; weekly reflection notes.
- [ ] Commit `docs: Phase-4 memory surfaces (CLAUDE.md + app-guide)`.

## Self-Review

- [ ] `gofmt -l . && go vet ./... && go build ./... && go test ./...` green; `golangci-lint run` clean; daemon coverage floor (70) satisfied; sentrux baseline unchanged or refreshed intentionally. Swift: `swift build` + SwiftLint clean, `swift test` green.
- [ ] Guard sweep: MEM-01..08 tests byte-unchanged **except** the deliberate, owner-approved MEM-02 dump-normalization extension (Task 1); INBOX-01..09 + DASH-01..07 byte-unchanged and green; MEM-09/10/11 present and green; every `TestMemoryNN_`/`TestInboxNN_` still in the naming convention.
- [ ] MEM-05/10 grep check: `grep -rn "inbox_\|situations\b" internal/memory/` shows reads only; no `inbox_items`/`situations`/`situation_signals` writes and no `inbox_last_processed_ts` / `SetMemoryWatermark`-into-inbox from any memory step. Dispute item creation lives only in `internal/inbox/`.
- [ ] MEM-09 grep check: the only `rankOwner` mint sites are code paths keyed on `chat:` prefix + `role='user'` (Task 3) or `memory(owner-edit)`; the belief-op JSON schema carries no rank field.
- [ ] All four surfaces default off: with `memory.surfaces.*` all false, a consolidate run + a briefing + an inbox cycle + the Swift prompt are byte-identical to pre-Phase-4 behavior.
- [ ] Manual E2E: run the Section-2 staged-disagreement drill end to end with the four gates on.
- [ ] Run `/local-review` before PR.

## Resolved ambiguities (for reviewer attention)

1. **`chat_conversations`/`chat_messages` are Swift-owned, not in the Go schema.** They are created lazily by the Desktop app (`ChatConversationQueries.ensureTable` / `ChatMessageQueries.ensureTable`), so they are absent on a headless daemon until the user opens a Discuss chat. Columns used: `chat_conversations(id INTEGER PK, context_type TEXT='situation', context_id TEXT=<situation id>, ...)`; `chat_messages(id INTEGER PK AUTOINCREMENT, conversation_id INTEGER FK, role TEXT ∈ {user,assistant}, text TEXT, created_at REAL unix-seconds)`. **Turn identity = `chat_messages.id`** (the floor is `MAX(id)`); **turn ts = `chat_messages.created_at`** (cast to INTEGER seconds for the evidence line). Go must guard table-absence (`chatTablesPresent`) and treat it as an empty read, never an error (Tasks 3, 4).
2. **`dispute_pending` placement + the MEM-02 tension.** Primary: a `memory_nodes.dispute_pending` column (as the spec names it), which is **runtime** state (not file-derived), so `TestMemory02_ReindexEquivalence` must ignore it (sibling of `indexed_at`) — an additive normalization requiring @Vadym sign-off since it edits a MEM- guard. Fallback if the owner declines: a separate `memory_disputes(node_id, flagged_at, reason)` side table (naturally excluded from MEM-02, like `memory_node_stats`/`memory_entity_hints`) — same detector/consumer logic, no guard touch. Resetting the flag on reindex is safe: a still-conflicting belief is re-flagged by the next belief pass (self-healing).
3. **`subject`/`confidence` added to the index (beyond the spec's stated two columns).** The spec's Swift block requires "active/shaken beliefs whose subject is one of those entities … statement + confidence + status … pure index reads." The Phase-3 index has none of `subject`/`confidence` (only `id/type/tier/status/title/...`), so the join is impossible index-only. Both are **file-derived** (`Node.Subject`/`Node.Confidence`), so adding them keeps MEM-02 green with no guard change (both incremental and rebuild populate them identically from `ParseNode`). They live in the same 00019 migration.
4. **Dispute trigger_type reuses `decision_made` (no CHECK migration).** The spec says "reuse the watchtower type"; `inbox_items.trigger_type` is a CHECK enum whose expansion needs the table-recreation dance. Reusing the existing watchtower-family `decision_made` type (with `channel_id="memory"`, `message_ts="dispute:<belief_id>"`) avoids that. Trade-off: `decision_made` is `ambient` by default, so a dispute does not *demand* a reply out of the gate (triage/compose still surface it as a situation). Whether disputes deserve a dedicated **actionable** `memory_dispute` type (CHECK-expansion migration) is a validation-time tuning decision, matching the spec's "documented defaults, not blockers."
5. **How Swift reads config.** `ConfigService` parses `config.yaml` with Yams (it does not shell out to the Go CLI). `buildSystemPrompt` is `nonisolated static`, so it reads `memory.surfaces.chat` via a new nonisolated `Constants.memorySurfacesChatEnabled()` YAML helper (mirroring `Constants.activeWorkspaceDir()`), injected as a defaulted param for testability. The memory vault dir is `Constants.activeWorkspaceDir()/memory` (map.md read from disk).
6. **Briefing placeholder = template edit + version bump, not a new prompt ID.** `briefing.daily` is a single positional-`%s` template at `DefaultVersions[BriefingDaily]=5`; the journal is one added `%s` + one added `fmt.Sprintf` arg + a bump to **6** (per add-ai-prompt: an edited shipped template without a version bump leaves customized DBs on the old arg count → `%!s(MISSING)`). "Both providers" is satisfied by the single provider-agnostic template routed through one `Generate` — no per-provider template and no light-tier switch entry (briefing is already strong by absence).
7. **Reflection cadence = deterministic weekly stagger keyed on the workspace id** (mirrors `dueForRewrite`), so no new watermark column is needed and the pass fires at most once per 7 days without a `memory_last_reflected_at` scalar. Reflection applies observations as `dispute_pending` flags and entity `## Current` notes only — never a direct belief mutation (MEM-11).
8. **`ingestChatStatements` gate.** The owner write-back is part of "surface 2 (chat)", so it is gated by `memory.surfaces.chat` (the same flag that turns on the Swift injection) rather than a separate flag — the two halves of the chat surface travel together.
