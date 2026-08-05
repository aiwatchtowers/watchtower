# Jira Multi-Account — Design

**Date:** 2026-08-02
**Status:** implemented
**Sub-project:** 3 of 3 of the multi-account initiative (after Google, 2026-07-30, and Slack, 2026-07-31)

## Problem

Watchtower supported exactly one Jira Cloud site per workspace: the site
identity lived in config.yaml (`jira.cloud_id` / `site_url` /
`user_display_name`), the OAuth token in a single `jira_token.json`, and every
`jira_*` table was keyed by raw Jira ids (`jira_issues.key`, `jira_boards.id`,
`jira_sync_state.project_key`) that collide across Atlassian sites. A user
with two sites (e.g. employer + client) could connect only one.

## Decision summary

One `jira_accounts` row per connected Atlassian site (migration **00049** —
the number both earlier specs reserved for this sub-project), with the
site-scoped tables re-keyed by a composite PK.

### Identity strategy: composite PK, not namespaced strings

The two precedents diverge, and Jira follows **Google's composite-PK route**
(`gmail_messages (account_id, id)`), not Slack's namespaced strings
(`"1:C0123"`):

- Jira issue keys (`PROJ-123`) are **user-visible** and flow through regexes
  (the key detector, `cmd/digest.go`, Swift `JiraKeyExtractor` — three copies
  of the same pattern), AI prompts (`"jira:PROJ-123"` in targets schemas),
  `targets.source_id`, memory `jira:<KEY>` provenance refs, and MCP tool
  arguments. Prefixing them `"1:PROJ-123"` would break every one of those
  surfaces at once.
- Board ids are small integers — collision across two sites is effectively
  guaranteed, so leaving PKs unscoped was not an option.

Composite PKs re-key the tables while **bare-key readers keep their
signatures**: `GetJiraIssueByKey("PROJ-123")` still works, returning the first
match. A key shared by two sites is a **documented v1 ambiguity** (the
`mail:<message_id>` / `gmailthread:` account-unscoped precedent from the
Google spec). Only writers (driven by the per-account syncer) and
board/sprint-scoped readers gained an `accountID` parameter.

### Schema (migration 00049)

- **`jira_accounts`**: `id`, `cloud_id`, `site_url`, `site_name`, `label`,
  `status` (`ok|error|revoked|removed`), `error`, `enabled`,
  `memory_jira_last_extracted_ts` (moved off `workspace`), `created_at`.
