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

## Jira key detector caches known project keys for the whole daemon lifetime

- type: bug · confidence: high · tags: [jira, slack-links, cache]
- where: internal/jira/key_detector.go:97-116, internal/jira/key_detector.go:230-252

`knownProjectKeys` memoizes the first non-empty set and reloads only while it is empty. `ResetCache` has no production caller. A daemon launched from the tray runs for weeks. When a board for a new project is connected (or a new project appears in `jira_issues`), that project's keys are never linked from Slack messages, digests or tracks until the daemon restarts. `get_task_context`, the Linked Jira badges and `--jira` silently leave those links out. Fix: refresh on a TTL (e.g. hourly), or call `ResetCache` after a Jira sync pass that added boards or projects.

## Jira client: a 401 after three 429s is reported as a revoked grant with no refresh attempt

- type: bug · confidence: med · tags: [jira, auth, retry]
- where: internal/jira/client.go:56-113, internal/jira/rate_limiter.go:60-69

`do` has one shared attempt counter (0..3) for both 429 and 401. If attempts 0–2 get 429 and attempt 3 is the first 401 (for example, the access token expired during the backoff), the `attempt == 3` branch returns `ErrAuthRevoked` without ever refreshing. `phaseJiraSync` then stamps the account `revoked`, and only a re-login clears it. The 429 backoff is also a fixed 1/2/4 s that ignores `Retry-After`, which makes this path more likely under real throttling. Fix: count 401-after-refresh separately from 429 retries, and honor `Retry-After`.

## IMAP "new since" listing uses a N:* UID range, which per RFC 3501 always includes the last message

- type: bug · confidence: med · tags: [imap, sync, rfc]
- where: internal/imap/client.go:64-99, internal/imap/sync.go:94-163

`SearchNewSince` fetches the UID range `lastUID+1:*`. RFC 3501 §6.4.8 says a range like `559:*` "always includes the UID of the last message in the mailbox, even if 559 is higher than any assigned UID value". So on a real server (Dovecot, Exchange, Gmail IMAP), a cycle with no new mail still returns the latest message. The code comment claims FETCH is immune and only SEARCH has this quirk; the RFC rule applies to UID sets in general. The effect is mostly waste, but it is real: every cycle re-fetches and re-upserts that message (bumping `synced_at`/`updated_at`), logs "imap: 1 messages synced", and re-feeds the inbox detector and kb cursor. The in-repo go-imap memory test server does not implement the rule (a throwaway overlay test with lastUID = highest returned `[]`), which is why tests pass. Fix: drop UIDs `<= lastUID` from the result.

## Slack search sync can never finish a window with more than 100 result pages

- type: bug · confidence: low · tags: [slack, sync, pagination]
- where: internal/sync/search_sync.go:118-246, internal/slack/client.go:350-373

`search.messages` is paged at 100 results per page, and Slack serves at most 100 pages (10k matches) per query. `syncViaSearch` keeps going until `page >= result.Pages`, and sets the watermark only when `completed`. If a window holds more than 10k matches (a first run with `initial_history_days=30` for someone in many busy channels, or a 30-day clamped catch-up), page 101 either errors or comes back empty. If it errors, the watermark never moves: the same 100 pages (100 Tier-2 calls) are re-fetched every cycle and the pass never completes. If it comes back empty, `completed=true` and the newest matches beyond page 100 are skipped for good. This is unverified against the live API (hence low confidence). Fix: shrink the window (split by `before:`/`after:` date ranges) whenever `result.Pages > 100`.

## Google calendar events share one global id key across accounts, so shared meetings flip owner and account removal unlinks recordings

- type: bug · confidence: med · tags: [calendar, multi-account, schema]
- where: internal/db/calendar.go:87-112 (ON CONFLICT(id)), internal/db/google_accounts.go:106-123, internal/calendar/sync.go:143-186

Google gives the same event id to every attendee's copy of a meeting, but `calendar_events` is keyed on `id` alone. When two connected Google accounts (or two selected calendars in one account) both have the same meeting, each sync overwrites `calendar_id`, `attendees` (including each attendee's `responseStatus`) and `raw_json` with the latest writer's view, so the row flip-flops every cycle. The documented v1 non-goal is cross-account dedup; the harm here goes further. `DeleteGoogleAccount` deletes by `calendar_id IN (account's calendars)` without the transcript/recap guard. Removing the account that happened to write last deletes the shared event, and every recording or recap linked to it is set to NULL for good, even though the other account re-inserts the event on its next sync. Fix: at minimum, add the `NOT EXISTS meeting_transcripts/meeting_recaps` guard to `DeleteGoogleAccount`. The longer-term fix is an `(account_id, id)` identity (a migration plus a key change).

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
