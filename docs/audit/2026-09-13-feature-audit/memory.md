# Feature-state audit — Memory vault (all phases)

Repo: `/Users/user/PhpstormProjects/watchtower` @ `37179540` (feature/agent-actions). Read-only audit; live vault inspected via `ls`/`git log` and the daemon log only (no DB opened, no binary run).

## 0. Effective gate table for the owner's install

Config source of truth: `internal/config/config.go:493-526` (`SetDefault` block) + struct `internal/config/config.go:281-362`. Owner's file sets `memory.enabled: true`, `memory.semantic.enabled: true`, `memory.surfaces.{chat,briefing,disputes,reflection}: true`, `memory.sources.actions: false`; everything else absent → default.

| Key | Effective | Governs |
|---|---|---|
| `memory.enabled` | **true** | `phaseMemory` (`internal/daemon/daemon.go:1038-1041`), `wireMemoryPipeline` (`cmd/memory.go:165-175`), `Pipeline.Run` early return (`internal/memory/pipeline.go:202`) |
| `memory.semantic.enabled` | **true** | `runSemantic` (`pipeline.go:255-258`): dedupe → promote → rewrite → beliefs → age → evict → reflect; strong `map.md` render (`pipeline.go:421`) |
| `memory.semantic.output_budget` | 200000 (default) | `outputBudgetExceeded` (`pipeline.go:617-619`) |
| `memory.semantic.preferences` | false | OWNER ACTIONS block in belief pass — DARK |
| `memory.surfaces.chat` | **true** | Swift MEMORY block in Situation/Target/Meeting Discuss (`Constants.swift:33-41`); Go `ingestChatStatements` (`pipeline.go:458-475`) |
| `memory.surfaces.briefing` | **true** | `internal/briefing/memory_revisions.go` journal |
| `memory.surfaces.disputes` | **true** | `detectMemoryDisputes` (`internal/inbox/pipeline.go:571-572`, `watchtower_detector.go:186`) |
| `memory.surfaces.reflection` | **true** | `Reflect` (`pipeline.go:593-609`) |
| `memory.surfaces.day_plan` / `meeting_prep` | false | DARK |
| `memory.sources.gmail` / `calendar` / `chats` / `operational` / `jira` | false | DARK (jira has no `SetDefault` line at all — zero-value false, `config.go:342`) |
| `memory.sources.actions` | false (explicit) | DARK |
| `memory.renders.digest_compare` | false | DARK |
| `memory.retrieve.{recall,briefing,meeting_prep}_compare` | false | DARK — Slice B never switched any surface off legacy ranking |
| `memory.focus.enabled` | false | DARK; `runFocusDisable` still runs each cycle (`pipeline.go:303-307`) |
| `inbox.situations.enabled` (not a memory key) | false | mutes compose → no NEW situations for `IngestSituations`; dispute items never become situations |
| `ai.models.light: sonnet` | — | every "cheap/light tier" memory call (`memory.extract_episodes[_batch]`, `internal/digest/models.go:19`) runs on Sonnet; strong steps on Opus |

**Bottom line for this owner:** on paper Phases 0–4 are live. In practice **nothing past Run step 2 (seeding) has executed since 2026-08-03** — see Critical #1. Every downstream surface (extraction, semantic tier, briefing journal, disputes, reflection, MEMORY chat block content, MCP recall freshness) has been frozen at its 2026-08-01 state for six weeks while the daemon reports the phase as running.

## 1. Feature status table

