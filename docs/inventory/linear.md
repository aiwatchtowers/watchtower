# Behavior Inventory — Linear connector

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/linear/`,
> `internal/db/linear.go`, `internal/db/linear_accounts.go`,
> `internal/db/linear_users.go`, `internal/db/migrations/00116_linear_tables.sql`,
> `internal/db/migrations/00117_tracker_views.sql`, `cmd/linear.go`, or
> `phaseLinearSync` in `internal/daemon/daemon.go`, read this file first.
> Any proposed change that would break a guard test or remove a contract
> must be raised as a question before touching code.

**Module:** `internal/linear/` (OAuth, GraphQL client, syncer), `internal/db/linear*.go`, migrations 00116 (`linear_*` tables) and 00117 (`tracker_*` views), `cmd/linear.go`, `internal/daemon/daemon.go` (`phaseLinearSync`). Feature note: `docs/features/linear.md`. The Linear rung of OWNER-01 is documented in [owner-identity.md](owner-identity.md); not repeated here.
**Last full audit:** 2026-10-15

## LINEAR-01 — The watermark is honest

**Status:** Enforced

**Observable:** A team's incremental sync position advances only when every page of that team's issues and comments, and its planning (cycles and projects), was fetched and stored. A failed pass is retried from the same point, so no issue or comment is skipped.

**Mechanism:** `linear_sync_state` holds one watermark per `(account, team)`. The syncer queries issues and comments with `updatedAt gte since` (`gte`, not `gt`, so rows sharing the boundary timestamp are re-read, never lost; upserts are idempotent). The watermark is written only after the issue pass, the comment pass and the planning pass (cycles, projects) of the team all returned without error; a page error leaves the stored watermark untouched and records the error (`db` keeps the watermark when an error is stored). The new watermark is the maximum **issue** `updatedAt` seen; comments are queried with the same `since` but never raise it. A team pass that succeeds and sees nothing records the `since` it queried with as the watermark (so a quiet team does not re-scan the whole backfill window each cycle, and the value is never invented from the clock).

**Why locked:** Advancing the watermark past a failed page silently drops issues forever (the next pass starts after them); letting comment timestamps or the wall clock move it can skip issues that were updated between the query and the write.

**Test guards:**
- `internal/linear/syncer_test.go`: `TestLinear01_PageErrorHoldsWatermark`, `TestLinear01_CommentFailureHoldsWatermark`, `TestLinear01_PlanningFailureHoldsWatermark`, `TestLinear01_QuietTeamRecordsSinceAsWatermark`, `TestLinear01_CommentsDoNotRaiseWatermark`.
- `internal/db/linear_accounts_test.go`: `TestLinear01_ErrorKeepsWatermark`.

**Locked since:** 2026-10-15

## LINEAR-02 — The rotated token pair is saved before use, single-flight

**Status:** Enforced

**Observable:** After a token refresh the new access and refresh tokens are on disk before any request uses them, and concurrent requests that hit an expired token trigger exactly one refresh. The user is never signed out of Linear by a lost or doubled rotation.

**Mechanism:** Linear rotates the refresh token on every refresh, so the old one is dead the moment the server answers. `Client` refreshes under a two-part single-flight guard: `Client.mu` serializes the goroutines of one process, and the per-account file lock (`<token file>.lock`, `TokenStore.Lock`) serializes processes (the daemon and a CLI command). Under both, the token is re-read before refreshing: an expired token that another holder already refreshed, or a 401 on an access token that is no longer the stored one, reuses the stored pair instead of spending the refresh token again. Token and revoke requests time out after 30 s, so a stalled endpoint never holds the lock indefinitely. The token store (`<workspace>/linear_token_<accountID>.json`) is saved with the rotated pair before the retried request is sent; if the response omits a new refresh token the old one is kept. A second 401 after a refresh is `ErrAuthRevoked`; `invalid_grant` on refresh is revoked, a server error is not.

**Why locked:** A refresh that is not persisted before use, or two parallel refreshes that each burn the same refresh token, leave the account with a dead token pair and force a manual re-login.

**Test guards:**
- `internal/linear/client_test.go`: `TestLinear02_RefreshSavesRotatedPair`, `TestLinear02_ConcurrentRefreshSingleFlight` (one client, `Client.mu`), `TestLinear02_TwoClientsOneStoreSingleRefresh` (two clients on one token file — the file lock; both the 401 and the expired-token paths).

**Locked since:** 2026-10-15

## LINEAR-03 — Auth loss marks the account revoked and never deletes data

**Status:** Enforced

**Observable:** When Linear rejects the grant, the account shows status `revoked` (Re-login) and keeps all its synced data. Removing a workspace deletes the token and disables the account but keeps every `linear_*` row.

**Mechanism:** `phaseLinearSync` persists exactly one failure, `linear.ErrAuthRevoked`, via `SetLinearAccountAuthState(id, "revoked", msg)`; rate-limit and network errors are only logged, a cancelled context is checked first and leaves auth state untouched, and a nil error never writes a blanket "ok" (only a login clears the state). `linear remove` is a soft delete (status `removed`, token file deleted under the token lock, rows kept); `linear add` for a workspace whose org belongs to a **removed** account revives that account (same id, data kept), a non-removed match is refused, any failure after the account row is created cleans that row up, and `linear login` refuses a login into a different workspace than the account's.

**Why locked:** Deleting synced data on auth loss or removal destroys history the owner cannot re-fetch cheaply, and writing "ok" over a revoked state hides the Re-login prompt.

**Test guards:**
- `internal/daemon/linear_sync_test.go`: `TestLinear03_RevokedMarksAccount`, `TestLinear03_CancelledContextLeavesAuthState` (a cancelled context wins over a wrapped `ErrAuthRevoked`).
- `internal/db/linear_accounts_test.go`: `TestLinear03_AccountLifecycleSoftDelete` (also asserts the account's issue and comment rows survive remove).

**Locked since:** 2026-10-15

## LINEAR-04 — Issues are keyed by UUID and keys move

**Status:** Enforced

**Observable:** An issue moved to another team (its `ENG-12` becomes `OPS-40`) stays one row with the new key; its comments and history in `tracker_comments`/`tracker_history` show the new key, with no duplicate under the old key. This holds when the issue moves to a team that is not selected for sync too: the row follows it there and keeps refreshing (amended 2026-10-16, ask #182).

**Mechanism:** `linear_issues` is keyed `(account_id, id)` with the Linear UUID; `key` (`identifier`) is a mutable column. The syncer upserts by UUID `(account_id, id)`, so a team move updates the existing row in place; `previousIdentifiers` is stored as `previous_keys` and is only used by `GetLinearIssueByKey` to find an issue by an old key. `linear_comments.issue_key` is stamped at comment sync, so `tracker_comments` derives the current key from `linear_issues` by `issue_id` (falling back to the stamped key), and `tracker_history` does the same. An issue moved out of every selected team matches no team filter, so each pass (once a selected team has a watermark) lists the issues changed outside the selected teams since the account's `moved_watermark` (`id` only; the cursor advances to the oldest selected team watermark only after a successful reconcile, so a failed one is retried from the same point), keeps the ids the account already stores (`KnownLinearIssueIDs`) and refetches those issues and their comments by id; unselected-team issues never stored are not fetched. Slack ids already resolved on the row are preserved across upserts; an assignee or creator change resets the matching Slack id.

**Why locked:** Keying by the human identifier forks one issue into two rows on every team move and orphans its comments and history.

**Test guards:**
- `internal/linear/syncer_test.go`: `TestLinear04_TeamMoveKeepsOneRow`, `TestLinear04_MoveToUnselectedTeamIsReconciled`.
- `internal/db/tracker_test.go`: `TestLinear04_TrackerCommentsFollowTeamMove`.

**Locked since:** 2026-10-15
