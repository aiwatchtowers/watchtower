# Claude plan limits — 5h / 7d usage and a projection of when you hit them

**Date:** 2026-10-15
**Status:** design approved (asks #137, #139, #145); spec under review

## Goal

The owner sees their Claude subscription limits (Max plan) inside Watchtower at a
glance — the 5-hour session window, the 7-day weekly window and any per-model weekly
limit — together with a projection: "at the current pace you hit this limit at HH:MM"
or "you will not hit it before it resets". A macOS notification warns once per window
when the projection says the limit will be hit before the reset.

The limits are **account-wide**: Claude chats, Cowork and Claude Code all draw from
them. The feature is named **Claude plan**, not "Claude Code"; the Claude Code OAuth
token is only the means of reading the account's numbers, and the projection is built
from the account-wide percentages, so usage from every surface counts.

### Decisions taken with the owner

| Ask | Decision |
|-----|----------|
| #137 | Show it both in the menu bar (compact) and as a detailed card in the app. |
| #139 | macOS notification when the projection hits before the reset (and at 90%). |
| #139 | Per-model weekly limits shown in the card; the menu bar shows 5h and 7d only. |
| #139 | The card lives on the existing **Usage** screen as a new tab. |
| #139 | Note: "not only Claude Code" — limits and wording are account-wide. |

### Out of scope (v1)

- The iPhone app (a slice can follow later).
- Codex / ChatGPT plan limits.
- Refreshing the OAuth token (see Credentials).
- Buying extra usage, spend/credits display beyond what the card shows for free.

## Data source

`GET https://api.anthropic.com/api/oauth/usage` with
`Authorization: Bearer <access token>` and `anthropic-beta: oauth-2025-04-20` — the
endpoint Claude Code's `/usage` reads. It is undocumented, so the parser is lenient:
unknown keys are ignored, every field is optional, and a response with no usable
limit is an error state, not a crash.

Fields used (shape verified 2026-10-15, values illustrative):

```json
{
  "five_hour":  { "utilization": 12.0, "resets_at": "2026-10-15T11:00:00Z" },
  "seven_day":  { "utilization": 40.0, "resets_at": "2026-10-19T16:00:00Z" },
  "limits": [
    { "kind": "session",        "group": "session", "percent": 12, "severity": "normal",
      "resets_at": "2026-10-15T11:00:00Z", "scope": null, "is_active": false },
    { "kind": "weekly_all",     "group": "weekly",  "percent": 40, "severity": "normal",
      "resets_at": "2026-10-19T16:00:00Z", "scope": null, "is_active": true },
    { "kind": "weekly_scoped",  "group": "weekly",  "percent": 7,  "severity": "normal",
      "resets_at": "2026-10-19T16:00:00Z",
      "scope": { "model": { "display_name": "Fable" }, "surface": null } }
  ],
  "seven_day_breakdown": {
    "as_of": "…", "window_started_at": "…",
    "rows": [ { "key": "claude_code", "display_name": "Claude Code", "percent": 100 },
              { "key": "chat", "display_name": "Chats", "percent": 0 } ]
  }
}
```

Parsing rules:

- `limits[]` is the primary list. Each entry becomes a **limit** with a stable key:
  `session`, `weekly_all`, and `weekly_scoped:<model display name lowercased>` (or
  `:<surface>` when the scope is a surface). Label comes from kind + scope
  ("5-hour", "Weekly", "Weekly · Fable").
- If `limits` is absent or empty, fall back to `five_hour` → `session` and
  `seven_day` → `weekly_all` (and `seven_day_opus` / `seven_day_sonnet` when non-null
  → `weekly_scoped:opus` / `:sonnet`).
- `percent` is clamped to 0…100 (stored as a float; `utilization` may be fractional).
- `seven_day_breakdown.rows` is kept as-is (key, label, percent) for the card.
- `severity` is stored verbatim and used only as a hint; our own colour thresholds
  decide the UI.

## Credentials

`internal/planusage` reads the Claude Code OAuth credentials, read-only:

1. macOS Keychain generic password, service `Claude Code-credentials`, via
   `/usr/bin/security find-generic-password -s … -w` (the same way Claude Code reads
   it, so the item's ACL already allows it without a prompt).
2. Fallback: `~/.claude/.credentials.json` (Linux-style install / older versions).

From `claudeAiOauth` it uses `accessToken`, `expiresAt` (ms epoch) and
`subscriptionType` (shown in the card, e.g. "Max").

**Watchtower never refreshes the token.** A refresh rotates the refresh token and
would sign Claude Code out. If the access token is expired (or the endpoint answers
401), the status becomes `stale` with reason `token_expired`; the next poll re-reads
the credentials, so as soon as Claude Code refreshes its token (it does on its next
run) the numbers come back. The UI says "Open Claude Code to refresh" while stale.

No credentials → status `unavailable` (reason `no_credentials`); the feature shows a
one-line hint instead of numbers and does not poll the network.

The token is never logged, never written to the DB and never passed on argv
(`security` prints it to our stdout pipe).

## Polling (Go daemon)

A `PlanUsagePoller` started by the daemon next to the other long-lived goroutines,
on its own ticker, independent of the sync cadence:

- Interval 5 min. First poll ~10 s after daemon start.
- Gated by the feature flag (`claude-plan-limits`, config key
  `plan_usage.enabled`, default on). Off → no polls; the daemon writes `disabled` once at start (`MarkDisabled`), keeping the last numbers.
- HTTP timeout 15 s, `User-Agent: watchtower/<version>`.
- 429 / 5xx / network error: exponential backoff 5 → 10 → 20 → 30 min cap; status
  keeps the last good numbers and records `last_error` + `last_error_at`.
- 401: `stale/token_expired` (see above), no backoff beyond the normal interval.
- `watchtower usage plan --now` (and the Desktop "Refresh" button, which runs it)
  forces one poll outside the ticker; it does not reset backoff on failure.

The poller lives in `internal/planusage` (client, parser, projection, store); the
daemon only owns the goroutine and the flag check.

## Storage — migration 00115

```sql
-- +goose Up
CREATE TABLE plan_usage_samples (
    taken_at   TEXT NOT NULL,           -- RFC3339 UTC, poll time
    limit_key  TEXT NOT NULL,           -- session | weekly_all | weekly_scoped:<x>
    percent    REAL NOT NULL,           -- 0..100
    resets_at  TEXT NOT NULL,           -- window end from the response
    PRIMARY KEY (limit_key, taken_at)
);

CREATE TABLE plan_usage_status (
    id               INTEGER PRIMARY KEY CHECK (id = 1),   -- singleton
    state            TEXT NOT NULL CHECK (state IN ('ok','stale','unavailable','error','disabled')),
    reason           TEXT NOT NULL DEFAULT '',
    plan             TEXT NOT NULL DEFAULT '',             -- subscriptionType
    fetched_at       TEXT,                                 -- last good fetch
    last_error       TEXT NOT NULL DEFAULT '',
    last_error_at    TEXT,
    limits_json      TEXT NOT NULL DEFAULT '[]',           -- current limits + projection
    breakdown_json   TEXT NOT NULL DEFAULT '[]',           -- surface breakdown rows
    updated_at       TEXT NOT NULL
);
-- +goose Down
DROP TABLE plan_usage_status;
DROP TABLE plan_usage_samples;
```

- Samples older than 8 days are deleted after each successful poll.
- A sample is written per limit per successful poll (≈ 3 rows / 5 min ≈ 7 k rows / 8 d).
- `limits_json` is an array of
  `{key, label, group, percent, resets_at, severity, projection: {state, hit_at, rate_per_hour}}`
  so the Desktop and the CLI read one row and never recompute the projection.
- Mirrored into `schema.sql`, `TestAllTablesExist`, the golden snapshot and the Swift
  test schema, per CLAUDE.md.

## Projection

Computed in Go (`planusage.Project`) after each successful poll, per limit, written
into `limits_json`. Single implementation — Swift only renders.

Input: the samples of this limit **in the current window** (same `resets_at`, ±60 s
tolerance for the server's sub-second jitter) inside a lookback:

| Limit group | Lookback |
|-------------|----------|
| session (5 h) | last 60 min |
| weekly | last 24 h |

Algorithm:

1. If the current percent ≥ 100 → `state = "hit"`, `hit_at = null`.
2. If the samples span < 15 min → `state = "collecting"`.
3. Rate = least-squares slope of percent over time (percent per hour), floored at 0.
4. Rate ≈ 0 (< 0.01 %/h) → `state = "safe"`.
5. `hit_at = now + (100 − percent) / rate`. If `hit_at ≥ resets_at` → `"safe"`
   (with `hit_at` kept for the tooltip "at this pace: 112% by reset"); otherwise
   `"will_hit"` with `hit_at`.

A window reset (new `resets_at`) naturally restarts the projection at "collecting".
The weekly lookback of 24 h means a burst in the last hour does not swing the weekly
forecast; the 5-hour forecast reacts within the hour.

## Desktop

All Desktop code reads the shared DB through GRDB (`PlanUsageQueries` in
WatchtowerCore, a `PlanUsageStatus` model decoding `limits_json`), observed with
`ValueObservation` so the menu bar and the card update when the daemon writes.

### Menu bar

- The status item shows a compact text next to the icon: `5h 4% · 7d 59%`.
- Colour of the text follows the worst of the two: normal < 70%, amber 70–89% or
  projection `will_hit`, red ≥ 90% or `hit`.
- Stale / error → the last numbers greyed out; unavailable or feature off → icon only.
- A setting "Show Claude plan usage in the menu bar" (default on) in the Usage tab
  hides the text without turning the feature off.
- Tray menu gets one row per window: `5-hour: 4% · resets 13:59 · safe` /
  `Weekly: 59% · resets Mon 18:59 · hits Sun 21:40`, clicking opens Usage → Claude
  plan.

### Usage screen → "Claude plan" tab

New segment next to Progress / Usage (first position; remembered selection):

- Header: plan name ("Max"), "updated 2 min ago", Refresh button, stale/error banner.
- One row per limit (5-hour, Weekly, then per-model weekly): progress bar, percent,
  "resets in 3 h 12 m (13:59)", projection line ("At this pace you hit it at 21:40,
  2 h before the reset" / "You won't hit it before the reset" / "Collecting data…").
- Chart (Swift Charts): percent over time for the current 5-hour window and the
  current weekly window (two small charts), with the projection drawn as a dashed
  line to 100% or to the reset, and a vertical rule at the reset time.
- Surface breakdown for the weekly window: Claude Code / Chats / Cowork / Other with
  their share.

### Notifications

Posted by the Desktop app (`PlanUsageNotifier`, through the existing
notification-centre plumbing and its settings toggle):

- `will_hit` for a limit → one notification per `(limit_key, resets_at)`:
  "Weekly Claude limit: at this pace you hit it Sun 21:40 (resets Mon 18:59)".
- percent ≥ 90 → one notification per `(limit_key, resets_at)`.
- Dedupe keys kept in `UserDefaults`; pruned when their `resets_at` is past.
- Only `session` and `weekly_all` notify by default; per-model limits only at ≥ 90%.

## CLI

`watchtower usage plan [--json] [--now]`:

- Prints the status row: plan, state, each limit with percent, reset, projection.
- `--now` polls once first (shares the poller's code path and writes the same rows).
- `--json` keys are pinned in a test (Desktop's Refresh relies on the exit code only).

## Feature Manager

New registry entry `claude-plan-limits` ("Claude plan limits"), config key
`plan_usage.enabled`, default on, no onboarding goal, category with the other
system/utility features. Off → the poller does not run, the menu bar shows the icon
only, the Usage tab shows "Turned off in Features".

## Error handling summary

| Situation | state / reason | UI |
|-----------|----------------|----|
| No credentials | unavailable / no_credentials | hint "Sign in to Claude Code to see plan limits" |
| Token expired / 401 | stale / token_expired | last numbers grey, "Open Claude Code to refresh" |
| 429 / 5xx / network | error / http_<code> or network (numbers kept) | grey numbers, "Last updated 25 min ago" |
| Response without limits | error / parse | same as above |
| Feature off | disabled (numbers kept) | banner "turned off in Features", no menu bar or tray numbers |

`error` keeps the last good `limits_json`; the UI greys values older than 15 min.

## Testing

Go (`internal/planusage`):
- Parser: fixture responses (redacted, synthetic values) — full `limits[]`, legacy
  `five_hour`/`seven_day` only, scoped by surface, unknown keys, nulls everywhere,
  garbage → parse error.
- Credentials: Keychain path via an injected command runner; file fallback; expired
  `expiresAt`; the token never appears in errors.
- Projection: table tests — collecting (< 15 min), flat → safe, steady → will_hit
  with exact `hit_at`, hit-after-reset → safe, window change resets, ≥ 100 → hit,
  negative slope floored.
- Poller: fake HTTP server for 200 / 401 / 429 / 500 and backoff sequence; retention
  pruning; flag off → no request.
- Migration: `TestAllTablesExist`, schema golden, Swift test schema regenerated.
- CLI: `usage plan --json` pinned keys.

Swift (`Tests/Core`):
- `PlanUsageStatus` decoding of `limits_json`.
- Presentation: colour thresholds, menu bar text, projection sentences, stale greying.
- `PlanUsageNotifier`: one notification per window, prune past keys, per-model only at 90%.

## Docs

New `docs/features/claude-plan-limits.md` and a line in CLAUDE.md's Feature Notes;
behaviour inventory entries for the never-refresh-the-token rule and the
one-notification-per-window rule.
