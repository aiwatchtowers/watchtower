---
type: bug
title: "A rate-limited first search page triggers a full conversations.history sync"
status: done
priority: med
tags: [slack, sync, rate-limit, api-budget, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go sync/daemon/integrations)
created: 2026-09-26
---

**Where:** internal/sync/search_sync.go:129-146, internal/sync/orchestrator.go:272-280, internal/sync/orchestrator.go:800-808
**Confidence:** high

`isNonFatalError` counts `*slack.RateLimitedError` as non-fatal. In `syncViaSearch`, a non-fatal error on page 1 is returned (meant for `missing_scope`). `runSearchSync` then sees `isNonFatalError(err)` and falls back to `runFullSync`: conversations.list, users.list and one conversations.history per member channel, which is hundreds of Tier-3 calls. So when Slack is already throttling this token (after `doRequest`'s 3 retries), the daemon answers with its most expensive sync path. It also bypasses the hourly/daily throttles added in the 2026-09-26 API-budget work. The reaction-commands poll uses its own client and limiter against the same token, so exhausting the quota is realistic. Fix: fall back to full sync only for scope-type errors (`missing_scope`/`access_denied`). A rate limit should end the cycle with the watermark unchanged.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

Resolution: added `isRateLimitError` (`internal/sync/orchestrator.go`), which
recognizes only `*slack.RateLimitedError` — a real Slack 429 — never a scope error or
any other non-fatal Slack error code. `syncViaSearch`'s page-1 handling now checks
`isRateLimitError` (not the broader `isNonFatalError`) before deciding whether to
return the error: a rate limit ends the cycle with the watermark untouched and sets a
new `Orchestrator.searchRateLimited` flag, which also suppresses `runSearchSync`'s
separate "zero channels discovered" fallback — a rate-limited fresh account used to
still fall through to full sync via that second path even after the primary fallback
was fixed. Every OTHER non-fatal page-1 error (`missing_scope`/`access_denied`,
`account_inactive`, `channel_not_found`, ...) is unchanged from before this fix and
still falls back to full sync, exactly as it did pre-fix — only the rate-limit case
is carved out. (An earlier version of this fix, reviewed in PR #20, instead special-
cased scope errors and treated every other non-fatal error the same as a rate limit;
that inverted the fallback decision for `account_inactive`/`channel_not_found`/etc.,
a real behavior change the review caught (F10) — the narrower `isRateLimitError` check
above replaces it.) Pinned by
`TestSyncViaSearch_RateLimitedFirstPageDoesNotFallBackToFullSync` (a real HTTP 429
with `Retry-After`, asserting zero `conversations.list`/`conversations.history` hits
and an unchanged watermark), `TestIsRateLimitError`, and
`TestSyncViaSearch_NonRateLimitNonFatalFirstPageFallsBackToFullSync` (channel_not_found
still falls back, alongside the pre-existing missing_scope coverage in
`TestSearchSync_MissingScopeFallsBackToFullSync`).

A second finding from the same PR #20 review (bisecting an over-100-page search
window by date) was withdrawn as a separate, still-open backlog item — see sub-item 4
of `docs/backlog/2026-09-26-review-low-priority-go-bugs-infra.md` for that note.

**Verify round (same PR):** a rate-limited cycle wasn't actually "ending the cycle" —
`syncViaSearch` returned `nil`, so `runSearchSync` went on to the channel read-state
refresh, the user roster refresh and the inbox reactions sync, each a further Slack
call against the same throttled token. `runSearchSync` now returns early right after
`syncViaSearch` when `Orchestrator.searchRateLimited` is set, before any of those three
phases and before `finishSync` (so `TouchSyncedAt` doesn't refresh the Desktop's "last
synced" time for a cycle that fetched nothing); `readStateSyncedAt`/`rosterSyncedAt`
are left untouched, so both refreshes are still due next cycle exactly as if the cycle
hadn't run. `searchGapNote` is now set to a short note ("search sync: rate-limited by
Slack; retrying next cycle") at the same point `searchRateLimited` is set, so it rides
the existing gap-note mechanism into `recordAuthResult`'s "ok" write and shows up on
the account row instead of a rate-limited token silently looking healthy. Extended
`TestSyncViaSearch_RateLimitedFirstPageDoesNotFallBackToFullSync` to seed an unread
digest and a pending inbox item (so the skipped phases would have real Slack calls to
make if they ran) and assert zero `conversations.info`/`users.list`/`reactions.list`
hits, both refresh timestamps still zero, and the account row's `status`/`error`
after the run. `TestIsRateLimitError` also gained bare and `%w`-wrapped
`*slack.RateLimitedError` positive cases (it previously asserted only negatives).
