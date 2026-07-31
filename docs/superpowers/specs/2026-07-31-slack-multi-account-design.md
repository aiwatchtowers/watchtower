# Slack Multi-Account — Design

**Date:** 2026-07-31
**Branch:** `feature/multi-account` (parallel worktree, per the initiative plan)
**Status:** proposed

Sub-project 2 of 3 of the multi-account initiative (Google → Slack → Jira). Reuses
the conventions established by sub-project 1 (`docs/superpowers/specs/2026-07-30-google-multi-account-design.md`,
PR #48): account rows instead of singleton token state, per-account token files,
namespaced ids, daemon syncer fan-out slices, non-destructive-by-default removal
where the domain calls for it.

## Goal

Allow connecting **N Slack organizations** to one workspace, synced into the
single shared database, so the secretary sees everything as one context — one
dashboard, one inbox, one memory. Each account is connected via the normal
browser OAuth flow against the built-in Watchtower Slack app (confirmed to work
across all target workspaces — no custom-OAuth-client escape hatch needed,
unlike Google's org-restricted case).

The existing single-account install migrates in place: current Slack data
becomes account #1, nothing is lost, no re-sync required.

## Non-goals (v1)

- Cross-account message/channel dedup (the same person DMing you in two
  different Slack orgs stays two separate threads).
- Concurrent OAuth flows (one login at a time, as today).
- Per-account sync schedules (all enabled accounts sync in the same daemon
  phase).
- Hard/cascading deletion of downstream analysis products (digests, tracks,
  people cards, situations, memory) when an account is removed — see
  "Removal semantics" below; this is a deliberate departure from the Google
  precedent, not an oversight.

## Existing model this replaces

Today `watchtower auth login` already supports logging into different Slack
orgs, but through the pre-existing `active_workspace` mechanism
(`internal/config/config.go`): each login creates a **fully separate**
Watchtower instance (own DB, own directory, own secretary context) keyed by a
sanitized team name. That mechanism is unrelated to this design and is left
untouched for its original use case (running fully isolated Watchtower
profiles). It must not be confused with the per-account-in-one-DB model below.

## Data model (one goose migration, number reserved after the Google migration)

New table `slack_accounts` — the Slack analog of `google_accounts`:

| column | notes |
|---|---|
| `id INTEGER PRIMARY KEY AUTOINCREMENT` | account discriminator; also the namespace prefix used in every Slack-derived id |
| `team_id TEXT NOT NULL DEFAULT ''` | Slack team_id, from `auth.test` |
| `team_name TEXT NOT NULL DEFAULT ''` | organization display name |
| `team_domain TEXT NOT NULL DEFAULT ''` | needed to build permalinks (`https://<domain>.slack.com/archives/...`) |
| `label TEXT NOT NULL DEFAULT ''` | user-visible name, defaults to `team_name`, editable in Desktop |
| `current_user_id TEXT NOT NULL DEFAULT ''` | **namespaced** id of the token owner in this account (`"<id>:U0123..."`) — drives own-message suppression |
| `status TEXT NOT NULL DEFAULT 'ok'` + `error TEXT` | last sync outcome, mirrors `google_accounts` |
| `enabled INTEGER NOT NULL DEFAULT 1` | soft on/off switch — disabled accounts are skipped by sync, all synced data stays queryable |
| `search_last_date TEXT NOT NULL DEFAULT ''` | per-account search-sync watermark (moved off the `workspace` singleton) |
| `created_at` | |

### ID scoping: namespaced strings, not a composite PK

Slack channel/user ids are generated independently per organization and are
not guaranteed globally unique, so cross-account collision must be closed
structurally. Two approaches were weighed:

- **Composite PK `(account_id, id)`** (the literal `gmail_messages` pattern) —
  relationally clean, but `channel_id`/`user_id` are threaded through nearly
  every package (digest, tracks, people, memory, inbox, MCP tools,
  permalinks, feedback, chat) as bare unique strings. Adding an `account_id`
  parameter to all of that is a large, regression-prone rewrite.
- **Namespaced string ids** (chosen) — reuse the `gmail:<acct>:<thread>` /
  `imap:<acct>:...` precedent already used for inbox channel ids and memory
  provenance schemes. `channels.id` and `users.id` store `"<accountID>:<rawSlackID>"`;
  `messages.channel_id`/`messages.user_id` reference the same namespaced
  strings. Column types are unchanged (`TEXT PRIMARY KEY`). Every downstream
  query that treats these columns as opaque unique strings keeps working
  without modification — only code that talks to the *live* Slack API or
  renders a cross-account-ambiguous value needs to resolve the account (see
  "Sync, inbox & pipelines" below).

A new helper `slack.SplitAccountID(id string) (accountID int, rawID string)`
is the single unpacking point: every Slack API call uses `rawID`; every
UI/attribution surface uses `accountID` to look up the owning account's label.

### Changed tables

- `channels.id`, `users.id`, `messages.channel_id`, `messages.user_id` — now
  namespaced strings as above.
- Everything that references these columns (digest tables, `tracks`,
  `situations`/`situation_signals`, `feedback`, `channel_settings`,
  `jira_slack_links`, memory provenance `""`-scheme refs, MCP
  `list_messages`) needs no signature change — it inherits account-scoping
  for free because the referenced ids are already namespaced.

### `workspace` singleton

`workspace.id/name/domain` today literally hold one organization's
`team_id`/`team_name`/`team_domain` — meaningless with N accounts.
`current_user_id` and `search_last_date` move to `slack_accounts` (they are
per-account by nature; every existing read of them is a `LIMIT 1` — nothing
keys off `workspace.id`, confirmed by grep). `id/name/domain/synced_at`
remain as a frozen legacy snapshot of account #1 — harmless, since nothing
reads them by key — but call sites that use `ws.Domain`/`ws.Name`/`ws.ID` for
AI-facing rendering (`ai.BuildSystemPrompt`, `ai.NewResponseRenderer` in
`internal/ai/context_builder.go`, `internal/repl/repl.go`, `cmd/ask.go`,
`cmd/root.go`, `cmd/status.go`) must become multi-account aware: resolve
domain/team_id per message from its `channel_id` prefix, and list *all*
connected accounts in the system prompt rather than one. `permalink.go`
itself needs no change — `GeneratePermalink`/`GenerateDeeplink` already take
`domain`/`teamID` as plain arguments; only callers change what they pass.

### Migration of existing data

The goose migration seeds `slack_accounts` #1 from the current `workspace`
row (`team_id`→`team_id`, etc., `current_user_id`, `search_last_date`), then
rewrites `channels.id`/`users.id`/`messages.channel_id`/`messages.user_id`
and every dependent id reference (digest/tracks/situations/feedback/
`channel_settings`/`jira_slack_links`/memory-provenance) to the `"1:"`
prefix. As always: mirror into `internal/db/schema.sql`, extend
`TestAllTablesExist`, regenerate the schema golden, and mirror into the Swift
`TestDatabase.swift` schema.

## Credentials & token storage

Token per account: `<ws>/slack_token_<id>.json`. This is a deliberate
departure from today's single-account model, which embeds the token directly
in `config.yaml` (`workspaces.<team>.slack_token`) — moving to a file
matches the convention `google_token_<id>.json` established, keeps secrets
out of the human-edited config file, and avoids the token being unreadable
whenever `active_workspace` doesn't happen to equal the team that owns it.
The existing single-account token is moved to `slack_token_1.json` as part
of the account-#1 seed.

## Auth & login flow

- The existing browser OAuth implementation (`auth.Login`/`auth.Prepare`/
  `auth.Complete` against the built-in Watchtower Slack app) is reused
  unchanged internally. What changes is the save path.
- `watchtower slack add [--label L] [--no-open] [--app-return]` — runs OAuth,
  creates the `slack_accounts` row, writes the token file, fills
  `team_id`/`team_name`/`team_domain` from `auth.test`, sets
  `current_user_id`.
- `watchtower slack login --account <id>` — re-consent for an existing
  account (revoked grant, expired token).
- `watchtower slack accounts` — list accounts (label, team, status, enabled).
- `watchtower slack disable <id>` / `watchtower slack enable <id>` — soft
  on/off: sync skips a disabled account; all previously synced data and every
  downstream product built from it stay queryable.
- `watchtower slack remove <id>` — **non-destructive**, the key departure
  from the Google precedent (`google remove` cascades a full delete).
  Deletes the token file and sets `status='removed'`, `enabled=0`. The
  `slack_accounts` row itself is **not** hard-deleted — it stays as the
  label/domain lookup for historical permalinks and account attribution.
  `channels`/`messages`/digests/tracks/situations/memory for that account are
  left untouched.
- `watchtower auth login`/`auth logout` become thin legacy aliases operating
  on account #1 (created if absent), matching the `google login` alias
  pattern.

## Sync, daemon fan-out, inbox & pipelines

- `wireSlackSyncers` replaces the single `slackClient :=
  watchtowerslack.NewClient(ws.SlackToken)` construction in `cmd/sync.go`:
  iterates `ListSlackAccounts` (enabled only), builds one `slack.Client` +
  syncer per account from its token file, tags every synced row with that
  account's namespace prefix. One account's auth failure sets only its own
  `status`/`error`; the others keep syncing (the `wireImapSyncers` fan-out
  pattern). Zero-accounts is a clean no-op.
- **Inbox namespacing is inherited for free.** Unlike Gmail, where
  `channel_id = "gmail:<acct>:<thread>"` had to be constructed specially for
  the inbox, Slack inbox items reference `messages.channel_id` directly —
  already namespaced by the data model above.
- **Own-message suppression is a direct string comparison, no parsing
  needed**: `messages.user_id` and `slack_accounts.current_user_id` are both
  stored in the same `"<acct>:<Uxxx>"` form, so
  `message.user_id == account.current_user_id` works as-is.
- **Memory provenance** (the message-scheme resolver in
  `internal/memory/provenance.go`, MEM-12) is keyed on `channel_id`+`ts`, so
  it inherits account-scoping automatically — no registry change needed.
- What genuinely needs code changes: anything that calls back into the live
  Slack API (needs `slack.SplitAccountID` + the owning account's client) or
  renders a cross-account-ambiguous value (permalink callers, AI system
  prompt / response renderer, per "workspace singleton" above). Pure DB read
  paths (digest, tracks, people, MCP tools) need no change.
- **UI attribution**: inbox rows / situation sources show the account label,
  resolved from the `channel_id` prefix — the same contract as the Gmail
  design.

## Desktop UI

Settings → Slack is greenfield: today's Slack login happens once at
first-run/CLI setup with no account-management screen (unlike Google, which
already had a "Connect Google" block to replace). New: an account list
(`SlackAccountsViewModel` + `SlackAccountQueries` GRDB, mirroring
`EmailAccountsViewModel`/`GoogleAccountQueries`) — row = label/team + status +
Enable/Disable toggle + Remove; "Add Slack Account" sheet (optional label
field) triggers `watchtower slack add --app-return` through the same in-app
WKWebView OAuth flow Google/Gmail already use (`auth prepare`/`auth complete
--code --redirect-uri`, unchanged).

## Testing

- Migration: single-account DB → account #1 seeded from `workspace`, every
  `channels.id`/`users.id`/`messages.channel_id`/`messages.user_id` and
  dependent reference rewritten with the `"1:"` prefix, token moved to
  `slack_token_1.json`.
- Fan-out: two accounts, account A's auth failure marks only A's `status`
  and B still syncs; zero-accounts case exits clean.
- Own-message suppression with two accounts: each account's messages
  suppressed only by its own `current_user_id`.
- Permalink / system-prompt rendering resolves the correct account's
  domain/team_id per message, verified with channels from two different
  accounts appearing in the same digest/AI response.
- Removal: `slack remove` deletes the token file and flips status, but
  `channels`/`messages`/digests/tracks/memory for that account are still
  present and queryable afterward — proves the non-destructive contract.
- Schema: `TestAllTablesExist`, schema golden regen, Swift
  `TestDatabase.swift` mirror.

## Rollout

Land as a PR chain into `feature/multi-account` (parallel worktree, per the
initiative plan), migration number reserved ahead of Jira's (sub-project 3).
Final merge to `main` after the owner verifies live: connect a second real
Slack workspace, confirm both sync, show up correctly attributed in the
dashboard/inbox, and a shared AI response (digest/chat) renders permalinks
for both correctly.
