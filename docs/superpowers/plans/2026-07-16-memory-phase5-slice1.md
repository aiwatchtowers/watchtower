# Secretary Memory Phase 5 — SLICE 1 (Universal substrate: registry + Gmail source + mechanical interaction ingest): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task is sized for one focused agent session; obey the stated dependencies. Read `docs/superpowers/specs/2026-07-16-memory-phase5-universal-substrate-design.md` (SLICE-1 scope only: §5A resolver registry + Gmail; §5D mechanical parts) and `docs/inventory/memory.md` (MEM-01..11) **first**.

**Scope (this plan covers ONLY):**
1. **The provenance-resolver registry (MEM-12, the enabling refactor):** one interface, one validator per ref scheme, replacing the two hardcoded provenance checks that exist today (`messageChecker.MessageExists` for Slack refs; `validateChatRefs` for `chat:` refs). MEM-01 generalizes from hardcoded cases to registered resolvers; an unregistered scheme is rejected at write.
2. **5A Gmail source:** a Gmail thread → episode extractor (a thread IS one story arc), sender → person entities with email aliases (identity stitching via the alias table), the `mail:<message_id>` ref scheme, its own extraction watermark, behind the dark flag `memory.sources.gmail`.
3. **5D mechanical interaction ingest:** the `act:<table>:<id>` ref scheme, a new `owner-action` evidence rank in the belief math (between `observed` and `owner`), episode-mirror outcome annotations, and per-entity engagement aggregates that feed retention importance. Behind `memory.sources.actions`. **No preference beliefs** — that is semantic 5D, a later slice.

**Everything else is OUT of this plan:** calendar, Jira, chats-generalization, 5B render inversions, 5C internal-entity mirrors, the semantic 5D preference-belief pass.

**Architecture (extends the Phase-0–4 pipeline; nothing in the existing order changes):**
- A new `internal/memory/provenance.go` holds the **`ProvenanceRegistry`**: `channel_id` scheme (the prefix before the first `:`, or `""` for a bare Slack channel id) → a `ProvenanceResolver` that answers "does this ref resolve against a raw source of record?". The pipeline builds one registry at construction with four resolvers: `message` (Slack, scheme `""`), `chat` (scheme `chat`), `mail` (scheme `mail`), `act` (scheme `act`). `validateRefs` (extractor) and `validateChatRefs` (belief pass) both route through it; the freeze-vs-drop *policy* stays at each call site (MEM-01/MEM-04 extractor freeze; belief-pass soft-drop) — the registry only answers existence.
- `internal/memory/gmail_extract.go` — a cheap-tier thread→episode extractor over `gmail_messages`, mirroring the Slack extractor's batching + own-watermark + MEM-04 freeze discipline. New prompt `memory.extract_email_episodes`. Wired into `Run` as a new step behind `memory.sources.gmail`, with its own watermark `workspace.memory_gmail_last_extracted_ts` (separate from the Gmail *sync* watermark `gmail_last_internal_date` and from the Slack extraction watermark `memory_last_extracted_ts`).
- Gmail sender seeding folds into the existing mechanical `SeedEntities` pass as a new `seedGmailSenders` source (email-alias identity stitching — an email that already resolves to a seeded Slack person is skipped).
- `belief_math.go` gains `rankOwnerAction` between `rankObserved` and `rankOwner`; `beliefs.go`'s `newEvidenceLines` mints it for validated `act:` refs (MEM-15 — code-minted only, never a model rank). Owner-action does **NOT** confer MEM-06 fresh-owner protection (recorded ambiguity #4).
- `internal/memory/interaction_ingest.go` — a mechanical (no-AI) sub-step behind `memory.sources.actions`: reads `inbox_feedback` / `user_interactions` / `decision_reads` / situation transitions + conversions above an interaction floor, annotates situation episode mirrors with interaction outcomes, and accumulates per-entity engagement aggregates in a new memory-owned side table `memory_engagement`. Advances `workspace.memory_last_interaction_id`.
- `evict.go`'s `RetentionInputs`/`RetentionScore` gain an engagement-importance term read from `memory_engagement` (the Phase-3 retention-importance input that was stubbed — the access-stats known-limitation finally gets a live, writable consumer that is NOT `memory_node_stats`).

**Tech stack:** unchanged. Go 1.25, `modernc.org/sqlite`, goose migrations, `digest.Generator` (mocked in tests). No Swift in this slice.

## Precondition (do not start until it lands)

All Phase-0–4 code is merged on `feature/memory-phase5` (the worktree contains phases 0–4). Confirm `go test ./internal/memory/ ./internal/db/ ./internal/inbox/ ./internal/gmail/ ./internal/config/ ./cmd/` is green before Task 1. Read `internal/memory/{beliefs.go, belief_math.go, extract.go, pipeline.go, evict.go, seed.go, resolver.go, ingest.go}` and `internal/db/{memory.go, gmail.go}` in full first — the registry (Task 1), the Gmail extractor (Tasks 4–5), the owner-action rank (Task 6), and the interaction ingest (Task 7) each extend a specific seam in those files.

## Global Constraints