| Feature | Gate key + default | Entry points | Reachable from UI? | Verdict | Why |
|---|---|---|---|---|---|
| Consolidation run (Phase 0–2: owner-edit commit, reconcile, seed, situations ingest, Slack extraction) | `memory.enabled` (false; owner: true) | daemon `phaseMemory` (`daemon.go:1038`), CLI `memory consolidate` | indirectly (Memory tab, chat) | **BROKEN** | Run dies at step 2 every cycle since 2026-08-03: seed re-creates ~120 person entities, index insert hits `memory_aliases` UNIQUE on the email alias, `SeedEntities` returns error → `Run` fatal (`pipeline.go:325-328`). 364 `memory(seed)` commits, 46,431 entity files, zero extraction since 2026-08-01. |
| Slack extraction watermark (`memory_last_extracted_ts`) | same | `runExtract` (`pipeline.go:745-807`) | — | WORKS (mechanism) / frozen by Critical #1 | `safeWatermark`/`advanceWatermark` (`pipeline.go:832-842, 1002-1027`) never pass a pending window; same-second drain (`internal/db/memory.go:982-1002`). Never reached since 2026-08-01. |
| Gmail extraction watermark (per account) | `memory.sources.gmail` (false) | `runGmailExtract` (`gmail_extract.go:234-307`) | — | DARK | Mirrors Slack math; per-account `MemoryGmailWatermark`. |
| Calendar builder watermark | `memory.sources.calendar` (false) | `runCalendarIngest` (`calendar_ingest.go:76-121`) | — | DARK | Advances to max loaded `end_time` after one commit, 2-day lookback re-scan, loader ordered ASC + LIMIT (`db/memory.go:1289-1293`). Was on at some point (3 `memory(calendar)` commits in live vault), now off. |
| Jira builder watermark (per account) | `memory.sources.jira` (false, no SetDefault) | `runJiraIngest` (`jira_ingest.go:81-142`) | — | DARK | First run inits to max `updated_at`, no backfill (documented). |
| Semantic tier: dedupe / promote / age / evict | `memory.semantic.enabled` | `runSemantic` (`pipeline.go:483-584`) | — | WORKS (mechanism) / not reached since 2026-08-01 | Mechanical, isolated per step. |
| Entity-page rewrite (strong) | same; cap `rewrite_max_entities` 10 | `RewriteEntityPages` (`rewrite.go:59-119`) | vault pages / Memory tab | **WORKS DIFFERENTLY** | "At most once per 7 days" is false: `dueForRewrite` is day-granular (`rewrite.go:204-208`), no last-rewritten memo → the SAME first-10 due entities are rewritten by Opus on every daemon cycle of their slot day; live vault: commits `f9b9596` 09:00 and `8899645` 12:10 on 2026-08-01 touch an identical 10-file set. Entities past position 10 in `ListMemoryNodes` order never get rewritten. |
| Belief pass (strong) | same; cap `beliefs_max` 20 | `ReviseBeliefs` (`beliefs.go:160`, `applyExistingOp` `beliefs.go:293-333`) | Memory tab → Beliefs | **WORKS DIFFERENTLY** | Re-runs over the same rewritten subjects each cycle; `confirm` always +confidence, +stability (`belief_math.go:222-226`), no evidence-ref dedupe → a belief created 2026-07-17 from ONE Slack message was confirmed 17× the same day and sits at confidence 1.0 / stability 18 (`beliefs/bel_01KXPQJG4RF018Z7FPWVM1MYPD.md`). Calcification by repetition, not by evidence. |
| Strong `map.md` render | `memory.semantic.enabled` | `renderMap` (`worldmap.go:166`, `pipeline.go:421-426`) | Swift `hotMap` reads `map.md` into every MEMORY block | WORKS DIFFERENTLY | One Opus call per cycle, no change gate (44 `memory(map)` commits). Content frozen at 2026-08-01 21:51 on the live install. |
| Reflection (weekly) | `memory.surfaces.reflection` | `Reflect` (`reflect.go:97-129`, `dueForReflect` `reflect.go:378-382`) | Memory tab (dispute badge), entity `## Current` | **WORKS DIFFERENTLY** | Day-granular slot, no "already reflected this week" memo → fires on EVERY daemon cycle of the slot day (live: 5 `memory(reflect)` commits 18:12–22:40 on 2026-07-30), each a fresh Opus call appending more `## Current` bullets. |
| Disputes → inbox | `memory.surfaces.disputes` | `detectMemoryDisputes` (`watchtower_detector.go:186-204`) | **No** | **UNREACHABLE (surface)** | Detector still mints a `decision_made` `inbox_items` row (runs before compose, ungated by `inbox.situations.enabled`), but compose is muted (`inbox/pipeline.go:288`) so no situation is made, and the only renderer of inbox items/situations (`InboxFeedView` → `DashboardView` → `SituationReviewPane`) is instantiated nowhere (`Navigation.swift:203-204` routes `.inbox` to `ActionStripView`). A live dispute item `dispute:bel_01KYP8PMMXFKMSTMMEMJMXK5FV` exists and is invisible. |
| Chat surface — MEMORY block | `memory.surfaces.chat` | `relevantMemoryContext` (`RelevantMemory.swift:48-104`), Target/Situation/Meeting chat VMs | Target chat, Meeting chat: yes; Situation chat: **no** | WORKS DIFFERENTLY | Block renders, but entity/belief lookup joins `memory_aliases` on namespaced subjects (`1:Uxxx`) while every legacy person entity carries a bare alias → person entities with an email never match (see High #2). Content stale since 2026-08-01. |
| Chat surface — owner-rank evidence minting (MEM-09) | `memory.surfaces.chat` (+ `sources.chats` false → situation-only, `pipeline.go:36`) | `ingestChatStatements` (`pipeline.go:458-475`) | **No** | UNREACHABLE | Only `context_type='situation'` turns stage; the situation Discuss chat is unreachable from navigation. Zero possible input. |
| Briefing "Memory revisions" journal | `memory.surfaces.briefing` | `internal/briefing/memory_revisions.go` | Briefing tab | WORKS (mechanism) / empty | Reads belief `## History` in window; no belief has changed since 2026-08-01 → placeholder every day. |
| Interaction ingest (5D) | `memory.sources.actions` (false, explicit) | `runInteractionIngest` (`pipeline.go:403-407`) | — | DARK | — |
| Target/track mirrors | `memory.sources.operational` (false) | `runOperationalMirrors` (`pipeline.go:356-362`) | — | DARK | — |
| Digest render/compare | `memory.renders.digest_compare` (false) | `runDigestCompare` (`pipeline.go:270-272`), CLI `memory digest-compare` | — | DARK | Shadow-only by design. |
| Slice B unified retrieval | `memory.retrieve.*_compare` (false) | `retrieve.go`; live `memory_recall` = alias hit + FTS (`internal/mcp/memory.go:215-220`), `RetrieveByQuery` only inside `runRecallCompare` (`memory.go:247`) | — | DARK | Evidence-gated switch never happened; every surface still on its legacy heuristic (consistent with MEM-17 text). |
| Focus salience | `memory.focus.enabled` (false) | `runFocusStep` (`pipeline.go:295-308`); Swift focus editor (`MemoryViewModel.swift:422-491`) | Memory tab has a focus editor | DARK | Editing `focus.md` in the Desktop has no effect until the key is set. |
| MCP `memory_map`/`memory_open`/`memory_recall` | `memory.enabled` (vault path threaded via `WithMemoryVault`, `server.go:99-101`) | `internal/mcp/memory.go:92` | AI chat (via `watchtower mcp`) | WORKS / stale | Reads index + files; content frozen at 2026-08-01. |
| CLI `memory status/reindex/open/recall/consolidate/index/seed/digest-compare/retrieve-compare` | — | `cmd/memory.go:118-131` | — | WORKS | `consolidate` would fail identically to the daemon (same `Run`). |
| Desktop Memory browser | none (sidebar Analytics → Memory, `SidebarSection.swift:26`, `Navigation.swift:223-225`) | `MemoryView`/`MemoryViewModel` | **Yes** | WORKS DIFFERENTLY | Lists only INDEXED nodes (duplicates are quarantined so hidden), but `rebuildBacklinkGraph` enumerates every vault file on each `refresh()` (`MemoryViewModel.swift:149, 286-296`, comment assumes "a few hundred small files") — now 46k+ files per tab visit. |

Counts: BROKEN 1 · WORKS DIFFERENTLY 6 · UNREACHABLE 2 · DARK 9 · WORKS 5 (three of them frozen by the Critical).

## 2. Findings

### Critical

#### C1. Consolidation has been dying at the seeding step on every cycle since 2026-08-03; the vault is being flooded with duplicate person entities
- **Refs:** `internal/memory/seed.go:93-102` (idempotency keyed on `aliases[0]` only), `seed.go:130` (vault commit BEFORE index write), `seed.go:135-138` (index error returned), `internal/memory/pipeline.go:325-328` (seed error is fatal to `Run`), `internal/db/memory.go:111-114` (alias insert), `internal/db/schema.sql:1345-1348` (`alias TEXT PRIMARY KEY COLLATE NOCASE`), `internal/memory/index.go:248-250` (Reconcile quarantines the duplicate instead of indexing it), `internal/memory/seed.go:159-170,185` (`aliases[0]` = `users.id`, namespaced `1:Uxxx` since migration 00048).
- **Intended:** CLAUDE.md "Memory": `Run` order owner-edit → reconcile → seed → situations → extraction → semantic → renders; seeding "no-op when the natural key already resolves" (`seed.go:62-66`). CLAUDE.md "Slack Multi-Account" decision (2): "the memory vault's markdown files … stay bare".
- **Actual:** After 00048 rewrote `users.id` to `1:Uxxx`, `seedPeople` emits candidates whose `aliases[0]` is `1:Uxxx` (unknown to the index — legacy pages carry bare `Uxxx`) and whose `aliases[1]` is the person's email — which the legacy page ALSO carries. `LookupMemoryAlias("1:Uxxx")` → `ErrNoRows` → a new node is minted, `WriteNodes` COMMITS it to git, then `upsertIndexNode` fails on the email alias (`UNIQUE constraint failed: memory_aliases.alias`) → `SeedEntities` returns error → `Run` returns fatal → steps 3–7 never execute. Next cycle: `Reconcile` quarantines the new file (so `1:Uxxx` still resolves to nothing), seed repeats. Live evidence: 364 `memory(seed): ~120 entities` commits from 2026-08-03 11:03 to now, `entities/` = 46,431 files, 344 files carry alias `1:U010CJR1XV0`; daemon.log: `memory error: … inserting alias "<colleague>@ec319.com" … UNIQUE constraint failed` every cycle (e.g. `2026/09/12 17:03:44`), 439,975 `reconcile: quarantined` lines in the current 130 MB daemon.log alone. Last non-seed commit: `memory(map)` 2026-08-01 21:51.
- **Failure scenario:** if a person entity was seeded before 00048 (bare alias) and has an email, then every cycle since re-creates it and aborts consolidation, because idempotency checks only the first alias and the vault commit precedes the index write.
- **Consequences:** no Slack extraction (watermark frozen ≈ 2026-08-01), no situation ingest, no rewrite/beliefs/reflection/map since 2026-08-01, briefing journal permanently empty, MEMORY chat block and MCP recall serve six-week-old content, each cycle spends ~2 min re-quarantining 46k files, vault `.git` and daemon.log bloat. MEM-03 side effect: owner-edit detection (`OwnerEditedFiles`) is unaffected, but `memory(seed)` history is now 90 % noise.
- **Contracts implicated:** none violated by letter (the watermark correctly froze — MEM-04), but MEM-02's "index derived from files" promise is now: 46k files can NEVER be indexed (permanent quarantine). **Needs owner decision** on the repair (see §3).

### High

#### H1. Bare-vs-namespaced alias split makes every legacy person entity unreachable by namespaced lookups (independent of C1)
- **Refs:** `WatchtowerDesktop/Sources/WatchtowerCore/Services/Memory/RelevantMemory.swift:56-63` (JOIN `memory_aliases a … a.alias IN (subjects)`), `SituationChatViewModel.swift:378-385` (subjects = `signal.channelID`/`senderUserID`, namespaced post-00048), `internal/memory/pipeline.go:1130` `buildEpisodeNodes` participant linking (resolves Slack user ids via alias), `internal/db/memory.go:1289` (`memory_provenance.sender_id` join in the recent-episodes query, `RelevantMemory.swift:87-96`).
- **Intended:** MEMORY block "entities/beliefs/recent activity this chat's subjects match" (spec 2026-07-22 Slice C); extraction links participants to entity pages (changelog 2026-07-16 "entity linking was structurally broken" fix).
- **Actual:** Legacy person pages carry `Uxxx`; all live subjects are `1:Uxxx`; the namespaced re-seeds that would bridge the gap are exactly the files C1 quarantines. So: Target/Meeting chat MEMORY blocks find channel entities (their `1:Cxxx` re-seeds indexed fine on 2026-08-03 since channels have no email alias) but never person entities or their beliefs; new Slack episodes (once C1 is fixed) will not link to legacy people. Also the `memory_provenance` rows of every pre-00048 episode hold bare `channel_id`, so `ListEpisodesForChannelWindow`/recent-activity lookups keyed on namespaced ids miss them.
- **Failure scenario:** if the owner opens a Target chat about a track whose participants are colleagues seeded in July, then the MEMORY block contains only the stale `map.md` and channel titles, because `1:Uxxx` matches no alias row.
- **Contract:** extends the CLAUDE.md "decision (2)" limitation into a functional gap; **needs owner decision** (alias migration of the vault vs. dual-form lookups).

#### H2. "Weekly"/"staggered" strong-tier steps fire on every daemon cycle of their slot day
- **Refs:** `internal/memory/rewrite.go:204-208` (`dueForRewrite`: `day%7 == slot`), `rewrite.go:88-109` (first 10 due entities in `ListMemoryNodes` order, no last-rewritten memo), `internal/memory/reflect.go:378-382` (`dueForReflect`, same shape), `pipeline.go:421-426` + `worldmap.go:166` (strong map render every run, no change gate), `beliefs.go:293-333` + `belief_math.go:222-226` (confirm always bumps; no evidence dedupe).
- **Intended:** spec `2026-07-15-memory-phase3-semantic-tier-design.md` / `2026-07-16-memory-phase4-surfaces-design.md`: rewrite "staggered over the week", reflection "weekly", registry cost label "Medium AI use" (`internal/features/registry.go:230`).
- **Actual (live vault):** identical 10-page rewrite sets at 09:00 and 12:10 on 2026-08-01; 5 reflection runs in 4.5 h on 2026-07-30; 44 map renders; a belief confirmed 17× on 2026-07-17 to confidence 1.0 / stability 18 from a single evidence ref. Per ~70-min cycle with gates on: up to 10 rewrite + 1 beliefs + 1 map (+1 reflect) Opus calls → ~250–300 Opus calls/day, all re-deriving the same content.
- **Failure scenario:** if a belief's subject is among the first 10 due entities on its slot day, then it gains ~15 `confirm`s that day from the same evidence, because nothing records "already processed this evidence/this day" — and `flipThreshold(stability)` then makes it practically un-retirable (undermines the MEM-06/08 hysteresis intent even though no contract text is violated).
- **Contract:** MEM-08 letter holds (code disposes), but the disposing math assumes one pass per evidence. **Needs owner decision** (cost + calcification).

#### H3. Dispute surface and owner-evidence ingestion have no reachable UI on the current Inbox
- **Refs:** `internal/inbox/watchtower_detector.go:186-204` (mints `inbox_items` row), `internal/inbox/pipeline.go:288` (compose muted by `inbox.situations.enabled=false`), `WatchtowerDesktop/Sources/App/Navigation.swift:203-204` (`.inbox` → `ActionStripView`), `InboxFeedView.swift:45` (only `DashboardView` instantiation; `InboxFeedView(` itself is constructed nowhere), `internal/memory/pipeline.go:36-45` (`chatContextTypes` = situation-only when `sources.chats` off).
- **Intended:** MEM-05 dispute clause: "compose merges it into a dashboard situation (DASH-01)" so the owner sees "the arguing secretary"; MEM-09: owner Discuss replies become owner-rank evidence.
- **Actual:** dispute items are minted and sit pending forever, unseen; the only chat surface that stages owner turns cannot be opened. Live: `dispute:bel_01KYP8PMMXFKMSTMMEMJMXK5FV` pending since at least 2026-09-11.
- **Failure scenario:** if reflection flags a flapping belief, then the owner is never asked, because the item's only renderer is dead code and the item never becomes a situation.
- **Contract:** MEM-05 dispute flow's observable ("surfaces … as an ordinary detector item") is now un-observable; **needs owner decision** (Wave-2 §10 follow-up should route disputes to the action strip or retire the surface).

### Medium

#### M1. Semantic output budget counts light-tier extraction and starves the tail in fixed order
- **Refs:** `pipeline.go:782` (`acc.add(usage)` in `runExtract`), `pipeline.go:505,530,594,421` (checks before rewrite/beliefs/reflect/map, in that order), `pipeline.go:617-619`.
- **Actual:** one shared 200k output-token counter; no per-step reservation, so a heavy rewrite pass can skip beliefs, reflection and the strong map (falls back to mechanical map). At current volumes (≤2000 msgs/run) it is unlikely to trip — Medium as design risk, not observed.

#### M2. Desktop memory browser scans the whole vault per refresh
- **Refs:** `MemoryViewModel.swift:149` (`rebuildBacklinkGraph()` on every `refresh()`), `MemoryViewModel.swift:286-296` (FileManager enumerator over all files, comment "the vault is a few hundred small files").
- **Failure scenario:** with 46k files (C1) every visit to the Memory tab reads 46k files off-main; grows ~120 files/cycle until C1 is fixed.

#### M3. `memory.sources.jira` has no `SetDefault`
- **Refs:** `internal/config/config.go:493-526` vs struct field `config.go:342`.
- Harmless functionally (zero-value false), but `viper`-based config dumps / `features list` may not show the key. Low-Medium.

#### M4. Extraction watermark is keyed on message `ts_unix`, not sync time
- **Refs:** `internal/db/memory.go:986` (`m.ts_unix > ?`).
- Thread replies or backfilled history synced AFTER the watermark passed their `ts` are never extracted. Not acknowledged in `docs/inventory/memory.md` (only the Jira source notes the analogous case, line 345). Same class as INBOX-09's known shape; flag as documentation gap.

### Low

#### L1. "Light tier" is Sonnet on this install
- `internal/digest/models.go:19` routes `memory.extract_episodes[_batch]` to `TierLight`; owner's `ai.models.light: sonnet` → extraction is not "cheap/haiku" as the specs assume. Cost expectation, not a bug.

#### L2. `pipeline.go:179-199` Run doc comment and CLAUDE.md say "phaseMemory after phaseInbox, before phaseNextStep" — true, but three phases (stream digests, ideas, reaction commands) now sit in between (`daemon.go:356-361`). Doc drift only.

#### L3 (cross-domain, for the runtime/inbox auditor). The live daemon still logs `slack API: reactions.get channel=memory ts=dispute:bel_…` every cycle (11× in today's log, last `2026/09/12 17:13:23`), i.e. the reaction sync hits Slack with the memory pseudo-channel. HEAD's `ownsID` filter (`internal/sync/orchestrator.go:349-352, 379-381`, in main since 2026-08-04) should skip a colon-less id — so either the running binary predates it or the filter does not hold. Not verified further (outside domain).

## 3. Needs owner decision

1. **C1 repair strategy.** Options: (a) make `SeedEntities` check ALL candidate aliases (not just `aliases[0]`) and, when a secondary alias resolves, ADD the namespaced alias to the existing page instead of minting; (b) a one-shot vault alias migration (`Uxxx` → `1:Uxxx` in frontmatter, committed as a machine commit); (c) both. Plus cleanup of ~46k duplicate files (git history rewrite vs. tombstoning — MEM-07 "nothing is deleted" and MEM-03 history semantics are both touched). Also whether the vault commit should move AFTER the index write in `SeedEntities` (currently commit-then-index, `seed.go:130-138`).
2. **H1 dual-form lookups** — should Swift `relevantMemoryContext`, Go `RetrieveBySubject`, participant linking and `memory_provenance` queries accept both bare and namespaced forms (the `slack.MentionPatterns` precedent), or is the vault alias migration the fix?
3. **H2 cadence** — introduce per-entity/per-workspace "last rewritten/reflected at" memo (or make the stagger hour-granular), a change-gate on the strong map render, and evidence-ref dedupe in `applyExistingOp` (a confirm citing only already-present refs should be a no-op). The last item changes the disposing math (MEM-08 adjacent) → explicit approval.
4. **H3 disputes** — with the situations Dashboard retired from navigation, decide: route `decision_made` dispute items into the action strip, or turn `memory.surfaces.disputes` off / remove the flag path (MEM-05 dispute clause would need rewording).
5. Whether `memory.surfaces.chat` should stay on while its only evidence-minting surface (situation chat) is unreachable and `sources.chats` (target/track "remember:") is off.

## 4. What I could not verify

- `pipeline_runs`/`pipeline_steps` rows and the exact watermark values (no DB access); inferred from the vault git log + daemon.log.
- Whether the strong-map/rewrite/beliefs cadence still costs what it did in July (they have not run since 2026-08-01 because of C1).
- Gmail/calendar/jira/actions/operational/digest-compare/focus/retrieve-compare paths were traced for gates and watermark shape only; none is enabled on this install, no end-to-end behaviour claim beyond "DARK".
- The exact binary the live daemon is running (L3).
- Whether `watchtower memory reindex` on 46k files completes in acceptable time (Rebuild will quarantine the same duplicates; legacy pages win alias ownership by filename order since `os.ReadDir` sorts).
