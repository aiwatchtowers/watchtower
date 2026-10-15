# Behavior Inventory — Claude plan limits

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/planusage/`, `internal/db/plan_usage.go`,
> `cmd/usage_plan.go`, `cmd/plan_usage_daemon.go` or the Desktop `PlanUsage*` files,
> read this file first. Any proposed change that would break a guard test or remove
> a contract must be raised as a question before touching code.

**Module:** `internal/planusage/` + `internal/db/plan_usage.go` + `cmd/usage_plan.go` + `cmd/plan_usage_daemon.go` + Desktop `PlanUsage*`
**Last full audit:** 2026-10-15

## PLANUSAGE-01 — The token is never refreshed or written; an expired token sends no request

**Status:** Enforced

**Observable:** Watchtower reads the Claude Code OAuth credentials read-only. It never calls a refresh endpoint and never writes the Keychain item or `~/.claude/.credentials.json`, because a refresh rotates the refresh token and signs Claude Code out. When `expiresAt` is not in the future, the poller makes no HTTP request: status becomes `stale` / `token_expired` and the next poll re-reads the credentials.

**Why locked:** A silent refresh would log the owner out of Claude Code, a far worse outcome than a stale number.

**Test guards:**
- `internal/planusage/poller_test.go::TestPlanUsage01_ExpiredTokenMakesNoRequest`

**Locked since:** 2026-10-15

## PLANUSAGE-02 — The token never reaches the DB, logs or errors

**Status:** Enforced

**Observable:** The access token is read into memory, sent in one `Authorization` header and dropped. It is not written to any table (`plan_usage_status.last_error` included), not logged, not in any returned error, and not passed on argv (`security` prints it to our stdout pipe).

**Why locked:** The database and logs can end up in support bundles and other tools; a bearer token there is a credential leak.

**Test guards:**
- `internal/planusage/poller_test.go::TestPlanUsage02_TokenNeverPersisted`

**Locked since:** 2026-10-15

## PLANUSAGE-03 — At most one notification per kind per (limit, window)

**Status:** Enforced

**Observable:** The Desktop posts a `will` notice (projection `will_hit`) and a `p90` notice (percent at or above 90) at most once each per `(limit_key, resets_at)`. The dedupe key is `<kind>|<limit_key>|<resets_at ISO>`; a new window gives a new key. Keys are stored in `planUsage.sentNotices` and pruned once their window is past.

**Why locked:** The status row refreshes every few minutes; without the key, a limit sitting above 90 % would notify on every refresh.

**Test guards:**
- `WatchtowerDesktop/Tests/Core/PlanUsageNoticePolicyTests.swift::PlanUsageNoticePolicyTests.testPlanUsage03_OneNoticePerWindow`

**Locked since:** 2026-10-15

## Changelog

- 2026-10-15: file created with 3 contracts (PLANUSAGE-01..03), introduced by the Claude plan limits feature (spec `docs/superpowers/specs/2026-10-15-claude-plan-limits-design.md`).