- Module path `watchtower`, Go 1.25. Before each commit: `gofmt -l`, `go vet ./...`, `go build ./...`, and the affected package tests green; `golangci-lint run` clean before PR; daemon coverage floor (70) satisfied; sentrux baseline refreshed only intentionally.
- **Never weaken a guard.** MEM-01..11, INBOX-01..09, DASH-01..07 stay exactly as they read today. New contracts follow the `TestMemoryNN_...` naming convention (MEM-12 registry, MEM-15 action-rank). MEM-13/14 are OUT of this slice (they cover 5B/5C).
- **MEM-01 preserved and generalized (MEM-12).** Every provenance ref written to the vault still resolves against a raw source of record at write time — now *via a registered resolver* instead of a hardcoded `MessageExists`. A ref whose scheme has **no registered resolver** is rejected and counted (MEM-12), never written. The extractor freeze on a lookup *error* (MEM-01/MEM-04) and the belief-pass soft-drop on a `chat:`/`act:` lookup *error* both stay exactly as they are — the registry returns `(ok, err)`; the *caller* keeps its disposition.
- **MEM-05 preserved (restated for Slice 1).** Neither the Gmail extractor nor the interaction-ingest step writes `inbox_items` / `situations` / `situation_signals` or moves `inbox_last_processed_ts`. The interaction step is a **pure reader** of `inbox_feedback` / `user_interactions` / `decision_reads` / `situations`; all its writes land in the vault, the memory-owned `memory_engagement` side table, or `workspace` scalars.
- **MEM-06 preserved (restated for the new rank).** `owner-action` rank is authentically the owner but **non-propositional and ambiguous** (a dismissal has many readings), so it weighs less than the owner's own words AND — decisively — it does **not** trigger MEM-06 fresh-owner protection. `hasFreshOwnerSupport` continues to key on `rankOwner` **exactly**; `rankOwnerAction` never protects a belief from retirement. (Recorded ambiguity #4; a `TestMemory06_*` guard must stay byte-green — assert an owner-action line does NOT protect.)
- **MEM-08/MEM-09 preserved and extended (MEM-15).** The belief-op JSON schema still carries **no rank field**; the model proposes a ref + direction, the code mints the rank. `owner-action` is minted **only** by `newEvidenceLines` for an `act:` ref that a registered resolver confirmed points at a real owner-interaction row — the model can mint neither `owner` nor `owner-action`.
- **Every source is independently dark.** `memory.sources.gmail` and `memory.sources.actions` default `false`; each gated path is a byte-identical no-op when its flag is off; the two flags have independent blast radii and are independent of `memory.semantic.enabled` and the `memory.surfaces.*` gates.
- **All vault writes flow through the Phase-0–3 commit discipline** (`Vault.WriteNodes` after `CommitOwnerEdits`; index mirrored via `upsertIndexNode`). No step writes files outside the vault helpers.
- **MEM-04 watermark discipline for Gmail.** The Gmail extractor advances `memory_gmail_last_extracted_ts` only behind fully-committed thread batches, freezes on AI/lookup failure, and never advances past an unextracted thread — the exact freeze discipline the Slack extractor uses, over threads instead of channel windows.
- **Runtime side tables are MEM-02-exempt.** `memory_engagement` is derived-from-interactions runtime state (the `memory_node_stats`/`memory_entity_hints` precedent), so it is excluded from `TestMemory02_ReindexEquivalence` and — like `memory_entity_hints`, not `memory_node_stats` — is NOT cleared by `DropMemoryIndex` (a reindex must not lose accumulation the interaction floor has already stepped past). Add it to `TestAllTablesExist`.
- English docs. Every new AI step gets a fake-`Generator` fixture test; the registry, the rank math, and the ref-grammar validators are pure-function / seam tested.

## File Structure

- `internal/db/migrations/00022_memory_phase5_slice1.sql` (+ mirror in `internal/db/schema.sql`, golden snapshot, `TestAllTablesExist`) — `workspace.memory_gmail_last_extracted_ts REAL NOT NULL DEFAULT 0`; `workspace.memory_last_interaction_id INTEGER NOT NULL DEFAULT 0`; new table `memory_engagement(node_id TEXT PRIMARY KEY REFERENCES memory_nodes(id), engaged_count INTEGER NOT NULL DEFAULT 0, dismissed_count INTEGER NOT NULL DEFAULT 0, last_interaction_at TEXT NOT NULL DEFAULT '')`. All additive `ALTER TABLE ADD COLUMN` + one `CREATE TABLE` — no CHECK change, no table recreation.
- `internal/memory/provenance.go` (+`provenance_test.go`) — `ProvenanceResolver` interface, `ProvenanceRegistry`, scheme classifier, and the four resolvers (`message`/`chat`/`mail`/`act`). Migrates the bodies of today's `MessageExists` and `validateChatRefs` checks in.
- `internal/memory/beliefs.go` — `validateMarkers`/`validateChatRefs` re-expressed over the registry (`p.registry`); `newEvidenceLines` mints `rankOwnerAction` for `act:` refs.
- `internal/memory/belief_math.go` (+`belief_math_test.go`) — `rankOwnerAction` const between `rankObserved`/`rankOwner`; `evidenceWeight`/`parseEvidenceRank`/`rankName` cases; `hasFreshOwnerSupport` **unchanged**.
- `internal/db/memory.go` (+`memory_test.go`) — `GmailMessageExists(id)`; `GmailThreadExists`/`ListGmailThreadsForExtract(sinceTS, limit)` + `MemoryGmailWatermark`/`SetMemoryGmailWatermark`; `InteractionExists(table, id)`; `MemoryInteractionFloor`/`SetMemoryInteractionFloor`; `BumpEngagement(nodeID, engaged bool, at)` + `GetEngagement(nodeID)`; the `memory_engagement` accessors are additive.
- `internal/memory/gmail_extract.go` (+`gmail_extract_test.go`) — thread grouping, batching, `extractGmailThreads`, MEM-04 watermark, `pipeline_steps` rows.
- `internal/memory/seed.go` (+`seed_test.go`) — `seedGmailSenders` source (email-alias identity stitching).
- `internal/memory/interaction_ingest.go` (+`interaction_ingest_test.go`) — the 5D mechanical sub-step.
- `internal/memory/evict.go` (+`evict_test.go`) — `RetentionInputs.Engagement` term in `RetentionScore`.
- `internal/memory/pipeline.go` — wire the Gmail extractor (behind `memory.sources.gmail`) and the interaction ingest (behind `memory.sources.actions`); `RunStats` gains `GmailEpisodes`, `GmailThreadsFailed`, `InteractionsIngested`, `EngagementUpdated`.
- `internal/prompts/store.go`, `internal/prompts/defaults.go` — register `memory.extract_email_episodes` (const + `Defaults` + `AllIDs` + `DefaultVersions` + `Descriptions`); add its source tag to the **light-tier switch** in `internal/digest/models.go` **and** `internal/codex/models.go`.
- `internal/config/config.go` — `MemoryConfig.Sources MemorySourcesConfig{Gmail, Actions bool}`; `SetDefault` per flag. `cmd/config.go` — two keys in `knownConfigKeys` (+ cmd test).
- `docs/inventory/memory.md` (+ changelog), `CLAUDE.md`, `docs/app-guide.md`, `docs/specs/memory-final-validation-task.md` (Section 3).

