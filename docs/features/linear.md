# Linear connector (2026-10-15, Plan 1 of 3)

Plan 1 ships the schema, the tracker-neutral views and the connector. Consumers (briefing, inbox, meeting prep, tools) are Plan 2; Desktop is Plan 3. Contracts: LINEAR-01..04 in `docs/inventory/linear.md`; the OWNER-01 Linear rung is in `docs/inventory/owner-identity.md`.

## Architecture

Connector (`internal/linear/`) → `linear_*` tables (migration 00119) → `tracker_*` views (migration 00120) over Jira and Linear. Consumers will read only `tracker_*`; connectors write the normalized columns (`status_category`, `state_changed_at`) so the views stay plain projections.

## OAuth

Authorization-code flow with PKCE (no client secret). The client id comes from `WATCHTOWER_LINEAR_CLIENT_ID`, else `linear.DefaultLinearClientID` (build-time `-X`, Makefile `LINEAR_ID`; release builds need `LINEAR_ID`/`WATCHTOWER_LINEAR_CLIENT_ID` in the build environment); with neither, `add`/`login` fail before opening a browser. The loopback listener tries fixed ports 18531..18535, so the Linear OAuth app must register `http://localhost:18531/callback` ... `18535`. Tokens rotate: every refresh returns a new refresh token, saved before use and single-flight across goroutines and processes (LINEAR-02); token and revoke calls time out after 30 s. Token file `<workspace>/linear_token_<accountID>.json`.

## API key (2026-10-18, #694)

An alternative to OAuth, for a workspace where the owner prefers a personal API key: `watchtower linear add --api-key` / `login --api-key` read the key from stdin (prompt `Linear API key: `, an empty key is refused). The token file carries `token_type: "api_key"`; the client sends it as a bare `Authorization` value (no `Bearer`), never refreshes it (no refresh lock), and treats a 401 as `ErrAuthRevoked` (the account goes `revoked`, LINEAR-03). `add` identifies the workspace with `FetchViewerWithToken` as for OAuth. `remove` deletes the token file and disables the account but revokes nothing at Linear: the owner revokes the key in Linear's settings. `linear accounts` shows `auth` (`oauth`|`api_key`, empty with no token file, `error` for an unreadable or corrupt one) in text and `--json`.

## Sync

`phaseLinearSync` runs every `linear.sync_interval_mins` (default 15) when `linear.enabled`, one syncer per account, errors isolated per account; `ErrAuthRevoked` marks the account `revoked` (LINEAR-03). The syncers are built once at daemon start (`wireLinearSyncers`), so an account added, disabled or removed is picked up on the daemon's next start (the Jira precedent).

- Per-team watermark in `linear_sync_state`; issues and comments are queried with `updatedAt gte since` (LINEAR-01). The watermark is the max issue `updatedAt` only; a quiet successful pass records the `since` it queried with.
- First pass: every open issue plus issues updated within `linear.backfill_days` (default 90).
- Pages: issues 25 per page (with nested labels 20, relations 20, history 50), comments 50, teams 50, users 100, cycles/projects 50. The client gate waits when remaining requests drop below 5 or complexity below 20000 and refuses waits over 10 minutes (`ErrRateLimited`).
- `state_changed_at` means what Jira's `status_category_changed_at` means: the newest history entry that moved the issue to another status category (In Progress → In Review, both `started`, does not count); without one it falls back to the current category's timestamp (`startedAt`, `completedAt` or `canceledAt`).
- Issues moved to an unselected team are reconciled by id account-wide each pass: a cheap id-only query over issues changed outside the selected teams since `linear_accounts.moved_watermark` (advanced only after a successful reconcile), then a full refetch (issues and comments) of the ids already stored. Issues of unselected teams that were never stored are not fetched; issues of a team the owner deselects keep refreshing for the same reason.
- Archived or trashed issues are stored with `is_deleted = 1`. Issues are keyed by UUID; keys move (LINEAR-04).
- Users are fetched each pass and mapped to Slack by email only (`db.ResolveLinearUsersByEmail`; manual mappings are untouched); Slack ids are back-filled onto issues (assignee and creator; `db.BackfillLinearSlackIDs`); comments keep their Linear author id. Comment mentions are read from the body's `suggestion_userMentions` nodes (`attrs.id`).

## Tables (00119)

`linear_accounts`, `linear_teams` (selection), `linear_sync_state`, `linear_issues`, `linear_comments`, `linear_issue_history` (state and assignee changes), `linear_cycles`, `linear_projects`, `linear_relations`, `linear_user_map`.

## Views (00120)

