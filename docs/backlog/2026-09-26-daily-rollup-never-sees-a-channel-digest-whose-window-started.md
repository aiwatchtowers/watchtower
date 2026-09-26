---
type: bug
title: "Daily rollup never sees a channel digest whose window started before UTC midnight"
status: open
priority: med
tags: [digest, rollup, window, timezone, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/digest/pipeline.go:1396-1406 (plus internal/db/digests.go:103-110, internal/digest/pipeline.go:588-597, 1098, 1313)
**Confidence:** high

A channel digest's `period_from` is the channel's own mark (`channelDigestSince`: the last digest's `period_to` or `digest_considered_ts`), not the first message of the day. `runDailyRollupForDate` selects channel digests with `GetDigests{FromUnix: dayStartUTC, ToUnix: dayEndUTC}`, which becomes `period_from >= dayStart AND period_to <= dayEnd`. So every channel's first digest after 00:00 UTC is excluded from both days' rollups, because its window opens on the previous mark. For a quiet channel, or one held back by `applyDigestCooldown`, every digest usually starts on an earlier day, so that channel never reaches any daily rollup. The briefing's `gatherDigests` filter has the same containment shape with a 1-day lookback, which hides this less. `dailyRollupNeeded` reads the same filtered set, so a late digest of this kind does not trigger a regeneration either. Fix: select by overlap or by `period_to` inside the day (the `GetDigestsOverlapping` shape), not full containment.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
