# Revoked access wipes the account's data (2026-10-21, board #601)

When a company revokes the owner's Slack, Google, Jira or Linear access, or an install has not reached a source for 30 days, and the purge is on, the account's synced data is deleted after a 72 h notice unless the owner reconnects first. Part of board group #595 (corporate data on the Mac). Spec: `docs/superpowers/specs/2026-10-21-revoke-purge-design.md` (approved 2026-10-21, ask #474: Q1 on in the corp build and under a future MDM policy, opt-in elsewhere; Q2 (a); Q3 72 h; Q4 30-day lease; the LINEAR-03 amendment). Plan: `docs/superpowers/plans/2026-10-21-revoke-purge.md` (ask #477: the lease counts disabled accounts, and removed accounts get a lease of their own). Contracts: PURGE-01..02 in `docs/inventory/account-purge.md`, LINEAR-03 amended in `docs/inventory/linear.md`; SLACK-01 unchanged. User guide: `docs/guide/concepts/revoked-access.md`.

## Schema (migration 00146)

- `access_ok_at`, `revoked_at` (TEXT, `''` = unset, RFC 3339 UTC) on `slack_accounts`, `google_accounts`, `jira_accounts`, `linear_accounts`. The migration stamps `access_ok_at` = now on every row (removed ones too) and `revoked_at` = now on revoked rows, so an upgrade never starts a clock in the past.
- `account_purges(id, source, account_id, reason revoked|lease, scheduled_at, due_at, state scheduled|running|done|cancelled, started_at, finished_at, rows_deleted, error)`, one open row per account (`idx_account_purges_open`). No foreign key: four parent tables, and the account row is never deleted.
- New `status` value `purged` (no CHECK on any of the four columns).

## Access facts

- `revoked_at` is kept by the `Set*AccountAuthState` writers themselves (`internal/db/account_access.go`): `revoked` sets it when empty (kept on a repeat), `ok` clears it, `error` keeps it. Every existing writer (sync phases, the `login` paths) is covered with no new call.
- `access_ok_at` is set by the same writers on `ok` (Slack and Google write `ok` after a clean sync). Jira and Linear passes never write `ok` (LINEAR-03), so the daemon calls `db.MarkAccountAccessOK(source, id)` after a nil `Sync` error; it touches `access_ok_at` only. A clean Confluence sync stamps its Jira account's access too: one Atlassian grant covers both, and an account used only for Confluence makes no Jira request.
- A `purged` row refuses every auth-state write except `ok` (`authStateWhereSQL`); that `ok` (a Re-login) re-enables Slack/Jira/Linear rows and starts the account over as a first sync. `MarkAccountAccessOK` leaves a purged row alone.

## The switch

