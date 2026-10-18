# Linear Tools (API key, reads, writes) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Linear works like Jira for the chat and automations: API-key login, `*_linear_*` read and write tools, and the `linear` automation capability.

**Architecture:** The connector (`internal/linear`) gains API-key auth, two small mirrors (workflow states, labels) and GraphQL mutations. `internal/tools` gets Linear read tools over the `linear_*` tables and Linear write tools that copy the Jira write pattern (Validate → Normalize pins ids → Execute through a client factory, then refreshes the mirror). `internal/automations` maps them to a `linear` capability scoped by team key.

**Tech Stack:** Go 1.26, SQLite (`modernc.org/sqlite`, goose migrations), Linear GraphQL API, SwiftUI (two catalog twins).

**Spec:** `docs/superpowers/specs/2026-10-18-linear-automation-tools-design.md`

## Global Constraints

- Tool names exactly: `list_linear_teams`, `list_linear_issues`, `get_linear_issue`, `get_linear_status_history`, `list_linear_cycles`, `create_linear_issue`, `add_linear_comment`, `transition_linear_issue`, `assign_linear_issue`, `update_linear_issue`.
- Write tools: `Access: AccessWrite`, `External: true`, `Surfaces: {"main", "target", AutomationSurface}`. Every write arg struct has `account_id,omitempty` and `reason`.
- Jira tools, names and surfaces unchanged.
- The API key is never in argv, a log, the database or a tool result. Token file `<workspace>/linear_token_<id>.json`, 0600, `token_type: "api_key"`.
- API-key requests send `Authorization: <key>` (no `Bearer`) and never refresh; OAuth unchanged (LINEAR-02).
- Issue key regex `^[A-Z][A-Z0-9]*-\d+$`; keys resolve by `key`, then `previous_keys`.
- Priority names: `none`=0, `urgent`=1, `high`=2, `medium`/`normal`=3, `low`=4.
- Capability: `"linear": {verbs: readWrite, scope: scopeRequired, upperScope: true}`; issue tools scope = the issue's **current** `team_key` (prefix when not mirrored).
- Unknown labels are refused, never created. `update_linear_issue` needs ≥ 1 field; a label in both add and remove is refused.
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, `make lint-swift` for Swift); full gate once at the end (CLAUDE.md).

## Review Focus

- A key that exists on two connected Linear workspaces → `ValidationError` asking for `account_id`, never a silent pick (Task 5 test `TestLinearIssueTarget_AmbiguousKey`).
- An issue moved to another team (old key in `previous_keys`) → the tools find it, and an automation grant for the old team does not cover it (Task 4 `TestLinearScope_MovedIssueUsesCurrentTeam`).
- A state or label created in Linear after the last sync → resolved by the one live refetch, not refused (Task 5 `TestResolveLinearState_LiveRefetchOnMiss`).
- The pinned account removed or disabled between propose and apply → apply fails, nothing sent (Task 5 `TestLinearWrite_PinnedAccountDisabledAtApply`).
- An API key pasted with a trailing newline or spaces → trimmed; an empty line → refused before any network call (Task 2 `TestLinearAdd_APIKeyTrimmedAndEmptyRefused`).

---

### Task 1: API-key auth in the Linear client

**Depends on:** none

**Files:**
- Modify: `internal/linear/token_store.go`, `internal/linear/client.go`
- Test: `internal/linear/client_test.go`

**Interfaces:**
- Produces: `const linear.TokenTypeAPIKey = "api_key"`; `func linear.APIKeyToken(key string) *Token` (trims; `TokenType: TokenTypeAPIKey`, no refresh/expiry); `func (t *Token) IsAPIKey() bool`.

- [ ] **Step 1: Failing tests**
  - `TestClient_APIKeySendsBareAuthorization`: store `APIKeyToken("lin_api_x")`, fake server records the header → `Authorization == "lin_api_x"`.
  - `TestClient_APIKeyNeverRefreshes`: `IsExpired()` would be true for an empty Expiry; assert no request hits the token endpoint and the call succeeds.
  - `TestClient_APIKey401IsAuthRevoked`: server answers 401 → `errors.Is(err, ErrAuthRevoked)`, token endpoint never called.
  - `TestTokenStore_APIKeyRoundTrip`: Save/Load keeps `token_type == "api_key"`, file mode 0600.
