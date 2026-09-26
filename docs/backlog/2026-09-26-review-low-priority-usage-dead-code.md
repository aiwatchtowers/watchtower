---
type: chore
title: "Low-priority findings bundle — usage analysis & dead functionality"
status: open
priority: low
tags: [usage-dead-code, review-2026-09-26, bundle]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track usage analysis & dead functionality
created: 2026-09-26
---

10 low-priority findings from the usage analysis & dead functionality track, bundled so the backlog
stays readable. Split any item into its own file when it gets picked up.

## Transcription dark toggles never validated on the owner's install

- type: question · confidence: high · tags: [transcription, dark-flags, desktop]
- where: WatchtowerDesktop/Sources/Services/Transcription/ (MicAGC.isEnabled, contextPrompt); CLAUDE.md Meeting Transcriber section

`transcription.micAGC` and `transcription.contextPrompt` ship default OFF "until validated end-to-end on a
real recording". The owner's `UserDefaults` contain neither key (only `transcription.provider`), across 86
recorded meetings (last 2026-09-23) — so the validation gate has not been exercised in ~7 weeks. Each flag
keeps a code path, Settings UI and equivalence pins alive. Owner call: run the planned A/B on one real
meeting, or remove the features.

## DayPlanQueries.markRead has no caller; day_plans.read_at is write-never, read-never

- type: chore · confidence: high · tags: [day-plan, desktop, dead-code]
- where: WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/DayPlanQueries.swift:151

Grep finds no call to `DayPlanQueries.markRead` and no reader of `day_plans.read_at` on either side
(0 of 135 plans have it set). Either wire it (so day plans get the same unread semantics as briefings and
the usage metric above becomes measurable) or delete the function.

## Unreachable Desktop views: the whole Home/WorkspaceOverview stack and ExtractNoticeBanner

- type: chore · confidence: high · tags: [desktop, dead-code]
- where: WatchtowerDesktop/Sources/Views/Home/{WorkspaceOverviewView,ActivityFeed,StatsCard,SyncStatusBanner}.swift; WatchtowerDesktop/Sources/ViewModels/WorkspaceOverviewViewModel.swift; WatchtowerDesktop/Sources/Views/Targets/ExtractNoticeBanner.swift

`WorkspaceOverviewView` is instantiated nowhere; its three subviews are used only by it; its view model is
used only by tests (`ViewModelTests`, `SlackLinkViewModelTests` — which keep dead code "green" and add
maintenance, e.g. the multi-account link test). `ExtractNoticeBanner`/`ExtractNotice` are referenced only by
`ExtractNoticeBannerTests`. ~230 lines plus tests. Delete (or wire the banner if Target extract was meant to
use it).

## Four targets.* config keys have defaults but no reader

- type: chore · confidence: high · tags: [config, targets, dead-code]
- where: internal/config/config.go:219-230,509-513; internal/config/defaults.go:113-118

`targets.extract.max_per_call`, `targets.extract.model`, `targets.resolver.slack_enabled` and
`targets.resolver.jira_enabled` are defaulted and decoded but never read (only `extract.enabled`,
`extract.timeout_seconds`, `resolver.mcp_timeout_seconds`, `resolver.active_snapshot_limit` are). A user
setting them gets no effect and no warning. Delete the fields/defaults (or wire them).

## Retired config keys stay in real configs silently

- type: idea · confidence: med · tags: [config, ux]
- where: internal/config/config.go (Load); cmd/config.go

The owner's config.yaml still carries at least six inert keys: `memory.surfaces.disputes`,
`memory.sources.actions`, `gmail.account_email`, `digest.model` (the retired seeded default),
`jira.cloud_id`/`site_url`/`user_display_name` — none decoded into anything, no warning at load or in
`config` output. Each retirement so far chose "leave inert"; the sum is a config file that misleads
anyone reading it (e.g. "disputes: true"). Suggest a `watchtower config doctor` (or a one-line load-time
notice) listing unknown/retired keys, with an optional `--prune`.

