# Claude plan limits — 5h / weekly usage + projection (2026-10-15)

Spec: `docs/superpowers/specs/2026-10-15-claude-plan-limits-design.md`. Plan: `docs/superpowers/plans/2026-10-15-claude-plan-limits.md`. Contracts: PLANUSAGE-01..03 in `docs/inventory/plan-usage.md`.

## Summary

Shows how much of the account's Claude plan limits is used — the 5-hour session window, the weekly window and per-model weekly limits — and a projection of when each limit is hit at the current pace. The limits are account-wide (Claude chats, Cowork and Claude Code all draw from them), so the feature is named "Claude plan", not "Claude Code"; the Claude Code OAuth token is only the means of reading the numbers. Feature Manager id `claude-plan-limits`, config key `plan_usage.enabled`, default on, no AI calls (`CostNone`).

## Data source

`GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <access token>` and `anthropic-beta: oauth-2025-04-20` (the endpoint Claude Code's `/usage` reads). It is undocumented, so `planusage.Parse` is lenient: unknown keys are ignored, every field is optional, and a body with no usable limit is a parse error, never a crash. HTTP timeout 15 s, `User-Agent: watchtower/<version>`.

- `limits[]` is the primary list. Each entry gets a stable key `<kind>:<slug(name)>`, where slug trims, lowercases and turns spaces into `-` (the slug comes from the model `display_name`, for example `weekly_scoped:opus` or `weekly_scoped:fable`); `session` and `weekly_all` carry no scope and keep the bare kind. An unknown kind with no scope keeps the bare kind as both key and label. Labels read "5-hour", "Weekly", "Weekly · <model>".
- If `limits` is absent or empty the parser falls back to `five_hour` → `session`, `seven_day` → `weekly_all`, and `seven_day_opus` / `seven_day_sonnet` when non-null.
- `percent` is clamped to 0…100 and kept as a float. `severity` is stored verbatim as a hint only; the UI thresholds are our own.
- `seven_day_breakdown.rows` (key, label, percent) is kept for the card.

## Credentials

`planusage.CredentialSource` is read-only: the macOS Keychain item `Claude Code-credentials` through `/usr/bin/security find-generic-password -s … -w` (the token arrives on our stdout pipe, never argv), then `~/.claude/.credentials.json`. It uses `claudeAiOauth.accessToken`, `expiresAt` and `subscriptionType`.

Watchtower never refreshes the token — a refresh rotates the refresh token and would sign Claude Code out (PLANUSAGE-01). An expired token, or a 401, gives status `stale` / reason `token_expired`; the next poll re-reads the credentials, so the numbers return once Claude Code refreshes its own token. No credentials gives `unavailable` / `no_credentials`. The token is never logged, stored or put in an error (PLANUSAGE-02; errors are redacted).

## Poller

`planusage.Poller` runs as a goroutine in the daemon (`cmd/plan_usage_daemon.go` wires it with `d.SetPlanUsage`), on its own ticker, independent of the sync cadence.

- First poll 10 s after start, then every 5 min.
- 429 / 5xx / network / parse failure: status `error` (reason `http_<code>`, `network` or `parse`), the last good numbers are kept, `last_error` + `last_error_at` are recorded, and the next delay backs off 5 → 10 → 20 → 30 min (cap). A 401 or an expired token resets the failure count and polls at the normal interval.
- `watchtower usage plan --now` (and the Desktop Refresh button, which runs it) forces one poll outside the ticker through the same `PollOnce`.
- A poll cancelled by shutdown (context cancelled during the credentials read or the fetch) returns the context error, writes no status row and counts no failure.
- Feature off: no polls; the daemon calls `MarkDisabled`, which sets status `disabled` and keeps the last numbers.

## Storage — migration 00115

- `plan_usage_samples(taken_at, limit_key, percent, resets_at)`, PK `(limit_key, taken_at)`; one row per limit per successful poll, pruned after 8 days following each successful poll.
- `plan_usage_status`, singleton (`id = 1`): `state` CHECK in `ok | stale | unavailable | error | disabled`, `reason`, `plan`, `fetched_at`, `last_error`, `last_error_at`, `limits_json`, `breakdown_json`, `updated_at`.
- Times are stored as whole-second RFC3339 UTC, so string order equals time order.
- `limits_json` is an array of `{key, label, group, percent, resets_at, severity, projection: {state, hit_at, rate_per_hour}}`: Desktop and CLI read one row and never recompute the projection.

## Projection

`planusage.Project`, computed in Go after each successful poll; Swift only renders. Samples are those of the limit in the current window (same `resets_at` within ±60 s) inside a lookback: 60 min for the session group, 24 h for weekly.

States: `idle` (window not started, no `resets_at`), `collecting` (samples span under 15 min), `safe`, `will_hit`, `hit`.

1. percent ≥ 100: `hit`.
2. No `resets_at`: `idle`.
3. Span under 15 min: `collecting`.
4. Rate is the least-squares slope in percent per hour, floored at 0; under 0.01 %/h: `safe`.
5. `hit_at = now + (100 − percent) / rate`; at or after `resets_at`: `safe` (with `hit_at` kept), otherwise `will_hit`.

A window reset (new `resets_at`) restarts the projection at `collecting`.

## Desktop

- `PlanUsageCenter` re-reads the status row every 30 s. The daemon writes the DB from another process, so there is no GRDB observation. `refresh()` runs `usage plan --now` and reloads.
- Menu bar text `5h N% · 7d M%`, showing the session and `weekly_all` limits only (per-model limits are not in the menu bar). A `⚠︎ ` prefix marks a warning state instead of colour, because a `MenuBarExtra` label is rendered as a template and drops colour. Toggle `planUsage.showInMenuBar` (default on) hides the text; `stale` and `error` keep the text but drop the `⚠︎`; only `unavailable` and `disabled` show the icon alone. A status that is still `ok` but older than 15 min (daemon stopped) shows its numbers with no stale mark, because the template label cannot grey them. Refresh is disabled while the state is `disabled`.
- The tray menu shows one item per limit line (session and weekly); a click opens Usage → Claude plan.
- Usage → Claude plan tab (`ClaudePlanView`): plan name, updated-ago, Refresh, stale / error banner, one row per limit (bar, percent, reset, projection sentence), percent-over-time charts with the projection as a dashed line, and the weekly surface breakdown. Pure rendering rules live in `PlanUsagePresentation` (WatchtowerCore).
- Notifications (`PlanUsageNoticePolicy` decides, the Desktop posts them): kind `will` for `session` and `weekly_all` when the projection is `will_hit`; kind `p90` for any limit at or above 90 %. Dedupe key `<kind>|<limit_key>|<resets_at ISO>`, so at most one notice per kind per limit per window (PLANUSAGE-03); sent keys are kept in the `planUsage.sentNotices` default and pruned a minute after their (rounded) reset; a limit whose `resets_at` is already past (old data until the next poll) never notifies. The `planUsage.notifications` toggle (absent = on) switches them off. Clicking a notice routes to Usage → Claude plan. Pause notifications (`quietHoursEnabled`, formerly "quiet hours") suppress notices without touching the sent set, so a notice still due fires after quiet hours end. The dedupe key rounds the reset time to the nearest minute, so server jitter across a second boundary cannot mint a new key. The policy sends nothing when the status is not `ok` or is stale (older than 15 min), and a limit with no `resets_at` never notifies.

## CLI

`watchtower usage plan [--json] [--now]` prints plan, state, and each limit with percent, reset and projection. `--now` polls once first (a failed poll shows in the exit code). When the feature is off (`plan_usage.enabled=false`) `--now` refuses with an error, does not poll and leaves the `disabled` status row untouched. The `--json` keys (`state`, `reason`, `plan`, `fetched_at`, `last_error`, `limits`, `breakdown`) are pinned by a test.

## Contracts

- PLANUSAGE-01: the token is never refreshed or written; an expired token sends no request.
- PLANUSAGE-02: the token never reaches the DB, logs or errors.
- PLANUSAGE-03: at most one notification per kind per `(limit, window)`.

## v1 limits

No iPhone slice, no Codex / ChatGPT limits, no token refresh, no spend display.
