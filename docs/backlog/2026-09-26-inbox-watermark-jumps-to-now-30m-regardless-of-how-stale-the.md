---
type: bug
title: "Inbox watermark jumps to now-30m regardless of how stale the synced data is"
status: open
priority: high
tags: [inbox, watermark, INBOX-09, slack, jira, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/inbox/pipeline.go:246-254,302-303 (plus internal/daemon/daemon.go:375-429, internal/db/inbox.go:428)
**Confidence:** high

`decideWatermark` sets `inbox_last_processed_ts = now − 30 min`, where "now" is the time `phaseInbox` runs. But `phaseInbox` runs only after channel digests, tracks, rollups and people cards. The Slack sync that feeds it ran at the start of the cycle, and those AI phases can take tens of minutes. The Slack detectors filter on `m.ts_unix > lastTS`, which is the message's post time, not its sync time. Scenario: the Slack sync finishes at S, the AI phases run 45 minutes, and the inbox runs at S+45m, setting the watermark to S+15m. A mention posted at S+5m is synced on the next cycle with `ts_unix` < watermark and is never detected. The same happens when `phaseSlackSync` fails or is rate-limited: `runSync` still runs the inbox on the existing data, and the watermark still advances. That contradicts inbox-pulse.md INBOX-09, which says a "Slack sync error" freezes it. Jira `updated_at` has the same exposure through the shared cursor. Fix: cap the new watermark at the sync high-water, e.g. `min(now−30m, slack-sync start time)`, and freeze it when the sync phase errored. This touches an Enforced contract, so it needs owner sign-off.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