`purge.Enabled(cfg)` returns the effective value and its origin, strongest first: a policy (`policy` seam, unset until #608) > the config key `privacy.purge_revoked_data` (tri-state `*bool`, absent = build default) > the build default `purge.BuildDefault` (ldflags from `WATCHTOWER_PURGE_DEFAULT`, which `Makefile` and `scripts/build-app.sh` pass next to the OAuth client ids; the corporate build profile sets `WATCHTOWER_PURGE_DEFAULT=on`) > off. The Desktop never re-implements it: it reads `enabled`/`enabled_by` from `watchtower accounts purges --json`, writes only the config key (Settings → System → Privacy, absent stays absent until the owner toggles), and restarts the daemon after a Save that changed it, since the daemon reads config only at startup.

## Scheduling (`phaseAccountPurge`, first phase of every cycle)

`purge.Plan(accounts, open, enabled, now)` reads the account rows and the open ledger rows only; `purge.Apply` writes its decision.

- **Off:** every scheduled row is cancelled; nothing is scheduled; a running row finishes.
- **Revoked:** a revoked account is scheduled due `max(revoked_at + 72 h, now + 72 h)`. Cancelled when the account is no longer revoked or in error. A due row runs only while the account is still `revoked`; `error` waits.
- **Lease (live accounts, status not removed/purged, disabled included):** when every live account of a source has an `access_ok_at` and the newest is older than 30 d − 72 h, each is scheduled due now + 72 h (on a daemon that runs every cycle, the 30-day mark). An empty `access_ok_at` is no evidence: that source is never lease-scheduled.
- **Lease (removed accounts):** a removed account whose own `access_ok_at` is older than 30 d is scheduled due now + 72 h. Removed accounts are not part of their source's live set.
- A lease row is cancelled when its account's deadline moves past the row's `due_at` (fresh access, or the account added back) and runs only once the deadline has passed.
- **Deviation from the plan text:** every due date is at least 72 h after the pass that schedules it, so the notice always shows for the full grace period (also when the purge is turned on for an account revoked long ago, or the daemon was off longer than the lease).

The daemon then keeps `purgeHold`: the sync phases skip accounts being or already purged, so a syncer wired at startup never refills one.

## Running a purge (`purge.Run`)

`db.PurgeSteps(source, id)` is an ordered list of idempotent statements (dependents before the rows their predicates read). `RunPurgeStep` deletes at most 500 rows of the step's driving table per transaction and is repeated until it affects nothing; `AddPurgeRows` counts them on the ledger. A cycle spends at most 5 minutes (`purgeCycleBudget`); an unfinished purge stays `running` and resumes from the top of its list next cycle. A failed chunk is recorded in `error` and retried. Token files are deleted after the steps, outside any transaction (Jira/Linear under their token lock); no remote revoke call is made. `FinishAccountPurge` then marks the ledger row `done` and the account row `purged` in one transaction.

### What each source deletes

- **Slack** (namespace `<id>:`): messages, reactions, files; inbox items of Slack trigger types and the situations whose every signal is such an item; learned rules scoped to its channels and senders; the account's channel digests (cross-channel digests have `channel_id ''` and stay) with their KB documents and feedback; tracks whose every channel is the account's; user analyses, people cards, `user_interactions`; `issue_slack_links`, reaction commands and events, reminders; `sync_state`, watch list, channel settings, user checkpoints, users, channels; KB documents under `slack:thread:<id>:` and `slack:day:<id>:` with their `kb_dirty` marks and `doc_links`; `history_backfill`.
- **Google:** `gmail_messages`; inbox items of its Gmail threads and of the calendar events it deletes; learned rules; `meeting_prep_cache` and KB documents of those events; calendar events and emptied calendars (`purgeGoogleAccountCalendarsTx` rules: events a transcript or recap references are kept, and their calendars are detached); Gmail stream digests and their KB documents; KB documents under the Gmail prefix; `history_backfill`.
- **Jira:** inbox items whose key is the account's issue and no other account's; every `jira_*` table with `account_id`; the account's Confluence `ext_comments`, `ext_documents`, their KB documents, marks and `doc_links`, and its `ext_sources` rows; Jira stream digests; KB documents under `jira:<id>:`; `history_backfill`.
- **Linear:** inbox items as for Jira; every `linear_*` table with `account_id`; Linear stream digests; KB documents under `linear:<id>:`.
- The account row is kept with `status = 'purged'`, `error` cleared, `enabled = 0` (Google: `gmail_enabled = calendar_enabled = 0`), and its sync watermarks reset (`purgedAccountSQL`), so a Re-login is a first sync.

Scope additions beyond the spec's list: stream digests and their KB documents, `doc_links`, `meeting_prep_cache` of deleted events, `user_interactions`, the Jira account's Confluence `ext_*` rows, and the watermark reset. Kept on purpose (`purgeKeptTables` in `internal/db/account_purge_steps_test.go`, enforced by `TestPurge02_EveryAccountTableCovered`): `imap_messages` (IMAP is not a purge source), `account_purges`, `jira_user_map`, `linear_user_map` (identity maps keyed by the provider's user id). AI text that mixes sources is kept: briefings, Catch-Up recaps, ideas and decisions, memory, chats, automation outputs, transcripts; so are digests and tracks spanning several accounts.

## CLI

`watchtower accounts purges [--json]` lists the ledger, newest first, every state. Text: a header `Purge on revoked access: on (build default)` and one line per row. `--json` (pinned by `TestAccountsPurgesJSONKeys`):

```json
{"enabled": true, "enabled_by": "policy|setting|build|default", "grace_hours": 72, "lease_days": 30,
 "purges": [{"id", "source", "account_id", "account_label", "reason", "state", "scheduled_at", "due_at",
             "started_at", "finished_at", "rows_deleted", "error"}]}
```

Times are RFC 3339 UTC, `""` when unset; `purges` is `[]`, never `null`; `account_label` is `""` when the account row is gone. There is no command to purge sooner or to export first.

## Desktop

- `WatchtowerCore`: `AccountPurge` + `AccountPurgeQueries.open/recent` (the ledger joined to the account, Go's label rule), `AccountPurgeNoticePolicy` (revoked, lease and removed-account lines, done line, purged line pointing to Re-login, once-per-row-per-state notices keyed `"<id>:scheduled"`/`"<id>:done"`), `AccountPurgeStatus` (the switch from the CLI), `isPurged` on the four account models.
- `AccountPurgeCenter` on `AppState`: a 30 s poll of the ledger (the daemon writes it from another process, so GRDB observation never fires), the notifications through `NotificationService.sendAccountPurgeNotice` (deduped in `UserDefaults` `accountPurges.noticesSent`, held back while notifications are paused; a click opens the source's connection), and the switch's state.
- The red line under each Slack, Google, Jira and Linear account in Settings → Connections (`AccountPurgeLine`); a purged account shows **Data deleted** (gray dot, the Enabled switch off) and the purged line. Home's `AccountPurgeBanner` above Getting ready, with **Reconnect** on scheduled rows (a running purge cannot be stopped).
- `linear add` for a purged workspace still says it is already connected; the copy points to Re-login.

## Later

- #603 (encrypted database, key bound to the Mac): the lease can lock instead of delete, and a purge also drops the account's part of the key material.
- #608 (MDM policy): feeds the `policy` seam in `internal/purge/enabled.go`; the Settings switch then shows "Set by your organisation" and is disabled. A policy may also mark IMAP accounts as corporate, which IMAP (no revocation signal) needs for a lease.