---

## Task 1: Provenance-resolver registry (MEM-12)

**Depends on:** nothing. **Blocks:** Tasks 4, 5, 6, 7, 9.

**Files:** new `internal/memory/provenance.go` (+`provenance_test.go`); modify `internal/memory/beliefs.go` (`validateMarkers`/`validateChatRefs` seams), `internal/memory/pipeline.go` (build the registry in `NewPipeline`). Read `extract.go`'s `messageChecker`/`validateRefs` and `beliefs.go`'s `validateChatRefs`/`parseChatRef` in full first.

Define the seam and migrate the two existing hardcoded validators into it, changing **no observable behavior** for Slack or chat refs:

```go
type ProvenanceResolver interface {
    Scheme() string                    // "" (Slack), "chat", "mail", "act"
    Validate(ref episodeRef) (ok bool, err error)
}
type ProvenanceRegistry struct { byScheme map[string]ProvenanceResolver }
func (r *ProvenanceRegistry) Validate(ref episodeRef) (ok, registered bool, err error)
```

- `schemeOf(channelID)` returns the substring before the first `:` if that prefix is a registered scheme, else `""` (a Slack channel id has no `:`; `act:<table>:<id>` classifies as scheme `act` on its first segment).
- Register in `NewPipeline`: `messageResolver{db}` (scheme `""`, body = today's `MessageExists`), `chatResolver{db}` (scheme `chat`, body = today's `ChatTablesPresent` + `OwnerChatTurnExists` role='user' owner check — the **owner-authenticity check folds into the chat resolver's existence check**: a `chat:` ref "resolves" iff it is a genuine `role='user'` situation turn, which keeps MEM-09 exactly). `mailResolver`/`actResolver` are added in Tasks 4/6 respectively (register a stub now returning `(false, nil)` so the scheme is *registered*, or defer registration — decide in-task, but the scheme name must be reserved so an early Task-1 MEM-12 test can assert an *unregistered* scheme like `bogus:` is rejected).
- **MEM-12 write-time rejection:** `validateMarkers` (extractor input-set validation) and the belief-pass ref validation both call `registry.Validate`; a ref whose `registered == false` is **dropped and counted** exactly like an invented ref (never written). A `chat:`/`act:` lookup *error* stays a soft drop (belief pass); a Slack lookup *error* stays a fatal freeze (extractor / `validateRefs`) — the caller keeps its policy.
- **Behavior-parity requirement:** `validateRefs` (extract.go) and `validateChatRefs` (beliefs.go) become thin adapters over the registry. Every existing MEM-01/MEM-08/MEM-09 guard test must pass **byte-unchanged**; the registry is a pure refactor of the lookup, not of the disposition.

- [ ] **Step 1: failing tests** (`provenance_test.go`) — `schemeOf` classifies `"C0123"→""`, `"chat:42"→"chat"`, `"mail:abc"→"mail"`, `"act:inbox_feedback:7"→"act"`, `"bogus:x"→"bogus"`; `registry.Validate` dispatches a Slack ref to the message resolver, a `chat:` ref to the chat resolver; an **unregistered scheme** returns `registered=false`; a resolver lookup error propagates as `err`. **`TestMemory12_UnregisteredSchemeRejectedAtWrite`**: an extractor/belief ref carrying an unregistered scheme is dropped-and-counted, never written.
- [ ] **Step 2:** run → FAIL (plus assert the existing `internal/memory/` MEM-01/08/09 suites STILL compile against the new seam). **Step 3:** implement the registry; rewrite `validateRefs`/`validateChatRefs` as adapters; build the registry in `NewPipeline`. **Step 4:** `go test ./internal/memory/ -run 'Provenance|Memory01|Memory08|Memory09|Memory12|Belief|Extract|Chat'` green — every pre-existing guard byte-unchanged. Commit `refactor(memory): provenance-resolver registry (MEM-12); migrate slack+chat validators`.

## Task 2: Config — `memory.sources.{gmail,actions}` gates

**Depends on:** nothing (parallel with Task 1). **Blocks:** Tasks 4, 5, 7.

**Files:** `internal/config/config.go`, `cmd/config.go` (+`_test.go`).

Add `type MemorySourcesConfig struct { Gmail, Actions bool }` (mapstructure `gmail`/`actions`) and `Sources MemorySourcesConfig \`mapstructure:"sources"\`` on `MemoryConfig` (next to `Surfaces`). `v.SetDefault("memory.sources.gmail", false)` + `("memory.sources.actions", false)` in the `memory.*` block (~config.go:320, beside the surfaces defaults). Register both in `knownConfigKeys` (cmd/config.go:~216, next to `memory.surfaces.*`) with a cmd-test extension.

- [ ] **Step 1: failing tests** — config test: the two `memory.sources.*` defaults are present and false; cmd test: `watchtower config set memory.sources.gmail true` is accepted (not warned as unknown).
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/config/ ./cmd/ -run 'Config|Memory'` green; commit `feat(config): memory.sources.{gmail,actions} gates (default false)`.

## Task 3: Migration 00022 — Gmail extract watermark + interaction floor + engagement side table

**Depends on:** nothing (parallel with Tasks 1, 2). **Blocks:** Tasks 4, 5, 7, 8. Follow `.claude/skills/add-migration`.

**Files:** new `internal/db/migrations/00022_memory_phase5_slice1.sql`; modify `internal/db/schema.sql`, the golden snapshot, `internal/db/db_test.go` (`TestAllTablesExist`), `internal/db/memory.go` (+`_test.go`).

Three additive changes (no CHECK change, no table recreation → no `foreign_keys=OFF` dance):
1. `workspace.memory_gmail_last_extracted_ts REAL NOT NULL DEFAULT 0` — the Gmail episode-extraction watermark (unix seconds of the newest thread message fully extracted). **Distinct** from `gmail_last_internal_date` (sync watermark) and `memory_last_extracted_ts` (Slack extraction watermark).
2. `workspace.memory_last_interaction_id INTEGER NOT NULL DEFAULT 0` — the 5D interaction-ingest floor.
3. `memory_engagement(node_id TEXT PRIMARY KEY REFERENCES memory_nodes(id), engaged_count INTEGER NOT NULL DEFAULT 0, dismissed_count INTEGER NOT NULL DEFAULT 0, last_interaction_at TEXT NOT NULL DEFAULT '')` — per-entity engagement aggregates; runtime side table (MEM-02-exempt; NOT dropped by `DropMemoryIndex` — the `memory_entity_hints` precedent). Add to `TestAllTablesExist` and `DropMemoryIndex` must **not** touch it.

Down: drop the two columns (SQLite ≥3.35 `DROP COLUMN`, precedent 00019 Down) and `DROP TABLE memory_engagement`.

DB helpers (in `internal/db/memory.go`): `MemoryGmailWatermark()`/`SetMemoryGmailWatermark(ts)` (mirror `MemoryWatermark`); `MemoryInteractionFloor()`/`SetMemoryInteractionFloor(id)` (mirror `MemoryChatTurnFloor`); `BumpEngagement(nodeID string, engaged bool, at string)` (upsert incrementing `engaged_count` or `dismissed_count`, `memory_node_stats` upsert precedent) + `GetEngagement(nodeID) (engaged, dismissed int, err error)`.

- [ ] **Step 1: failing tests** (`internal/db/memory_test.go` + `db_test.go`) — the two workspace scalars default 0 and round-trip via the setters; `memory_engagement` exists (add to `TestAllTablesExist`), `BumpEngagement`/`GetEngagement` accumulate engaged/dismissed and stamp `last_interaction_at`; `DropMemoryIndex` leaves `memory_engagement` rows intact (survives reindex).
- [ ] **Step 2:** `go test ./internal/db/ -run 'Migration|AllTables|MemoryGmail|Interaction|Engagement|SchemaGolden'` → FAIL. **Step 3:** implement goose Up/Down, schema.sql mirror, helpers. **Step 4:** regenerate `go test ./internal/db/ -run TestSchemaGolden -update`; full `go test ./internal/db/` green. Commit `feat(db): gmail-extract watermark + interaction floor + memory_engagement side table (00022)`.

## Task 4: `mail:` resolver + Gmail sender → person seeding

**Depends on:** Tasks 1, 3. **Blocks:** Tasks 5, 9.

**Files:** `internal/memory/provenance.go` (add `mailResolver`, register it), `internal/db/memory.go` (`GmailMessageExists`), `internal/memory/seed.go` (+`seed_test.go`) (`seedGmailSenders`). Read `seed.go`'s `seedPeople` (email-alias handling) first.

- **`mail:` resolver.** `mailResolver.Validate(ref)`: `channel_id = "mail:<message_id>"`, `ts = <internal_date unix seconds>`. Existence keys on the message id only — `db.GmailMessageExists(strings.TrimPrefix(channelID, "mail:"))` (`SELECT 1 FROM gmail_messages WHERE id=?`); the `ts` is carried for the belief/retention age math, not re-validated (mirrors how the Slack resolver keys on `channel_id + ts` but mail's identity is the message id). Register into the pipeline registry (always registered — `gmail_messages` is a base table, present even when the source is dark).
- **`seedGmailSenders`** — a new loader in the `SeedEntities` fan-out (`seedPeople, seedChannels, seedJiraProjects, seedGmailSenders`): one candidate per distinct `from_email` that sent a message in the seed window, titled from `from_name` (fallback: the local-part of the email), alias = the email address (lower-cased; the alias column is COLLATE NOCASE). **Identity stitching is free:** `SeedEntities`'s existing `LookupMemoryAlias(c.aliases[0])` idempotency check means an email that already resolves to a seeded Slack person (who carried that email as an alias, per `seedPeople`) is skipped — the sender is unified with the existing person, no duplicate entity. A genuinely external sender becomes a new person entity. No activity threshold beyond "sent ≥1 kept message in the window" (external senders are sparse; the `seed_min_messages` floor is Slack-specific).

- [ ] **Step 1: failing tests** — `provenance_test.go`: a `mail:` ref for an existing `gmail_messages.id` validates; a missing id drops-and-counts; a DB error propagates. `seed_test.go`: a distinct external `from_email` becomes a person entity aliased by its email; a `from_email` equal to an already-seeded Slack user's email creates **no** second entity (stitched); re-running `SeedEntities` is a no-op (idempotent).
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/memory/ ./internal/db/ -run 'Provenance|Seed|GmailMessage'` green; commit `feat(memory): mail: provenance resolver + gmail sender→person seeding (email-alias stitching)`.

## Task 5: Gmail thread → episode extractor + `memory.extract_email_episodes` + Run wiring

**Depends on:** Tasks 2, 3, 4. **Blocks:** Task 9. Follow `.claude/skills/add-ai-prompt`.

**Files:** new `internal/memory/gmail_extract.go` (+`gmail_extract_test.go`); `internal/db/memory.go` (`ListGmailThreadsForExtract`); `internal/prompts/store.go` + `defaults.go` (register `memory.extract_email_episodes`); `internal/digest/models.go` + `internal/codex/models.go` (light-tier switch entry); wire into `internal/memory/pipeline.go` `Run` behind `memory.sources.gmail`.

- **Grouping key = `thread_id`.** `ListGmailThreadsForExtract(sinceTS, limit)` loads `gmail_messages` with `internal_date` (unix) strictly above `memory_gmail_last_extracted_ts`, oldest-first, grouped by `thread_id` — each thread is one extraction unit (a thread IS one story arc: participants, question, resolution). Cap threads per run (reuse a `max_chunk` bound) and batch small threads into one AI call the way `groupWindowsIntoBatches` packs quiet channels; a large thread gets a solo call.
- **New prompt `memory.extract_email_episodes` (cheap tier).** A separate prompt, **not** a reuse of `memory.extract_episodes` (resolved ambiguity #2): an email thread differs structurally from a channel window — it has a subject line, explicit From/To/Cc participant identity, and maps to **one** episode per thread rather than N-per-window. The prompt renders `Subject: … / Participants: … / [internal_date] from_name <from_email>: body` lines and returns the same `extractedEpisode` JSON schema, but each `ref` is `{channel_id: "mail:<message_id>", ts: "<internal_date unix>"}`. Register at v1; add `"memory.extract_email_episodes"` to the light-tier switch in **both** `models.go` files (a `models_test.go` case asserting the cheap route, mirroring the existing `memory.extract_episodes` entry). The user message must not open with a `-`/`--` line (claude-CLI argv gotcha — reuse the `TestBuildExtractPromptsNeverStartWithDash` shape).
- **Provenance + MEM-01/MEM-12.** Extracted refs validate through the registry's `mail:` resolver (Task 4). `refsSameChannel` / `splitMalformed` generalize: a thread-episode's refs must all share the same `thread_id` **channel bucket** — but since each ref is a distinct `mail:<message_id>`, replace the "same channel_id" degeneracy check with "all refs belong to the extracted thread" (the thread id is known at call time; a ref to a message outside the thread is degenerate). Zero-ref episodes stay degenerate → batch freeze (MEM-04).
- **Own watermark (MEM-04).** Advance `memory_gmail_last_extracted_ts` only behind committed thread batches, never past a failed/pending thread — a thread-level `safeWatermark` analog over `internal_date`. A batch AI failure freezes every thread in that batch and re-extracts next run. Record one `pipeline_steps` row per batch (`channel_name` = subjects/thread ids). `RunStats.GmailEpisodes` / `GmailThreadsFailed`.
- **Run wiring.** Add step 4b in `Run`, after the Slack `runExtract` and before the semantic tier, gated `if p.cfg.Sources.Gmail`. Same isolation contract as Slack extraction: a per-batch failure never fails the run. The Slack extraction watermark is untouched.

- [ ] **Step 1: failing tests** (`gmail_extract_test.go`, fake generator + fixture `gmail_messages`) — a two-message thread becomes one episode with two `mail:` refs and the right participants; refs validate through the registry; a shape-degenerate reply (zero refs) freezes the Gmail watermark (thread re-extracted next run) while a good sibling batch commits; the watermark never advances past a failed thread; gate off (`memory.sources.gmail=false`) → no Gmail work, watermark unmoved, `Run` byte-identical to today. `models_test.go`: `memory.extract_email_episodes` routes cheap on both providers.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement + wire (gated). **Step 4:** `go test ./internal/memory/ ./internal/prompts/ ./internal/digest/ ./internal/codex/ -run 'GmailExtract|Model|Extract|Memory04'` green; daemon coverage floor holds; commit `feat(memory): gmail thread→episode extractor behind memory.sources.gmail (memory.extract_email_episodes v1)`.

## Task 6: `owner-action` rank in belief math + `act:` resolver (MEM-15)

**Depends on:** Task 1. **Blocks:** Tasks 7, 9.

**Files:** `internal/memory/belief_math.go` (+`belief_math_test.go`); `internal/memory/beliefs.go` (`newEvidenceLines`); `internal/memory/provenance.go` (add `actResolver`, register it); `internal/db/memory.go` (`InteractionExists`). Read `belief_math.go`'s rank enum + `evidenceWeight` + `hasFreshOwnerSupport` and `beliefs.go`'s `newEvidenceLines`/`rankName`/`parseEvidenceRank` first.

- **Rank enum.** Insert `rankOwnerAction` **between** `rankObserved` and `rankOwner` (`rankInferred=0, rankObserved=1, rankOwnerAction=2, rankOwner=3`). Add cases to `evidenceWeight`, `parseEvidenceRank` (`"owner-action"`), and `rankName` (`"owner-action"`).
- **Weight curve (resolved ambiguity #4).** `rankOwnerAction` → a **fixed** weight `weightOwnerAction = 0.8`, **no age decay** in Slice 1 (a `const` beside the other tuning constants). It sits above `weightObserved` (0.6) and below fresh owner (1.0) — an owner interaction outweighs a third-party observation but never the owner's own words. Decay is deferred (recorded ambiguity — revisit when preference beliefs land); a dismissal's staleness is not yet modeled.
- **MEM-06 untouched.** `hasFreshOwnerSupport` continues to test `e.Rank == rankOwner` **exactly** — `rankOwnerAction` does **not** confer fresh-owner protection. Add an explicit `TestApplyOp` case: an `owner-action for` line does NOT downgrade a model `retire` to `shaken` (no protection), whereas `owner for` still does.
- **`act:` resolver + MEM-15 minting.** `actResolver.Validate(ref)`: `channel_id = "act:<table>:<row_id>"`, `ts = <interaction unix seconds>`. `db.InteractionExists(table, id)` checks the row exists in a **whitelisted** table (`inbox_feedback`, `user_interactions`, `decision_reads`, `situations`) — an unknown table is `(false, nil)` (dropped, not an error). Register into the pipeline registry. `newEvidenceLines` mints `rankOwnerAction` for an `act:` scheme ref (as it mints `rankOwner` for `chat:`), every other ref stays `rankObserved`. **MEM-15:** the model never names the rank (`beliefOpJSON` has no rank field); the elevation is a pure code path keyed on the `act:` prefix + a validated interaction row.

- [ ] **Step 1: failing tests** — `belief_math_test.go`: `weightOwnerAction` orders `0.6 < 0.8 < 1.0`; `parseEvidenceRank("owner-action")`/`rankName(rankOwnerAction)` round-trip; **`TestMemory06_*`** stays green AND a new case asserts `owner-action` gives NO retire-protection. `provenance_test.go`: an `act:inbox_feedback:<id>` ref for an existing row validates; a missing row / non-whitelisted table drops-and-counts. `beliefs_test.go` / a new `action_evidence_test.go`: **`TestMemory15_ActionRankOnlyFromInteractionRows`** — a validated `act:` ref mints an `owner-action` evidence line; a model op that names a rank never reaches `rankOwnerAction` (the op schema carries no rank field); an `act:` ref to a non-existent row is dropped like an invented ref.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/memory/ -run 'Belief|ApplyOp|OwnerRank|Memory06|Memory15|Provenance|Action'` green; commit `feat(memory): owner-action evidence rank + act: resolver (MEM-15; no owner-protection, code-minted)`.

## Task 7: 5D mechanical interaction ingest step

**Depends on:** Tasks 2, 3, 6. **Blocks:** Tasks 8, 9. **Read `docs/inventory/inbox-pulse.md` + `dashboard.md` first** (this step reads inbox/situation tables — MEM-05 discipline).

**Files:** new `internal/memory/interaction_ingest.go` (+`interaction_ingest_test.go`); wire into `internal/memory/pipeline.go` `Run` after `IngestSituations` (episode mirrors must already exist), gated `memory.sources.actions`. Read `ingest.go` (situation episode mirrors, the `situation:<id>` alias) and `internal/db/memory.go`'s floor accessors first.

Mechanical, **no AI call** (this is the "mechanical first" half of 5D; preference beliefs are a later slice):
- **`ingestInteractions(db, vault, floor) (annotated, engaged int, newFloor int64, err error)`** — scan the owner-interaction sources above `memory_last_interaction_id`, oldest id first, ordered so the floor advances through a contiguous prefix (the ingest-floor discipline in `ingest.go`): `inbox_feedback` (👍=engaged, 👎=dismissed), situation status transitions (`resolved`/`converted` = engaged; dismissed/snoozed = dismissed), conversions (situation→target/track = engaged). `user_interactions` / `decision_reads` are read for engagement aggregates but are windowed rows (not id-monotonic); fold them by their own natural keys under a separate sub-floor or a bounded re-scan (decide in-task — the simplest correct choice: aggregate `user_interactions` per person entity on every run since the table is small and self-idempotent via upsert-by-latest-window, and use the id floor only for the append-only `inbox_feedback` rows).
- **(1) Episode-mirror outcome annotations.** For an interaction that maps to a `situation:<id>` episode mirror, append a dated interaction-outcome bullet to that episode's `## Outcome` (e.g. `- 2026-07-16: owner dismissed` / `- 2026-07-16: converted to target #12`). This is distinct from `IngestSituations`'s status-derived Outcome (it records the *owner's action*, not the situation's terminal state). An ordinary `memory(interactions)` vault commit through `WriteNodes` + index mirror. **MEM-05:** the situation/inbox row is only read; the annotation lives in the vault.
- **(2) Engagement aggregates.** Map each interaction to its subject entity/entities (situation subject via `situation:<id>` alias → the episode's linked entities; `user_interactions` → the person entity by user id/email alias) and `db.BumpEngagement(nodeID, engaged, at)`. These are the retention-importance input Task 8 consumes.
- **Floor discipline.** `SetMemoryInteractionFloor(newFloor)` only after the commit + aggregate writes succeed (the "advance after success" discipline). A mapping DB error freezes the whole step (floor unmoved, re-scanned next run); an interaction that maps to no memory entity is *consumed* (floor advances) but aggregates nothing (logged) — same rule as the chat-turn floor's "consumed but stages nothing" case.
- Gate: `if p.cfg.Sources.Actions`. `RunStats.InteractionsIngested` / `EngagementUpdated`; one `pipeline_steps` row.

- [ ] **Step 1: failing tests** (`interaction_ingest_test.go`, fixture DB with a situation, its episode mirror, and interaction rows) — a 👎 on an inbox item whose situation maps to an entity increments that entity's `dismissed_count` and appends an `owner dismissed` bullet to the mirror's `## Outcome`; a conversion appends `converted to target #N` and increments `engaged_count`; the floor advances only after commit (a forced commit error leaves it unmoved, rows re-scanned); an interaction mapping to no entity advances the floor but writes no aggregate; gate off → no vault write, floor unmoved; **MEM-05:** `inbox_items`/`situations`/`situation_signals` byte-identical across the step (dump compare) and `inbox_last_processed_ts` unmoved.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement + wire (gated). **Step 4:** `go test ./internal/memory/ -run 'Interaction|Engagement|Memory05'` green; daemon coverage floor holds; commit `feat(memory): mechanical interaction ingest — outcome annotations + engagement aggregates (behind memory.sources.actions)`.

## Task 8: Retention importance consumes engagement aggregates

**Depends on:** Tasks 3, 7. **Blocks:** Task 9.

**Files:** `internal/memory/evict.go` (+`evict_test.go`). Read `RetentionScore`/`RetentionInputs` + the retention-constants block first.

- Add `Engagement int` to `RetentionInputs` (net engagement = `engaged_count`, or `engaged_count - dismissed_count`, floored at 0 — decide in-task; the retention importance is additive and must never go negative). Add a `retentionEngagementWeight` constant (code, not config — the one-auditable-place convention) and fold `retentionEngagementWeight * float64(in.Engagement)` into the `importance` sum, beside `LinksIn` / situation / owner-touch bonuses.
- In `EvictEpisodes`, populate `Engagement` from `db.GetEngagement(nodeID)` for the eviction-candidate episode's linked/subject entity (bounded to the candidate set, like the existing `OwnerEdited` git read — no full scan). An episode whose entity the owner actively engages with scores higher and resists eviction; a dismissed one does not gain the bonus. This finally gives Phase-3's stubbed retention-importance input a **live, writable** source that is NOT the write-dead `memory_node_stats` access counters (the access-stats known-limitation is untouched — `memory_engagement` is a separate, writable table).

- [ ] **Step 1: failing tests** (`evict_test.go`) — `RetentionScore` rises monotonically with `Engagement` (pure-math); two otherwise-identical cold episodes, one whose entity has engagement > 0, only the un-engaged one falls below the eviction threshold; zero/negative net engagement adds no bonus (never lowers the score below the un-engaged baseline). MEM-07 (provenance-preserving eviction) stays byte-green.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/memory/ -run 'Retention|Evict|Memory07'` green; commit `feat(memory): retention importance consumes engagement aggregates`.

## Task 9: Guards MEM-12/15 + inventory + final-validation Section 3

**Depends on:** Tasks 4, 5, 6, 7, 8. **Blocks:** Task 10.

Add/confirm the two new guard tests exactly as named; do NOT weaken MEM-01..11 / INBOX / DASH.
- **`TestMemory12_UnregisteredSchemeRejectedAtWrite`** (`provenance_test.go`, from Task 1): a provenance ref whose scheme has no registered resolver is dropped-and-counted and never written to the vault; every registered scheme (`""`/`chat`/`mail`/`act`) resolves through its resolver.
- **`TestMemory15_ActionRankOnlyFromInteractionRows`** (`action_evidence_test.go`, from Task 6): `owner-action` evidence is minted only by code for an `act:` ref backed by a real whitelisted interaction row; a model op that names/forges a rank, or cites a non-existent interaction row, never yields an `owner-action` line; owner-action confers no MEM-06 protection.

Docs:
- [ ] Append **MEM-12** (resolver registry — every provenance scheme has a registered validator; unregistered rejected at write; MEM-01 generalization) and **MEM-15** (action rank is code-minted; no owner-protection) to `docs/inventory/memory.md` (Status/Observable/Why-locked/Test-guards/Locked-since 2026-07-16), with a changelog entry. Add Known-limitations notes: `memory_engagement` runtime side-table (MEM-02-exempt, survives reindex, memory_entity_hints precedent); the Gmail extraction watermark is a *third* independent watermark; `owner-action` weight is a fixed 0.8 with no decay in Slice 1 and is explicitly non-protecting; email thread grouping key is `thread_id`; the mechanical 5D ingest forms **no preference beliefs** (deferred to semantic 5D).
- [ ] Write `docs/specs/memory-final-validation-task.md` **Section 3** — the Slice-1 drill: enable `memory.sources.gmail`, run consolidate, confirm mail threads become episodes with working `mail:` provenance and senders become person entities (external senders new, an email-matched Slack person stitched, not duplicated); enable `memory.sources.actions`, dismiss/convert a dashboard situation, confirm its episode mirror gains an interaction-outcome bullet and the subject entity's engagement aggregate moves; confirm an engaged entity's cold episode resists eviction while an un-engaged twin evicts; confirm MEM-05 (inbox tables untouched) and MEM-12 (an injected bogus-scheme ref is rejected) hold.
- [ ] Commit `docs(memory): MEM-12/15 contracts + Slice-1 validation drill`.

## Task 10: Docs — CLAUDE.md + app-guide

**Depends on:** Tasks 5, 7. **Blocks:** nothing.

- [ ] Refresh `CLAUDE.md`'s memory feature note: the provenance-resolver registry (MEM-12) as the universal write-time validator; Gmail as a memory source behind `memory.sources.gmail` (threads→episodes, senders→people with email aliases, `mail:` scheme, own watermark); mechanical interaction ingest behind `memory.sources.actions` (owner-action rank MEM-15, episode outcome annotations, engagement aggregates feeding retention); no preference beliefs yet.
- [ ] Refresh `docs/app-guide.md`: the secretary now builds memory from Gmail as well as Slack, and learns from the owner's own dashboard interactions (dismiss/convert) mechanically.
- [ ] Commit `docs: Phase-5 Slice-1 (registry + gmail source + interaction ingest)`.

## Self-Review

- [ ] `gofmt -l . && go vet ./... && go build ./... && go test ./...` green; `golangci-lint run` clean; daemon coverage floor (70) satisfied; sentrux baseline unchanged or refreshed intentionally.
- [ ] Guard sweep: MEM-01..11 + INBOX-01..09 + DASH-01..07 byte-unchanged and green; MEM-12/15 present and green; the registry refactor changed NO existing MEM-01/08/09 assertion (Task 1 is a pure lookup refactor).
- [ ] MEM-05 grep check: `grep -rn "inbox_\|situations\b" internal/memory/` shows reads only from the Gmail extractor and the interaction-ingest step — no `inbox_items`/`situations`/`situation_signals` writes, no `inbox_last_processed_ts` nudge.
- [ ] MEM-06 check: `hasFreshOwnerSupport` still keys on `rankOwner` exactly; an `owner-action` line grants no retire-protection.
- [ ] MEM-12 check: the only write-time provenance validation is `registry.Validate`; no code path writes a ref of an unregistered scheme. MEM-15 check: the only `rankOwnerAction` mint site is the `act:`-prefix path in `newEvidenceLines`; the belief-op JSON schema carries no rank field.
- [ ] Both new sources default off: with `memory.sources.gmail`/`memory.sources.actions` false, a consolidate run is byte-identical to pre-Slice-1 behavior (no Gmail work, no interaction ingest, all three watermarks unmoved).
- [ ] Manual E2E: run the Section-3 drill end to end with both source gates on.
- [ ] Run `/local-review` before PR.

## Resolved ambiguities (for reviewer attention)

1. **Email thread grouping key = `thread_id`; one thread → one episode.** A Gmail thread is the natural story arc (participants, question, resolution), so the extraction unit is the thread, not a per-message or time-window slice. `ListGmailThreadsForExtract` groups `gmail_messages` by `thread_id` above the Gmail extraction watermark; small threads batch into one AI call (the `groupWindowsIntoBatches` precedent), a large thread goes solo.
2. **New prompt `memory.extract_email_episodes`, not a reuse of `memory.extract_episodes`.** Email threads differ structurally from channel windows: a subject line, explicit From/To/Cc identity, and a thread that maps to **one** episode rather than N-per-window. A separate cheap-tier prompt renders `Subject/Participants/[date] sender: body` and emits refs as `mail:<message_id>`. It shares the `extractedEpisode` JSON schema (so `parseExtract` is reused) and is added to the light-tier model switch in both `models.go` files.
3. **Engagement-aggregate storage = a dedicated `memory_engagement` side table, not columns on `memory_nodes` and not `memory_node_stats`.** It is runtime state derived from interaction rows (MEM-02-exempt, like `memory_node_stats`/`memory_entity_hints`), and — unlike `memory_node_stats` — it must **survive `DropMemoryIndex`/reindex** (the interaction floor may have stepped past the rows that produced it), so it follows the `memory_entity_hints` "not cleared on reindex" precedent. It is deliberately separate from the write-dead `memory_node_stats` access counters (which stay dead in this slice) — giving Phase-3's stubbed retention importance its first live, writable feed.
4. **`owner-action` weight curve = fixed 0.8, no decay, non-protecting.** The rank orders `observed (0.6) < owner-action (0.8) < owner-fresh (1.0)`: an owner interaction outweighs a third-party observation but never the owner's own words. It is a `const` (the belief-math "constants in code" convention). **No age decay in Slice 1** (a dismissal's staleness is unmodeled — revisit with preference beliefs). **Decisively, `owner-action` does NOT confer MEM-06 fresh-owner protection** — `hasFreshOwnerSupport` keys on `rankOwner` exactly; an ambiguous interaction (a dismissal has many readings) must never permanently shield a belief the way an owner statement does. A `TestApplyOp`/`TestMemory06_*` case pins this.
5. **`mail:` ref shape = `channel_id="mail:<message_id>"`, `ts=<internal_date unix seconds>`.** The resolver keys existence on the message id (`gmail_messages.id`); the `ts` is carried for the belief/retention age math, not re-validated (mail's identity is the message id, whereas a Slack ref's identity is channel+ts).
6. **`act:` ref shape = `channel_id="act:<table>:<row_id>"`, `ts=<interaction unix seconds>`.** The resolver whitelists the source tables (`inbox_feedback`, `user_interactions`, `decision_reads`, `situations`); an unknown table is a clean drop, not an error. The scheme classifies as `act` on its first colon-segment despite carrying two colons.
7. **Three independent extraction/sync watermarks coexist.** `gmail_last_internal_date` = Gmail API *sync* (what is pulled into `gmail_messages`); `memory_last_extracted_ts` = Slack episode extraction; the new `memory_gmail_last_extracted_ts` = Gmail episode extraction. The Gmail extractor's watermark advances only behind committed thread batches (MEM-04), never coupling to the sync watermark.
8. **Registry does existence; callers keep their disposition.** The registry unifies the *lookup*, not the *policy*: `validateRefs` (extractor) still freezes the window/batch on a lookup error (MEM-01/MEM-04); the belief pass still soft-drops a `chat:`/`act:` lookup error (the surface is a soft owner-writeback). This is why the registry returns `(ok, registered, err)` and the caller decides — a pure refactor that leaves every existing guard byte-green.
