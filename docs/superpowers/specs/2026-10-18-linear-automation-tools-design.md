# Linear in automations — API key, read and write tools (design)

Date: 2026-10-18. Board: #694 (under #685). Parent spec:
`docs/superpowers/specs/2026-10-15-linear-integration-design.md` (this slice
replaces its §3.3 neutral write tools with Linear-specific ones, owner ask #384).

## 1. Intent

The owner files issues in Linear from a work machine. On their own machine, a
workbench automation picks those issues up, triages them with the owner
(`ask()`), and starts a session to do the work (`session()`). Today the same
recipe can be written for Jira on v0.21.0; for Linear it cannot, because the
Linear connector syncs into `linear_*` but nothing reads or writes Linear from
an automation or the chat.

Owner's words (ask #384): "Linear is basically the same as Jira, and I want a
similar integration." So the rule of this slice is **mirror Jira**: the same
tool shapes, the same approval path, the same capability grammar, named
`*_linear_*`.

## 2. Goals

1. **API key login** next to the existing OAuth: `watchtower linear add
   --api-key` works without a registered OAuth app or a build-time client id.
2. **Read tools** an automation (and the chat) can call over the synced
   `linear_*` tables.
3. **Write tools** that mirror the Jira write set: create, comment, change
   state, assign, update fields.
4. **Automation capability** `linear:read|write@<TEAM-KEY>|*`.
5. **A workbench template** `linear-triage` that is the owner's use case,
   installable from the gallery.

## 3. Non-goals

- No `linear.issue_changed` event (owner: cron + `list_linear_issues` is
  enough). The recipe polls the local mirror.
- No neutral `*_issue` tools and no consumer moves to `tracker_*` (that stays
  in #686/#689).
- No Desktop settings screen for Linear accounts (#691). The API key is added
  from the CLI.
- No time-in-status or releases tool (Linear has no `fixVersion`; time in
  status can follow later from `linear_issue_history`).
- No change to the Jira tools, their names or their surfaces.

## 4. Anti-goals

- A key or token in argv, in a log, in the database or in a recipe.
- A write that reaches Linear without going through `agent_actions`
  (propose → owner approval or an owner auto grant → apply exactly once).
- A proposal that applies to a different workspace than the one it was
  proposed against.

## 5. API key login

- `watchtower linear add --api-key [--label L]` reads the key from stdin
  (a prompt with echo off on a TTY, a single line from a pipe). It is never a
  flag value. `linear login --api-key [--account N]` replaces the credential of
  an existing account the same way.
- The key is stored in the existing token file
  `<workspace>/linear_token_<accountID>.json` (0600) with
  `token_type: "api_key"`, `access_token: <key>`, no refresh token and no
  expiry. No migration: the kind lives in the token file.
- The client sends `Authorization: <key>` (Linear's personal-key form, no
  `Bearer`) for an `api_key` token and never refreshes it; an OAuth token keeps
  `Bearer` and the rotating refresh (LINEAR-02 unchanged). A 401 or an auth
  GraphQL error on a key marks the account `revoked` (LINEAR-03 unchanged).
- Workspace identification, revival of a removed account and the cleanup on
  failure work exactly as `add` does today (`linear.FetchViewerWithToken` with
  the key in memory). `remove` deletes the file; there is nothing to revoke
  for a personal key (the owner revokes it in Linear; the CLI says so).
- `--api-key` is a mode flag on the existing `add` and `login` commands; without
  it they run OAuth as today. `login --api-key` keeps the wrong-workspace guard
  (the key's workspace must match the account's `org_id`, else nothing is
  saved).
- The client branches on the token file's `token_type == "api_key"` (today
  `client.go` always sends `Bearer`); nothing else keys off the token kind.
- `linear accounts` (text and `--json`) gains `auth: "oauth" | "api_key"`, read
  from the token file by the CLI only (`db.LinearAccount` is unchanged; the
  Desktop does not show it in this slice).
- The key needs write access in Linear (the owner creates it with full access);
  a key without it fails at the first write with Linear's message.

## 6. Tools

All tools take an optional `account_id` with the Jira meaning: needed only
when the key or team exists on several connected Linear workspaces. Issue keys
match `^[A-Z][A-Z0-9]*-\d+$` and resolve through `linear_issues.key`, then
`previous_keys` (a moved issue keeps working, LINEAR-04).

Account resolution mirrors `ResolveJiraAccount`/`resolveIssueTarget`
(`internal/tools/jira.go`, `jira_write.go`): explicit `account_id` → that
account, refused when removed or disabled; else the one enabled account whose
mirror holds the key (or the team) → else the single enabled account; several
matches → a `ValidationError` asking for `account_id` (see
`list_linear_teams`); none connected → "the owner must run `watchtower linear
add` first". Execute re-resolves the pinned `account_id` through the same
function, so an account removed or disabled since the proposal fails the apply;
a revoked one fails at the Linear call and is marked as today.

### 6.1 Reads (local mirror only, no network)

| Tool | Args | Returns |
|---|---|---|
| `list_linear_teams` | — | accounts with their teams: key, name, selected |
| `list_linear_issues` | `team`, `state` (name), `state_type` (`triage`/`backlog`/`unstarted`/`started`/`completed`/`canceled`), `assignee` (`me`, email or Linear user id), `created_after` (RFC 3339 or YYYY-MM-DD), `limit` | lean rows, newest `created_at` first: key, title, state, state type, assignee, priority, estimate, labels, due date, url, created/updated; description clipped at 512 bytes |
| `get_linear_issue` | `key` | the whole issue plus its comments, newest last |
| `get_linear_status_history` | `keys` (≤ 20) | state and assignee changes from `linear_issue_history` |
| `list_linear_cycles` | `team` | cycles with derived state (active/upcoming/past) |

Deleted (`is_deleted = 1`) issues are left out. Surfaces: `main`, `target`,
`automation`, as the Jira reads.

`created_after` and `state_type` are additions over `list_jira_issues`: they
are what a triage recipe needs (`state_type: "triage"`, or "created since my
last run"). `created_after` compares against the issue's Linear `created_at`
(not `synced_at`), parsed and normalized to UTC RFC 3339 before the string
comparison; a date means its midnight UTC.

`list_linear_teams` also returns each team's workflow states (name, type,
position) and labels, so a recipe can choose names without a network call.
These come from two new small mirror tables filled by `phaseLinearSync`
(`linear_workflow_states`, `linear_labels`: one migration, `schema.sql`,
`TestAllTablesExist`, the golden and Swift test schema regenerated), refreshed
for the selected teams on every pass.

### 6.2 Writes (External, AGENT-03)

| Tool | Jira twin | Args | Linear call |
|---|---|---|---|
| `create_linear_issue` | `create_jira_issue` | `team`, `title`, `description` (markdown), `labels`, `priority`, `assignee`, `state` | `issueCreate` |
| `add_linear_comment` | `add_jira_comment` | `key`, `body` (markdown, ≤ 32000) | `commentCreate` |
| `transition_linear_issue` | `transition_jira_issue` | `key`, and exactly one of `state` (name) or `state_type` (`backlog`/`unstarted`/`started`/`completed`/`canceled`: the team's lowest-position state of that type) | `issueUpdate(stateId)` |
| `assign_linear_issue` | `assign_jira_issue` | `key`, `assignee` (`me`, email, display name, or `none`) | `issueUpdate(assigneeId)` |
| `update_linear_issue` | `update_jira_issue` | `key`, any of `title`, `priority`, `labels_add`, `labels_remove`, `due_date`, `estimate` | `issueUpdate` |

Every write has a `reason` and follows the Jira write pattern:

- **Validate** checks the args and resolves the account and the issue (no
  write).
- **Normalize** pins what was resolved at propose time into the persisted args:
  `account_id`, the canonical key, and the resolved ids (`state_id`,
  `assignee_id`, label ids, `team_id`). The owner approves exactly what will
  be applied, and a later rename or a second workspace cannot redirect it.
- **Execute** applies with the pinned ids, then refetches the issue and
  upserts it into `linear_issues` through the syncer's own issue upsert (same
  `previous_keys`, `raw_json` and Slack back-fill handling; no watermark or
  `linear_sync_state` is touched), so the next `list_linear_issues` sees the
  change without waiting for the sync. It returns the issue's url. A failed
  refetch does not fail the write (the write already happened); the result
  says the mirror refreshes on the next sync.

Name resolution:

- **State:** by name, case-insensitive, among the issue's team's workflow
  states (fetched from Linear at validate time). Linear has no transition
  graph: any state of the team is allowed. A miss lists the team's states.
- **Priority:** `none`, `urgent`, `high`, `medium` (also `normal`), `low` →
  Linear's 0–4.
- **Labels:** by name among the team's and the workspace's labels. A label that
  does not exist is refused, never created.
- **Assignee:** `me` = the account's `owner_user_id`; else an email or exact
  display name among the workspace's users (fetched at validate time); an
  ambiguous name is refused with the candidates.
- **Estimate:** a number; Linear refuses a value outside the team's scale and
  that message is returned. Clearing an estimate or a due date is not
  supported in this slice (Jira's `update_jira_issue` cannot clear either).
- `update_linear_issue` needs at least one field; a label in both
  `labels_add` and `labels_remove` is refused (the `validateIssueUpdate`
  rules).

State names and labels resolve from the mirror tables (§6.1) at validate
time, with one live refetch of the team's states/labels on a miss (a state
created since the last sync); users resolve from `linear_user_map` plus a live
workspace-users fetch on a miss.

Surfaces: `main`, `target`, `automation` (and `reaction` for
`create_linear_issue` only if reaction commands learn Linear later — not in
this slice). Not on the workbench surface (DEV-06 unchanged).

### 6.3 Automation capability

- `capabilitySpecs` gains `"linear": {verbs: readWrite, scope: scopeRequired,
  upperScope: true}`.
- `ToolCapabilities` maps every tool above to `linear`, scoped by the team
  key: `team` for the team tools; for the issue tools, the issue's **current**
  `team_key` as resolved from the mirror (a moved issue is scoped by the team
  it lives in now, never by an old prefix; a key absent from the mirror falls
  back to its prefix); `list_linear_teams` unscoped (`@*` or `tool:`).
- Automation auto grants (`automations auto … on`) work for the Linear writes
  as for the Jira ones; nothing new.

### 6.4 Desktop twins

- `ChatToolCatalog` / `ChatToolCatalog+Actions`: display entries and icons for
  the ten tools (the Jira entries' wording with "Linear").
- `AutomationCardPresentation`: the `linear` capability's label.
- No new screens.

## 7. Template `linear-triage`

A workbench template in the P6 gallery (`internal/automations/templates/`):

- Trigger: cron every 15 minutes (`*/15 * * * *`), `run_once`.
- Param `TEAM` (allowlist rule as `PROJECT`), defaulting from owner data the
  way `jira-state-report` picks `PROJECT`
  (`TestInstallTemplate_JiraProjectFromOwnerData`): the selected team with the
  most issues assigned to the owner, else the first selected team by key. With
  no Linear team selected the gallery install is refused with "connect Linear
  and select a team first"; a key shared by two accounts is still one scope
  value (scopes are team keys, as Jira's are project keys).
- Permissions: `linear:read@<TEAM>`, `linear:write@<TEAM>`, `ask:owner`,
  `session`, `llm:light`.
- Script: `list_linear_issues({team, state_type: "triage"})`, skip keys already
  in `state.seen`; for each new issue (at most 5 per run) a light `llm()`
  summary and a suggested priority, then one `ask({kind: "question"})` with
  options *Take it now* / *Backlog* / *Skip*. *Take it now* →
  `transition_linear_issue {state_type: "started"}` +
  `assign_linear_issue me` + `session({prompt})` with the issue key, title and
  url; *Backlog* → `transition_linear_issue {state_type: "backlog"}`;
  *Skip* → remembered, nothing written.
- Installed unconfirmed and disabled, as every template.

## 8. Freshness

The recipe reads the local mirror, so a new Linear issue reaches it after the
next `phaseLinearSync` (`linear.sync_interval_mins`, default 15) plus the next
cron tick. A Linear account added while the daemon runs is picked up on the
daemon's next start (current v1 limit of the connector; the guide says so).

## 9. Testing

- `internal/linear`: API-key client header and no-refresh path; 401 on a key →
  `ErrAuthRevoked`; token-file round trip with `token_type: "api_key"`.
- `cmd`: `linear add --api-key` reads stdin, never argv; the key is absent
  from output and logs; revival and failure cleanup.
- `internal/tools`: each tool against a fake Linear client and a seeded DB —
  account resolution, `previous_keys`, Normalize pinning, name resolution
  misses, upsert after Execute, revoked marking.
- `internal/automations`: the capability table and scope extraction;
  `TestTemplates_*` pick up `linear-triage` (parse, dry run E2E).
- `cmd/actions_registry_test.go`: the new tools' surfaces pinned next to
  `automationWriteSurfaces`; the chat actions-contract goldens regenerated.
- Desktop: catalog entries in `ChatToolCatalogTests`.

## 10. Contracts and docs

- LINEAR-02 gets a note: an API-key token never refreshes. LINEAR-03 covers
  key auth failures. AGENT-03: the five Linear writes are External.
  AUTO-01: the `linear` capability. New guard tests named in
  `docs/inventory/linear.md`.
- `docs/features/linear.md` (API key, tools, v1 limits),
  `docs/features/automations.md` (capability, template),
  `docs/guide/` Linear and Automations pages.

## 11. Decisions

From the owner (ask #384): both API key and OAuth; separate `*_linear_*`
tools; cron + list instead of an event; the same writes as Jira.

My calls (check while reading):

- Reads mirror the Jira core (teams, issues, issue, history, cycles); no
  time-in-status and no releases tool.
- `list_linear_issues` gets `state_type` and `created_after`, which Jira's
  list lacks, because triage needs them.
- `create_linear_issue` has no issue type (Linear has none); a bug is a label.
- Unknown labels are refused, never created.
- The key is read from stdin and stored in the existing token file (no
  migration for auth).
- Workflow states and labels get two small mirror tables (one migration), so
  recipes and validation read names locally; `transition_linear_issue` also
  takes a `state_type`, so the template never hardcodes state names.
- A moved issue is scoped by its current team, not by the key's old prefix.
- The write upsert reuses the syncer's upsert and never moves a watermark.
- The `linear-triage` template is in scope: it is the owner's use case and the
  proof the tools fit together.
