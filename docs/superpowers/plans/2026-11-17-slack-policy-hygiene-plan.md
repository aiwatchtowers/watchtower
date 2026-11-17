# Slack Developer Policy Hygiene Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the Slack Developer Policy gaps for company mode: purge on by default with per-account rules and verified deletion, 17 scopes from one manifest, people cards and `find_experts` without surveillance, LLM provider disclosure, the FileVault line, and the privacy policy text.

**Architecture:** Go owns the rules (`internal/purge`, `internal/auth` + a new `internal/slackmanifest`, `internal/guide`, `internal/tools`); the Desktop reads them through the CLI and WatchtowerCore models whose strings are pinned by tests. One migration adds the people exclusions table and clears the dropped people fields. The site's privacy policy is not edited here: a task produces the exact text change as a file for the owner.

**Tech Stack:** Go 1.26 (SQLCipher `database/sql`, goose migrations, cobra), SwiftUI + GRDB (WatchtowerDesktop, WatchtowerCore, DesignKit), XCTest, DesignShotCatalog.

**Spec:** `docs/superpowers/specs/2026-11-17-slack-policy-hygiene-design.md` (approved, ask #1419; decisions P1–P10 asks #1412, A1–A20 ask #1412, A21–A24 ask #1416). Mockups: `docs/design/mockups/slack-policy-hygiene/` (fixtures `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+SlackPolicy.swift`, strings `SlackPolicyMockCopy`).

## Global Constraints

- Grace is 72 h (`purge.Grace`), the lease 30 days (`purge.Lease`); every due date is at least 72 h after the pass that schedules it (PURGE-01, unchanged).
- `purge.Enabled` falls back to **on** with origin `default`, in every build and for every source (P7, A1). With origin `default` the 30-day lease of **live** accounts is held; revoked accounts (72 h) and removed accounts run.
- A removed **Slack** account has a zero lease (reason `lease`, no CHECK change, no migration): due 72 h after the first pass after the remove (A2). Other removed accounts keep the 30-day removed lease.
- A policy-forbidden source keeps today's hold of its leases (POLICY-03).
- The Full app's manifest has exactly these 17 user scopes: `channels:history`, `groups:history`, `im:history`, `mpim:history`, `channels:read`, `groups:read`, `im:read`, `mpim:read`, `im:write`, `search:read`, `users:read`, `users:read.email`, `files:read`, `reactions:read`, `team:read`, `chat:write`, `emoji:read`. No bot user.
- Slack's `long_description` limit: 4,000 characters, with the connect block included.
- People cards hold no active hours, volume change, average length, stats grid, red flags, team-norm comparison, Jira+Slack compound signals or Team Summary attention list (A12); the prompt forbids health, mood, burnout, workload judgment, personal life, protected characteristics and performance verdicts (A17).
- Every UI string lives in a WatchtowerCore model pinned by a test, and must equal the matching `SlackPolicyMockCopy` string (the mock table is the spec's copy).
- Tests never wait on wall-clock time: purge timing uses an injected `now`; `fdesetup` is a stubbed runner with a 2 s timeout, reaped on cancel.
- Inventory: PURGE-01 and SLACK-01 amendments are approved (ask #1412); PURGE-02 is extended; DEV-03 and POLICY-01/02 are unchanged. No guard test is relaxed or renamed.
- Migrations: the next free number on `origin/main` at write time is **00194**; if another branch takes it first, renumber at merge (one file, no Go migration).
- Repo hygiene: sample data only (`acme`, `example.com`, made-up people).

## Review Focus

- A Mac that was off for a week and comes back to a revoked Slack token must give the full 72 h notice from its first pass, never delete at once (T1, `TestPlan_LongOfflineRevokedGetsFullNotice`).
- "Add again" of a removed workspace between the re-plan and the purge start must win and delete nothing (T1, `TestStartAccountPurge_ZeroLeaseNeedsRemovedStill`).
- The Privacy switch opened before the CLI answered must show on, not off (T3, `AccountPurgeDefaultFixtureTests`).
- A legacy token with no recorded grant and no `emoji:read` must not spam the log or fail the sync each cycle (T4, `TestSyncEmoji_MissingScopeSkipsUntilLogin`).
- An install with no resolved owner must make no people cards and say why, never fall back to everyone (T6, `TestPeopleCards_NoOwnerNoCards`).

---

### Task 1: Per-account purge rules, default on, verified deletion

**Depends on:** none

**Files:**
- Modify: `internal/purge/enabled.go` (default fallback; `Rule`, `Rules`, `Cutoff`)
- Modify: `internal/purge/schedule.go` (`Plan`, `PlanWith`, `leaseDeadlines`, cancel branch, `Apply`)
- Modify: `internal/purge/run.go` (`start`: same rules for the re-plan, per-row cutoff; verify after the last step)
- Modify: `internal/db/account_purge_steps.go` (`StartAccountPurge`; count form of each step: `PurgeLeft`)
- Modify: `internal/daemon/account_purge.go` (both passes build the rules)
- Create: `internal/purge/testdata/default_cases.json`
- Test: `internal/purge/enabled_test.go`, `internal/purge/schedule_test.go`, `internal/purge/run_test.go`, `internal/db/account_purge_steps_test.go`
- Docs: `docs/inventory/account-purge.md` (PURGE-01 amendment text + new guards, PURGE-02 extension), `docs/features/revoke-purge.md` ("The switch", "Scheduling")

**Interfaces:**
- Produces:
  - `type Rule int` with `RuleNone`, `RuleRevokedAndRemoved`, `RuleFull`
  - `func Rules(on bool, origin Origin, sourceAllowed func(string) bool) func(db.PurgeAccount) Rule`
  - `func Cutoff(a db.PurgeAccount, r Rule, now time.Time) (cutoff time.Time, requireRemoved bool)` — `now − Lease` today; `now, true` for a removed Slack account
  - `func Plan(accounts []db.PurgeAccount, open []db.AccountPurge, rules func(db.PurgeAccount) Rule, now time.Time) Actions` (`PlanWith` is removed; its source hold moves into `Rules`)
  - `func (db *DB) StartAccountPurge(id int64, cutoff time.Time, requireRemoved bool) (bool, error)`
  - `func (db *DB) PurgeLeft(source string, id int64) (map[string]int64, error)` — read-only transaction, non-zero tables only
  - `internal/purge/testdata/default_cases.json`: array of `{"name","policy":null|bool,"setting":null|bool,"build":"on"|"",  "status_enabled":null|bool,"status_enabled_by":"", "shown":bool,"origin":"policy|setting|build|default"}` — read by T3 too

- [ ] **Step 1: Write the failing tests**

`TestPurge01_EnabledOrder` gains the case: no policy, no setting, `BuildDefault == ""` → `(true, OriginDefault)`.

`TestPurge01_DefaultSharedFixture`: for each case of `default_cases.json`, set the policy seam, config and `BuildDefault`, assert `Enabled(cfg)` equals `(shown, origin)` (cases with `status_*` set are Swift-only and skipped here by `status_enabled != null`).

`TestPurgeRules_Table`: one sub-test per row of spec §2 "Per-account rules":

```go
// off → RuleNone for every account
// on/default: live slack → RuleRevokedAndRemoved; removed slack → RuleRevokedAndRemoved; live google → RuleRevokedAndRemoved
// on/setting|policy|build: live → RuleFull
// sourceAllowed("jira") == false: jira accounts → RuleRevokedAndRemoved with leases held (no lease deadline)
```

`TestPlan_DefaultOriginHoldsLiveLeaseButSchedulesRemovedSlack`: accounts = live Slack with `access_ok_at` 40 days ago, removed Slack with `access_ok_at` 1 hour ago, removed Jira with `access_ok_at` 1 hour ago; rules = `Rules(true, OriginDefault, allowAll)`; assert Schedule holds exactly the removed Slack account, reason `lease`, `due_at == now + 72h`.

`TestPlan_LongOfflineRevokedGetsFullNotice`: revoked Slack account with `revoked_at` 8 days ago, no open row → scheduled `due_at == now + 72h`.

`TestRun_ZeroLeaseRowStartsAfterReplan`: a scheduled zero-lease row due now → `Run` starts and finishes it (no `ErrNoLongerDue`).

`TestStartAccountPurge_ZeroLeaseNeedsRemovedStill`: account set back to `ok` between re-plan and start (`afterReplan` hook) → `StartAccountPurge(id, now, true)` returns `false`; no rows deleted.

`TestPurgeRun_VerifyLeftRowsFails`: a step list whose last predicate still matches a row (insert one after the delete via the test hook) → row state `failed`, `error` starts with `"left: "` and names the table.

`TestPurgeRun_VerifyErrorRetries`: `PurgeLeft` errors once → counted as a chunk failure; next cycle succeeds → `done`.

`TestPolicy_DeletionWithinFourteenBusinessDays`: revoked seen Friday 17:00 UTC, passes every 60 min via injected `now`, 3,000 rows at 500 per chunk, 5-minute budget → `finished_at` minus first-seen ≤ 14 business days (and in practice ≤ 4 calendar days; assert both).

- [ ] **Step 2: Run them to verify they fail**

Run: `go test ./internal/purge ./internal/db -run 'Purge01|PurgeRules|Plan_|Run_Zero|StartAccountPurge_Zero|PurgeRun_Verify|DeletionWithin'`
Expected: FAIL (undefined `Rules`, `Cutoff`, `PurgeLeft`; `Enabled` returns false).

- [ ] **Step 3: Implement**

`Enabled` returns `true, OriginDefault` at the end. `Rules` per the table; `leaseDeadlines` takes the rules and gives no deadline to a live account under `RuleRevokedAndRemoved` or of a source `sourceAllowed` refuses, and `access_ok_at` (zero lease) to a removed Slack account under any rule but `RuleNone`. The cancel branch cancels an open row whose account's rule no longer schedules it (`RuleNone`, or a lease row whose account has no deadline). `start` builds the rules with `Rules(on, origin, policy.SourceAllowed)` passed in from `Run`, and calls `StartAccountPurge(p.ID, cutoff, requireRemoved)` from `Cutoff`. `StartAccountPurge` adds `AND status = 'removed'` to its conditional `UPDATE` when `requireRemoved`. After the last step `Run` calls `PurgeLeft`; empty → `done`; non-empty → `failed`, `error = "left: " + sorted "table=n" pairs joined by ", "`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/purge ./internal/db ./internal/daemon`
Expected: PASS, including the unchanged `TestPurge01_PolicyForbiddenSourceHoldsLease`, `TestRun_AccessBetweenReplanAndStart`, `TestStartAccountPurge_AccountMustStillQualify`.

- [ ] **Step 5: Update inventory and feature note, lint, commit**

PURGE-01: the default line and the per-account table; add guards `TestPurge01_DefaultSharedFixture`, `TestPurgeRules_Table`, `TestPlan_DefaultOriginHoldsLiveLeaseButSchedulesRemovedSlack`, `TestStartAccountPurge_ZeroLeaseNeedsRemovedStill`. PURGE-02: the verify count, guard `TestPurgeRun_VerifyLeftRowsFails`. Run `make lint-diff`.

```bash
git add internal/purge internal/db/account_purge_steps.go internal/db/account_purge_steps_test.go internal/daemon/account_purge.go docs/inventory/account-purge.md docs/features/revoke-purge.md
git commit -m "purge: on by default, per-account rules, verified deletion (#1769)"
```

### Task 2: `slack remove` revokes the token

**Depends on:** Task 1

**Files:**
- Modify: `internal/slack/client.go` (add `RevokeToken`)
- Modify: `cmd/slack.go:497-560` (`runSlackRemove`, `removeSlackAccount`)
- Test: `cmd/slack_remove_test.go` (new) or the existing remove tests in `cmd/`
- Docs: `docs/inventory/slack-accounts.md` (SLACK-01 amendment), `docs/features/slack-multi-account.md`

**Interfaces:**
- Consumes: Task 1's zero-lease rule (the purge picks the removed account up on its own).
- Produces: `func (c *Client) RevokeToken(ctx context.Context) error` (`auth.revoke` through `doRequest`, Tier 3).

- [ ] **Step 1: Write the failing tests**

`TestSlackRemove_RevokesBeforeDelete`: a fake Slack server records calls; `removeSlackAccount` → exactly one `auth.revoke` with the account's token, then the token file is gone and the row is `removed` (assert the call happened before the file delete via the fake's timestamp vs a file-stat hook).

`TestSlackRemove_RevokeFailureStillRemoves`: the fake answers 500, then `invalid_auth` (two sub-tests) → the remove succeeds, the file is gone, the row is `removed`, and the command output contains `Slack did not confirm the token was revoked; it will expire`.

The existing SLACK-01 guards stay green (data kept at once).

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./cmd -run 'TestSlackRemove_|TestSlack01'`
Expected: FAIL (no `auth.revoke` call).

- [ ] **Step 3: Implement** `RevokeToken`, and call it in `removeSlackAccount` before `NewTokenStore(...).Delete`, with a 10 s context; an error is printed (the line above) and never returned.

- [ ] **Step 4: Run to verify they pass**

Run: `go test ./cmd -run 'TestSlackRemove_|TestSlack01' ./internal/slack`
Expected: PASS

- [ ] **Step 5: SLACK-01 text** — data kept at once; with the purge on it is deleted 72 h after the remove; the token is revoked at Slack first, which also signs out every other place using that sign-in. `make lint-diff`. Commit: `slack: revoke the token on remove (#1769)`.

### Task 3: Desktop purge copy and the shared default

**Depends on:** Task 1 (`default_cases.json`)

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/AccountPurge.swift` (`AccountPurgeStatus.shownValue`, `buildDefault`, `footnote`, `caption`, `removeDialogMessage` Slack variant)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/AccountPurgeNoticePolicy.swift` (zero-lease removed line)
- Modify: `WatchtowerDesktop/Sources/Views/Settings/PrivacySettings.swift` (use `shownValue`, `footnote`, `caption`)
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SlackConnectionDetail.swift:314` (Slack variant)
- Test: `WatchtowerDesktop/Tests/Core/AccountPurgeDefaultFixtureTests.swift` (new), `WatchtowerDesktop/Tests/Core/AccountPurgeStatusCopyTests.swift` (new), `WatchtowerDesktop/Tests/Core/AccountPurgeNoticePolicyTests.swift`
- Docs: `docs/guide/concepts/revoked-access.md`, `docs/guide/concepts/privacy.md` (the switch, the defaults, mixed AI text kept — P9)

**Interfaces:**
- Consumes: `internal/purge/testdata/default_cases.json` (read from the repo path in tests, like `policy_cases.json`).
- Produces:
  - `static let buildDefault = true`
  - `static func shownValue(policy: Bool?, setting: Bool?, status: AccountPurgeStatus?) -> Bool` — `policy ?? setting ?? status?.enabled ?? buildDefault`
  - `static func footnote(_ status: AccountPurgeStatus?, shown: Bool) -> String` — `SlackPolicyMockCopy.footOff` when off, `footDefault` when on with `enabledBy` `default` or unknown status, `footOnAll` otherwise
  - `static func caption(_ status: AccountPurgeStatus?, shown: Bool) -> String?` — `"On by default"` when on and origin `default` or unknown
  - `static func removeDialogMessage(slackAccount label: String, status: Self?) -> String` — `removeBodyOn`/`removeBodyOff` with the label

- [ ] **Step 1: Write the failing tests**

`AccountPurgeDefaultFixtureTests.testSharedCases`: for each case of the fixture, `shownValue(policy:setting:status:)` (status built from `status_enabled`/`status_enabled_by`, nil when null) equals `shown`.

`AccountPurgeStatusCopyTests.testCopyMatchesMockups`: `footnote` for the three states equals `SlackPolicyMockCopy.footDefault`/`footOnAll`/`footOff`; `caption` for default equals `captionDefault`; `removeDialogMessage(slackAccount: "acme", status: on)` equals `removeBodyOn`, with `off` equals `removeBodyOff`.

`AccountPurgeNoticePolicyTests.testZeroLeaseRemovedLine`: a removed Slack account's lease row due Nov 20 14:00 → equals `SlackPolicyMockCopy.removedLine` (no "has not been reached since").

- [ ] **Step 2: Run** `make test-swift FILTER='AccountPurgeDefaultFixtureTests|AccountPurgeStatusCopyTests|AccountPurgeNoticePolicyTests'` — Expected: FAIL.

- [ ] **Step 3: Implement** the functions above; `PrivacySettings` uses `shownValue` for its binding's getter and `footnote`/`caption` for its texts; the Slack remove dialog uses the Slack variant (Jira and Linear keep today's message). Compare with `slack-ph-privacy*`, `slack-ph-slackRemoved*`, `slack-ph-removeOn/Off` shots (`make desktop-shots DESKTOP_SHOTS=<dir>`).

- [ ] **Step 4: Run** the same filter plus `make lint-swift` — Expected: PASS, no new warnings.

- [ ] **Step 5: Guide pages** (revoked-access: on by default, removed Slack after 72 h, revoke signs out everywhere; privacy: the switch in both states and that mixed AI text is kept). `go test ./docs/guide`. Commit: `desktop: purge default and copy (#1769)`.

### Task 4: One manifest, 17 scopes, emoji skip

**Depends on:** none

**Files:**
- Create: `internal/slackmanifest/manifest.go`, `internal/slackmanifest/slack-app-manifest.json` (moved from the repo root with `git mv`), `internal/slackmanifest/manifest_test.go`
- Modify: `internal/auth/oauth.go:53-65` (`UserScopes` from the manifest)
- Modify: `internal/sync/orchestrator.go:1146-1170` (`syncEmoji`)
- Test: `internal/sync/coverage_test.go` (emoji cases)
- Docs: `docs/features/slack-send.md` (manifest path), `docs/features/slack-multi-account.md` (scopes, the move)

**Interfaces:**
- Produces:
  - `func UserScopes() []string` (manifest order)
  - `func Description(connectBlock string) (string, error)` — `connectBlock` + the scope paragraph (spec §4, verbatim) + the AI paragraph (spec §6 item 1, verbatim, privacy URL `https://aiwatchtowers.com/privacy/`); error when over 4,000 characters
  - `const ShortDescription = "Your Slack on your Mac, with the AI provider you choose"`
  - `func Manifest(connectBlock string) ([]byte, error)` — the embedded JSON with `display_information.description`/`long_description` filled, for parent T7's `apps.manifest.create`/`update`
  - `auth.UserScopes = slackmanifest.UserScopes()`

- [ ] **Step 1: Write the failing tests**

`TestSlackManifest_ScopesAreTheRequestedOnes`: `UserScopes()` equals the 17 scopes of Global Constraints (set equality and length 17), and `auth.UserScopes` equals `UserScopes()`.

`TestSlackManifest_DescriptionFits`: `Description(strings.Repeat("x", 600))` succeeds and is ≤ 4,000 characters; `Description(strings.Repeat("x", 4000))` errors.

`TestSlackManifest_DescriptionDiscloses`: the text contains `Anthropic (Claude)`, `OpenAI (Codex)`, `Ollama`, `AI output can be wrong.`, `https://aiwatchtowers.com/privacy/`, and does not contain `All data stays on your machine`.

`TestSyncEmoji_RecordedGrantWithoutScopeSkips`: a token whose recorded `Scope` lacks `emoji:read` → no `emoji.list` call.

`TestSyncEmoji_MissingScopeSkipsUntilLogin`: legacy token (empty `Scope`), fake answers `missing_scope` → one call in the first cycle, none in the next two, one log line total.

- [ ] **Step 2: Run** `go test ./internal/slackmanifest ./internal/auth ./internal/sync -run 'SlackManifest|SyncEmoji'` — Expected: FAIL.

- [ ] **Step 3: Implement.** `git mv slack-app-manifest.json internal/slackmanifest/`; set its user scopes to the 17; `//go:embed slack-app-manifest.json`. `syncEmoji` checks the recorded grant first, and keeps an in-memory `emojiSkip` per orchestrator set on `missing_scope`.

- [ ] **Step 4: Run** `go test ./internal/slackmanifest ./internal/auth ./internal/sync ./cmd` — Expected: PASS.

- [ ] **Step 5:** `make lint-diff`; docs; commit `slack: one manifest, 17 scopes, emoji skip (#1769)`.

### Task 5: Remove Mark read in Slack

**Depends on:** none

**Files:**
- Delete: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SlackService.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Digests/DigestDetailView.swift` (button at ~:215-235, `markChannelRead` ~:625, its `@State`)
- Test: `WatchtowerDesktop/Tests/Core/SlackServiceRemovedTests.swift` (new)

- [ ] **Step 1: Write the failing test** `SlackServiceRemovedTests.testNoConversationsMark`: scans every `.swift` file under `WatchtowerDesktop/Sources` (path from `#filePath`) and asserts none contains `conversations.mark` or `Mark read in Slack`.
- [ ] **Step 2: Run** `make test-swift FILTER=SlackServiceRemovedTests` — Expected: FAIL.
- [ ] **Step 3: Delete** the service and the button; the header matches `slack-ph-digestHeader`.
- [ ] **Step 4: Run** the filter and `make lint-swift` — Expected: PASS.
- [ ] **Step 5: Commit** `desktop: remove Mark read in Slack (#1769)`.

### Task 6: People data — migration, exclusions, interaction partners

**Depends on:** Task 1 (purge step list file is shared)

**Files:**
- Create: `internal/db/migrations/00194_people_policy_hygiene.sql`
- Modify: `internal/db/schema.sql` (the new table), `internal/db/db_test.go` (`TestAllTablesExist`), goldens and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`)
- Create: `internal/db/people_exclusions.go`, `internal/db/people_exclusions_test.go`
- Modify: `internal/db/user_analyses.go:315` (`ComputeAllUserStats`)
- Modify: `internal/db/account_purge_steps.go` (Slack steps), `internal/db/account_purge_steps_test.go` (`purgeKeptTables` unchanged)
- Modify: `internal/guide/pipeline.go` (callers at ~:227, ~:261; skip excluded ids)
- Modify: `cmd/people.go` (`exclude`, `include` subcommands)
- Test: `internal/guide/pipeline_test.go`, `cmd/people_test.go`

**Interfaces:**
- Produces:
  - Table `people_card_exclusions(user_id TEXT PRIMARY KEY, created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')))`, namespaced `<account>:<U>` ids
  - `func (db *DB) ExcludePerson(userID string) error` — inserts and deletes the person's `people_cards` rows in one transaction
  - `func (db *DB) IncludePerson(userID string) error`
  - `func (db *DB) PeopleExclusions() (map[string]bool, error)`
  - `func (db *DB) ComputeAllUserStats(from, to float64, minMessages int, ownerID string) ([]UserStats, error)` — empty `ownerID` → empty result
  - CLI `watchtower people exclude|include --user <id> --json` → `{"ok":true,"user_id":"…","excluded":true|false}`; unknown user → non-zero exit, `user not found`

- [ ] **Step 1: Write the failing tests**

`TestMigration_PeopleSurveillanceCleared`: a DB at 00193 with one `people_cards` row (`active_hours_json='{"9":3}'`, `volume_change_pct=-40`, `avg_message_length=80`, `red_flags='["x"]'`), one `people_card_summaries` row (`attention='["y"]'`), one `user_analyses` row, one `user_interactions` row → after 00194: the card's fields are `'{}'`, `0`, `0`, `'[]'`; `attention='[]'`; both legacy tables empty; running the migration's Up statements again changes nothing.

`TestPeopleCards_OnlyInteractionPartners`: owner `1:UOWN`; P1 shares a DM, P2 replied in the owner's thread, P3 mentioned `<@UOWN>`, P4 only posted 30 messages in a channel the owner reads → stats for P1–P3 and the owner only.

`TestPeopleCards_NoOwnerNoCards`: `ownerID == ""` → no stats, and the guide pipeline records the existing owner-unknown readiness, not an error.

`TestPeopleExclude_BlocksFutureCards`: exclude P1 (no card yet) → the next pipeline run makes none; include → the next run makes one.

`TestPeopleExcludeCLI_JSON`: `people exclude --user 1:UP1 --json` → the JSON above; unknown user → error.

`TestPurge02_EveryAccountTableCovered` passes with the new table in the Slack steps (namespace range on `user_id`).

- [ ] **Step 2: Run** `go test ./internal/db ./internal/guide ./cmd -run 'PeopleSurveillance|OnlyInteraction|NoOwnerNoCards|PeopleExclude|Purge02|AllTablesExist'` — Expected: FAIL.

- [ ] **Step 3: Implement.** Migration Up: `CREATE TABLE people_card_exclusions …`; the three `UPDATE`s and two `DELETE`s of spec §5.3 (A15). Down: drop the table only. The interaction test is one SQL `EXISTS` over `messages` per spec §5.3 (DM/group DM with both authors, a `thread_ts` with both authors, a mention either way, within `[from, to)`). Remove `analysis.legacy_mode` from `internal/config/config.go:276-279`.

- [ ] **Step 4: Run** the same command plus `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema'` — Expected: PASS.

- [ ] **Step 5:** `make lint-diff`; commit `people: exclusions, interaction partners, cleared fields (#1769)`.

### Task 7: People prompt, parser and every reader

**Depends on:** Task 6 (same `internal/guide/pipeline.go`)

**Files:**
- Modify: `internal/prompts/defaults.go` (`defaultPeopleReduce`, its version in the versions map)
- Modify: `internal/guide/pipeline.go` (`PeopleCardResult`, `BatchCardResult`, stats written as defaults), `internal/guide/jira.go:20-115`
- Modify: `internal/briefing/pipeline.go`, `internal/briefing/prompt.go`, `internal/dayplan/gather.go`, `internal/dayplan/prompt.go`, `internal/memory/node.go`, `internal/memory/seed.go` (stop reading dropped fields)
- Modify: `internal/tools/people_read.go` (explicit output struct), `internal/tools/experts.go` (drop `ActiveHours`)
- Modify: `internal/devpack/skills/watchtower-who-to-ask/SKILL.md`
- Test: `internal/prompts/defaults_extra_test.go` (golden), `internal/guide/pipeline_test.go`, `internal/tools/people_read_test.go`, `internal/tools/experts_test.go`, `internal/devpack/pack_test.go`

**Interfaces:**
- Consumes: Task 6's `PeopleExclusions()`.
- Produces: `type personOutput struct` in `people_read.go` with JSON keys `user_id`, `period_from`, `period_to`, `message_count`, `channels_active`, `summary`, `communication_style`, `decision_role`, `highlights`, `accomplishments`, `communication_guide`, `decision_style`, `tactics`, `relationship_context`, `status`; an excluded person → `{"user_id":…, "card":null, "note":"no card (the owner stopped it)"}`.

- [ ] **Step 1: Write the failing tests**

`TestPeoplePrompt_HasNoSurveillanceRules`: the rendered prompt contains each of `health`, `mood`, `burnout`, `workload`, `personal life`, `protected characteristics`, `performance` inside one rule line starting `- Never`, and contains neither `red_flags` nor `TEAM NORMS`.

`TestPeopleCard_DropsSurveillanceFields`: a model reply carrying `red_flags` and `active_hours` → parsed and stored with `red_flags='[]'`, `active_hours_json='{}'`, `volume_change_pct=0`, `avg_message_length=0`.

`TestGuideJira_NoRiskLabels`: the signals for 5 overdue / 20 open issues contain no `burnout`, `bottleneck`, `risk`, `COMPOUND`.

`TestGetPerson_OutputHasNoSurveillanceFields`: the JSON keys equal the `personOutput` list exactly.

`TestFindExperts_NoActiveHours`: no candidate JSON has `active_hours`; the DEV-03 guards still pass.

`TestDevpackSkills_NoDroppedPeopleFields`: no embedded skill contains `active_hours`, `ActiveHoursJSON`, `RedFlags`, `VolumeChangePct`; `watchtower-who-to-ask` contains `the owner stopped it`.

- [ ] **Step 2: Run** `go test ./internal/prompts ./internal/guide ./internal/tools ./internal/devpack ./internal/briefing ./internal/dayplan ./internal/memory` — Expected: FAIL on the new tests.

- [ ] **Step 3: Implement.** The rule line text: `- Never infer or mention health, mood, burnout, workload judgments, personal life or protected characteristics, and never give performance verdicts; describe work topics and how to collaborate.` Bump the prompt version. Rewrite the skill's field-name bullet to the remaining fields and add `A person with no card may be one the owner stopped — don't guess.`

- [ ] **Step 4: Run** the same command — Expected: PASS, prompts store re-seed test green.

- [ ] **Step 5:** `make lint-diff`; `docs/features/developer-surface.md` (get_person output, skill line); commit `people: no-surveillance prompt and readers (#1769)`.

### Task 8: Desktop People screens

**Depends on:** Task 6 (CLI, Swift test schema), Task 7 (fields no longer written)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/PeopleCardCopy.swift`
- Modify: `WatchtowerDesktop/Sources/Views/People/PeopleListView.swift` (rows ~:290-390, team summary header ~:216-240)
- Modify: `WatchtowerDesktop/Sources/Views/People/PersonDetailView.swift` (stats grid ~:130-150, red flags ~:273-300, active hours ~:446-500; basis line; Stop card)
- Modify: `WatchtowerDesktop/Sources/Views/People/TeamSummaryDetailView.swift` (drop Needs Attention ~:85-110)
- Modify: `WatchtowerDesktop/Sources/Views/People/ConnectionsView.swift` (org links only)
- Modify: `WatchtowerDesktop/Sources/ViewModels/PeopleViewModel.swift` (`stopCard`, `makeCardsAgain` through `cliRunner`, like `ChannelStatsViewModel.setSyncExcluded`)
- Delete: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/InteractionQueries.swift` if no reader remains
- Test: `WatchtowerDesktop/Tests/Core/PeopleCardCopyTests.swift`, `WatchtowerDesktop/Tests/PeopleViewModelStopCardTests.swift` (new, next to `PeopleViewModelOwnerTests.swift`)
- Shots: replace the mocks `personCard`, `personStopConfirm`, `personStopped`, `peopleList`, `teamSummary`, `orgLinks`, `orgLinksEmpty` in `DesignShotFixtures+SlackPolicy.swift` with the real views on fixture data (the `SlackAdaptiveSyncShotFixtures` pattern), keeping the shot names
- Docs: `docs/guide/features/people.md`

**Interfaces:**
- Consumes: CLI `people exclude|include --user <id> --json` (Task 6).
- Produces: `PeopleCardCopy.basisLine(messages: Int, channels: Int) -> String` (`"Based on 42 messages in 5 channels you share"`), `stopCard`, `stopTitle(name:)`, `stopBody(name:)`, `stopConfirm`, `stoppedLine(name:)`, `makeAgain`, `orgLinksEmpty` — each equal to the `SlackPolicyMockCopy` string for `@dana`/42/5.

- [ ] **Step 1: Write the failing tests** — `PeopleCardCopyTests.testMatchesMockups` (every function above against `SlackPolicyMockCopy`); `PeopleViewModelStopCardTests.testStopCardRunsCLIAndReloads` (fake runner receives `["people","exclude","--user","1:UDANA","--json"]`, the person shows the stopped state); `testStopCardFailureKeepsCard` (runner throws → error message set, card still shown).
- [ ] **Step 2: Run** `make test-swift FILTER='PeopleCardCopyTests|PeopleViewModelStopCardTests'` — Expected: FAIL.
- [ ] **Step 3: Implement** the view changes to match the shots; the Stop card confirm uses `kitDestructive`.
- [ ] **Step 4: Run** the filter, `make desktop-shots DESKTOP_SHOTS=<dir>` and compare with `docs/design/mockups/slack-policy-hygiene/slack-ph-person*`, `-peopleList`, `-teamSummary`, `-orgLinks*`; `make lint-swift` — Expected: PASS.
- [ ] **Step 5:** guide page; commit `desktop: people screens without surveillance (#1769)`.

### Task 9: FileVault status line

**Depends on:** Task 3 (both edit `PrivacySettings.swift`)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/FileVaultStatus.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/FileVaultNotice.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/PrivacySettings.swift`, `WatchtowerDesktop/Sources/Views/Settings/SlackConnectionDetail.swift`, `AppState` (read at launch and on activation)
- Test: `WatchtowerDesktop/Tests/Core/FileVaultStatusTests.swift`, `FileVaultNoticeTests.swift`

**Interfaces:**
- Produces: `enum FileVaultState { case on, off, unknown }`; `struct FileVaultStatus { init(run: @escaping @Sendable () async throws -> String); func read() async -> FileVaultState }` (default runner: `/usr/bin/fdesetup status`, 2 s timeout, process group killed and reaped on timeout or cancel); `FileVaultNotice.text` = `SlackPolicyMockCopy.fileVaultOff`, `FileVaultNotice.action` = `openFileVault`, `FileVaultNotice.settingsURL` = `x-apple.systempreferences:com.apple.preference.security?FileVault`.

- [ ] **Step 1: Write the failing tests** — `FileVaultStatusTests`: `"FileVault is On."` → `.on`; `"FileVault is Off."` → `.off`; `""`, garbage, a thrown error and a runner that never returns (cancelled by the 2 s budget via an injected clock) → `.unknown`. `FileVaultNoticeTests.testCopy` against the mock table.
- [ ] **Step 2: Run** `make test-swift FILTER='FileVaultStatusTests|FileVaultNoticeTests'` — Expected: FAIL.
- [ ] **Step 3: Implement**; the line shows only for `.off`, on Privacy and Connections → Slack (shots `slack-ph-privacyFileVault`, `slack-ph-slackFileVault`). Before coding, confirm the parent spike's answer that `fdesetup status` runs without admin rights; if it does not, stop and report.
- [ ] **Step 4: Run** the filter and `make lint-swift` — Expected: PASS.
- [ ] **Step 5:** guide (privacy page, one line); commit `desktop: FileVault line (#1769)`.

### Task 10: Disclosure copy for setup and connect

**Depends on:** Task 4 (manifest text)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SlackDisclosureCopy.swift`
- Test: `WatchtowerDesktop/Tests/Core/SlackDisclosureCopyTests.swift`
- Modify (when present on the branch): the Set up for my company sheet and the connect confirm built by the parent spec's T7/T8; otherwise add one line to that plan's setup and connect tasks: "show `SlackDisclosureCopy.setup` before the token paste and `SlackDisclosureCopy.connect` in the confirm (shots `slack-ph-setupDisclosure`, `slack-ph-connectDisclosure`)".

**Interfaces:**
- Produces: `SlackDisclosureCopy.setupTitle`, `setupLines: [String]`, `connectLine(workspace:) -> String`, `privacyLink`, `privacyURL = URL(string: "https://aiwatchtowers.com/privacy/")!`.

- [ ] **Step 1: Write the failing test** — `SlackDisclosureCopyTests.testMatchesMockupsAndManifest`: `setupLines == SlackPolicyMockCopy.disclosureLines`; `connectLine(workspace: "acme") == SlackPolicyMockCopy.connectLine`; every provider name in `setupLines` also appears in Go's description (read the Go source's constant through the repo path, the `policy_cases.json` pattern).
- [ ] **Step 2: Run** `make test-swift FILTER=SlackDisclosureCopyTests` — Expected: FAIL.
- [ ] **Step 3: Implement**, and wire it or add the plan line as above.
- [ ] **Step 4: Run** the filter and `make lint-swift` — Expected: PASS.
- [ ] **Step 5: Commit** `desktop: Slack disclosure copy (#1769)`.

### Task 11: Privacy policy text for the owner, feature notes, guide sweep

**Depends on:** Tasks 1–10

**Files:**
- Create: `docs/legal/2026-11-17-privacy-policy-slack-changes.md` — the exact change for the site's page (`public/privacy/index.html` in the site's repository): for each of spec §7's 11 items, the section it goes in, the old sentence (if replaced) and the new text, ready to paste. Not applied here.
- Modify: `docs/features/README.md` (summary lines of revoke-purge, slack-multi-account, developer-surface), `docs/guide/concepts/sources-and-accounts.md` (why each Slack permission, one short list)
- Test: `go test ./docs/guide`

- [ ] **Step 1: Write the file.** Item 2 is the A23 text verbatim from spec §7; item 3 names Anthropic (Claude), OpenAI (Codex), Ollama and links nothing of ours but the policy itself; item 7 is P9. Every number matches Global Constraints (72 hours, 30 days).
- [ ] **Step 2: Check** with `grep -c` that the file has 11 numbered items and contains `Delete an account's data when its access ends`, `72 hours`, `Reset All Data…`, `never trains`.
- [ ] **Step 3: Run** `go test ./docs/guide` — Expected: PASS (page size caps).
- [ ] **Step 4: Commit** `docs: privacy policy text for the site, notes (#1769)`. The owner applies the file in the site's repository.

---

## Promise coverage (spec §11 → task)

| Spec promise | Task |
|---|---|
| Purge on unless turned off; default-on never deletes a live account for inactivity | 1 |
| Go and the Desktop show the same default | 1, 3 |
| Removed Slack account deleted 72 h after the remove; token revoked | 1, 2 |
| Deletion within 14 business days on a running Mac | 1 |
| A purge reported done left nothing | 1 |
| Per-account rules; zero-lease row survives the re-plan and needs the account still removed | 1 |
| Remove dialog and Privacy caption say the rules | 3 |
| 17 scopes, one list in one file | 4 |
| No code calls `conversations.mark` | 5 |
| A token without `emoji:read` keeps syncing | 4 |
| The description explains each scope and the providers within Slack's limit | 4 |
| Cards hold no presence, scores or judgments | 6, 7 |
| Cards only for people the owner works with | 6 |
| Stop card stays stopped | 6, 8 |
| `find_experts` and `get_person` give no dropped field; the skill names none | 7 |
| People screens show only work signals | 8 |
| The admin and every user see the disclosure | 4, 10 |
| FileVault off is said where Slack data is stored | 9 |
| The privacy policy states §7 | 11 (file for the owner) |
