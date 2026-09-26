# No-Slack Owner Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** replace the Slack-#1-only `GetCurrentUserID()` with one owner resolver (Slack #1 → Google #1 → Jira #1) on both the Go and Swift sides, and make a missing owner a visible error instead of a silent no-op.

**Architecture:** a pure `db.ResolveOwner()` in `internal/db/owner.go` returns `Owner{ID, Source, SlackUserID, Email, JiraAccountID, DisplayName}`; every call site takes the field it actually needs. `user_profile` is read and written as a singleton. Jira learns the owner via `GET /rest/api/3/myself` into three new `jira_accounts` columns (migration 00071). A Swift twin `OwnerQueries.resolve` mirrors the ladder (declared dual path). Two new inventory contracts, OWNER-01 and OWNER-02, each guarded.

**Tech Stack:** Go 1.25, `database/sql` + modernc sqlite, goose, cobra; SwiftUI + GRDB, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-25-no-slack-owner-identity-design.md` (read it before your task). Call-site census (authoritative list of every site, with file:line): `/private/tmp/claude-501/-Users-user-PhpstormProjects-watchtower/81fdf01c-e953-4f48-b77f-1b6edc45847a/scratchpad/owner-callsites.md`.

**Worktree:** `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/no-slack-identity`, branch `feature/no-slack-identity`.

## Global Constraints

1. English only in every repo file (code, comments, tests, commits, docs).
2. One commit per task, files by path — never `git add -A`, never `git stash`, never a working-tree-wide git command. Verify `git branch --show-current` = `feature/no-slack-identity` before committing. Trailer: `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
3. Inner-loop tests only: Go `go test ./internal/<pkg>` (no reflexive `-count=1`; never `go test -race ./cmd` — >40 min, use `-run`); Swift `make test-swift FILTER=<Class>` (multi-class: `cd WatchtowerDesktop && swift test --filter 'A|B'`, the Makefile does not quote FILTER). Log to a file and check `$?` explicitly; never pipe through tail; never wrap xctest in `timeout`; never delete `WatchtowerDesktop/.build`.
4. Never run the `watchtower` binary; never open the owner's live DB under `~/.local/share/watchtower/` or `~/Library/Application Support/Watchtower/`; never read/write the real `config.yaml`. Tests use temp DBs.
5. Owner id shapes, verbatim: Slack rung = the stored namespaced `current_user_id` unchanged (e.g. `1:U123`); Google rung = `"google:" + strings.ToLower(email)`; Jira rung = `"jira:" + owner_account_id`.
6. Ladder order, verbatim: Slack account `id = 1` with non-empty `current_user_id` and `status != 'removed'` → first `google_accounts` row by id with non-empty email → first **enabled** `jira_accounts` row by id with non-empty `owner_account_id` and `status != 'removed'` → unknown.
7. The shared no-owner error message, verbatim: `no owner identity: connect Slack, Google or Jira first` (Go: `db.ErrNoOwner`).
8. Migration number is **00071** (00070 is taken). New columns: `jira_accounts.owner_account_id`, `owner_email`, `owner_display_name`, all `TEXT NOT NULL DEFAULT ''`. Mirror into `internal/db/schema.sql`; regenerate the golden (`go test ./internal/db/ -run TestSchemaGolden -update`).
9. No new config keys.
10. Guard tests for the new contracts are named `TestOwner01_…` / `TestOwner02_…` (Go) and `testOwner01…` / `testOwner02…` (Swift). Every guard is mutation-checked: neuter the fix in a scratch copy OUTSIDE the repo (`/private/tmp/claude-501/-Users-user-PhpstormProjects-watchtower/81fdf01c-e953-4f48-b77f-1b6edc45847a/scratchpad`), confirm the test fails, restore from the scratch copy, `diff -q`. Never `git checkout --` to restore.
11. Build the fixture that can fail: assert every Owner field **by value**, per case. A test that only checks `ID` cannot see enrichment bugs; a single-source fixture cannot tell "the ladder" from "always Slack".
12. Sentrux complexity gate (gocyclo between CC 13 and 19, tests count): split functions rather than grow them. `ResolveOwner` must be a short orchestrator over small helpers.
13. Dual paths move together and the Swift side names the Go file in its doc comment (`SlackAccountID.swift` ↔ `internal/slack/namespace.go` precedent).
14. Read `docs/review/review-rules.md` "Swift / Desktop conventions" before any Swift task.

## Review Focus

1. **An existing Slack install must see zero change** — same owner id, same profile row, same day plans. Pinned in Task 1 (`TestOwner01_SlackInstallIDUnchanged`) and Task 4 (Swift mirror).
2. **Google email casing** — `Me@X.com` in one place and `me@x.com` in another must be one owner, one profile row. Pinned in Task 1 (lower-casing in the ID) and Task 1's profile re-key test.
3. **A revoked or 401ing Jira account at connect** must not fail `jira add`/`jira login`. Pinned in Task 2.
4. **Owner switches rung (Google → Slack connected later)** must keep exactly one `user_profile` row with the old content. Pinned in Task 1 (`TestOwner01_ProfileSurvivesRungSwitch`) and Task 4.
5. **Daemon log spam** — a no-owner install must not print the skip line every 15-minute cycle. Pinned in Task 3 (once per UTC day).

