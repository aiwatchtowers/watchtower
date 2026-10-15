# Linear integration — a second first-class issue tracker (design)

**Date:** 2026-10-15
**Status:** draft for owner review
**Decisions:** asks #158–#163 (workbench 1)

## 1. Goal

Linear becomes a first-class issue tracker in Watchtower, on par with Jira, for
Watchtower's users (a product decision, ask #158): a team that lives in Linear
gets the same briefing, day plan, inbox, memory, search, agent tools and Desktop
screens that a Jira team gets today. Linear appears in Goals → Connect as a peer
of Jira.

"On par" means function, not a port of every Jira mechanism (ask #159): what
Jira needs only because of Jira's configurability is left out (§2.3).

**Success criteria**

- A user who connects only Linear sees their Linear issues in the briefing, day
  plan, inbox (assigned + mentioned), Catch-Up streams, memory, knowledge
  search, tracks, meeting prep, people cards, `get_task_context`/`find_experts`,
  and the Desktop blocker map, iteration progress and project progress.
- The agent can read, create, update and comment Linear issues through the
  propose/apply path.
- A user with both Jira and Linear gets one merged picture.
- Jira behaviour is unchanged (every existing Jira guard test still passes
  unmodified, except the deliberately extended contracts in §8).

## 2. Scope

### 2.1 Architecture: hybrid (ask #160)

1. **Connector** `internal/linear/` writes Linear's own raw tables `linear_*`,
   the same way `internal/jira/` owns `jira_*`.
2. **Neutral read layer**: SQL views `tracker_*` (`UNION ALL` of the Jira and
   Linear tables, with a `tracker` column `'jira' | 'linear'`) plus a Go query
   API in `internal/db/tracker*.go` and a Swift twin in WatchtowerCore.
3. **Consumers move to the neutral layer one by one.** Jira tables, the Jira
   connector and the Jira-only analytics stay as they are.

A third tracker later is one more `UNION ALL` branch and one connector, not
another pass over every consumer.

### 2.2 In scope

OAuth + multi-workspace accounts; incremental sync of issues, comments, status
and assignee history, cycles, projects, relations, users and teams; the
neutral views; every consumer listed in §6; agent read and write tools; Desktop
settings, onboarding card, readiness, and the neutral analytics screens.

### 2.3 Not ported (Jira-only machinery)

Linear's workflow-state *types* are fixed (`triage`, `backlog`, `unstarted`,
`started`, `completed`, `canceled`), it has no custom-field zoo and no boards,
so these are not ported: the board analyzer (LLM board profile,
`connect_jira_board`), board selection, custom-field mapping, the project map.

### 2.4 Deferred (P6, separate spec)

Team workload, "discussions without a ticket" (`fetchChannelsWithoutJira`), and
a release dashboard (Linear has no `fixVersion`; project milestones are the
nearest analogue). The first two become cheap once their queries read
`tracker_*`.

## 3. Linear connector — `internal/linear/`

### 3.1 Auth

- OAuth 2.0 authorization code **with PKCE** (`S256`). With PKCE Linear needs
  no `client_secret` at the token exchange or on refresh, so only
  `DefaultLinearClientID` is injected via `-ldflags` — no secret ships in the
  binary.
- Endpoints: authorize `https://linear.app/oauth/authorize`, token
  `https://api.linear.app/oauth/token`, revoke
  `https://api.linear.app/oauth/revoke` (package vars, overridable in tests).
- Loopback redirect `http://localhost:<port>/callback` on its own port, the
  result page from `internal/oauthpage`, the same shape as `jira.Login`.
- Scopes: `read write issues:create comments:create`; `actor=user` (writes are
  made as the owner).
- Access tokens live ~24 h; **refresh tokens rotate on every refresh** (a lost
  refresh response may be replayed within 30 min). The new pair is written
  atomically under the per-account token-file lock before the new access token
  is used; a refresh that returns `invalid_grant` or a 401 marks the account
  `status='revoked'` (the `ErrAuthRevoked` pattern of Jira).
