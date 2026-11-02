# Subscription plan limits — Claude and Codex

Spec: `docs/superpowers/specs/2026-11-01-plans-codex-design.md`. Plan: `docs/superpowers/plans/2026-11-01-plans-codex.md` (approved ask #936). Claude credential/notification contracts remain PLANUSAGE-01..03 in `docs/inventory/plan-usage.md`.

## Summary

**Usage → Plans** shows separate Claude and Codex subscription cards, published usage history and a forecast to each window's reset. All quota buckets remain available in the screen and popup; percentages are never summed. Feature id `claude-plan-limits`, config `plan_usage.enabled`, default on and `CostNone` are retained; its displayed name is **Subscription plan limits**.

## Sources and identity

Claude uses the read-only Claude Code credential loader and `GET https://api.anthropic.com/api/oauth/usage`. The macOS Keychain item is tried before Claude Code's credential file. Watchtower never refreshes or writes Claude credentials; an expired token sends no request, and a 401 marks the snapshot stale until Claude Code refreshes its own sign-in.

Codex uses the installed CLI's bounded JSON-RPC app-server in a neutral directory. Its only conversation is initialize → initialized → `account/read` with `refreshToken:false` → `account/rateLimits/read` with `excludeResetCreditDetails:true`. It makes no model/thread/turn, login/logout or reset-credit request, enables no experimental capability, and does not read `auth.json`. The process group is reaped on success, failure, timeout and cancellation.

Nonempty `rateLimitsByLimitId` wins over legacy `rateLimits`. Every bucket and optional primary/secondary window keeps a collision-free key; duration comes from `windowDurationMins`, never slot position. Actual 300/10080-minute windows map to five hours/week; other positive durations keep their own labels, and missing windows are not invented. Malformed data is a parse failure rather than 0%.

Codex history is scoped by SHA-256 of the Codex-home namespace plus the same response's account id. Raw identity, email, credentials and stderr are excluded from storage errors, plot JSON and the public CLI. A successful response without identity may publish its own current numbers, but stores no samples and has no history/forecast. A failed response without confirmation hides retained scoped numbers. Account switches cannot reuse another account's samples. API-key-only authentication is unsupported for subscription quotas.

## Polling and writers

Each provider runs independently: first attempt after 10 seconds, success every 5 minutes, transient-failure delays 5 → 10 → 20 → 30 minutes (cap), reset after success. A busy background lock skips the cycle without writing status or changing the failure count; its next tick is 5 minutes later. One failure never holds back the other provider.

All production writers share stable workspace lockfiles `.plan-usage-claude.lock` and `.plan-usage-codex.lock` (0600): daemon, aggregate refresh, legacy Claude refresh and disabled-state publication. Lockfiles are never replaced/unlinked. Manual refresh waits at most 20 seconds within a 45-second provider budget, rechecks the feature and snapshot under lock, then performs one fetch and publication. Separate external CLI refreshes each fetch once; the Desktop coalesces refreshes per provider and every caller awaits the shared result.

Network/process work is outside SQL transactions. Context-aware reads and transactions prevent cancellation during the storage phase from publishing a status; a cancelled transaction rolls back and does not advance backoff. Turning the common feature off stops both sources. Manual refresh while off only reads retained data.

## Storage and publication

Migration 00115's Claude singleton/samples stay compatible. Migration 00169 adds `codex_plan_usage_status`, scoped `codex_plan_usage_samples`, and `plot_json TEXT NOT NULL DEFAULT '{}'` to both status tables. Samples are retained for 8 days.

Codex publishes successful status and samples in one transaction. Claude retains samples-before-status; a status upsert publishes limits/fetched time/plot together. Reads select samples no later than published `fetched_at`, matching the current reset within ±60 seconds; Codex also requires the current scope. Repeated publication is idempotent. Errors retain last-good diagnostic data, while presentation gates prevent drawing an old forecast.

## Forecast contract

The existing Go least-squares policy is reused: nonnegative rate, at least 15 minutes of observations, a 1-hour session lookback and 24 hours for other groups. Raw states remain `idle | collecting | safe | will_hit | hit`. A reset restarts collection.

Go publishes schema-1 plot candidates with `fetched_at` and a map of limit key to nullable Line. Line has exactly `start_at`, `start_percent`, `end_at`, `end_percent`; its start equals the published snapshot. A will-hit line ends at 100% before reset; a safe line ends at reset. Swift validates and renders these points without extrapolating the rate.

Current eligibility is ordered: disabled; clock skew/stale; unknown Codex identity; missing duration/reset; expired reset; raw idle/collecting/hit; missing matching sample; expired prediction; unavailable endpoints; invalid projection. A snapshot is fresh only when ok, fetched, no more than 900 seconds old and no more than 60 seconds in the future. Invalid plot/schema/start/window data is a storage error; legacy `{}`, null or a missing candidate means endpoints unavailable until the next poll. A past prediction says it needs an update.

The aggregate CLI always includes `projection.line: Line|null`; drawable is true exactly when line is present. Legacy Claude JSON keeps its three-field projection. A source restriction (`ordinaryUsageAllowed:false`) overrides the overall availability message.

## Desktop and menu

The app-wide center independently reads each provider every 30 seconds; DB read failures are explicit. Its observed clock advances on this existing poll, so stale labels/cards invalidate even when rows are unchanged. Stop/generation guards discard late reads, and successful Feature Manager loads update the actual common feature state.

Plans uses two columns from 800pt, one column below it. Weekly/5-hour selection uses real durations; an absent selected window is explained rather than substituted. Charts show current history as solid and eligible Go Line as dashed, with Now/Reset/hit markers. Details retain additional quotas and Claude surface breakdown. Copy lives in pure presentation models.

The existing `planUsage.showInMenuBar` toggle/default controls both provider counters. Names/order are Claude then Codex. Claude retains its 5h/7d counters; Codex shows one most restrictive quota across every bucket: reached limit first, otherwise the nearest eligible hit, otherwise highest percent, with stable-key ties. Its duration is real. Fresh unknown-identity numbers may participate without forecast; stale/unconfirmed Codex numbers and warnings are hidden.

The popup keeps each provider's loading/error/empty/busy state, all current quota rows and independent refresh/retry actions. Quota/navigation actions open Plans. Claude notifications retain the existing once-per-kind/window ledger, pause handling and navigation route; Codex adds no system notifications. The persisted tab raw value remains `Claude plan`, displayed as **Plans**.

## CLI

- `watchtower usage plan [--json] [--now]`: legacy Claude-only command and JSON shape are unchanged.
- `watchtower usage plans --json [--now] [--provider all|claude|codex]`: schema-1 envelope, selected providers in Claude→Codex order, arrays always present. The local provider flag selects subscriptions, independently of the configured AI backend.
- Without `--now`, and for refresh while off, an existing read-only DB handle performs no migration, DB creation, source call or status/sample write. No row is a successful null status; read failure is an operation storage error.
- Provider `ok` describes the operation, not subscription health. Results include safe operation error, refresh outcome and nullable status; partial results wait for both providers and are never fail-fast.
- Exit 0: operations succeeded; 1: source/read/busy/deadline failure; 2: invalid arguments before command I/O, stderr only; 3: refresh while feature off; 130/143: best-effort partial JSON after SIGINT/SIGTERM. Priority is signal → disabled refresh → failure → success.
- Raw ids, hashed scope, email and credentials are absent from the public envelope.

## Validation and references

Production catalog: [58 PNGs / 29 states](../design/shots/plans/index.html). Approved references: [Plans and menu mockups](../design/mockups/plans/index.html). The archived renderer reproduces the 40 approved PNGs without using the production snapshot fixtures.

`pipeline_fixture_test.go` drives synthetic raw RPC responses through the real reader, atomic store and public envelope. Its shared DB/sample fixture is replayed by Swift production queries and Plans presentation/render tests, including foreign-scope, reset and unpublished-sample noise.

No iPhone plan slice or subscription spend estimate is added. API call/token/cost accounting stays on Watchtower's usage tab. PLANUSAGE-01..03, LLMUSAGE-01 and PROJ-* guards remain load-bearing.