- [ ] **Step 2:** `go test ./internal/linear -run 'APIKey'` → FAIL.
- [ ] **Step 3:** In `getAccessToken` return the key as-is for an API-key token (skip expiry/refresh); in `send` set the header without `Bearer` when the token in use is an API key (pass the kind alongside the access string); on an auth failure with an API key return `ErrAuthRevoked` without `refreshIfCurrent`.
- [ ] **Step 4:** `go test ./internal/linear` → PASS.
- [ ] **Step 5:** Commit `feat(linear): API-key tokens — bare Authorization, no refresh (#694)`.

### Task 2: `linear add|login --api-key` and the `auth` column

**Depends on:** Task 1

**Files:**
- Modify: `cmd/linear.go`
- Test: `cmd/linear_test.go`

**Interfaces:**
- Consumes: `linear.APIKeyToken`, `Token.IsAPIKey`.
- Consumes also: the existing `readPassword(cmd *cobra.Command) (string, error)` (`cmd/imap.go:233`, echo off on a TTY, one line from a pipe) — reuse it, no new reader.
- Produces: `linearAccountJSON` gains `Auth string` with JSON key `auth`.

- [ ] **Step 1: Failing tests**
  - `TestLinearAdd_APIKeyFromStdin`: stdin `"lin_api_x\n"`, fake viewer server → account created, token file `token_type == "api_key"`, the key absent from stdout/stderr.
  - `TestLinearAdd_APIKeyTrimmedAndEmptyRefused`: `"  lin_api_x \n"` stored trimmed; `"\n"` → error "empty API key", no HTTP request, no account row.
  - `TestLinearLogin_APIKeyWrongWorkspaceRefused`: viewer org differs from the account's `org_id` → error, old token file unchanged.
  - `TestLinearAccounts_JSONAuth`: one OAuth and one API-key account → `auth` = `"oauth"` / `"api_key"`; a missing token file → `""`.
  - `TestLinearRemove_APIKeySkipsRevoke`: remove deletes the file, no revoke request, prints that the key is revoked in Linear's settings.
- [ ] **Step 2:** `go test ./cmd -run 'TestLinear(Add|Login|Accounts|Remove)_'` → FAIL.
- [ ] **Step 3:** Register `--api-key` (bool) on `linearAddCmd` and `linearLoginCmd`. With it, `runLinearAdd`/`runLinearLogin` build the token with `readPassword` + `APIKeyToken` (prompt text "Linear API key: ") and then reuse `connectLinearAccount` / `relinkLinearAccount` unchanged (no OAuth config needed: skip `linearLoginConfig()` on this path). `revokeAndDeleteLinearToken` skips `linear.Revoke` for an API key. `printLinearAccounts` reads each account's token file kind.
- [ ] **Step 4:** `go test ./cmd -run 'TestLinear'` → PASS.
- [ ] **Step 5:** Commit `feat(linear): add/login --api-key from stdin; accounts show auth (#694)`.

### Task 3: Mirrors for workflow states and labels; live fetches and mutations

**Depends on:** Task 1 (client only for compile order; can run parallel otherwise)

