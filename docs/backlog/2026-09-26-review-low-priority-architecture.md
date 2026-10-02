---
type: chore
title: "Low-priority findings bundle — architecture"
status: open
priority: low
tags: [architecture, review-2026-09-26, bundle]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track architecture
created: 2026-09-26
---

5 low-priority findings from the architecture track, bundled so the backlog
stays readable. Split any item into its own file when it gets picked up.

## Slack markup parsing is duplicated in 8+ places with divergent grammars

- type: chore · confidence: med · tags: [slack, duplication, swift, go]
- where: internal/inbox/pipeline.go:26-28, internal/kb/normalize.go:21-22, internal/tracks/pipeline.go:1698, internal/memory/worldmap.go:52-53, internal/memory/slackids.go:24, WatchtowerDesktop/Sources/Utilities/SlackTextParser.swift:15-17, ViewModels/TracksViewModel.swift:342; also Jira key regex in internal/jira/key_detector.go:16, cmd/digest.go:712, Utilities/JiraKeyExtractor.swift:13

Each package compiles its own mention/channel regex, and they disagree. `inbox` accepts any `<@[A-Z0-9]+>`, `kb` accepts `[UW]…`, while Swift's `SlackTextParser` and `tracks.reUserID` only accept `U…`. So a Slack Enterprise Grid user id (`W…`) renders as raw markup on the Desktop and is missed by tracks participant extraction, while inbox and kb handle it. `internal/slack/namespace.go` already hosts `MentionPatterns`/`MentionTag`, which is the natural home. Direction: move the Go regexes into `internal/slack` (a `markup.go` with parse helpers) and make one Swift `SlackMarkup` in WatchtowerCore, with a shared fixture list of markup strings tested on both sides. `cmd/digest.go`'s Jira key regex should reuse `jira.jiraKeyPattern` through an exported helper.

**Resolution (2026-10-02, refactor/go-arch-lows): partly done.** `cmd/digest.go` now
uses the shared `jira.KeyRegexp` (backed by `internal/jirakey`) instead of its
own copy, and `jiraBadgeForText` has a unit test. Open: the mention/channel
regex unification across `inbox`/`kb`/`tracks`/`memory` and Swift
`SlackTextParser`. It changes behaviour (W-prefixed ids), crosses Go and Swift,
and needs the shared fixture list, so it is its own item. Note: the `tracks`
`reUserID` is a dedup fingerprint, not participant extraction.

## Config keys with no reader, still accepted by config set

- type: chore · confidence: high · tags: [config]
- where: internal/config/config.go:73,87,207,221,228-229, :426-433, :509-513; cmd/config.go:205-224

Of the 119 mapstructure fields, 7 are never read outside `internal/config` (config-package references are defaults/validation only): `digest.action_items_interval`/`tracks_interval` (TracksInterval), `inbox.max_items_per_run`, `targets.extract.max_per_call`, `targets.resolver.slack_enabled`, `targets.resolver.jira_enabled`, `jira.selected_boards`, and `analysis.legacy_mode`, which only the Swift side reads. Several of them still get `SetDefault` and are in `knownConfigKeys`, so `watchtower config set digest.action_items_interval 1h` succeeds and does nothing. The frozen `jira.cloud_id/site_url/user_display_name` add three more that exist only for the legacy seed. Direction: delete the no-reader fields and defaults and drop them from `knownConfigKeys`. Have `config set` print "key retired" for them instead of silently accepting them. Also add a unit test that reflects over `Config` and asserts every field has a reader, with an allowlist for Swift-only keys.

**Resolution (2026-10-02, refactor/go-arch-lows): done.** The four `targets.*` keys
(`targets.extract.max_per_call`, `targets.extract.model`,
`targets.resolver.slack_enabled`, `targets.resolver.jira_enabled`) were already
removed in PR #120. This pass removed the struct fields and defaults of
`digest.action_items_interval` (and its alias `digest.tracks_interval`),
`inbox.max_items_per_run`, and `jira.selected_boards`. It also removed three
more no-reader keys from the 2026-09-13 audit: `tracks.min_messages` and
`day_plan.max_timeblocks`/`min_backlog`/`max_backlog`. `config set` now refuses
all twelve with a "retired" error (`retiredConfigKeys` in `cmd/config.go`),
and a config.yaml that still carries them loads unchanged (pinned by tests).
Kept on purpose: `analysis.legacy_mode`, which the Desktop reads, and the
frozen `jira.cloud_id`/`site_url`/`user_display_name`, which the legacy-seed
path (`cmd/jira_legacy.go`) reads. Not done: the reflection "every field has a
reader" test. Go reflection cannot see readers, so it would need a source scan,
and fields with common names like `Enabled` make that scan noisy. Revisit it
only if dead keys come back.

## Dead and frozen schema: four workspace columns with no reader, frozen situation tables, and a legacy identity snapshot

- type: chore · confidence: high · tags: [schema, migrations]
- where: internal/db/schema.sql (workspace), internal/db/slack_purge.go:81, internal/db/situations.go