---

### Task 1: `db.Owner` resolver, profile singleton, migration 00071

**Files:**
- Create: `internal/db/owner.go`, `internal/db/owner_test.go`, `internal/db/migrations/00071_jira_account_owner.sql`
- Modify: `internal/db/jira_accounts.go` (struct fields, scan columns, `SetJiraAccountOwner`), `internal/db/profile.go` (`GetOwnerProfile`, `UpsertOwnerProfile`), `internal/db/schema.sql`, `internal/db/testdata/schema_v73.golden` (regenerated)

**Interfaces:**
- Produces:
  ```go
  var ErrNoOwner = errors.New("no owner identity: connect Slack, Google or Jira first")
  type OwnerSource string
  const (OwnerSourceNone OwnerSource = ""; OwnerSourceSlack = "slack"; OwnerSourceGoogle = "google"; OwnerSourceJira = "jira")
  type Owner struct { ID string; Source OwnerSource; SlackUserID, Email, JiraAccountID, DisplayName string }
  func (o Owner) Known() bool
  func (db *DB) ResolveOwner() (Owner, error)
  func (db *DB) GetOwnerProfile(o Owner) (*UserProfile, error)
  func (db *DB) UpsertOwnerProfile(o Owner, p UserProfile) error
  func (db *DB) SetJiraAccountOwner(accountID int64, atlassianID, email, displayName string) error
  // JiraAccount gains: OwnerAccountID, OwnerEmail, OwnerDisplayName string
  ```
- `GetCurrentUserID` is NOT removed here (Task 3 removes it after migrating callers).

- [ ] **Step 1: Migration.** `internal/db/migrations/00071_jira_account_owner.sql`:
  ```sql
  -- +goose Up
  -- The connecting person's own Atlassian identity, from GET /rest/api/3/myself.
  -- Feeds db.ResolveOwner's Jira rung and the owner's authoritative Jira id
  -- (before this, the owner's Jira identity was only a fuzzy jira_user_map guess).
  ALTER TABLE jira_accounts ADD COLUMN owner_account_id TEXT NOT NULL DEFAULT '';
  ALTER TABLE jira_accounts ADD COLUMN owner_email TEXT NOT NULL DEFAULT '';
  ALTER TABLE jira_accounts ADD COLUMN owner_display_name TEXT NOT NULL DEFAULT '';

  -- +goose Down
  ALTER TABLE jira_accounts DROP COLUMN owner_display_name;
  ALTER TABLE jira_accounts DROP COLUMN owner_email;
  ALTER TABLE jira_accounts DROP COLUMN owner_account_id;
  ```
  Add the three columns to `jira_accounts` in `internal/db/schema.sql` (same comment, one line). Add the fields to `JiraAccount` and to every `SELECT … FROM jira_accounts` scan in `jira_accounts.go`. Add:
  ```go
  // SetJiraAccountOwner records the connecting person's own Atlassian identity
  // (GET /rest/api/3/myself). An empty atlassianID is a no-op error-free write
  // callers never make; they only call it on a successful /myself.
  func (db *DB) SetJiraAccountOwner(accountID int64, atlassianID, email, displayName string) error {
      _, err := db.Exec(`UPDATE jira_accounts SET owner_account_id = ?, owner_email = ?, owner_display_name = ? WHERE id = ?`,
          atlassianID, email, displayName, accountID)
      if err != nil {
          return fmt.Errorf("setting jira account %d owner: %w", accountID, err)
      }
      return nil
  }
  ```
  Run `go test ./internal/db/ -run TestSchemaGolden -update`, then `go test ./internal/db/` → PASS.

