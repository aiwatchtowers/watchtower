---
type: bug
title: "Gmail noise-label messages never advance the watermark, so they are re-fetched every cycle and can stall sync"
status: open
priority: med
tags: [gmail, watermark, api-cost, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go sync/daemon/integrations)
created: 2026-09-26
---

**Where:** internal/gmail/sync.go:98-114, internal/gmail/sync.go:136-148
**Confidence:** high

Messages labelled `CATEGORY_PROMOTIONS`/`CATEGORY_SOCIAL` hit `continue` before `maxSeen` is updated. Two consequences:
1. Every promotional or social message received after the last "real" message is listed and fetched again (`GetMessage`, format=full) on every cycle, until a non-noise message arrives after them.
2. If the oldest `MaxMessagesPerSync` (default 100) ids in the window are all noise, the watermark never moves. The same 100 messages are fetched every cycle and newer mail is never reached, and there is no error or log line.

These messages are skipped on purpose, not lost, so it is safe to move the watermark past them (the non-stalled branch). Fix: update `maxSeen` for a noise skip when `!stalled`.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