## Orphaned running pipeline_runs rows are never reaped

- type: chore · confidence: high · tags: [pipeline-runs, observability]
- where: internal/db/pipeline_runs.go:49; internal/daemon/daemon.go (trackedPipelineRun)

15 rows sit in `status='running'` forever (7 `ask` from one 2026-09-11 minute, 7 `memory` from July plus
one from 2026-09-25, 1 `people` from 2026-08-17): a killed process never finishes its row and nothing
reaps it (no stale-running sweep on either side). They inflate "running" in Pipeline Progress/history and
skew duration/error statistics. Suggest a startup sweep marking `running` rows older than N hours as
`error` ("interrupted"), the Catch-Up `reapStaleRecaps` precedent.

## items_found means different things per pipeline, making usage metrics unreliable

- type: chore · confidence: high · tags: [pipeline-runs, observability]
- where: internal/daemon/daemon.go:1199-1216 (stream-digests), slack-sync tracked run

`stream-digests` never sets `items` (48 runs, all `items_found=0`, while 7 stream_digests rows were written);
`slack-sync` records a cumulative total (~72k on every run, summing to 65M over 30 days) rather than the
run's delta; `next_step` and `jira-boards` also always report 0. Anyone judging "features producing
nothing" from `pipeline_runs` (Desktop Pipeline Progress included) gets wrong answers. Make each
tracked run report rows it wrote.

## Gmail stream digests: 25 consecutive runs wrote nothing, and the log cannot say why

- type: bug · confidence: low · tags: [ideas, streams, gmail, observability]
- where: internal/ideas/email_digest.go:385-425

Since 2026-09-21 every Gmail stage-1 pass logged "no topics survived validation, no stream_digests row
written" (25 times, both accounts) while ~100 new messages / ~94 threads were synced and the per-account
floors advanced past them. `mineStreamTopics` returns `validateRefs(...)` output, so the log conflates "the
model found no topics" with "the model found topics but every ref was rejected" — the latter would be a
silent-drop bug with the floor already advanced (IDEA-01 converse clause). Log proposed vs rejected counts
(the `refs_rejected` pattern used elsewhere) to tell the two apart; then decide whether this is a bug.

## Legacy CLI surfaces: visible tasks stub and a second decisions view

- type: chore · confidence: high · tags: [cli, dead-code]
- where: cmd/tasks.go:11-24; cmd/decisions.go:17,54-82

`watchtower tasks` is a non-hidden deprecation stub for the April tasks→targets rename; the repo was just
re-published with fresh history, so no external user can have the old name — hide or delete it.
`watchtower decisions` still scrapes decisions out of raw `digest_topics`, while the canonical decision
ledger is `ideas WHERE kind='decision'` (822 rows, deduped, with supersede/reverse status); the CLI shows
a different, undeduped set than the Desktop Decisions view. Point it at the ledger or remove it. No
Desktop or daemon caller for either.

## Retired inbox_items columns and a stale CLAUDE.md claim about dispute flags

- type: chore · confidence: high · tags: [inbox, memory, schema, docs]
- where: internal/db/inbox.go:19-20; WatchtowerDesktop/Sources/WatchtowerCore/Models/InboxItem.swift; WatchtowerDesktop/Sources/ViewModels/SidebarCountsViewModel.swift:83,155

`inbox_items` still carries the triage/situation-card columns `why_matters`, `thread_digest`, `draft_reply`,
`card_status`, `card_generated_at`, `composed_at`, `ai_reason` — only scanned into the model struct, never
written since the 2026-09-14 demolition (0 non-default values on rows from 09-25+). Drop them in a future
table-recreation migration. Separately, CLAUDE.md says "nothing reads" `memory_dispute_flags` since the
demolition, but the Desktop Memory sidebar badge (`MemoryQueries.fetchDisputedCount`) and the memory
queries' LEFT JOINs do — the flags table is 0 rows on the live install; fix the doc sentence.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
