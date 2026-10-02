---
type: chore
title: "Low-priority findings bundle — bugs (Go sync/daemon/integrations)"
status: open
priority: low
tags: [go-bugs-infra, review-2026-09-26, bundle]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go sync/daemon/integrations)
created: 2026-09-26
---

5 low-priority findings from the bugs (Go sync/daemon/integrations) track, bundled so the backlog
stays readable. Split any item into its own file when it gets picked up.

Still open after fix/go-low-priority-bundle: the Slack search >100-pages item (needs a live-API
check) and the calendar `(account_id, id)` identity half (a migration-sized design item).

## Jira key detector caches known project keys for the whole daemon lifetime (fixed in fix/bl-jira-hardening)

- type: bug · confidence: high · tags: [jira, slack-links, cache]
- where: internal/jira/key_detector.go:97-116, internal/jira/key_detector.go:230-252

`knownProjectKeys` memoizes the first non-empty set and reloads only while it is empty. `ResetCache` has no production caller. A daemon launched from the tray runs for weeks. When a board for a new project is connected (or a new project appears in `jira_issues`), that project's keys are never linked from Slack messages, digests or tracks until the daemon restarts. `get_task_context`, the Linked Jira badges and `--jira` silently leave those links out. Fix: refresh on a TTL (e.g. hourly), or call `ResetCache` after a Jira sync pass that added boards or projects.

Resolution: `KeyDetector` gained an hourly `knownProjectKeysTTL`; `knownProjectKeys` now reloads once
the cached set is either empty or older than the TTL (stamped in `loadedAt` on every successful
load), via an injectable `now` clock (the `internal/sync.Orchestrator.now` precedent) so the tests
cross the TTL without a real hour's wait. A failed TTL-triggered reload keeps serving the last
known-good set instead of wiping it, so a transient DB hiccup can't turn a stale-but-correct cache
into "detects nothing." `ResetCache` is untouched and still available for an immediate forced
reload. Pinned by `TestKeyDetector_KnownKeysRefreshOnTTLExpiry` and
`TestKeyDetector_TTLReloadFailureKeepsServingStaleSet`.

## Jira client: a 401 after three 429s is reported as a revoked grant with no refresh attempt (fixed in fix/bl-jira-hardening)

- type: bug · confidence: med · tags: [jira, auth, retry]
- where: internal/jira/client.go:56-113, internal/jira/rate_limiter.go:60-69

`do` has one shared attempt counter (0..3) for both 429 and 401. If attempts 0–2 get 429 and attempt 3 is the first 401 (for example, the access token expired during the backoff), the `attempt == 3` branch returns `ErrAuthRevoked` without ever refreshing. `phaseJiraSync` then stamps the account `revoked`, and only a re-login clears it. The 429 backoff is also a fixed 1/2/4 s that ignores `Retry-After`, which makes this path more likely under real throttling. Fix: count 401-after-refresh separately from 429 retries, and honor `Retry-After`.

Resolution: `doURLWith` now tracks `refreshAttempts` (401) and `rateLimitAttempts` (429) as two
independent 3-retry budgets instead of one shared counter, so a run of 429s can no longer spend the
401 refresh budget before a real 401 arrives. The 429 branch also honors a `Retry-After` header
(`retryAfterDuration`, seconds or an HTTP-date) before falling back to `BackoffDuration`'s fixed
1/2/4s schedule. Pinned by `TestClient_401AfterRateLimitedAttemptsStillRefreshes` (three 429s, a
`Retry-After: 0` header, then a 401 that must still refresh and succeed) and the
`TestRetryAfterDuration_*` tests in `internal/jira/rate_limiter_test.go`. The same change also fixes
the scope-denied-401 sub-item in `docs/backlog/2026-09-27-review-low-priority-pr3-confluence-go.md`
(both live in the same `doURLWith` 401 branch) — see that file's own resolution note.

## IMAP "new since" listing uses a N:* UID range, which per RFC 3501 always includes the last message

- type: bug · confidence: med · tags: [imap, sync, rfc]
- where: internal/imap/client.go:64-99, internal/imap/sync.go:94-163

`SearchNewSince` fetches the UID range `lastUID+1:*`. RFC 3501 §6.4.8 says a range like `559:*` "always includes the UID of the last message in the mailbox, even if 559 is higher than any assigned UID value". So on a real server (Dovecot, Exchange, Gmail IMAP), a cycle with no new mail still returns the latest message. The code comment claims FETCH is immune and only SEARCH has this quirk; the RFC rule applies to UID sets in general. The effect is mostly waste, but it is real: every cycle re-fetches and re-upserts that message (bumping `synced_at`/`updated_at`), logs "imap: 1 messages synced", and re-feeds the inbox detector and kb cursor. The in-repo go-imap memory test server does not implement the rule (a throwaway overlay test with lastUID = highest returned `[]`), which is why tests pass. Fix: drop UIDs `<= lastUID` from the result.

Resolution (fix/go-low-priority-bundle): not reproducible through our client — go-imap v2's
`FetchCommand` keeps only responses whose UID is inside the requested set, so the last message a
real server answers for `N:*` never reached `SearchNewSince`'s loop. The loop now also skips any
UID <= lastUID itself, so the contract no longer rests on that library detail. Pinned by
`TestSearchNewSinceDropsAlreadySeenUIDsTheServerReturns`, whose test session widens every FETCH to
`1:*` the way a real server would; the doc comment that claimed FETCH itself is immune is corrected.

## Slack search sync can never finish a window with more than 100 result pages

- type: bug · confidence: low · tags: [slack, sync, pagination]
- where: internal/sync/search_sync.go:118-246, internal/slack/client.go:350-373

