# Linear reaction commands — plan (lane 3, board #690)

**Spec:** `docs/superpowers/specs/2026-10-15-linear-integration-design.md` §6 row
"reaction commands" (P4). No migration. Contracts: `docs/inventory/reaction-commands.md`
(REACT-01..05 unchanged; REACT-04 gains a Linear guard), `docs/inventory/agent-actions.md`
(AGENT-01/03: Linear create stays a pending proposal).

## Behaviour

An "issue" reaction — an emoji the dictionary maps to `create_jira_issue` or
`create_linear_issue` — is routed to a tracker before compose:

1. Collect the issue keys (`ABC-12`) in the reacted message, its thread context
   and the channel's 200 most recent synced messages.
2. A key prefix is a **Jira** key when it is a synced Jira project
   (`jira_sync_state`) or a mirrored issue's project (`jira_issues.project_key`);
   a **Linear** key when it is a team key of an enabled Linear account
   (`linear_teams.key`). A prefix that is both counts for neither (collision).
3. Route: only Jira keys → `create_jira_issue`; only Linear keys →
   `create_linear_issue`; **both** (ambiguous channel) → the dictionary's own tool
   (the owner's explicit choice), logged; **none** → the dictionary's tool, except
   when exactly one tracker is connected (a Linear-only install's `:ticket:` files
   in Linear). A Jira-only install never routes anywhere new.
4. A routed tool missing from the registry or the reaction surface falls back to
   the dictionary's tool; a DB error in routing falls back too (logged, never a
   skip: routing is a refinement, not a gate).

Compose then uses the routed tool's argument guide and grounding: Jira projects
for Jira (unchanged), selected Linear team keys of enabled accounts for Linear
(`KEY (account_id N)` when a key exists on several workspaces).

## Tasks

1. `internal/db/tracker_reaction.go` (own file; not `tracker.go`, not
   `jira_slack_links`): `ReactionTrackerPrefixes()`, `RecentChannelTexts()`,
   `ListReactionLinearTeams()` + tests.
2. `internal/reactioncmd/route.go`: pure `routeIssueTool` + key scan; wire into
   `resolveTool`/`compose`; `argGuide("create_linear_issue")`; Linear teams in the
   compose message. Tests: Linear-only channel, Jira-only channel (unchanged), mixed
   channel (explicit fallback), collision key, no keys + one/two trackers, routed
   tool off the surface, Linear proposal stays pending (REACT-04).
3. `create_linear_issue` gains the `reaction` surface; pin in
   `cmd/actions_registry_test.go` and `internal/tools/linear_write_test.go`.
4. Docs: `docs/features/reaction-commands.md`, `docs/features/linear.md`,
   `docs/inventory/reaction-commands.md` changelog, guide page.

## Seams

- Lane 2 moves `jira_slack_links` → `issue_slack_links` and the key detector; this
  lane reads neither (own regex + prefix tables), so the two do not collide. A
  follow-up may switch the scan to the neutral detector.
- Lane 4: `ReactionDictionaryTools.all` (Swift) does not offer `create_linear_issue`
  yet.