- [ ] **Step 2: Write the failing ladder test** `internal/db/owner_test.go` (table-driven; each case seeds a fresh `openTestDB(t)`):
  ```go
  func TestOwner01_ResolveOwnerLadder(t *testing.T) {
      type seed struct {
          slack        *SlackAccount // id 1 when non-nil
          slackUser    *User         // users row for slack.CurrentUserID
          google       []GoogleAccount
          jira         []JiraAccount // OwnerAccountID/OwnerEmail/OwnerDisplayName set via SetJiraAccountOwner
          jiraUserMap  []JiraUserMap
      }
      cases := []struct {
          name string
          seed seed
          want Owner
      }{
          {"none", seed{}, Owner{}},
          {"slack only", seed{slack: &SlackAccount{TeamID: "T1", CurrentUserID: "1:U123"},
              slackUser: &User{ID: "1:U123", DisplayName: "Vadym", Email: "v@slack.io"}},
              Owner{ID: "1:U123", Source: OwnerSourceSlack, SlackUserID: "1:U123", Email: "v@slack.io", DisplayName: "Vadym"}},
          {"google only, mixed-case email", seed{google: []GoogleAccount{{Email: "Me@X.com"}}},
              Owner{ID: "google:me@x.com", Source: OwnerSourceGoogle, Email: "Me@X.com", DisplayName: "Me"}},
          {"jira only", seed{jira: []JiraAccount{{CloudID: "c1", Enabled: true, OwnerAccountID: "acc-9", OwnerEmail: "j@x.com", OwnerDisplayName: "J Doe"}}},
              Owner{ID: "jira:acc-9", Source: OwnerSourceJira, Email: "j@x.com", JiraAccountID: "acc-9", DisplayName: "J Doe"}},
          {"google + jira: google wins ID, jira enriches", seed{
              google: []GoogleAccount{{Email: "me@x.com"}},
              jira:   []JiraAccount{{CloudID: "c1", Enabled: true, OwnerAccountID: "acc-9", OwnerEmail: "j@x.com", OwnerDisplayName: "J Doe"}}},
              Owner{ID: "google:me@x.com", Source: OwnerSourceGoogle, Email: "me@x.com", JiraAccountID: "acc-9", DisplayName: "J Doe"}},
          {"slack without current_user_id falls through to google", seed{slack: &SlackAccount{TeamID: "T1"}, google: []GoogleAccount{{Email: "me@x.com"}}},
              Owner{ID: "google:me@x.com", Source: OwnerSourceGoogle, Email: "me@x.com", DisplayName: "me"}},
          {"removed slack is skipped", seed{slack: &SlackAccount{TeamID: "T1", CurrentUserID: "1:U123", Status: "removed"}, google: []GoogleAccount{{Email: "me@x.com"}}},
              Owner{ID: "google:me@x.com", Source: OwnerSourceGoogle, Email: "me@x.com", DisplayName: "me"}},
          {"disabled jira is skipped", seed{jira: []JiraAccount{{CloudID: "c1", Enabled: false, OwnerAccountID: "acc-9"}}}, Owner{}},
          {"slack + jira_user_map bridge fills JiraAccountID", seed{
              slack: &SlackAccount{TeamID: "T1", CurrentUserID: "1:U123"},
              slackUser: &User{ID: "1:U123", DisplayName: "Vadym"},
              jiraUserMap: []JiraUserMap{{JiraAccountID: "acc-map", SlackUserID: "1:U123"}}},
              Owner{ID: "1:U123", Source: OwnerSourceSlack, SlackUserID: "1:U123", JiraAccountID: "acc-map", DisplayName: "Vadym"}},
      }
      for _, tc := range cases {
          t.Run(tc.name, func(t *testing.T) {
              d := openTestDB(t)
              seedOwner(t, d, tc.seed) // helper in this file: creates rows via the existing Create*/Upsert* helpers
              got, err := d.ResolveOwner()
              require.NoError(t, err)
              assert.Equal(t, tc.want, got) // every field by value
          })
      }
  }

  func TestOwner01_SlackInstallIDUnchanged(t *testing.T) {
      // An existing Slack install that ALSO has Google + Jira connected keeps
      // its Slack id as the owner id — the one guarantee for every live install.
      d := openTestDB(t)
      // seed slack 1:U123 + google me@x.com + jira acc-9 …
      got, err := d.ResolveOwner()
      require.NoError(t, err)
      assert.Equal(t, "1:U123", got.ID)
      assert.Equal(t, OwnerSourceSlack, got.Source)
  }
  ```
  Use the real helper/struct names from `internal/db` (`CreateSlackAccount`, `CreateGoogleAccount`, `CreateJiraAccount`, `UpsertUser`, `UpsertJiraUserMap`, the `JiraUserMap`/`User` structs) — read their signatures; adjust the seed struct to match, keeping every expected field above.
  DisplayName rule for a Google-only owner: the email local part with its case preserved from the stored email (`"Me@X.com"` → `"Me"`).
  Run: `go test ./internal/db -run TestOwner01` → FAIL (`ResolveOwner` undefined).

