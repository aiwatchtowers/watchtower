# Mobile: read-only connected-accounts status in Settings

Workstream 2 of the 2026-08-17 mobile reanimation plan (items 7-8).

## Goal

The phone shows which external accounts the desktop has connected (Slack
workspaces, Google accounts, Jira sites) and their health — read-only.
OAuth flows cannot run on the phone, so there are no connect/manage
actions; the desktop stays the only writer.

## Wire format (FROZEN)

Three new DataZone slice kinds, one record per account row, published by
`SlicePublisher` as PROJECTIONS (never `SELECT *` — the account tables also
carry sync watermarks and, schema-wise, sit next to token state that must
never reach the wire). Exact published column sets:

| kind             | columns                                                            |
|------------------|--------------------------------------------------------------------|
| `slack_account`  | `id, team_name, team_domain, label, status, error, enabled`        |
| `google_account` | `id, email, label, status, error, calendar_enabled, gmail_enabled` |
| `jira_account`   | `id, site_name, site_url, label, status, error, enabled`           |

- NO tokens, NO secrets, nothing credential-shaped. `google_accounts.client_id`
  (non-secret OAuth client half) is still excluded — the phone has no use for
  it and nothing credential-adjacent goes on the wire.
- Slack/Jira rows with `status = 'removed'` are excluded from the slice
  window (the Go side's `ListEnabled*Accounts` and the desktop's
  `JiraAccountQueries.fetchAll` treat removed rows as tombstones), so a
  removed account falls out of the window and the diff deletes it from the
  phone. `google_accounts` has no `removed` status (rows are deleted).
- Status vocabulary (from schema): `ok | error | revoked` (+ `removed`,
  filtered out for slack/jira). Google has no per-account `enabled` toggle;
  its participation flags are `calendar_enabled` / `gmail_enabled`.

## Kit model

`ConnectedAccount` (WatchtowerKit/Models): one `FetchableRecord` struct
decoding all three kinds — the identity columns are disjoint
(`team_name`/`email`/`site_name`), everything else is shared. Fields absent
from a kind's payload read their defaults (`''`, `enabled = true`,
`*_enabled = false`). Presentation helpers mirror the desktop models:
`displayName` = label, else first non-empty identity, else `Account #<id>`;
`isOK` (`status == "ok"`), `isRevoked` (`status == "revoked"`).

## Phone UI

Settings gains a "Connected accounts" section:

- Grouped by service (Slack / Google / Jira), one row per account:
  display name, secondary identity line (workspace domain / email / site
  URL) when it adds information, status dot + status text.
- Badge semantics mirror the desktop Connections tab:
  green = `ok`, red = `revoked`, orange = any other non-ok (`error`),
  gray = account disabled on the desktop (a disabled account's status is
  not actively verified — same neither-ok-nor-problem rule as
  `ConnectionStatusLogic.enabledFilteredStatus`).
- Non-ok rows show the `error` text (falling back to the raw status word).
- Read-only: no actions, no toggles, no deep links (deferred).
- The whole section is HIDDEN when no account slices exist in the replica —
  an older desktop that does not publish these kinds yet renders the
  Settings screen exactly as before.

## Invariants

- Desktop-writes-only DataZone discipline: the phone never enqueues any
  relay action for accounts.
- Wire format frozen by literal test fixtures (Kit) and an exact published
  column-set assertion (desktop projection test).
- `SliceKind` raw-value freeze list grows additively (append, never
  reorder) — sibling workstreams append their own cases at merge.
- Plan item 9 (account-scoped inbox badges with 2+ workspaces) is DEFERRED.

## Test plan

- Kit: `SliceKind` frozen raw-value list extended; literal JSON payload
  fixtures decode into `ConnectedAccount` for each kind; degenerate row
  (all-empty strings) decodes with fallback `displayName`.
- Desktop (`SlicePublisherTests`): per kind — published payload's column
  set equals the frozen list EXACTLY (secrets can never ride along
  unnoticed); removed slack/jira rows are not published and deletion
  reaches the transport when a row becomes removed; empty account tables
  publish nothing (degenerate path).
- Mobile: demo seed grows account records (counts pinned in
  `ReplicaWiringTests`); Settings view model surfaces grouped accounts;
  status-badge mapping unit-tested including disabled and unknown-status
  rows; empty replica → section hidden. Mobile target compiles via
  `make mobile-build` (the shared-simulator test target is not run here).