- Removing an account calls `/oauth/revoke`, then marks it `removed`
  (non-destructive, like Jira).
- At login the `viewer` query records the owner's Linear user id, email and
  name on the account row, and `organization` gives the workspace name and
  url key.

### 3.2 Sync

- No webhooks: a local app has no public endpoint. The daemon polls in a new
  `phaseLinearSync`, on the same cadence as Jira.
- Hand-written GraphQL (no SDK), each connection with an explicit `first: 50`,
  `filter: { updatedAt: { gt: <watermark> } }`, ordered by `updatedAt`. Budget:
  5 000 requests and 2 M complexity points per hour per user for OAuth apps,
  10 000 points per query max.
- A rate limiter reads `X-RateLimit-Requests-Remaining` and
  `X-RateLimit-Complexity-Remaining`; an HTTP 400 with extension code
  `RATELIMITED` backs off and **does not advance the watermark**.
- Watermark per (account, team) in `linear_sync_state`, with the Jira
  boundary-second drain (re-read the boundary second, dedupe by id). An error
  is recorded in `linear_sync_state.last_error` and holds the watermark.
- Teams: by default every team the owner is a member of; the user can switch
  teams on or off in Settings. Initial backfill: all open issues plus issues
  updated in the last 90 days.
- Per issue: core fields, comments (with `bodyData` for mentions), history
  entries that change state or assignee, relations. Cycles, projects (with
  Linear's own `progress`), users and teams are synced per team.
- Archived or deleted issues set `is_deleted = 1`.
- **Identifiers move:** moving an issue to another team changes `ENG-12` into
  `OPS-40`. The primary key is the Linear UUID; `key` is mutable and
  `previous_keys` (JSON, from `previousIdentifiers`) keeps the old ones so
  Slack links and memory refs to an old key still resolve.

### 3.3 Writes

Neutral agent tools `create_issue`, `update_issue` (state, assignee, priority,
title, description) and `comment_issue` route by tracker: a Jira key or Jira
account → the existing Jira write path; a Linear key or account → Linear
`issueCreate` / `issueUpdate` / `commentCreate`. All go through
`agent_actions` (propose → apply exactly once; external trust, AGENT-01/03/05).
An ambiguous key (the same prefix on two trackers or two workspaces) is pinned
to one account at propose time, as `pinSite` does for Jira. After a
successful mutation the returned issue is upserted into `linear_issues`.
The existing `*_jira_*` tools stay as they are; their names are pinned by
automations and tests.

### 3.4 Identity

- `linear_user_map`: Linear user → Slack user by email (the same matcher as
  `jira_user_map`), with `match_method` and confidence.
- `db.ResolveOwner` gains a Linear rung (OWNER-01 extended, owner-approved in
  ask #162): `Owner` carries the owner's tracker identities
  `[]TrackerIdentity{Tracker, AccountID, UserID}` from
  `jira_accounts.owner_account_id` and `linear_accounts.owner_user_id`.
  `JiraAccountID` stays for the existing callers.

### 3.5 Feature, onboarding, readiness

A `linear` feature in `internal/features` (on when an enabled account exists),
a Linear card in Goals → Connect, and a `.linear` readiness keyed on rows in
`linear_issues`, through the existing `FeatureReadiness` vocabulary. The
existing Jira feature toggles (`my_issues`, `awaiting_input`, `blocker_map`, …)
govern the tracker-neutral behaviour for both trackers; their config keys keep
their names.

## 4. Schema

One migration for P1 (00116 at the time of writing), following the `add-migration`
skill: mirror into `schema.sql`, `TestAllTablesExist`, the golden snapshot and
the Swift test schema.

### 4.1 Linear raw tables

| Table | Key | Main columns |
|---|---|---|
| `linear_accounts` | `id` | `org_id` UNIQUE, `url_key`, `org_name`, `label`, `status` (ok/error/revoked/removed), `error`, `enabled`, `owner_user_id`, `owner_email`, `owner_display_name`, `memory_last_extracted_ts`, `ideas_floor`, `created_at` |
| `linear_teams` | (`account_id`, `id`) | `key`, `name`, `is_selected` |
| `linear_sync_state` | (`account_id`, `team_id`) | `watermark`, `last_synced_at`, `last_error` |
| `linear_issues` | (`account_id`, `id`) | `key`, `previous_keys` (JSON), `team_id`, `team_key`, `title`, `description_text`, `state_name`, `state_type`, `status_category`, `state_changed_at`, `assignee_id`, `assignee_email`, `assignee_display_name`, `assignee_slack_id`, `creator_*` (same four), `priority` (0–4), `estimate`, `due_date`, `cycle_id`, `project_id`, `parent_id`, `labels` (JSON), `url`, `created_at`, `updated_at`, `completed_at`, `canceled_at`, `raw_json`, `synced_at`, `is_deleted` |
| `linear_comments` | (`account_id`, `id`) | `issue_id`, `issue_key`, `author_id`, `author_display_name`, `body_text`, `mentioned_user_ids` (JSON), `created_at`, `updated_at`, `synced_at` |
| `linear_issue_history` | (`account_id`, `id`, `field`) | `issue_id`, `field` (status/assignee), `from_value`, `from_string`, `to_value`, `to_string`, `actor_id`, `actor_display_name`, `changed_at` |
| `linear_cycles` | (`account_id`, `id`) | `team_id`, `number`, `name`, `starts_at`, `ends_at`, `completed_at`, `progress` |
| `linear_projects` | (`account_id`, `id`) | `name`, `state`, `progress`, `target_date`, `lead_id`, `url` |
| `linear_relations` | (`account_id`, `id`) | `issue_id`, `related_issue_id`, `type` (blocks/related/duplicate) |
| `linear_user_map` | `linear_user_id` | `email`, `slack_user_id`, `display_name`, `match_method`, `match_confidence`, `resolved_at` |

Indexes mirror the Jira ones that consumers rely on (`assignee_id`,
`assignee_slack_id`+`status_category`, `status_category`, `cycle_id`,
`project_id`, `updated_at`, `due_date`, `synced_at`, `key`).
`status_category` and `state_changed_at` are written by the connector so the
view stays a plain projection.

Mapping (written by the connector, tested on both sides, §7):
`triage`/`backlog`/`unstarted` → `todo`, `started` → `in_progress`,
`completed`/`canceled` → `done`. Priority 1 Urgent, 2 High, 3 Medium, 4 Low,
0 none.

### 4.2 Neutral views

Every view carries `tracker` and `account_id`. Filtering on `is_deleted = 0`
stays with the reader, as today.

- **`tracker_issues`**: `tracker`, `account_id`, `issue_id`, `key`,
  `project_key` (Jira project / Linear team key), `title`, `description_text`,
  `status`, `status_category`, `status_changed_at`, `assignee_id`,
  `assignee_email`, `assignee_display_name`, `assignee_slack_id`,
  `reporter_id`, `reporter_display_name`, `reporter_slack_id`, `priority`
  (name), `priority_rank` (1 highest … 5 lowest, 0 none — Jira's names and
  Linear's numbers both map onto it), `points`, `due_date`, `iteration_id`,
  `iteration_name`, `container_kind` (`epic`/`project`), `container_id`,
  `container_name`, `parent_key`, `labels`, `is_bug`, `is_blocked`, `url`,
  `created_at`, `updated_at`, `resolved_at`, `synced_at`, `is_deleted`.
  `is_blocked` is Jira's status-name rule (`LOWER(status) LIKE '%block%'`) or,
  for Linear, an incoming `blocks` relation from an issue that is not `done`.
- **`tracker_comments`**: `tracker`, `account_id`, `id`, `issue_key`,
  `author_id`, `author_display_name`, `body_text`, `mentioned_ids` (NULL for
  Jira), `created_at`, `updated_at`, `synced_at`.
- **`tracker_history`**: status and assignee changes from
  `jira_issue_changelog` and `linear_issue_history`.
- **`tracker_iterations`**: `jira_sprints` and `linear_cycles` — `id`, `name`
  (`Cycle N` when a cycle has none), `state` (active/future/closed), dates,
  `project_key`.
- **`tracker_people`**: `jira_user_map` ∪ `linear_user_map` — `tracker`,
  `user_id`, `email`, `slack_user_id`, `display_name`.
- **`tracker_accounts`**: enabled, non-removed accounts of both kinds, for
  labels and site/workspace links.

Each hot consumer query gets an `EXPLAIN QUERY PLAN` test that pins index use
through the compound view (the `TestOwnJiraComments_QueryUsesIndex` pattern),
so a view that stops pushing a filter down fails a test instead of slowing the
daemon.

### 4.3 `issue_slack_links` (ask #161)

`jira_slack_links` is replaced by `issue_slack_links` with a `tracker` column;
the migration copies the rows as `tracker='jira'` and drops the old table. The
same partial unique indexes per `link_type` (mention/track/decision) gain
`tracker`. The key detector (`internal/jira/key_detector.go`, moved to a
tracker-neutral package next to `internal/jirakey`) matches a key when its
prefix is a known Jira project key **or** a known Linear team key; a prefix
known to both writes one link per tracker. Readers (`GetJiraIssuesFor*`, Swift
`JiraQueries`, `db/tracks.go`, `slack_purge.go`) move to the new table.

### 4.4 Enum CHECKs

`linear` is added via the table-recreation dance to
`targets.source_type`, `day_plan_items.source_type` and
`inbox_items.trigger_type` (`linear_assigned`, `linear_comment_mention`).

## 5. Error handling

- Sync: per-team `last_error`, watermark held; account-level auth failure →
  `revoked` and a Settings banner; the ideas floor holds back on a failing
  team (the `OldestFailingJiraProjectSync` rule, extended).
- Consumers: a read error from a `tracker_*` view behaves exactly as the Jira
  read error did (INBOX-09 freezes the watermark; briefing/day plan fail the
  section, not the run).
- Writes: a failed mutation leaves the action `failed` with Linear's error
  message; a timeout with an unknown outcome follows the agent-actions
  executing-claim rules (never re-applied blindly).

## 6. Consumers moved to `tracker_*`

| Consumer | Change |
|---|---|
| briefing (`internal/briefing/jira.go`) | assigned, reported-by-me, stale, overdue, blocked from `tracker_issues`; iteration progress from `tracker_iterations`; ordering by `priority_rank` |
| day plan (`internal/dayplan/gather.go`) | open assigned issues from `tracker_issues`; items carry `source_type` `jira` or `linear` |
| inbox (`internal/inbox/jira_detector.go`) | assigned + comment mentions over `tracker_*`; mention predicate per tracker (`[~id]` in `body_text` for Jira, `mentioned_ids` for Linear); own-comment suppression and auto-resolve (INBOX-02) and watermark freezing (INBOX-09) unchanged |
| targets | `CreateTargetFromIssue`, status sync for `source_type IN ('jira','linear')`, resolver enrichment |
| memory | mechanical ingest per Linear account with its own watermark; provenance scheme `linear:<KEY>` registered in the MEM-12 registry, resolving `previous_keys` too; project-key seeds include Linear team keys |
| ideas | a Linear stream per account with its own floor (IDEA-01 floor honesty); Linear comments feed the same comment digest |
| Catch-Up | renders the Linear stream next to the Jira one (stream name only) |
| KB search | a Linear work source with anchors `linear:<account>:<key>` (KB-03) |
| tracks / digest | ticket keys and links via the neutral detector and `issue_slack_links` |
| meeting prep, people cards (`internal/guide`) | assignee load and delivery stats from `tracker_issues` |
| `get_task_context`, `find_experts` | issues, comments and links from `tracker_*` |
| NL→SQL schema (`internal/ai/prompt.go`) | documents the `tracker_*` views |
| agent read tools | `list_issues`, `get_issue`, `get_issue_history`, `list_iterations`; Jira tools stay |
| reaction commands | create an issue on the tracker the channel's keys belong to; available projects/teams from both |
| automations | capability scopes for the neutral tools (project or team key), AUTO-01 manifest rules |
| Desktop | `TrackerIssue` GRDB model over `tracker_issues`; blocker map, iteration progress, project/epic progress and chat mention search read the views; Settings → Linear accounts and teams; Releases stays Jira-only on `jira_issues` |

## 7. Testing

- `internal/linear`: an `httptest` GraphQL fake for login (PKCE), token
  rotation (atomic save, replay window, `invalid_grant` → revoked), revoke,
  paging, `RATELIMITED` back-off without watermark advance, team moves
  (`previous_keys`), deletion.
- Views: tests over mixed Jira + Linear rows for each view; `EXPLAIN QUERY
  PLAN` pins for hot queries.
- Dual path Go ↔ Swift: the state-type → `status_category` and priority →
  `priority_rank` tables tested on both sides with the same cases.
- Each moved consumer keeps its Jira tests green unmodified and gains a Linear
  case.
- Inventory: a new `docs/inventory/linear.md` with guard tests
  `TestLinear01_…` onward — watermark held on any error; token pair saved
  atomically before use; auth failure → `revoked`, never deleted; writes only
  through propose/apply. OWNER-01, INBOX-02/09, MEM-12, IDEA-01, AUTO-01 and
  KB-03 guards are **extended** with Linear cases, never relaxed.

## 8. Inventory contracts touched

| Contract | Change | Approval |
|---|---|---|
| OWNER-01 | Linear rung in `ResolveOwner`; `Owner` gains tracker identities | ask #162 |
| INBOX-02/09 | same guarantees for Linear items | extension only |
| MEM-12 | `linear:` provenance scheme registered | extension only |
| IDEA-01 | Linear stream floor | extension only |
| AUTO-01 | scopes for the neutral tools | extension only |
| KB-03 | Linear anchors open and anchor | extension only |
| EXT-04 | the neutral key detector still imports no AI or sync-engine packages | unchanged |

## 9. Phases

1. **P1 Schema** — `linear_*`, `tracker_*` views, `issue_slack_links`, CHECKs.
   Jira behaviour unchanged (golden + existing tests).
2. **P2 Connector** — auth, accounts CLI (`watchtower linear login|accounts|
   sync`), `phaseLinearSync`, user map, OWNER-01 rung.
3. **P3 Consumers** — one consumer per task, in the order of §6.
4. **P4 Writes** — neutral write tools, reaction commands, automation scopes.
5. **P5 Desktop** — Settings, Goals → Connect, readiness, `TrackerIssue`
   screens, mention search.
6. **P6 (deferred, own spec)** — workload, discussions without a ticket,
   releases/milestones.

## 10. Open risks

- **View performance**: SQLite pushes `WHERE` into `UNION ALL` branches in most
  cases, but not through every aggregate or `LIMIT`; the query-plan pins catch
  regressions, and a hot query may read the two tables directly behind the Go
  API if a plan cannot be fixed.
- **Key collisions**: a Linear team key equal to a Jira project key makes a
  bare `ABC-12` ambiguous; links are written per tracker and readers that need
  one issue go through the existing unambiguous-match rule.
- **OAuth app registration**: a Linear OAuth app with the loopback redirect
  must be registered before P2 can be tested end to end.