- **Re-keyed with `account_id INTEGER NOT NULL REFERENCES jira_accounts(id)
  ON DELETE CASCADE`** (table-recreation dance, `-- +goose NO TRANSACTION` +
  `PRAGMA foreign_keys = OFF`, the 00043 shape): `jira_boards (account_id,
  id)`, `jira_custom_fields (account_id, id)`, `jira_board_field_map
  (account_id, board_id, field_id)`, `jira_issues (account_id, key)`,
  `jira_sprints (account_id, id)`, `jira_issue_links (account_id, id)`,
  `jira_sync_state (account_id, project_key)` — two sites sharing a project
  key no longer clobber each other's watermark — and `jira_releases
  (account_id, id)` + `UNIQUE(account_id, project_key, name)`.
- **Deliberately NOT account-scoped**: `jira_user_map` (Atlassian account ids
  are globally unique) and `jira_slack_links` (keys detected in Slack text are
  site-ambiguous by nature).
- **Seed**: account #1 is minted when legacy Jira data exists (`jira_boards`
  or `jira_issues` non-empty, or the workspace watermark > 0), carrying the
  watermark; `cloud_id`/`site_url` stay empty for Go to fill (SQL can't see
  config.yaml). Fresh DBs get no seed row. The seed INSERT also requires
  `NOT EXISTS (SELECT 1 FROM jira_accounts)`, so re-applying the migration
  after a down/up cycle on a populated install cannot mint a duplicate
  account row.
- `workspace.memory_jira_last_extracted_ts` dropped (moved to the account row).

### Legacy migration (two-phase, the Google/Slack pattern)

`ensureLegacyJiraAccount` (cmd/jira_legacy.go) finishes what SQL can't:
guarded by **legacy-token-file existence, not row existence** (the "Google C1
lesson" — a row-existence guard would make a token-only install's migration
unreachable), it creates-or-fills row #1 from `cfg.Jira.CloudID`/`SiteURL`/
`UserDisplayName` and renames `jira_token.json` → `jira_token_1.json`.
Idempotent; called from daemon sync wiring, `jira add` (seed-then-create),
`jira login`/`jira logout`/`jira status`/`jira sync`. The config keys stay in
config.yaml as a frozen snapshot — nothing reads them any more (except the
Desktop's pre-migration yaml fallback).

### Token store

`jira.NewTokenStore(workspaceDir, accountID)` → `jira_token_<id>.json` (0600,
the `google_token_<id>.json` convention). `Load()` keeps its original
error-on-missing contract (unlike Slack's nil-on-missing) — the wiring gates
on `Exists()` as before.

### Sync fan-out

`wireJiraSyncers` (cmd/sync.go) iterates `ListEnabledJiraAccounts` and builds
one `jira.Syncer` per account (`NewSyncer(client, db, mapper, boardIDs,
accountID)`), each with its own per-account `BoardAnalyzer`/`FieldDiscovery`;
an account with no token or no cloud_id records only *its* `status`/`error`
(only flipping a currently-`ok` account, so status never churns) and never
blocks the others. The daemon holds `jiraSyncers []*jira.Syncer`
(`SetJiraSyncers`, replacing the singleton `SetJiraSyncer`); `phaseJiraSync`
loops accounts, aggregates board-analyzer LLM usage into one `jira-boards`
pipeline run, and runs `SyncJiraTargetStatuses` once per phase as long as at
least one account's pass returned nil (one broken site must not stop target
statuses from reflecting the healthy ones). The global `cfg.Jira.Enabled` stays
the daemon phase switch (the `cfg.Calendar.Enabled` precedent).

**Who writes `jira_accounts.status`, and what each writer may write:**

- **The OAuth connect** (`connectJiraAccount`) is the *only* writer of `"ok"`.
  It has just completed a consent + token exchange, so it is the one flow that
  genuinely proves access.
- **`wireJiraSyncers`** writes only `"error"`, and only for the two conditions
  it can see at wiring time (no token file, no `cloud_id`), and only when the
  row is currently `ok` — so an already-failing account's status never churns.
- **`phaseJiraSync`** writes only `"revoked"`, and only for
  `errors.Is(err, jira.ErrAuthRevoked)`. **Any other `Sync` error is
  log-only** — it touches no auth state at all. A transient network blip would
  otherwise stamp a sticky error that nothing but a re-login could clear, since
  the phase has no authority to write `"ok"` back. A cancelled context
  (shutdown) is likewise never persisted.

**A sync pass therefore never writes a blanket "ok".** `Syncer.Sync`
deliberately keeps going across projects: a per-project failure is logged and
skipped, and `Sync` still returns nil, so a nil error is *not* proof the
account is healthy. Writing "ok" back on it would paint a revoked account green
in Settings and hide its Re-login button. Pinned by
`TestPhaseJiraSyncNeverPaintsAccountGreen`.

This is a **deliberate divergence from the Google sibling**, not a copy of it:
`gmail.Syncer`/`calendar.Syncer` *do* write `"ok"` back after a clean pass
(`recordAuthResult(ctx, nil)` → `SetGoogleAccountAuthState(…, "ok")`), because
their `Sync` fails outright on an auth problem. Jira's does not — it swallows
per-project failures by design — so the same self-healing write would be a lie
here. (Slack is not a counterexample either way: its sync wiring writes no auth
state at all, only logs, so `"ok"` there likewise comes only from the connect
flow.) The cost of the divergence is that a Jira account stuck in `error` is
cleared only by a re-login — the button that state exists to surface, and the
intended user action anyway.

**`jira.ErrAuthRevoked` is what makes the per-account status surface real.**
Review surfaced that without it the feature was near-inert: `Sync`'s only
non-nil return was a failing `GetJiraSelectedBoards`, so a genuinely revoked
grant produced per-project 401s that were swallowed, the account kept
`status='ok'`, and Settings showed it green while it synced nothing. Jira
simply never got the sentinel its two siblings already had
(`gmail.ErrAuthRevoked`, `calendar.ErrAuthRevoked`), so it is added here on the
same shape: `isInvalidGrant` on the token-endpoint body, plus a 401 that
survives a successful token refresh. `Syncer.Sync` aborts the account's pass on
it — every remaining project would fail identically — and `phaseJiraSync`
stamps `status='revoked'` on the `jira_accounts` row, which is what surfaces the
Re-login button. Ordinary per-project failures are still logged and skipped, and
a generic (non-revoked) `Sync` error is logged without touching the row.

*Still true, and pre-existing:* `Syncer.Sync` sets `LastError`/`LastErrorAt` on
its in-memory `JiraSyncState`, but `UpdateJiraSyncState` writes only
`last_synced_at`/`issues_synced`, so those two columns are never persisted —
unchanged from before this branch. That now costs only per-project error
*detail*; the account-level auth signal no longer depends on it.

### CLI

`watchtower jira add [--label L] [--site URL] [--no-open]` (OAuth → new row +
token file; rollback soft-removes a failed new row), `jira login
[--account N]` (re-consent; prefers the account's existing site; without
`--account` operates on account #1, created on first use), `jira accounts`, `jira enable|disable <id>`, `jira remove <id>`
(**non-destructive**, the Slack precedent — token deleted, row marked
removed, synced data kept), `jira logout` (legacy alias = remove account #1 —
a deliberate behavior change: the old logout wiped every `jira_*` table via
`ClearJiraData`, which is now deleted). Per-account commands (`boards`,
`sync`, `fields`, `boards analyze/override`) take a persistent `--account`
flag defaulting to the single enabled account.

Three refusals keep the account fan-out honest rather than silently guessing:

- **Re-login never silently retargets a site.** `selectJiraSite` auto-picks
  only on `jira add` (no `preferCloudID`). On `jira login --account N`, if the
  account's stored `cloud_id` is not among the resources the new grant returned,
  the command errors out naming the expected site and the sites actually
  granted — signing in with the wrong Atlassian identity must not quietly
  re-point an existing account's row (and its synced data) at another site.
- **The four dashboard commands reject `--account`** (`workload`, `blockers`,
  `project-map`, `releases`): they aggregate every connected site by design, so
  an `--account` that silently did nothing would misreport scope. The persistent
  flag is refused with an explicit error there. (`releases` is genuinely
  cross-site: its per-release issue lookup is scoped by the release's own
  `account_id`.)
- **Removed accounts refuse to be operated on.** `jira enable|disable <id>` and
  an explicit `--account <id>` both error when the row's `status='removed'`;
  Desktop's `JiraAccountQueries.fetchAll` filters those rows out, so a removed
  site is neither a ghost row in Settings nor a target for a CLI action that
  has no token to work with.

### Memory

`runJiraIngest` loops enabled accounts (the `runGmailExtract` precedent), each
against its own `jira_accounts.memory_jira_last_extracted_ts` — a shared
watermark would let an account added later swallow the others' windows. The
`jira:<KEY>` provenance scheme and `jiraissue:<KEY>` alias stay
account-unscoped (documented v1 limitation mirroring `mail:`): if two sites
share an issue key, both accounts' ingest passes address the *same* vault node,
so each run rewrites it with the other site's issue — a flip-flop, not a
first-writer-wins pin. Alias scoping is an open follow-up for the owner, not a
decision this slice makes. `jira_issues`
listing/init are account-scoped (`ListJiraIssuesForExtract(accountID, ...)`,
`MaxJiraUpdatedUnix(accountID)`). MEM-12's `jiraResolver` is unchanged.

### Desktop

Settings → Jira becomes an account list (`JiraAccount` model +
`JiraAccountQueries` + `JiraAccountsViewModel` + `AddJiraAccountView` +
`jiraSettingsSection` — structural copies of the Slack four). Browse-URL
resolution moves off the frozen config keys: `JiraConfigHelper.readSiteURL()`
now reads the **first enabled account's** `site_url` from `jira_accounts`
(pool wired in `AppState.initJiraAccounts`), yaml as pre-migration fallback.
`JiraQueries.isConnected()` accepts any `jira_token*.json`. The old
single-connection `JiraAuthService` is deleted: the rewritten Settings block
left it with one consumer that only wanted `siteURL` (now
`JiraConfigHelper.readSiteURL()`), while its unreachable `disconnect()` still
shelled out to `jira logout` — whose meaning changed here to "remove account
#1".

## Non-goals (v1, documented deviations)

1. **Cross-site issue-key ambiguity**: a key present on two sites resolves to
   an arbitrary site's row in bare-key readers (`GetJiraIssueByKey`, MCP
   `get_jira_issue`, `SyncJiraTargetStatuses`, key-detector links) — accepted,
   mirrors the Gmail `mail:` decision.
2. **Desktop browse links resolve against the primary site** (first enabled
   account): `JiraConfigHelper.readSiteURL()` returns one site URL for the
   whole app, so an issue synced from a second site still opens under the
   first site's host. Per-issue site resolution via the row's `account_id` is a
   later slice. This is the *only* remaining Desktop deviation — per-*board*
   actions are fully account-scoped: the Swift `JiraBoard` model carries
   `accountID`, both boards screens pass `--account` on every CLI action they
   run (select / deselect in `JiraBoardsSettingsView`, analyze and the three
   override writes in `JiraBoardProfileView`), the boards refresh runs
   `jira boards --account <id>` once per enabled account instead of a single
   unscoped call, board lists key on `rowID` (`account:id`) since raw board ids
   collide across sites, and `JiraQueries.fetchBoard(_:accountID:id:)` addresses
   the composite primary key.
3. **Concurrent OAuth flows** (loopback ports 18511-18520 are shared;
   sequential logins only).
4. **Per-account sync schedules** — one `jira.sync_interval_mins` for all.
5. **Per-account custom OAuth clients** (Google has `client_id` per account;
   Jira keeps the build-time/env client for all accounts).
6. `jira remove` non-destructive (no cascade), `jira logout` no longer wipes
   data — deliberate departures from the old single-account behavior.
7. `db.GetCurrentUserID()`-derived flows (inbox Jira detector's assignee
   match) are unchanged: Atlassian account ids are globally unique, so
   assignee matching already works across sites.

## Testing

Migration fixture tests (`internal/db/jira_accounts_migration_test.go`):
upgrade-legacy (seed at 00048, apply 00049, assert re-parenting + watermark
move + unscoped tables untouched), fresh-DB-no-seed-row, composite-PK
collision (same raw id under two accounts), down/up cycle. CRUD tests
(`jira_accounts_test.go`, the slack_accounts_test shape). Per-account
watermark isolation rides the existing memory jira-ingest guards. Swift:
`JiraAccountQueriesTests` (incl. `primarySiteURL` skip rules),
`JiraAccountsViewModelTests` (pure-args).

## Plan / rollout

Implemented in one pass on `claude/jira-multika-ggnfta` (this repo's Slack
plan structure, tasks folded); merge to `main` after owner verifies live with
a real second site.