- [ ] **Step 3: Implement `internal/db/owner.go`.** Orchestrator plus one helper per rung and one per enrichment field (keep each under the complexity gate):
  ```go
  // ResolveOwner returns the one owner identity of this install: Slack account
  // #1 → Google account #1 → Jira account #1 (spec 2026-09-25). The Swift twin
  // is WatchtowerCore/Database/Queries/OwnerQueries.swift — change both
  // together. Every field is enriched from every source, independent of which
  // rung produced ID.
  func (db *DB) ResolveOwner() (Owner, error) {
      slackID, err := db.ownerSlackID()
      if err != nil { return Owner{}, err }
      google, err := db.ownerGoogleEmail()
      if err != nil { return Owner{}, err }
      jira, err := db.ownerJiraAccount()
      if err != nil { return Owner{}, err }

      o := Owner{SlackUserID: slackID}
      switch {
      case slackID != "":
          o.ID, o.Source = slackID, OwnerSourceSlack
      case google != "":
          o.ID, o.Source = "google:"+strings.ToLower(google), OwnerSourceGoogle
      case jira.OwnerAccountID != "":
          o.ID, o.Source = "jira:"+jira.OwnerAccountID, OwnerSourceJira
      default:
          return Owner{}, nil
      }
      return db.enrichOwner(o, google, jira)
  }
  ```
  - `ownerSlackID`: `SELECT current_user_id FROM slack_accounts WHERE id = 1 AND status != 'removed'`; `sql.ErrNoRows` → `""`.
  - `ownerGoogleEmail`: `SELECT email FROM google_accounts WHERE email != '' ORDER BY id LIMIT 1`.
  - `ownerJiraAccount`: `SELECT owner_account_id, owner_email, owner_display_name FROM jira_accounts WHERE enabled = 1 AND status != 'removed' AND owner_account_id != '' ORDER BY id LIMIT 1`.
  - `enrichOwner`: Slack user row (`GetUserByID(SlackUserID)`) → `Email`, `DisplayName` (DisplayName, else RealName); Email falls back to the Google email, then Jira `owner_email`; `JiraAccountID` = Jira `owner_account_id`, else the `jira_user_map` lookup by `SlackUserID` (move `atlassianIDsForUser`'s bare/`1:` candidate logic here as `db.ownerJiraFromUserMap(slackID)` returning the first id); DisplayName falls back to Jira `owner_display_name`, then the email local part.
  Run `go test ./internal/db -run TestOwner01` → PASS.

- [ ] **Step 4: Profile singleton — failing tests** in `owner_test.go`:
  ```go
  func TestOwner01_ProfileSurvivesRungSwitch(t *testing.T) {
      d := openTestDB(t)
      g := Owner{ID: "google:me@x.com", Source: OwnerSourceGoogle}
      require.NoError(t, d.UpsertOwnerProfile(g, UserProfile{Role: "EM", Team: "Core"}))
      s := Owner{ID: "1:U123", Source: OwnerSourceSlack}
      p, err := d.GetOwnerProfile(s) // no row keyed 1:U123 yet → falls back to the only row
      require.NoError(t, err)
      require.NotNil(t, p)
      assert.Equal(t, "EM", p.Role)
      require.NoError(t, d.UpsertOwnerProfile(s, UserProfile{Role: "Director", Team: "Core"}))
      var n int
      require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM user_profile`).Scan(&n))
      assert.Equal(t, 1, n, "the rung switch re-keys the one row, never adds a second")
      p, err = d.GetOwnerProfile(s)
      require.NoError(t, err)
      assert.Equal(t, "1:U123", p.SlackUserID)
      assert.Equal(t, "Director", p.Role)
  }

  func TestOwner01_OwnerKeyedProfileBeatsStaleRow(t *testing.T) {
      d := openTestDB(t)
      require.NoError(t, d.UpsertUserProfile(UserProfile{SlackUserID: "1:U123", Role: "Mine"}))
      require.NoError(t, d.UpsertUserProfile(UserProfile{SlackUserID: "legacy:x", Role: "Stale"})) // newer updated_at
      p, err := d.GetOwnerProfile(Owner{ID: "1:U123"})
      require.NoError(t, err)
      assert.Equal(t, "Mine", p.Role, "an exact-key row always wins over the most-recent fallback")
  }

  func TestOwner01_UnknownOwnerProfileIsNil(t *testing.T) {
      d := openTestDB(t)
      p, err := d.GetOwnerProfile(Owner{})
      require.NoError(t, err)
      assert.Nil(t, p)
  }
  ```
  Run → FAIL. Implement in `profile.go`: `GetOwnerProfile` = unknown owner → `nil, nil`; exact key via `GetUserProfile(o.ID)`; else the row with the greatest `updated_at` (tie → greatest id). `UpsertOwnerProfile` = in one transaction: if no row keyed `o.ID` but a fallback row exists, `UPDATE user_profile SET slack_user_id = ? WHERE id = ?`; then the existing upsert with `p.SlackUserID = o.ID`. Unknown owner → `ErrNoOwner`. Run → PASS.

- [ ] **Step 5: Mutation checks** (Constraint 10): (a) ladder = Slack only (return `Owner{}` when slackID is empty) → "google only" fails; (b) enrichment only from the winning rung (skip Jira enrichment when Source != jira) → "google + jira" fails; (c) no lower-casing → "google only, mixed-case" fails; (d) `GetOwnerProfile` exact-key only → `ProfileSurvivesRungSwitch` fails; (e) `UpsertOwnerProfile` without re-key → count 2 fails. Record each in the report.

- [ ] **Step 6: Commit** `feat(db): owner resolver (Slack → Google → Jira), profile singleton, jira_accounts owner columns`.

---

### Task 2: Jira `/myself` — store the connecting person's identity

**Files:**
- Modify: `internal/jira/client.go` (`Myself`, `GetMyself`), `cmd/jira.go` (`connectJiraAccount`), `cmd/sync.go` (`wireJiraSyncers` lazy fill)
- Test: `internal/jira/client_test.go`, `cmd/jira_test.go` (or the existing connect test file), `cmd/sync_test.go` (or the existing `wireJiraSyncers` test file)

**Interfaces:**
- Consumes: `db.SetJiraAccountOwner(accountID, atlassianID, email, displayName)`, `JiraAccount.OwnerAccountID` (Task 1).
- Produces:
  ```go
  type Myself struct {
      AccountID    string `json:"accountId"`
      EmailAddress string `json:"emailAddress"`
      DisplayName  string `json:"displayName"`
  }
  func (c *Client) GetMyself(ctx context.Context) (Myself, error)
  ```

- [ ] **Step 1: Failing client test** — `httptest` server serving `/ex/jira/<cloud>/rest/api/3/myself` (match how existing client tests route; read one) returning `{"accountId":"acc-9","emailAddress":"j@x.com","displayName":"J Doe"}`; assert all three fields by value. Second case: 404 → non-nil error wrapping "fetching myself".
- [ ] **Step 2: Implement** (the `GetProjectVersions` shape):
  ```go
  // GetMyself returns the connecting person's own Atlassian identity. Needs the
  // read:jira-user scope, which every Watchtower Jira grant already carries.
  func (c *Client) GetMyself(ctx context.Context) (Myself, error) {
      var m Myself
      if err := c.get(ctx, "/rest/api/3/myself", &m); err != nil {
          return Myself{}, fmt.Errorf("fetching myself: %w", err)
      }
      return m, nil
  }
  ```
- [ ] **Step 3: Connect fills it, best effort.** In `connectJiraAccount`, after the site is chosen and the token is saved (before `SetJiraAccountAuthState(…, "ok", "")`), build a client for the chosen site and call `GetMyself`; on success `SetJiraAccountOwner`; on any error write one line to `cmd.ErrOrStderr()` — `warning: could not read your Jira identity (/myself): <err>; it will be retried on the next sync` — and continue. Extract this into `recordJiraOwner(ctx, w io.Writer, database *db.DB, accountID int64, client myselfGetter)` with a one-method interface `myselfGetter { GetMyself(context.Context) (jira.Myself, error) }` so it is testable without OAuth. Tests: success stores the three columns (read back by value); an error leaves them empty, returns nothing, and writes the warning.
- [ ] **Step 4: Lazy fill.** In `wireJiraSyncers`, for each enabled account with `OwnerAccountID == ""` whose client was built, call `recordJiraOwner` with the logger's writer (one attempt per account per daemon start). Test through the same extracted helper: an account with an owner already set is not re-fetched (the fake getter records zero calls).
- [ ] **Step 5: Mutation checks:** connect without the `/myself` call → store test fails; lazy fill that ignores `OwnerAccountID != ""` → zero-calls test fails; a `/myself` error that aborts connect → the error-path test fails.
- [ ] **Step 6: Commit** `feat(jira): record the connecting person's identity via /myself`.