- `tracker_issues`: tracker, account_id, issue_id, key, project_key, title, description_text, status, status_category, status_changed_at, assignee_*, reporter_*, priority, priority_rank, points, due_date, iteration_id/name, container_kind/id/name, parent_key, labels, is_bug, is_blocked, url, created_at, updated_at, resolved_at, synced_at, is_deleted.
- `tracker_comments` (the Linear branch shows the issue's current key, so comments follow a team move), `tracker_history` (tracker, account_id, issue key, id, field, from/to value and string, actor, changed_at), `tracker_iterations` (sprints and cycles with a derived state), `tracker_people`, `tracker_accounts` (enabled, non-removed accounts only).

Read the migration for the exact column lists; the owner-open query shape is pinned by `TestTrackerIssues_OwnerOpenQueryUsesIndexes`.

## Mirrors for the write tools (migration 00142)

`linear_workflow_states` and `linear_labels` hold each selected team's workflow states and labels. They are refreshed per selected team on every sync pass (the workspace labels once per pass, by the first team that syncs); a failure fails that team and leaves its watermark unmoved (guard `TestLinear01_StatesLabelsFailureHoldsWatermark`). `Syncer.RefreshIssue` refetches one issue (and its comments) by id, stamps the Slack ids (`db.BackfillLinearSlackIDs`) and moves no cursor; the write tools call it after a successful write (non-fatal). Contract note: `TestSyncer_MirrorsStatesAndLabelsForSelectedTeams`, `TestSyncer_WorkspaceLabelsOncePerPass`, `TestSyncer_RefreshIssueNoWatermark`, `TestSyncer_RefreshIssueStampsSlackIDs`.

## Tools (2026-10-18, #694; spec `docs/superpowers/specs/2026-10-18-linear-automation-tools-design.md`)

Reads (`internal/tools/linear_read.go`, no live call except where noted): `list_linear_teams` (with states and labels), `list_linear_issues` (team, state, state_type, assignee `me`|email|id, created_after, limit; newest first; no account gives an empty list), `get_linear_issue` (with comments; a previous key resolves), `get_linear_status_history` (at most 20 keys), `list_linear_cycles` (automation surface only, like `list_jira_sprints`).

Writes (`internal/tools/linear_write.go`; `External`, surfaces main, target and automation; propose, approve, apply — AGENT-03): `create_linear_issue` (team, title, description, labels, priority, assignee, state), `add_linear_comment`, `transition_linear_issue` (state or state_type), `assign_linear_issue` (`me`, email, display name or `none`), `update_linear_issue` (title, priority, `labels_add`/`labels_remove`, due_date, whole-number estimate). Normalize pins the account, issue, team, state, assignee and label ids at propose time, resolving from the mirror first and doing one live refetch on a miss; an unknown label is refused, never created. `create_linear_issue` pins a client UUID (`issue_uuid`) so a Retry looks up the landed issue instead of creating a second one. An auth error at apply marks the account `revoked`.

Automations: capability `linear:read|write@<TEAM>|*` (AUTO-01); issue tools are scoped by the issue's current team, a list call without `team` is the absent scope. Desktop: chat catalog entries, approval-card summary lines and the automation card's "Linear" source.

## Consumers — knowledge half (Plan 2 lane 2, 2026-10-18, #688/#689)

Gating: the Jira switches govern both trackers (spec §3.5). A surface that was gated on `jira.enabled` runs when `jira.enabled || linear.enabled`; a feature toggle goes through `jira.TrackerFeatureEnabled(cfg, name)`; Memory's Linear source runs behind `memory.sources.jira`.

- **Slack links (migration 00144).** `jira_slack_links` is now `issue_slack_links` with `tracker` (`jira` | `linear`); existing rows were copied as `jira` (ids and the AUTOINCREMENT mark kept) and the per-kind identities (mention / track / decision) include `tracker`. The key detector moved to `internal/issuekey`: a key matches when its prefix is a known Jira project key (`GetKnownProjectKeys`) or a known Linear team key (`GetKnownLinearTeamKeys`: synced teams plus the team key of every stored issue); a prefix known to both writes one link per tracker. Gate: `jira.enabled || linear.enabled`. Readers: Jira-only ones (`GetJiraIssuesFor*`, `GetJiraSlackLinksBy*`, who-to-ping, blockers, project map, without-Jira, the Swift `JiraQueries` twin) filter `tracker = 'jira'`; the tracks has-ticket filter and the Slack purge cover both. `GetIssueSlackLinksByKeys(tracker, keys)` takes a Linear issue's current and previous keys.
- **Ideas.** `stream_digests.source` and `idea_mentions.source` gain `linear` (00144). `runLinearDigests` (part of `RunStreamDigests`) mines each enabled workspace's issues updated since `linear_accounts.ideas_floor` plus their new comments with the Jira stream's own render, floor and tie-drain code (IDEA-01) and the `ideas.digest_jira` prompt (v3, "Jira or Linear"); a selected team whose latest sync failed holds the floor at its last successful sync (`OldestFailingLinearTeamSync`). Refs are bare keys; the consolidator mints mentions with source `linear`. An empty floor initializes to now (no backfill); `ideas mine --from` and the history backfill do not cover Linear (v1). Feature fast-forward stamps the Linear floors (stream digests) and memory watermarks (memory).
- **Catch-Up.** The stream area gathers `linear` rows next to `jira` ones (named by the stored source); the prompt section reads `EMAIL / JIRA / LINEAR STREAMS`. Desktop labels the stream **Linear** with the ticket badge (`StreamDigest.sourceLabel` / `isTrackerStream`, `IdeaMention.Source.linear`).
- **Memory.** `runLinearIngest` (Run step 2e, right after the Jira builder, no AI call) builds one episode per updated issue per workspace; watermark `linear_accounts.memory_last_extracted_ts`, alias `linearissue:<account>:<uuid>` (a team move retitles the same episode), provenance `linear:<KEY>` resolved by `linearResolver` against the current key or `previous_keys` (MEM-12), back-links to the team entity and the assignee/creator people. Project-key seeds and the Slack-id migration's exclusion set include Linear team keys.
- **Knowledge search.** Source `linear`: one document per issue with its comments, key and anchor `linear:<account>:<key>` / `{account_id, key}`, link = the issue url; a team move re-keys the document. Workbench and chat-project scopes still cover Jira projects only.
- **Meeting prep and people cards.** Attendee load (`ListTrackerIssues`, open, by Slack id) and delivery stats (`GetTrackerDeliveryStats`, `GetTrackerResolvedIssuesForUser`) read `tracker_issues`; a Linear issue blocked by an open issue counts as blocked. Components stay Jira-only. The prompt sections keep their JIRA headers.
- **`get_task_context`, `find_experts`.** Jira first (unchanged; a key both trackers carry resolves to Jira), then Linear by current or previous key (`GetLinearIssueDossier`): issue, comments, threads linked under any key, meetings, decisions (`idea_mentions` source `linear`), people; find_experts cites kind `linear` (weight 2.0) and maps commenters through `tracker_people`. No Confluence section for Linear.
- **Tracks CLI.** List badges and the detail view show linked Linear issues under `track_linking`. The digest CLI's issue badges stay Jira-only (v1).
- **NL→SQL.** `ai.TrackerPromptSection()` documents the `tracker_*` views and `issue_slack_links` (ask/repl, when either tracker is enabled).

## CLI

`watchtower linear add [--label] | login | accounts [--json] | enable|disable|remove <id> | teams [--json] | select|deselect <TEAM-KEY>... | sync | status`, with `--account` to pick a workspace and `--no-open`/`--app-return` on the OAuth commands. `add` revives a removed account for the same org, refuses a non-removed one and cleans up on any failure; `login` refuses a different workspace. Both identify the fresh token's workspace with an in-memory viewer request (`linear.FetchViewerWithToken`: no token file, no refresh); `login` saves the token only after the workspace matches. Both refresh the stored workspace name and URL key, so a renamed workspace shows its new name. `enable`/`disable`/`remove` take the id positionally; an `--account` naming a different id is refused. `remove` revokes (best effort) and deletes the token under the account's token lock, so a daemon refresh in flight cannot write it back. `sync` prints a line per account and exits non-zero when any account failed (the `jira sync` rule).

## v1 limits

- Permanently deleted Linear issues are not detected (only archived/trashed).
- Nested history is capped at 50 per issue per pass (default order unconfirmed), labels and relations at 20.
- The mention node name `suggestion_userMentions` (`attrs.id`) is unconfirmed against live data.
- Slack mapping is by email only.
- Consumers (briefing, inbox, ...) come in Plan 2, Desktop tabs in Plan 3.
- The write tools cannot create labels, move an issue between teams, delete issues or touch cycles, projects, estimates other than whole numbers, or relations; they act through the mirror, so a team that is not selected for sync has no states to choose from.
- An API key is per person and has no scopes: the workspace permissions of its owner apply.
- The OAuth app must register the five redirect URIs above; release builds need `LINEAR_ID`.