`search.messages` is paged at 100 results per page, and Slack serves at most 100 pages (10k matches) per query. `syncViaSearch` keeps going until `page >= result.Pages`, and sets the watermark only when `completed`. If a window holds more than 10k matches (a first run with `initial_history_days=30` for someone in many busy channels, or a 30-day clamped catch-up), page 101 either errors or comes back empty. If it errors, the watermark never moves: the same 100 pages (100 Tier-2 calls) are re-fetched every cycle and the pass never completes. If it comes back empty, `completed=true` and the newest matches beyond page 100 are skipped for good. This is unverified against the live API (hence low confidence). Fix: shrink the window (split by `before:`/`after:` date ranges) whenever `result.Pages > 100`.

**Attempted in PR #20, withdrawn.** A first attempt added a recursive date-bisection
(`runSearchWindow`/`bisectSearchDate` in `internal/sync/search_sync.go`) that split an
over-cap window at its midpoint and paged each half. PR #20's review (prosecutor pass)
found it was built on an unverified assumption about Slack's `after:`/`before:` date
filters and had several correctness gaps that only a live-API check can resolve safely:
- **F1/F2 (blockers):** Slack's `after:`/`before:` filters are documented as exclusive
  on both ends (`after:D` = from D+1, `before:D` = up to D-1). The bisection as written
  assumed inclusive/adjacent bounds, so (F1) the midpoint day itself falls outside
  *both* halves — `after:a before:mid` and `after:mid` both exclude day `mid` — yet the
  watermark still advances past it as if fully covered, and (F2) the smallest splits
  (a 2-day window bisecting into two 1-day-wide-by-the-arithmetic halves) can both
  resolve to zero real days under the exclusive semantics, silently completing with 0
  pages and skipping the over-cap day with no gap note at all.
- **F3 (major):** when the newer half (after a successful older half) hit any error —
  including a rate limit, which this same PR was trying to stop from escalating — the
  function returned `("", nil)`, discarding the older half's already-completed and
  already-upserted progress instead of still advancing the watermark to the older
  half's boundary.
- **F4 (major):** combined with F3, any transient failure in a later leaf (ctx cancel,
  a Slack 5xx, a DB error) re-fetches every already-completed older leaf from scratch
  next cycle — up to ~100 Tier-2 calls per leaf at the 40 req/min budget — with no
  guarantee of ever converging on a heavily-throttled, >10k-match catch-up (exactly the
  scenario this fix targets).
- **F5 (major):** the "unsplittable floor" (a single day still over the page cap)
  discarded the already-fetched page 1 and recorded a total gap, even though up to 100
  pages (10k matches, sorted oldest-first) were actually fetchable and only the tail
  beyond page 100 was genuinely unrecoverable.
- **F7 (minor):** over-cap detection keyed only on the response's own `pages` field,
  which — per this same finding's "unverified against the live API" framing — might
  itself be clamped to 100 by Slack rather than reporting the true count, in which case
  the split would never trigger and the original bug would persist undetected;
  `result.Total > maxSearchResultPages*count` was flagged as the more robust signal.

The controller decision was to drop the bisection entirely rather than patch it
further, since every one of the above traces back to an assumption about Slack's date
filters that needs a live API check before a fix can be trusted — see PR #20's review
notes for the full finding list (F1-F11). A future attempt should verify
`after:`/`before:` exclusivity and the true (unclamped or clamped) shape of the `pages`
field against a real workspace before re-attempting a window split, and must
checkpoint the watermark per completed leaf (fixing F3/F4) rather than only at the
end of the whole recursion. PR #20 kept only the separate, narrower fix in
`docs/backlog/2026-09-26-a-rate-limited-first-search-page-triggers-a-full-conversations.md`
(status: done) — this sub-item is unchanged and stays open.

Left open (fix/go-low-priority-bundle): still needs the live-API check of `after:`/`before:`
exclusivity and the `pages` shape described above before any window split is safe.

## Google calendar events share one global id key across accounts, so shared meetings flip owner and account removal unlinks recordings

(Minimal guard fixed in fix/bl-calendar-account-removal — `DeleteGoogleAccount` now spares referenced events and detaches their calendar; tracked as done in `2026-09-27-google-remove-unlinks-recordings-from-their-calendar-events`. The `(account_id, id)` identity / flip-flop half stays open.)

- type: bug · confidence: med · tags: [calendar, multi-account, schema]
- where: internal/db/calendar.go:87-112 (ON CONFLICT(id)), internal/db/google_accounts.go:106-123, internal/calendar/sync.go:143-186

Google gives the same event id to every attendee's copy of a meeting, but `calendar_events` is keyed on `id` alone. When two connected Google accounts (or two selected calendars in one account) both have the same meeting, each sync overwrites `calendar_id`, `attendees` (including each attendee's `responseStatus`) and `raw_json` with the latest writer's view, so the row flip-flops every cycle. The documented v1 non-goal is cross-account dedup; the harm here goes further. `DeleteGoogleAccount` deletes by `calendar_id IN (account's calendars)` without the transcript/recap guard. Removing the account that happened to write last deletes the shared event, and every recording or recap linked to it is set to NULL for good, even though the other account re-inserts the event on its next sync. Fix: at minimum, add the `NOT EXISTS meeting_transcripts/meeting_recaps` guard to `DeleteGoogleAccount`. The longer-term fix is an `(account_id, id)` identity (a migration plus a key change).

Left open (fix/go-low-priority-bundle): the remaining `(account_id, id)` identity is a migration
plus a key change across the calendar sync, meeting links and the Desktop — a design item, not a
low-priority patch.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
