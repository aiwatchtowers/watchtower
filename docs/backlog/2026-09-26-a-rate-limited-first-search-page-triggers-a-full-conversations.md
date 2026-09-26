---
type: bug
title: "A rate-limited first search page triggers a full conversations.history sync"
status: open
priority: med
tags: [slack, sync, rate-limit, api-budget, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go sync/daemon/integrations)
created: 2026-09-26
---

**Where:** internal/sync/search_sync.go:129-146, internal/sync/orchestrator.go:272-280, internal/sync/orchestrator.go:800-808
**Confidence:** high

`isNonFatalError` counts `*slack.RateLimitedError` as non-fatal. In `syncViaSearch`, a non-fatal error on page 1 is returned (meant for `missing_scope`). `runSearchSync` then sees `isNonFatalError(err)` and falls back to `runFullSync`: conversations.list, users.list and one conversations.history per member channel, which is hundreds of Tier-3 calls. So when Slack is already throttling this token (after `doRequest`'s 3 retries), the daemon answers with its most expensive sync path. It also bypasses the hourly/daily throttles added in the 2026-09-26 API-budget work. The reaction-commands poll uses its own client and limiter against the same token, so exhausting the quota is realistic. Fix: fall back to full sync only for scope-type errors (`missing_scope`/`access_denied`). A rate limit should end the cycle with the watermark unchanged.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