Four `workspace` columns have no reader anywhere in Go or Swift: `memory_last_ingested_situation_id`, `memory_last_interaction_id`, and `memory_last_situation_feedback_id` (all fed by the removed situations/interaction ingest), plus `compose_last_run_ts`, which is only reset to 0 by the Slack purge and never read. `workspace.id/name/domain` is a frozen legacy snapshot, and `situations`/`situation_signals` are frozen read-only history kept only for memory's chat ingest. With 64 migrations and 92 tables, every such column is carried by `schema.sql`, the AI schema prompt (it is injected into the prompt), the Swift test-schema copy, and purge code. Direction: one "retire dead columns" migration (table-recreate for workspace), plus an optional schema-lint test that fails when a `schema.sql` column name appears nowhere in `cmd/`, `internal/` (outside migrations) or Swift sources, with an allowlist.

**Resolution (2026-10-02): still open, deferred.** All four columns are still in
`schema.sql`. Retiring them means a `workspace` table-recreate migration plus
the Swift test-schema copy (`TestDatabase+Schema.swift`) and the purge/gmail
code that resets `compose_last_run_ts`. That is a migration-lane task, not a
small Go cleanup.

## internal/db is one 19.8k-line package with 578 methods on a single *DB

- type: chore · confidence: high · tags: [go, god-package, complexity]
- where: internal/db/ (62 non-test files), internal/db/memory.go (2,179 lines), internal/db/user_analyses.go:539 (ComputeUserInteractions, CC 48), internal/db/channel_stats.go:207 (CC 36)

All persistence for every domain (memory, jira, ideas, inbox, kb, targets, people analytics…) hangs off one `*DB` type: 578 exported methods, and `internal/db` imports `internal/slack` for id helpers. Analytics logic also lives here (`ComputeUserInteractions` CC 48, `ComputeAllUserStats` CC 32, `ComputeRecommendations` CC 36 are domain computations, not queries). Other outliers repo-wide: `sync.buildChannelQueue` CC 44, `guide.RunForWindow` CC 43, `cmd.runDigestGenerate` CC 36. There are 32 cmd functions over CC 15, so cmd also holds real logic (for example `runTargetsShow` CC 33 and `runTrends` CC 32 format and compute inline). Direction (incremental, no big bang): move the analytics computations into their domain packages (`guide`/`stats`) behind narrow query methods, and split `db` by sub-package for the largest domains (memory first, which already has its own vault package), keeping `*DB` as the connection holder. Move `slack.SplitAccountID`/`MentionPatterns` into a leaf `slackid` package so `db` has no network-client import.

**Resolution (2026-10-02): still open, deferred.** This is an incremental
package split and analytics move with a wide blast radius, so it is out of
scope for a small-items pass. Do it per domain as separate items (memory first;
a leaf `slackid` package).

## CLAUDE.md and inventory describe a runtime-B/MCP layout that has since changed

- type: chore · confidence: high · tags: [docs, mcp, runtime-b, providers]
- where: CLAUDE.md (Agent Actions "Mandatory follow-up (runtime B)", Memory "MCP read tools in internal/mcp/memory.go", Quick Connections v1 limitation, Memory "nothing reads those flags"); internal/agentloop/client.go:1-10; internal/tools/readtools.go:13; internal/tools/memory.go; WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/MemoryQueries.swift:33,155

Runtime B has shipped (`internal/agentloop`, wired in `cmd/generator.go:143`), and `internal/mcp` is now a thin adapter: all 33 tools, the memory tools included, live in `internal/tools`, and `ReadTools()` is the single list. CLAUDE.md still calls runtime B a mandatory follow-up and points memory MCP tools at `internal/mcp/memory.go`. The Quick Connections "claude-only" limitation cites the missing runtime B as its blocker, but that blocker is gone. The path is now open to proxy external MCP servers through the agentloop registry for ollama, and through codex's own MCP config, which would also route external writes through `Registry.Propose`. CLAUDE.md also says nothing reads `memory_dispute_flags`, but `MemoryQueries.swift` joins and counts them for a sidebar badge. Direction: a doc-sync pass over these four statements, and a backlog idea to extend Quick Connections to runtime B now that the substrate exists (related to, but separate from, the existing external-write-without-Approve backlog item).

**Resolution (2026-10-02, refactor/go-arch-lows): done for the docs.** CLAUDE.md no
longer carries these statements (feature notes moved to `docs/features/`).
`docs/features/memory.md` already lists the Desktop readers of
`memory_dispute_flags`. `docs/features/quick-connections.md` already states the
claude-only limitation correctly. Its runtime-B sentence now says that runtime B
has shipped (ollama only) and does not proxy external servers yet. The runtime-B
extension idea is now its own item:
`2026-10-02-quick-connections-on-runtime-b-and-codex.md`. Left for the owner:
`docs/inventory/memory.md` still lists `internal/mcp/memory.go` (now
`internal/tools/memory.go`), and `docs/inventory/quick-connections.md` still
says "until runtime B lands". Both are inventory wording, which needs owner
approval to change.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
