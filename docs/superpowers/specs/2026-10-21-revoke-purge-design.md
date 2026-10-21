# Revoked access wipes the account's data — design (board #601)

Part of board group #595 (corporate data on the Mac). Status: approved by the
owner 2026-10-21 (ask #474) with the recommended answer to every question:
Q1 on in the corp build and under MDM, opt-in elsewhere; Q2 (a); Q3 72 h;
Q4 30 days → purge with the same notice. The LINEAR-03 amendment in §6 is
approved with it. Plan approved 2026-10-21 (ask #477) with two decisions:
the lease counts disabled (not removed) accounts, and removed accounts are
covered by the lease too (§2).

## Goal

When a person leaves a company, the company revokes their Slack, Google and
Atlassian tokens. Today Watchtower notices the revocation (the account turns
`revoked`, the backfill pauses) and keeps every synced row for ever. After this
change the data of a revoked account deletes itself, and an install that has not
reached any company source for a long time does the same, so the database left
on a former employee's Mac stops holding the company's correspondence.

Out of scope here: encryption and destroying the database key (#602/#603 — once
they land, "purge" also drops the account's part of the key material, see
"Later"), MDM policy (#608), IMAP (no revocation signal; see "Sources").

## What exists today

- Revocation is classified only from typed signals — the token endpoint's
  `invalid_grant`, a 401 that persists after a successful refresh, Slack
  `invalid_auth`/`account_inactive`/`token_revoked`/`not_authed`. A network
  error never becomes `revoked` (Jira/Linear write nothing on it; Slack/Google
  write `error`). Stored in `<source>_accounts.status`.
- No account has a "last confirmed access" time or a revocation time.
- Purge code: `ClearGmailData` + `DeleteGoogleAccount` (per account, used by
  `google remove`); `db.ClearSlackData` (whole Slack dataset, one transaction,
  not called anywhere). Slack/Jira/Linear `remove` are soft by contract
  (SLACK-01, LINEAR-03).
- Derived tables carry no account column; attribution is by the
  `<account>:<id>` namespace (Slack), the `gmail:<id>:` prefix, or `account_id`
  on raw tables.

## Design

### 1. Two new per-account facts (migration)

On `slack_accounts`, `google_accounts`, `jira_accounts`, `linear_accounts`:

- `access_ok_at` — the last time an authenticated call to the source succeeded.
  Written by the sync phases after a successful fetch (one `UPDATE` per account
  per cycle, outside any big transaction). It never changes `status`, so the
  LINEAR-03 rule "a nil error never writes a blanket ok" stays intact.
- `revoked_at` — set when `status` turns `revoked`, cleared by a successful
  login/reconnect (the existing paths that write `ok`).

Plus one table `account_purges(source, account_id, reason, due_at, state,
started_at, finished_at, error)` — the purge ledger, one row per scheduled
purge, `state` = `scheduled|running|done|cancelled`.

### 2. When a purge is scheduled

- **Revoked:** an account `revoked` continuously for the grace period (**Q3**,
  proposed 72 h) **and** still `revoked` on the latest sync attempt. A reconnect
  inside the grace period cancels the row. The grace period protects against
  one-off provider glitches and against an owner who simply changed a password
  (Google revokes Gmail-scope tokens on a password change).
- **Lease (offline):** no account of a source has a fresh `access_ok_at` for
  **N** days (**Q4**, proposed 30). Time without a network connection counts —
  that is the point of a lease. The same grace notice applies before it fires.
  A disabled (not removed) account counts as a live account of its source
  (owner decision 2026-10-21, ask #477).
- **Removed accounts (lease):** a `removed` account whose `access_ok_at` is
  older than 30 days gets the same scheduled purge and notice, due 72 h after
  scheduling (owner decision 2026-10-21, ask #477). `remove` itself stays soft
  and SLACK-01 is unchanged: the remove keeps the data; only this later lease
  purge deletes it, and only while the purge is on.

Scheduling runs as a cheap check at the start of each daemon cycle
(`phaseAccountPurge`), reading the account rows only.

### 3. What a purge deletes (Q2)

Proposed scope — everything that is attributable to the account without AI:

- Raw rows of the account: Slack `messages` / `reactions` / `files` / `users` /
  `channels` / `sync_state` / watch list / channel settings / checkpoints in the
  account's namespace; `gmail_messages`, calendar events and calendars
  (`purgeGoogleAccountCalendarsTx` rules: events linked to a transcript or
  recap keep only their link row); `jira_*` and the account's Confluence
  `ext_*` rows; `linear_*`.
- Inbox items, situations and learned rules keyed to the account.
- Knowledge index documents of those rows (through the existing `kb_dirty`
  triggers) and FTS rows (existing triggers).
- Slack digests, tracks and people cards whose every channel/user belongs to
  the account; cross-account ones are kept.
- Token files and the account row's credentials. The account row itself stays,
  as `status = 'purged'`, so history (permalinks, labels) does not break and the
  owner sees what happened.

Kept in v1: briefings, catch-up recaps, ideas/decisions, memory notes, chats,
automation outputs, meeting transcripts — AI-written text that mixes sources.
Option **Q2-c** would add memory facts whose every provenance row points at the
account.

Deletes run in chunks (≤ 500 rows per transaction, the heaviest tables first,
resumable from the ledger), so no write transaction holds the lock for long —
hooks give up after 500 ms / 1 s.

### 4. What the owner sees

- From the moment a purge is scheduled: a red line on the account in
  Settings → Connections and on Home: "Access to <account> was revoked. Its data
  will be deleted on <date> unless you reconnect." with **Reconnect**.
- A macOS notification once when scheduled and once when done.
- `watchtower accounts purges [--json]` lists the ledger; no command to make a
  purge sooner or to export before it.

There is no "keep my data" button — that would defeat the purpose. The way to
keep it is to restore access.

### 5. Who has it on (Q1)

Proposed: on by default in the corporate build and wherever an MDM policy
(#608) turns it on; elsewhere an opt-in switch in Settings → Privacy, default
off. A personal install that loses a token (a password change, an expired
test-mode grant) must not lose its history silently. The corporate build today
differs only by its OAuth client ids (`Makefile`, `scripts/build-app.sh`); "on in
the corp build" means one more build-time default next to them.

### 6. Contracts that change

- **LINEAR-03** ("auth loss … never deletes data") — amended: when the purge is
  on, a revoked account is purged after the grace period. Guard tests keep
  covering the "off" path and gain a "scheduled → cancelled by reconnect" case.
- **SLACK-01** — unchanged: `slack remove` stays soft. Revocation is not
  removal.
- New inventory entry `PURGE-01..02` (schedule/cancel rules; chunked delete +
  ledger).

## Questions for the owner

- **Q1. Who has it on** — corp build + MDM only, opt-in elsewhere
  (recommended); on for everyone; opt-in for everyone.
- **Q2. Scope** — (a) raw + inbox + KB + attributable digests/tracks/people
  cards, AI text kept (recommended); (b) raw rows only; (c) (a) plus memory facts
  sourced only from the account.
- **Q3. Grace period** — 72 h (recommended); 24 h; 7 days.
- **Q4. Lease** — 30 days without confirmed access → purge with the same notice
  (recommended); only hide the data until reconnect (a real lock needs #603);
  no lease in v1.

## Later

- With #603 (encrypted DB, key bound to the Mac) the lease can lock instead of
  delete: the key is released only while the lease is fresh.
- IMAP has no revocation signal; a lease on IMAP corp accounts can come with
  #608 (a policy marks which mail accounts are corporate).