---

### Task 3a: Go call sites — KEY, PROFILE, DISPLAY, daemon, OWNER-02

**Files:** every site in census §1 rows 1–15 and 18–23 **except** the inbox/style-sample rows (Task 3b): `cmd/day_plan.go` ×5, `cmd/briefing.go` ×2, `cmd/tracks.go:766`, `cmd/jira.go` ×2, `cmd/profile.go`, `internal/guide/pipeline.go`, `internal/tools/digests.go`, `internal/digest/pipeline.go`, `internal/tracks/pipeline.go`, `internal/meeting/pipeline.go`, `internal/briefing/pipeline.go`, `internal/dayplan/prompt.go` (profile read), `internal/daemon/daemon.go` (`shouldRunDayPlan`, `runDayPlanPhase`, `runDayPlanConflictPhase`, `phaseBriefing`'s handling of the briefing result). Tests next to each.

**Interfaces:**
- Consumes: `db.ResolveOwner`, `db.Owner`, `db.ErrNoOwner`, `db.GetOwnerProfile` (Task 1).
- Produces: `briefing.Pipeline.RunForDate` returns `db.ErrNoOwner` (wrapped) when the owner is unknown; a daemon helper `func (d *Daemon) logNoOwnerOnce(now time.Time, phase string)`.

- [ ] **Step 1: OWNER-02 failing tests** in `cmd/` — one table test over the user-triggered commands: `day-plan generate`, `day-plan show`, `day-plan list`, `day-plan reset`, `day-plan check-conflicts`, `briefing generate`, `briefing show`, `briefing list`, `tracks create`, `profile`. Each runs the real cobra command against a temp workspace DB with **no accounts**, and asserts `errors.Is(err, db.ErrNoOwner)` (not an error-string match, not "exit 0"). Name: `TestOwner02_UserTriggeredCommandsFailWithoutOwner`. Plus `TestOwner02_GetTodayBriefingToolErrorsWithoutOwner` in `internal/tools`. Use the existing cmd test harness for temp workspaces (read `cmd`'s `TestMain` and a neighbouring command test first — `HOME` is isolated package-wide).
- [ ] **Step 2: Migrate the KEY sites** to `owner, err := database.ResolveOwner(); if err != nil { return err }; if !owner.Known() { return db.ErrNoOwner }` and use `owner.ID`. Replace the printed "No current user set…" lines — they are gone. `cmd/tracks.go:766`: same, the silent empty assignee is gone.
- [ ] **Step 3: PROFILE sites** → `database.GetOwnerProfile(owner)`. `cmd/jira.go` ×2 keep their "no profile → default role" fallback (not an error: a Jira feature toggle does not need an owner). `internal/guide`, `internal/digest`: unknown owner → no profile, as today (these are pipelines, not user-triggered commands).
- [ ] **Step 4: `internal/meeting`**: `userName` from `owner.DisplayName` (fallback `"User"` stays), profile via `GetOwnerProfile`.
- [ ] **Step 5: `internal/briefing.RunForDate`**: unknown owner → `return 0, fmt.Errorf("briefing: %w", db.ErrNoOwner)`; KEY reads use `owner.ID`; `gatherJiraContext` takes the `Owner` and queries by `owner.JiraAccountID` when set (add `db.GetJiraIssuesByAssigneeAccountID(accountID)` next to `GetJiraIssuesByAssigneeSlackID`, same columns/order, `WHERE assignee_account_id = ?`), else the existing Slack-id query. Update `TestPipelineRunNoUser` to assert `errors.Is(err, db.ErrNoOwner)`.
- [ ] **Step 6: Daemon.** Day-plan gates use `ResolveOwner`; an unknown owner and a briefing `ErrNoOwner` are **benign skips**: no attempt-budget charge (the two `…BenignNoUserSkipDoesNotConsumeBudget` tests must still pass unchanged in meaning — adjust only their seeding if needed), and `logNoOwnerOnce(now, phase)` prints `daemon: <phase> skipped: no owner identity (connect Slack, Google or Jira)` at most once per UTC day per phase (in-memory map on the Daemon; a restart may print it once more — acceptable). Test: three cycles on the same day → one line; next day → one more.
- [ ] **Step 7: Mutation checks:** one KEY site reverted to the silent print-and-return-nil → OWNER-02 table fails for that command; `RunForDate` back to `(0, nil)` → its test fails; `logNoOwnerOnce` without the day key → the three-cycles test fails.
- [ ] **Step 8:** `go test ./internal/briefing ./internal/daemon ./internal/tools ./internal/meeting ./internal/tracks ./internal/digest ./internal/guide ./internal/dayplan ./internal/db` and `go test ./cmd -run 'TestOwner02|TestDayPlan|TestBriefing|TestTracks|TestProfile|TestJira'` → PASS. Commit `feat: owner resolver at every KEY/PROFILE site; no-owner is a visible error (OWNER-02)`.

---

### Task 3b: inbox, Jira detection, style sample; delete `GetCurrentUserID`; OWNER-01 Go scan

**Files:** `internal/inbox/pipeline.go` (`resolveCurrentUserID`, `Run` gate, `SetCurrentUser`, Calendar/Jira detector wiring), `internal/inbox/jira_detector.go` (`atlassianIDsForUser` callers), `internal/inbox/style_sample.go`, `internal/daemon/daemon.go` (`applyInboxCurrentUser`), `internal/db/workspace.go` (delete `GetCurrentUserID`), `internal/db/slack_accounts_test.go` (the two `TestGetCurrentUserID_*` tests become resolver tests or are deleted — their assertions are covered by `TestOwner01_ResolveOwnerLadder`'s "none" and "slack only" cases; say which in the commit body), create `internal/db/owner_scan_test.go`.

**Interfaces:**
- Consumes: Task 1's `Owner`; Task 3a's migrated daemon.
- Produces: `inbox.Pipeline.SetOwner(o db.Owner)` replacing `SetCurrentUser(id, email string)`.

- [ ] **Step 1: Failing inbox tests.** (a) Google-only install (a `google_accounts` row, a calendar event needing RSVP by that email, no Slack): `Run` produces the calendar inbox item — today the whole Run skips. (b) Jira-only owner (`jira_accounts.owner_account_id = acc-9`, empty `jira_user_map`) + a Jira comment mentioning `acc-9`: `Run` produces the `jira_comment_mention` item. (c) No accounts at all: `Run` returns `(0, 0, nil)` and logs the skip — no detector runs. Read the existing inbox pipeline tests for fixture helpers first.
- [ ] **Step 2: Implement.** `SetOwner(o db.Owner)` stores the owner; `Run` resolves it via `ResolveOwner` when not set; gate is `!owner.Known()`; Calendar gets `owner.Email`; the Jira detector and `autoResolveJira` take `owner.JiraAccountID` first and fall back to `atlassianIDsForUser(owner.SlackUserID)` only when it is empty; Slack per-account detection is untouched. `applyInboxCurrentUser` becomes `d.inboxPipe.SetOwner(owner)` — its hand-rolled Google-email fallback is deleted (the resolver does it). INBOX-09 is unchanged: a detector skipping for missing identity is not a detector error.
- [ ] **Step 3: Style sample** uses `owner.SlackUserID`; empty → `fmt.Errorf("style sample needs a connected Slack account")`. Update `style_sample_test.go:97` to the new message.
- [ ] **Step 4: Delete `GetCurrentUserID`** and fix compile errors (there must be none left outside tests after 3a+3b).
- [ ] **Step 5: OWNER-01 Go scan** `internal/db/owner_scan_test.go` — `TestOwner01_NoOwnerReadsOutsideResolver`: walk every `.go` file under `internal/` and `cmd/` (repo root resolved the way `cmd/prompt_store_scan_test.go` does), skip `_test.go` and `internal/db/owner.go`, and fail on any file containing `GetCurrentUserID` or the SQL fragment `current_user_id FROM slack_accounts WHERE id = 1`. Assert a floor: at least 300 files walked (a wrong root must fail loudly). Allowlist: per-account `current_user_id` reads in `internal/inbox` and `internal/db/slack_accounts.go` do not match the `WHERE id = 1` fragment, so they need no allowlist — confirm.
- [ ] **Step 6: Mutation checks:** re-add a `current_user_id FROM slack_accounts WHERE id = 1` query in a non-test file → scan fails; restore the whole-Run Slack gate → test (a) fails; Jira detector back to Slack-map only → test (b) fails.
- [ ] **Step 7:** `go test ./internal/inbox ./internal/daemon ./internal/db` + `go build ./...` + `golangci-lint run --new-from-rev origin/main --timeout 10m ./...`. Commit `feat(inbox): detectors run for any known owner; remove GetCurrentUserID (OWNER-01)`.

---

### Task 4: Swift `OwnerQueries.resolve` + the six sites + OWNER-01 Swift scan

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/Owner.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/OwnerQueries.swift`, `WatchtowerDesktop/Tests/Core/OwnerQueriesTests.swift`
- Modify: `WatchtowerCore/Models/JiraAccount.swift` (decode the three owner columns), `WatchtowerCore/Database/Queries/ProfileQueries.swift`, `WatchtowerCore/Database/Queries/TrackQueries.swift`, `Database/Queries/ChannelStatsQueries.swift`, `ViewModels/ProjectMapViewModel.swift`, `Views/Settings/ProfileSettings.swift`, `ViewModels/OnboardingChatViewModel.swift`, `Tests/Support/TestDatabase+Schema.swift` (the three columns), existing tests that seed `current_user_id` only as needed.

**Interfaces:**
- Consumes: the Go ladder (Task 1) — same order, same ID shapes, same enrichment.
- Produces:
  ```swift
  package enum OwnerSource: String { case none = "", slack, google, jira }
  package struct Owner: Equatable, Sendable {
      package let id: String; package let source: OwnerSource
      package let slackUserID: String; package let email: String
      package let jiraAccountID: String; package let displayName: String
      package var isKnown: Bool { !id.isEmpty }
      package static let unknown: Owner
  }
  package enum OwnerQueries {
      package static func resolve(_ db: Database) throws -> Owner
  }
  // ProfileQueries gains:
  package static func fetchOwnerProfile(_ db: Database, owner: Owner) throws -> UserProfile?
  package static func upsertOwnerProfile(_ db: Database, owner: Owner, profile: UserProfile) throws
  ```

- [ ] **Step 1: Failing Core tests** `OwnerQueriesTests` — the **same nine cases** as `TestOwner01_ResolveOwnerLadder` (copy the Go table's inputs and expected values literally; name the test `testOwner01ResolveOwnerLadder`), plus `testOwner01ProfileSurvivesRungSwitch` and `testOwner01OwnerKeyedProfileBeatsStaleRow` mirroring Task 1. Each field asserted by value.
- [ ] **Step 2: Implement** `OwnerQueries.resolve` with the exact SQL of Task 1's helpers; doc comment: `/// Swift twin of internal/db/owner.go (ResolveOwner) — a deliberate dual path; change both together. Ladder: Slack #1 → Google #1 → Jira #1.` Implement the profile pair mirroring Task 1 Step 4 (re-key in the same write transaction).
- [ ] **Step 3: Migrate the six sites** (census §6): `fetchCurrentProfile` → `fetchOwnerProfile(db, owner: resolve(db))` (keep `fetchCurrentProfile` as a thin wrapper only if its callers are many; otherwise update its callers — `DigestViewModel`, `PeopleViewModel` ×2, `AppState` ×2, `ProfileSettings`); `TrackQueries.fetchCurrentUserID` → returns `resolve(db).id` (nil when unknown); `ChannelStatsQueries.fetchCurrentUserID` → `resolve(db).slackUserID` (it matches `messages.user_id`); `ProjectMapViewModel` → owner profile; `ProfileSettings.getCurrentUserID` + `save()` → `upsertOwnerProfile`, unknown owner keeps its `errorMessage` but with the Constraint 7 text; `OnboardingChatViewModel.getCurrentUserID` → `resolve(db).id`, and `saveProfileWithContext`'s silent `return` on empty becomes `errorMessage = "no owner identity: connect Slack, Google or Jira first"` (keep `markOnboardingDone`'s documented "no owner is legitimate" branch).
- [ ] **Step 4: OWNER-01 Swift scan** `testOwner01NoRawOwnerQueriesOutsideResolver` in `Tests/Core/OwnerQueriesTests.swift`: read every `.swift` file under `WatchtowerDesktop/Sources` (resolve the path from `#filePath`), skip `OwnerQueries.swift`, fail on the fragment `current_user_id FROM slack_accounts WHERE id = 1`; floor ≥ 200 files.
- [ ] **Step 5: Site tests** — a Google-only fixture for `TrackQueries` (sidebar counts no longer zero out), `ProfileSettings` save (writes one row keyed `google:…`), and `ChannelStats` (still empty without Slack — it genuinely needs Slack; assert that).
- [ ] **Step 6: Mutation checks:** Swift ladder = Slack only → Google case fails; the scan with one site reverted to raw SQL → fails; profile without re-key → rung-switch test fails.
- [ ] **Step 7:** `make test-swift FILTER=OwnerQueriesTests`, then `cd WatchtowerDesktop && swift test --filter 'ProfileQueries|TrackQuery|ChannelStats|ProjectMap|ProfileSettings|Onboarding|Sidebar'`, `make lint-swift`. Commit `feat(desktop): OwnerQueries.resolve — the Swift twin of the owner resolver (OWNER-01)`.

---

### Task 5: Desktop — no-owner empty state and visible Generate failures

**Files:** `App/AppState.swift` (expose `owner: Owner`, refreshed where accounts change — find where Slack/Google/Jira account VMs reload and on DB open), `ViewModels/DayPlanViewModel.swift`, `Views/DayPlan/DayPlanView.swift`, `ViewModels/BriefingViewModel.swift`, `Views/Briefings/BriefingsListView.swift`, a small shared view `Views/Components/NoOwnerEmptyState.swift`; tests: `DayPlanViewModelTests`, `BriefingViewModelTests` (create if absent), ViewInspector tests for the two empty states following existing ViewInspector test files.

**Interfaces:**
- Consumes: `OwnerQueries.resolve`, `Owner.isKnown` (Task 4); the CLI now exits non-zero with `ErrNoOwner` (Task 3a).

- [ ] **Step 1: Failing tests.** (a) `BriefingViewModel.generateBriefing()` with a CLI stub that exits 1 with stderr `no owner identity: connect Slack, Google or Jira first` → `generateError` contains that text (today stdout is discarded and stderr ignored for this path — read the VM; route it through the injectable `CLIRunnerProtocol` the way `DayPlanViewModel` does, so it is testable). (b) `DayPlanViewModel.regenerate` with the same stub → `generationError` set. (c) Views: with `owner = .unknown`, Day Plan and Briefings render `NoOwnerEmptyState` (text: "Connect Slack, Google or Jira so Watchtower knows who you are", button "Open Connections" that selects Settings → Connections the way other deep links into Settings do) and no Generate button.
- [ ] **Step 2: Implement.** Keep the async-state house rule (state that must survive navigation lives on the VM/center already owned by AppState).
- [ ] **Step 3: Mutation checks:** revert the briefing VM to discarding stderr → (a) fails; render Generate regardless of owner → (c) fails.
- [ ] **Step 4:** `cd WatchtowerDesktop && swift test --filter 'DayPlan|Briefing|NoOwner'`, `make lint-swift`. Update `docs/app-guide.md` (Day Plan and Briefings sections: the no-owner empty state). Commit `feat(desktop): no-owner empty state; Generate failures are visible (OWNER-02)`.

---

### Task 6: Contracts and docs

**Files:** create `docs/inventory/owner-identity.md`; modify `docs/inventory/README.md` (module → file row), `CLAUDE.md`, `docs/audit/2026-09-13-feature-audit/README.md` (decision 15 row → "Shipped 2026-09-25").

- [ ] **Step 1:** `owner-identity.md` in the house format (read `docs/inventory/targets.md` for the shape): header, **OWNER-01** and **OWNER-02** exactly as spec §8 words them, each with Observable / Mechanism / Guard (the test names from Tasks 1, 3a, 3b, 4, 5, verified to exist by grep), plus a changelog entry dated 2026-09-25.
- [ ] **Step 2: CLAUDE.md.** (a) Slack Multi-Account "Documented v1 identity-scoping decisions" item (1): replace the `db.GetCurrentUserID()` sentence with the resolver (ladder, `internal/db/owner.go` ↔ `OwnerQueries.swift`, OWNER-01/02). (b) The same section mentions `db.ListOwnerSlackUserIDs()` feeding `ListStreamCandidatesSince` — neither exists since the 2026-09-14 inbox demolition; rewrite that sentence to say the stream-candidate path was removed with stream triage. (c) Add a short "Owner identity (2026-09-25)" feature note: resolver, profile singleton, `/myself` + migration 00071, no-silent-skip, the empty state. (d) Jira multi-account section: `jira_accounts` gains the three owner columns filled by `/myself`.
- [ ] **Step 3:** grep every test name cited in the inventory file exists: `grep -rn "<name>" internal cmd WatchtowerDesktop/Tests`. Commit `docs: owner-identity contracts (OWNER-01/02) and CLAUDE.md`.

---

## Execution order and parallelism

Sequential: 1 → 2 → 3a → 3b → 4 → 5 → 6. Task 2 and Task 4 do not depend on each other, but Task 4 needs Task 1's migration and Task 3a/3b share files with Task 2 (`cmd/sync.go`, `internal/daemon`), so run them in order in one worktree. Final gate (controller): `make test`, `make test-swift`, `make lint-all`, `sentrux gate`, then `local-review` (debate-review on the final PR), PR, merge on green.
