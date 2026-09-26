---
type: bug
title: "Gmail thread reply after eviction overwrites the rollup node (missing non-episode guard)"
status: open
priority: med
tags: [memory, gmail, eviction, idempotency, MEM-07, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/memory/gmail_extract.go:483-497, internal/memory/evict.go:156 (plus calendar_ingest.go:310-324; compare jira_ingest.go:258)
**Confidence:** high

`EvictEpisodes` moves an evicted episode's aliases onto its rollup (`roll.Aliases = mergeAliases(...)`, evict.go:156), so after eviction `gmailthread:<tid>` resolves to a `rollup` node. `jiraEpisodeNode` guards this (`existing.Type != "episode"` → leave the node alone). `gmailEpisodeNode` has no such guard: it reads the rollup, sets `existing.Title` and replaces the whole `existing.Body = episodeBody(...)`, and keeps `Type: rollup`. Scenario: the thread's episode ages (14 d) and is evicted (45 d, low retention score). A reply then arrives on that thread. The rollup's gist (the only surviving summary of the evicted story) is replaced by an episode body built from the reply alone. `unionRefs(parseProvenance(existing.Body), ...)` finds no `## Provenance` section in a rollup, so the evicted refs also disappear from the live node. That breaks MEM-07, and the result is a hybrid "rollup" that never ages, dedupes or evicts again. `calendarEpisodeNode` has the same missing guard, but it is latent in practice: calendar sync keeps ~24 h of past events and the lookback is 2 days. Fix: copy the jira guard into both builders. For Gmail it is better to mint a fresh episode and cross-link it to the rollup, so a revived thread is still captured.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