**Files:**
- Create: `internal/db/migrations/00142_linear_states_labels.sql`
- Modify: `internal/db/schema.sql`, `internal/db/linear.go`, `internal/db/db_test.go` (`TestAllTablesExist`), `internal/linear/queries.go`, `internal/linear/syncer.go`
- Create: `internal/linear/mutations.go`
- Test: `internal/db/linear_test.go`, `internal/linear/syncer_test.go`, `internal/linear/mutations_test.go`
- Regenerate: schema golden + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`)

**Interfaces:**
- Tables: `linear_workflow_states(account_id, team_id, id, name, type, position REAL, PK(account_id,id))`, `linear_labels(account_id, id, team_id DEFAULT '' /* '' = workspace label */, name, PK(account_id,id))`, both `REFERENCES linear_accounts(id) ON DELETE CASCADE`.
- db: `type LinearWorkflowState struct{AccountID int64; TeamID, ID, Name, Type string; Position float64}`; `type LinearLabel struct{AccountID int64; ID, TeamID, Name string}`; `ReplaceLinearTeamStates(accountID int64, teamID string, s []LinearWorkflowState) error`; `ReplaceLinearLabels(accountID int64, teamID string, l []LinearLabel) error` (teamID `""` replaces workspace labels); `ListLinearTeamStates(accountID int64, teamID string) ([]LinearWorkflowState, error)` ordered by `position, name`; `ListLinearLabels(accountID int64, teamID string) ([]LinearLabel, error)` = team's + workspace labels.
- linear (exported, on `*Client`): `FetchTeamStates(ctx, teamID string) ([]WorkflowState, error)`, `FetchLabels(ctx, teamID string) ([]Label, error)` (team + workspace), `FetchUsers(ctx) ([]User, error)`, `CreateIssue(ctx, IssueCreateInput) (IssueRef, error)`, `UpdateIssue(ctx, issueID string, IssueUpdateInput) error`, `CreateComment(ctx, issueID, body string) (string, error)`.
- Types: `WorkflowState{ID, Name, Type string; Position float64}`, `Label{ID, Name, TeamID string}`, `User{ID, Name, DisplayName, Email string}`, `IssueRef{ID, Identifier, URL string}`, `IssueCreateInput{TeamID, Title, Description, StateID, AssigneeID string; Priority *int; LabelIDs []string}`, `IssueUpdateInput{Title, StateID, DueDate *string; AssigneeID *string /* "" → null (unassign) */; Priority *int; Estimate *float64; AddedLabelIDs, RemovedLabelIDs []string}`.
- Syncer: `func (s *Syncer) RefreshIssue(ctx context.Context, issueID string) error` — fetches one issue with the sync's issue query (`filter: {id: {eq: issueID}}`) and its comments, stores them through `storeIssue`/the comment upsert; touches no watermark.

- [ ] **Step 1: Failing tests**
  - db `TestLinearTeamStates_ReplaceAndOrder`, `TestLinearLabels_TeamPlusWorkspace`, `TestAllTablesExist` (two new names).
  - syncer `TestSyncer_MirrorsStatesAndLabelsForSelectedTeams` (a deselected team's states not fetched), `TestSyncer_RefreshIssueNoWatermark` (`linear_sync_state` and `moved_watermark` unchanged after `RefreshIssue`).
  - mutations `TestCreateIssue_SendsInput`, `TestUpdateIssue_UnassignSendsNull`, `TestUpdateIssue_LabelDiff` (`addedLabelIds`/`removedLabelIds`), `TestCreateComment_ReturnsID`, `TestMutation_SuccessFalseIsError` (Linear's `success: false`).
- [ ] **Step 2:** `go test ./internal/db ./internal/linear` → FAIL.
- [ ] **Step 3:** Migration + `schema.sql`; db functions; queries `team(id){states{nodes{id name type position}}}`, `issueLabels(filter:{or:[{team:{id:{eq:$team}}},{team:{null:true}}]})`; syncer refreshes states and labels per selected team inside `syncPlanning` (an error there fails the team like a planning error does); mutations `issueCreate`, `issueUpdate`, `commentCreate` returning `issue { id identifier url }` / `comment { id }`.
- [ ] **Step 4:** Regenerate golden + Swift schema; `go test ./internal/db ./internal/linear` → PASS.
- [ ] **Step 5:** Commit `feat(linear): mirror workflow states and labels; issue/comment mutations (#694)`.

### Task 4: Read tools and the `linear` capability

**Depends on:** Task 3

**Files:**
- Create: `internal/tools/linear_read.go`
- Modify: `internal/tools/readtools.go`, `internal/tools/automation_reads.go`, `internal/db/linear.go`, `internal/automations/manifest.go`, `internal/automations/capabilities.go`, `internal/mcp/server_test.go` (`TestToolsList`, `readOnlyGuardCalls`)
- Test: `internal/tools/linear_read_test.go`, `internal/automations/capabilities_test.go`

**Interfaces:**
- db: `type LinearIssueFilter struct{TeamKey, StateName, StateType, Assignee, CreatedAfter string; Limit int}` (Assignee: `me` resolved by the tool to owner ids, or email, or Linear user id); `ListLinearIssues(f LinearIssueFilter) ([]LinearIssue, error)` (not deleted, `created_at DESC`); `ListLinearComments(accountID int64, issueID string)`; `ListLinearHistory(accountID int64, issueIDs []string)`; `ListLinearCycles(accountID int64, teamID string)`.
- tools: `NewListLinearTeams()`, `NewListLinearIssues()`, `NewGetLinearIssue()`, `NewGetLinearStatusHistory()` added to `ReadTools()` after the Jira reads; `NewListLinearCycles()` added to `AutomationReadTools()` after `NewListJiraReleases()`. No `Surfaces` (as the Jira reads).
- tools: `func linearIssuesByKey(d *db.DB, accountID int64, rawKey string) (db.LinearIssue, error)` — shared with Task 5; regex check, `GetLinearIssueByKey`, filter to enabled non-removed accounts, `account_id` narrows, several → `ValidationError` naming `account_id` and `list_linear_teams`.
- automations: `capabilitySpecs["linear"]`; `ToolCapabilities` rows for all ten tools; `func linearIssueScope(ctx, d, args) ([]CallScope, error)` = current `team_key` of the resolved issue, else the key's prefix.

- [ ] **Step 1: Failing tests**
  - `TestListLinearIssues_Filters`: seeded issues → `state_type: "triage"` keeps only triage; `created_after: "2026-10-17"` compares `created_at` as UTC; newest first; deleted excluded; description clipped at 512 bytes with `description_truncated`.
  - `TestListLinearIssues_AssigneeMe`: `me` matches `linear_accounts.owner_user_id`.
  - `TestGetLinearIssue_PreviousKeyAndComments`: lookup by an old key returns the issue with comments oldest→newest.
  - `TestLinearIssueTarget_AmbiguousKey` (two accounts, same key, no `account_id` → ValidationError mentions `account_id`).
  - `TestListLinearTeams_StatesAndLabels`, `TestGetLinearStatusHistory_MaxKeys` (21 keys → ValidationError), `TestListLinearCycles_DerivedState`.
  - `TestLinearScope_MovedIssueUsesCurrentTeam`: issue now in team `NEW`, called by old key `OLD-1` → scope `NEW`; unmirrored `ABC-9` → `ABC`.
  - `TestManifest_LinearCapability`: `linear:read@eng` parses as `ENG`; `linear:read` without scope refused.
  - `TestToolsList` and `readOnlyGuardCalls` updated with the four `ReadTools` additions (DEV-01 read-only guard covers them).
- [ ] **Step 2:** `go test ./internal/tools ./internal/automations ./internal/mcp -run 'Linear|ToolsList|NoToolMutates'` → FAIL.
- [ ] **Step 3:** Implement as the Jira reads in `jira_read.go`/`jira_history.go` (lean rows, `ClampListLimit` applies through the `limit` property).
- [ ] **Step 4:** Same command → PASS; `go test ./internal/tools ./internal/automations ./internal/mcp`.
- [ ] **Step 5:** Commit `feat(tools): Linear read tools and the linear automation capability (#694)`.

### Task 5: Write tools

**Depends on:** Tasks 3, 4

**Files:**
- Create: `internal/tools/linear_write.go`
- Modify: `cmd/actions_registry.go`, `cmd/actions_registry_test.go` (`automationWriteSurfaces`), chat contract goldens under `internal/chat/testdata/` (regenerate with the package's `-update` flag)
- Test: `internal/tools/linear_write_test.go`, `cmd/actions_registry_test.go`

**Interfaces:**
- Consumes: `linearIssuesByKey` (Task 4), the Task 3 client methods and db lists.
- Produces:
  ```go
  type LinearWriteClient interface {
      FetchTeamStates(ctx context.Context, teamID string) ([]linear.WorkflowState, error)
      FetchLabels(ctx context.Context, teamID string) ([]linear.Label, error)
      FetchUsers(ctx context.Context) ([]linear.User, error)
      CreateIssue(ctx context.Context, in linear.IssueCreateInput) (linear.IssueRef, error)
      UpdateIssue(ctx context.Context, issueID string, in linear.IssueUpdateInput) error
      CreateComment(ctx context.Context, issueID, body string) (string, error)
      RefreshIssue(ctx context.Context, issueID string) error
  }
  type LinearWriteClientFactory func(account db.LinearAccount) (LinearWriteClient, error)
  func LinearWriteTools(f LinearWriteClientFactory) []*Tool // create, comment, transition, assign, update
  ```
- cmd: `linearWriteClientFactory(cfg)` composes `linearClient(cfg, id)` with a `linear.NewSyncer` for `RefreshIssue`; registered in `buildToolRegistry` right after the Jira write tools.
- Pinned arg keys written by Normalize: `account_id`, `key` (canonical), `issue_id`, `team_id`, `state_id`, `assignee_id`, `label_ids_add`, `label_ids_remove`, `label_ids` (create), `priority_value`; schema descriptions say "do not set; filled in automatically" (the `resolved_assignee_account_id` precedent).
- Resolution helpers: `resolveLinearState(ctx, d, c, acct, teamID, name, stateType string) (linear.WorkflowState, error)` (mirror first, one live `FetchTeamStates` on a miss; `state_type` picks the lowest position; a miss lists the team's states), `resolveLinearLabels(...)`, `resolveLinearAssignee(...)` (`me` = `owner_user_id`; `none` = unassign; email or exact display name via `linear_user_map`, then one live `FetchUsers`; ambiguous → ValidationError with candidates), `linearPriority(name string) (int, error)`.

- [ ] **Step 1: Failing tests** (fake `LinearWriteClient`, seeded DB)
  - `TestCreateLinearIssue_PinsAndCreates`: Normalize writes `team_id`, `label_ids`, `priority_value`; Execute calls `CreateIssue` with them and returns the url; unknown label → ValidationError listing the team's labels.
  - `TestAddLinearComment_BodyRules` (empty, > 32000 runes refused), `TestAddLinearComment_RefreshesMirror` (`RefreshIssue` called with `issue_id`; its error does not fail the write, result notes the next sync).
  - `TestTransitionLinearIssue_ByNameAndType`: `state: "in review"` case-insensitive; `state_type: "started"` → lowest position; both or neither → ValidationError.
  - `TestResolveLinearState_LiveRefetchOnMiss`: name absent from mirror, present in `FetchTeamStates` → resolved; absent from both → ValidationError listing states.
  - `TestAssignLinearIssue_MeNoneAmbiguous`.
  - `TestUpdateLinearIssue_Rules`: no fields → refused; label in add and remove → refused; `priority: "normal"` → 3; estimate passed through.
  - `TestLinearWrite_PinnedAccountDisabledAtApply`: account disabled after Normalize → Execute errors, fake client saw no call.
  - `TestLinearWrite_RevokedMarksAccount`: client returns `linear.ErrAuthRevoked` → account `status = 'revoked'`.
  - `cmd`: `automationWriteSurfaces` gains the five tools with `{"main", "target", tools.AutomationSurface}`.
- [ ] **Step 2:** `go test ./internal/tools -run 'Linear'` and `go test ./cmd -run 'TestBuildToolRegistry|AutomationWrite'` → FAIL.
- [ ] **Step 3:** Implement following `jira_write.go` (`decodeStrict`, `mergeJSON`, `mustWriteSchema`, a `linearWriteFailed` twin of `jiraWriteFailed` using `SetLinearAccountAuthState`).
- [ ] **Step 4:** Regenerate the chat contract goldens; `go test ./internal/tools ./internal/chat ./internal/automations` and `go test ./cmd -run 'Registry|Automation|Actions'` → PASS.
- [ ] **Step 5:** Commit `feat(tools): Linear write tools mirroring the Jira writes (#694)`.

### Task 6: Desktop twins

**Depends on:** Task 5 (names only)

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatToolCatalog.swift`, `ChatToolCatalog+Actions.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationCardPresentation.swift`
- Test: `WatchtowerDesktop/Tests/Core/ChatToolCatalogTests.swift`, `ChatToolCatalogActionsTests.swift`, `AutomationCardPresentationTests.swift`

**Interfaces:**
- Entries for the ten tools, wording = the Jira entry with "Linear" (e.g. `get_linear_issue`: "Opened {}" / "Opened a Linear issue", key `key`); action titles/icons as the Jira twins; `"linear": Source(name: "Linear", noun: "issues", all: "all teams", write: "Change issues in")`.

- [ ] **Step 1:** Tests: each new tool name has a catalog entry and an action title; `linear:write@ENG` renders "Change issues in ENG".
- [ ] **Step 2:** `make test-swift FILTER='ChatToolCatalogTests|ChatToolCatalogActionsTests|AutomationCardPresentationTests'` → FAIL.
- [ ] **Step 3:** Add the entries.
- [ ] **Step 4:** Same command → PASS; `make lint-swift`.
- [ ] **Step 5:** Commit `feat(desktop): catalog entries for the Linear tools (#694)`.

### Task 7: Contracts, feature notes, guide

**Depends on:** Tasks 1–6

**Files:**
- Modify: `docs/inventory/linear.md` (LINEAR-02 note: API keys never refresh; LINEAR-03 covers key auth failures; guard test names from Tasks 1, 5), `docs/inventory/agent-actions.md` (AGENT-03: five Linear writes External), `docs/inventory/automations.md` (AUTO-01: `linear` capability), `docs/features/linear.md` (API key, tools, mirrors, v1 limits), `docs/features/automations.md` (capability line in the grammar and the read/write tool lists), `docs/guide/` Linear and Automations pages per `docs/guide/WRITING.md`, `CLAUDE.md` Linear bullet (one clause).

- [ ] **Step 1:** Write the docs; every guard test named exists (`grep` each name in the tree).
- [ ] **Step 2:** Commit `docs(linear): API key, Linear tools and capability (#694)`.

### Gate (controller, once)

- [ ] `bash scripts/dev-health.sh`; then `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...` — all green; then local-review → PR into `main`.
