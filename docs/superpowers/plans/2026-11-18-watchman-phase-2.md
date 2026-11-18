# Watchman Phase 2 (Sleep only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the owner hand a workbench session or target to Watchman at night: the twin answers asks, permission prompts, spec/plan reviews, diff review rounds and finish handovers in his place, journals every decision as **unsure**, never crosses a §5 hard limit, and the owner reads, OKs or corrects the night in the morning.

**Architecture:** Arming rows (`watchman_arming`) and a derived sidecar file decide which sessions are the twin's; the mode is computed in Go (`watchman.Mode`) from the hub's `platform.Away` reading, presence, the sleep request and the learned window. Wait-point writers (the MCP `ask_owner`, the permission hook, `finish_session`, the guard hook) queue `watchman_items`; a twin worker in the daemon leases items, runs the phase-1 `watchman.Decide`, applies the hard limits in Go before and after the model, and writes through the hub's answer core, extracted to `internal/askanswer` and shared by the hub and the twin. Hard limits are also enforced where the action lands: a chaining `pre-push` hook per armed worktree, a branch-protection warning at arm time, and a `workbench watchman-guard` PreToolUse hook. The Desktop arms through the CLI, reads the journal from the database and writes only the owner's feedback columns.

**Tech Stack:** Go 1.26 (`internal/watchman`, new `internal/watchmanact`, new `internal/askanswer`, `internal/db`, `internal/daemon`, `internal/tools`, `internal/hub`, `internal/specreview`, `internal/devpack`, `internal/prompts`, `cmd`), SQLite/goose, git hooks (POSIX sh generated from Go), SwiftUI + GRDB (`WatchtowerDesktop`).

**Spec:** `docs/superpowers/specs/2026-11-16-watchman-design.md` — §2 (Sleep only), §3, §4, §5, §6, §7, §8.1/§8.3 (morning feedback as a source), §10, §11, §11a, §12 item 2, §13, D1–D43; phase 2 scope is §12 item 2 as amended by **D43** (ask #1578): Sleep only, every decision journalled unsure, no Away mode, no relay or phone escalation, the §5 hard limits park. Contracts in §13 were approved in ask #1373.

## Global Constraints

- Umbrella branch `feature/watchman`; every task PR targets it, never `main`. The umbrella PR stays draft until Task 19 is merged.
- **New migrations continue the Watchman numbering** (this plan adds `00198_watchman_phase2.sql`); never edit 00194–00197 while the tasks run. Task 20 renumbers the Watchman migrations past `origin/main`'s latest before the umbrella merges.
- Phase 2 acts in **Sleep only**. `watchman.Mode` still returns `away` (spec §2 rules) but nothing acts in it until phase 3; Off and Away leave items queued. No relay, no phone, no CloudKit code in this phase.
- **Every twin decision is journalled unsure** (`watchman_items.unsure = 1`), whatever the category's measurement or the model's confidence (D43).
- Hard limits are checked in Go on the item **before** the model and on the choice **after**; the model never decides a hard limit (WATCHMAN-01). Permissions and commands go through the §5 table (`CheckLimits`); ask text goes through a Go keyword/pattern table (`AskParkedBy`, Task 9). The light-tier label call may only **add** a park, never remove one, and a label-call error or timeout parks (fail closed). Before any twin Approve, Go parks: a diff round that touches `docs/inventory/**` or adds, changes or removes a `Test<Module>NN_*` guard test (`ProtectedChange`); a spec/plan that proposes a contract change (`ProtectedDoc`, Task 12, D46): anywhere in the whole snapshot a `docs/inventory/` path or a guard-test name (`Test[A-Z][A-Za-z]*[0-9]{2}_`), or one paragraph or table row naming a contract id from `docs/inventory/*.md` headings (or its family wildcard) together with a change word; merely citing a contract does not park. No `docs/inventory` directory → no ids (paths and guard names still apply); an existing inventory directory that cannot be read, or has files but yields no ids, parks (fail closed). The owner can add limits, never remove a built-in row.
- Until a workbench is learned (`learned_through` set) and its relabel pass is done (`relabel_pending = 0`), every item is parked `Watchman is still learning this workbench` (Task 9).
- The twin writes only through `askanswer.Answerer` (asks, spec marks, permissions, typed lines) or the review-round functions in `internal/db`; every write is a compare-and-set and the item's outcome is written in the **same transaction** as the answer (WATCHMAN-02).
- Nothing acts while `platform.Away` says present or returns an error (WATCHMAN-04). An item already `deciding` when the owner returns finishes and races normally.
- `internal/watchman` stays a non-acting leaf (WATCHMAN-06: no import of `internal/hub/...`, `internal/sessionhost/...`, `internal/tools/...`). Acting code lives in the new package `internal/watchmanact`; `watchman.Mode` takes plain values, not a `platform.Away`.
- Owner verbs (`watchman arm|disarm|sleep|limits add|limits remove`) are refused under an AI agent's environment markers (`refuseUnderAgent`, AGENT-07). The Desktop arms only through these verbs (one implementation of arming, sidecar and hook install).
- Tier and ledger: decisions on the strong tier with purpose `watchman.decide`; the extra before/after park check of ask text reuses the light-tier `watchman.label` call (purpose `watchman.label`), after the Go table. Prompt changes go through `.claude/skills/add-ai-prompt` on both providers with a version bump and reason.
- Lease 10 min (`LeaseFor`), at most 2 items deciding at once (`MaxDeciding`), attempt ≥ 3 → parked (`MaxAttempts`), a provider refusal is retried once after 15 min (`ProviderRetry`) then parked.
- Item enums (shared by Go and Swift): `kind` ∈ `ask`, `review_doc`, `check`, `handover`, `permission`, `review_code`, `guard`; `state` ∈ `queued`, `deciding`, `done`; `outcome` ∈ `''`, `answered`, `handed`, `parked`, `owner_first`, `approved`, `changes`; `feedback` ∈ `''`, `ok`, `corrected`.
- Copy, verbatim (spec): `Parked for the owner: <reason>`; `Handed to the owner: <what he must do>`; check answer `The owner is away — verify what you can yourself (tests, screenshots, make desktop-shots) and continue`; brief line `The owner handed this session to Watchman; asks are answered by his twin; do not wait, keep working.`; arm-sheet warning `main is not protected on GitHub — an agent's gh pr merge cannot be stopped here`; `Watchman is not running — the daemon is stopped`; journal `the owner answered first`, `session ended`, `the Mac slept from <HH:MM> to <HH:MM>, nothing ran`; strip `Watchman · Sleep since <HH:MM>`, **Take back**, **Hand to Watchman**; target panel `Watchman has this target · Sleep since <HH:MM>`; tray **Hand all running sessions to Watchman**, **Going to sleep**; Home `Overnight Watchman decided <n> — <u> unsure, <w> waiting for you`; `Agent analytics turned on — Watchman learns from your sessions`; journal sections `WAITING FOR YOU`, `Checks nobody ran`, actions **OK**, **Correct…**, **Open session**. Any other copy is the builder's and lives in a view model with a test.
- Desktop screens follow `docs/design/desktop-style-guide.md`: built from `WatchtowerDesktop/Sources/DesignKit/`, **one mockup per state registered in `DesignShotCatalog`** (the spec §11a shots already exist; each Swift task re-renders its real screens under the same names, replacing the `*Mock` scene for that shot), **all UI copy in the view model with a test**, **colours only via `Tone`** (no hex, no `.red`). Fixture data only (`acme`, `example.com`).
- Public repo hygiene: no live data (ids, names, texts, counts from the owner's database) in code, tests, fixtures, docs or commits. Tests never wait on wall-clock time (synctest, fake clocks, injected `Clock`); tests that spawn processes reap them; packages whose tests create git repositories call `gittest.DisableBackgroundGit()` in `TestMain`.
- No background builds or tests. The agent never runs `watchman learn|backtest|arm` against the live database.
- **Guard suites.** Every Go task runs, besides its own package: `go test ./internal/watchman ./internal/db -run 'Watchman|WATCHMAN|Schema|AllTablesExist'`. Tasks touching `cmd` add `go test ./cmd -run 'Watchman|Permission|Finish|Integrate|Proj1[2-4]|Proj21'`; touching `internal/tools`: `go test ./internal/tools -run 'Proj14|SpecReview0|AskOwner|Finish|Agent0|Dev06'`; touching the brief or the agents' tools (AGENT-0x / DEV-06): `go test ./internal/tools ./cmd -run 'Agent0|Dev06|Proj12|Proj22'`; touching the Inbox (C1, the Watchman entry): `make test-swift FILTER='InboxFolder|ActionStrip|Inbox'`; touching `internal/hub`: `go test ./internal/hub/...`; touching prompts: `go test ./internal/prompts ./internal/llmusage` and `go test ./internal/transporttest ./internal/providers -run LLMTRANSPORT`; touching the schema: `go test ./internal/db -run 'TestSchemaGolden|TestDesktopTestSchema|Live01'`. Swift tasks: `make test-swift FILTER='Watchman|<their classes>'`, `make lint-swift` (swiftlint; `make lint-diff` is Go-only), and `make desktop-shots DESKTOP_SHOTS=<dir>` to look at their screens. The full gate (`make test`, `make test-swift`, `make lint-all`) runs once per phase by the controller, not per task.

## Contracts touched (spec §13, ask #1373)

PROJ-12 (brief line, answer delivery), PROJ-14 (finish gate), PROJ-21 (third permission decider), SPECREVIEW-0x (twin verdict), REVIEW-0x (twin round / Approve), **AGENT-0x / DEV-06** (the brief line; no new MCP tool for agents — Task 13 runs their guards), **C1 Inbox** (one more entry, **Watchman**, with its own empty-state copy key — Task 16 runs the Inbox guards), Go hub (`internal/askanswer`), WATCHMAN-01..06. Each owning task runs the guards of the contracts it touches (Global Constraints, guard suites); Task 19 writes the changelog lines.

## Writers and races (beyond spec §6)

| Data | Writers | Who wins |
|---|---|---|
| `owner_asks.answer`/`status` | Desktop (GRDB), hub (phone), twin (`Answerer`) | the existing `status='open' AND NOT author-loop` CAS; the loser writes nothing (Task 4) |
| `spec_review_marks` | Desktop, `Answerer` for the twin | only inside the winner's answer transaction (Tasks 4, 12) |
| `permission_requests` | Mac, phone (hub), twin (`Answerer.ClosePermission`), hook expiry (`ClosePermissionRequest`) | `status='pending'` CAS; `decided_by` names the winner (`watchman` for the twin) (Tasks 4, 10) |
| `review_rounds` outcome + `review_comments` | Desktop/`workbench review`, twin | the round's open-state guard in `SendReviewRound`/`ApproveReviewRound` (Task 12) |
| `watchman_arming` rows | `watchman arm|disarm|sleep` (CLI, also behind every Desktop control) | whole-row upsert, last write wins (Task 5) |
| `watchman_arming` sleep row | `watchman sleep` (set/clear), daemon upkeep (clear on owner input) | the daemon clears only by CAS on the `armed_at` it read, so a newer press survives (Task 5) |
| `<workspace>/watchman.armed` sidecar | every arming writer after its row write, daemon upkeep each cycle | atomic rename; the newest full rewrite from the database wins (Task 5) |
| `<workspace>/watchman.away` stamp | daemon upkeep only | single writer (Task 5) |
| worktree `core.hooksPath` (worktree config) | `EnsureHooks` (arm, upkeep), `RestoreHooks` (disarm), the owner | restore only if the value is still Watchman's; an owner change is never overwritten (Task 6) |
| `watchman_items` queue columns | wait-point writers (`INSERT OR IGNORE` on `(ref_kind, ref_id)`), daemon cycle scan (same insert) | one row per wait point; the first insert wins (Task 8) |
| `watchman_items` decision columns | twin worker under a lease | lease CAS from `queued`/expired; a finish with a stale lease writes nothing (Tasks 3, 9) |
| `watchman_items` feedback columns | Desktop only | Go never writes them (Task 3 test) |
| `watchman_gaps` | daemon upkeep only | single writer (Task 5) |
| `watchman_extra_limits` | `watchman limits add|remove` (CLI, behind Settings) | plain insert/delete by id (Task 7) |
| `watchman_precedents` from the journal | learning phase only | under the existing learn lock and cursor (Task 14) |

## Review Focus

1. The owner answers an ask at the Mac (or allows a permission on the phone) while the twin's model call is running → the twin's write loses the CAS, nothing is typed into the session, the journal says `the owner answered first`, and no spec marks are written. Test: `TestTwin_OwnerFirstJournalledNothingDelivered` (Task 9), `TestWATCHMAN02_TwinNeverOverwritesOwnerAnswer` (Task 4).
2. The owner comes back (console input, or presence in that session) with items queued and one deciding → no new item is leased, the deciding one finishes. Test: `TestTwin_DecidingItemFinishesAfterOwnerReturns`, `TestTwin_PresentInSessionLeavesQueued` (Task 9).
3. The Mac sleeps or the daemon dies mid-decision → the lease expires after 10 min, the item is retaken, the third failure parks it under **Waiting for you**, and the journal records the sleep gap. Test: `TestTwin_LeaseExpiryRetakenThenParked` (Task 9, synctest), `TestWatchmanUpkeep_RecordsGapAfterSleep` (Task 5).
4. An agent pushes to `main` from a nested script or make target in an armed worktree, where the repository has its own `pre-push` (the leak check) → the push is refused and the repository hook still ran for allowed pushes; after disarm a `core.hooksPath` the owner set meanwhile is kept. Test: `TestPrePush_RefusesMainFromNestedScript`, `TestPrePush_AllowsFeatureBranchAndChainsPrevious`, `TestRestoreHooks_KeepsOwnerLaterChange` (Task 6).
5. The database is locked or unreadable when the guard hook runs → the sidecar decides: armed denies the hard-limit command, unarmed allows; the deny still reaches the agent when the journal insert fails. Test: `TestWatchmanGuard_DBUnreadableUsesSidecar`, `TestWatchmanGuard_JournalFailureStillDenies` (Task 7).

---

### Task 1: Close the hard-limit gaps of phase 1b

**Depends on:** none

**Files:**
- Modify: `internal/watchman/hardlimit.go`, `cmd/workbench_permission_wait.go` (`permissionSummary`)
- Test: `internal/watchman/hardlimit_test.go`, `cmd/workbench_permission_wait_test.go`

**Interfaces:**
- Produces:
  - `const LimitUnreadable HardLimit = "unreadable"` — first row of the table; an unterminated quote or a wrapper around nothing readable parks under it (today it is reported as `main_ref`). `LimitMainRef` no longer matches the `unresolved` marker.
  - `type BranchInfo struct { Current string; Shared []string }` and `PermissionAsk.Branch *BranchInfo` — nil = not recorded (stored rows); non-nil with `Current == ""` = a live read that failed (parks a `reset --hard`). `Shared` holds the default branches and the session's PR base/umbrella branch.
  - `func ParkedBy(r PermissionAsk) (HardLimit, bool)` — unchanged signature.

- [ ] **Step 1: Failing tests** in `hardlimit_test.go`:
  - `TestParkedBy_ResetHardOnSharedLocalBranch` — `git checkout main && git reset --hard HEAD~1` → `reset_shared`; `git branch -f main HEAD~2` → `reset_shared`; `git update-ref refs/heads/master abc` → `reset_shared`; `git reset --hard HEAD~1` with `Branch: &BranchInfo{Current: "feature/watchman", Shared: []string{"main","feature/watchman"}}` → `reset_shared`; same with `Current: "wt/session-3"` → not parked; same with `Current: ""` → `reset_shared`; same with `Branch: nil` → not parked (stored row, unchanged phase-1b behaviour).
  - `TestParkedBy_InlineCommentApostrophe` — `go test ./... # don't cache` → not parked; `git push origin main # it's fine` → `main_ref`; `echo "it's # not a comment" && git push origin main` → `main_ref`; `echo a#b` → not parked (a `#` inside a word is no comment).
  - `TestParkedBy_DescriptionLinesAreComments` — `"go test ./...\n# Run tests\n# then don't push to main"` → not parked.
  - `TestParkedBy_JSONPathFieldsDecodedApart` — `Read` `{"file_path":"/wb/a.go","path":7}` with folder `/wb` → not parked; `Grep` `{"pattern":"x","path":"src"}` → not parked; `Edit` summary `[1]` (a file named `[1]`, relative, folder known) → not parked; `Edit` summary `{"file_path":"/elsewhere/x","old_string":"a"}` → `outside_folder` (object fallback still not a path).
  - `TestParkedBy_UnreadableIsItsOwnRow` — `sudo`, `env FOO=1`, `echo 'open` → `LimitUnreadable`, never `LimitMainRef`.
  - Before writing these, reproduce each gap from the phase-1b final review notes; if a case above already passes, keep it as a regression test and say so in the commit.
- [ ] **Step 2: Failing test** `TestPermissionSummary_EveryDescriptionLineIsAComment` (cmd) — `permissionSummary("Bash", {"command":"go test ./...","description":"Run tests\nthen push"})` = `"go test ./...\n# Run tests\n# then push"`.
- [ ] **Step 3: Run** `go test ./internal/watchman -run ParkedBy` and `go test ./cmd -run PermissionSummary` → FAIL.
- [ ] **Step 4: Implement.** `splitCommands`/`splitWords` treat `#` as a comment start only at a word start outside quotes, up to the newline; `permissionSummary` prefixes each description line with `# `; `filePath` decodes `file_path`, `notebook_path`, `path` each from its own `json.RawMessage` (a non-string value leaves that field empty, it does not unplace the others) and treats a plain-tool summary as the JSON fallback only when it is a valid JSON **object**; `matchResetShared` adds a `checkout|switch <default>` earlier in the same line, `git branch -f|-D|-M <default>`, `git update-ref refs/heads/<default>`, and `reset --hard` while `Branch` says the current branch is shared or unknown.
- [ ] **Step 5: Run** the task's tests and the Go guard suites (Global Constraints, `cmd` row included) → PASS.
- [ ] **Step 6: Commit** `fix(watchman): hard-limit gaps before acting (shared reset, inline comments, description lines, JSON paths, unreadable row)`.

### Task 2: Judge — a handoff's option label is not a claim

**Depends on:** none

**Files:**
- Modify: `internal/watchman/backtest.go` (`twinAnswer` / the `JudgeInput` built for a handoff), `internal/prompts/defaults.go` (`defaultWatchmanJudge`, version map, description)
- Test: `internal/watchman/backtest_test.go`, `internal/prompts/watchman_test.go` (or the existing prompt registry test file that pins the Watchman prompts)

**Interfaces:**
- Consumes: `JudgeInput{Situation, Owner, Twin string; Questions []string; Handoff bool}` (unchanged).
- Produces: `watchman.judge` **v5**; for `Handoff: true` the `Twin` text carries `Handed to the owner: <rationale>` and the confidence, never the chosen option label (live, a handed item is answered with that line, not with the option).

- [ ] **Step 1: Failing tests:**
  - `TestBacktest_HandoffSendsNoOptionLabel` — an ask precedent with options `["Signed in","Could not sign in"]`, a fake twin returning `Choice: "Signed in", Handoff: owner_only`; the fake judge captures its input: `in.Handoff == true`, `!strings.Contains(in.Twin, "Signed in")`, `strings.Contains(in.Twin, "Handed to the owner:")`.
  - `TestBacktest_ConfirmationHandoffJustifiedIsHanded` — options `["Connected it","Skip"]`, twin hands off, fake judge answers `justified` → the item counts in `handed`, not in `bad`.
  - `TestWatchmanJudgePrompt_HandoffLabelIsNotAClaim` — the v5 default text contains the rule that on a handoff the option list may be confirmations of the owner's own action ("signed in", "connected") and choosing none of them is not a claim that it was done, with one worked example; `DefaultVersions[WatchmanJudge] == 5`.
- [ ] **Step 2: Run** `go test ./internal/watchman -run 'Backtest_Handoff|ConfirmationHandoff'` and `go test ./internal/prompts -run WatchmanJudge` → FAIL.
- [ ] **Step 3: Implement** the handoff branch of the twin text and the v5 prompt (reason in the version map: "a handoff is judged on whether the step needs the owner's hands; confirmation-only option labels are not claims (phase-1b triage)"); keep the stored-template refusal of `backtest.go` working for v4 templates.
- [ ] **Step 4: Run** the tests, the Go guard suites and the prompt guard suites → PASS.
- [ ] **Step 5: Commit** `fix(watchman): judge v5 — a handoff's option label is not a claim`.

### Task 3: Store — arming, items, gaps, extra limits

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00198_watchman_phase2.sql`, `internal/db/watchman_arming.go`, `internal/db/watchman_items.go`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), goldens, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated)
- Test: `internal/db/watchman_arming_test.go`, `internal/db/watchman_items_test.go`

**Interfaces:**
- Produces (tables):
  - `watchman_arming(id, scope TEXT CHECK (scope IN ('session','target','sleep')), ref_id INTEGER NOT NULL /* 0 for sleep */, armed_at TEXT NOT NULL, armed_by TEXT NOT NULL /* 'desktop' | 'cli' */, UNIQUE(scope, ref_id))`.
  - `watchman_items(id, workbench_id → projects ON DELETE CASCADE, session_id INTEGER NULL, target_id INTEGER NULL, kind, ref_kind TEXT CHECK IN ('ask','permission','session','round'), ref_id INTEGER NOT NULL, state, outcome, attempts INTEGER NOT NULL DEFAULT 0, lease_until TEXT, not_before TEXT, question TEXT NOT NULL DEFAULT '' /* redacted, ≤ 2048 runes */, choice, rationale, precedent_ids TEXT /* JSON array */, confidence, importance, category, unsure INTEGER NOT NULL DEFAULT 1, park_reason, delivery, round_id INTEGER NULL, cost_usd REAL NOT NULL DEFAULT 0, error TEXT, created_at, decided_at, feedback, feedback_text, feedback_at, check_done_at, UNIQUE(ref_kind, ref_id, kind))` with CHECKs for the enums in Global Constraints; index on `(state, not_before)` and `(workbench_id, created_at)`.
  - `watchman_gaps(id, started_at, ended_at)`; `watchman_extra_limits(id, kind TEXT CHECK IN ('command','tool'), pattern TEXT NOT NULL, created_at, UNIQUE(kind, pattern))`.
- Produces (Go):
  - `type WatchmanArming struct { Scope string; RefID int64; ArmedAt time.Time; ArmedBy string }`; `func (db *DB) UpsertWatchmanArming(a WatchmanArming) error`; `func (db *DB) DeleteWatchmanArming(scope string, refID int64) (bool, error)`; `func (db *DB) ClearWatchmanSleep(seenArmedAt time.Time) (bool, error)`; `func (db *DB) ListWatchmanArming() ([]WatchmanArming, error)`.
  - `type ArmedSession struct { SessionID, WorkbenchID int64; Folder, WorkbenchFolder string; TargetID int64 }`; `func (db *DB) WatchmanArmedSessions() ([]ArmedSession, error)` — live (not finished, not deleting) sessions armed directly or through an armed target whose subtree holds the session's ticket; `func (db *DB) WatchmanSessionArmed(sessionID int64) (bool, error)`.
  - `type WatchmanItem struct` (all columns above as Go fields, times as `time.Time`/`*time.Time`).
  - `func (db *DB) QueueWatchmanItem(it WatchmanItem) (id int64, inserted bool, err error)` — `INSERT … ON CONFLICT DO NOTHING`.
  - `func (db *DB) LeaseWatchmanItem(now time.Time, lease time.Duration, eligible func(WatchmanItem) bool) (*WatchmanItem, error)` — picks the oldest `queued` (with `not_before <= now`) or `deciding` with `lease_until < now` that `eligible` accepts, then CAS-updates it to `deciding`, `attempts+1`, `lease_until = now+lease`; nil when none.
  - `func (db *DB) CountDecidingWatchmanItems(now time.Time) (int, error)`.
  - `type WatchmanOutcome struct { Outcome, Choice, Rationale, Confidence, Importance, Category, ParkReason, Delivery, Error string; PrecedentIDs []int64; RoundID int64; CostUSD float64; DecidedAt time.Time }`; `func (db *DB) FinishWatchmanItemTx(tx *sql.Tx, id int64, lease time.Time, o WatchmanOutcome) (bool, error)` — only while `state='deciding' AND lease_until = lease`.
  - `func (db *DB) RequeueWatchmanItem(id int64, lease time.Time, notBefore time.Time, errText string) (bool, error)`.
  - `func (db *DB) SetWatchmanItemKind(refKind string, refID int64, from, to string) (bool, error)` — only while `queued`.
  - `func (db *DB) AddWatchmanGap(start, end time.Time) error`; `type WatchmanExtraLimit struct { ID int64; Kind, Pattern string }`; `func (db *DB) WatchmanExtraLimits() ([]WatchmanExtraLimit, error)`; `AddWatchmanExtraLimit(kind, pattern string) (int64, error)`; `DeleteWatchmanExtraLimit(id int64) (bool, error)`.

- [ ] **Step 1: Migration** (follow `add-migration`; plain new tables, no rebuild). Mirror into `schema.sql` with a comment citing spec §§2, 4, 6 and this plan's item enums.
- [ ] **Step 2: Failing tests:**
  - `TestWatchmanArming_UpsertLastWriteWins` — two upserts of `('session', 7)` with different `armed_by`; one row, the second's values.
  - `TestClearWatchmanSleep_KeepsANewerPress` — sleep row at t1; `ClearWatchmanSleep(t0)` → false, row kept; `ClearWatchmanSleep(t1)` → true, row gone.
  - `TestWatchmanArmedSessions_TargetSubtree` — target 1 ⊃ 2; session A on 2, session B on an unrelated target, session C finished on 2; arm target 1 → only A.
  - `TestQueueWatchmanItem_OncePerWaitPoint` — two inserts of `(ask, 5, ask)` → second `inserted == false`, one row.
  - `TestLeaseWatchmanItem_OneWinner` — two concurrent `LeaseWatchmanItem` on one queued row → exactly one non-nil.
  - `TestLeaseWatchmanItem_ExpiredLeaseRetaken` — a `deciding` row with `lease_until` in the past is leased again, `attempts == 2`; one with `not_before` in the future is not.
  - `TestFinishWatchmanItem_StaleLeaseWritesNothing` — lease, re-lease (expired), finish with the first lease → false, row unchanged.
  - `TestFinishWatchmanItem_NeverTouchesFeedback` — set `feedback='ok'` directly, finish → `feedback` still `ok` (and no Go function in `watchman_items.go` names a feedback column: a source scan in the test).
- [ ] **Step 3: Run** `go test ./internal/db -run 'WatchmanArming|ClearWatchmanSleep|WatchmanArmedSessions|WatchmanItem'` → FAIL; implement; regenerate `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`; add the four tables to `TestAllTablesExist`.
- [ ] **Step 4: Run** the task tests and the guard suites (schema row included) → PASS.
- [ ] **Step 5: Commit** `feat(watchman): phase 2 store — arming, items, gaps, extra limits`.

### Task 4: One answer path — `internal/askanswer`

**Depends on:** none

**Files:**
- Create: `internal/askanswer/answerer.go`, `internal/askanswer/held.go`, `internal/askanswer/permission.go`, `internal/askanswer/answerer_test.go`
- Modify: `internal/hub/actions/handlers/ask.go`, `deps.go`, `permission.go`, `ask_specreview.go` (call the `Answerer`), `internal/hub/wiring.go` + `internal/hub/hub.go` (`Options.Answerer`), `internal/db/permission_requests.go` (`ClosePermissionRequest`), `cmd/workbench_permission_wait.go` (new argument), `cmd/sync.go` (construct one `Answerer`, hand it to the hub and keep it for the daemon)
- Move: the store/deliver/held tests from `internal/hub/actions/handlers/ask_test.go` that exercise the moved code go to `internal/askanswer/answerer_test.go` with the same names (`go-hub.md` says its tests move with the code)

**Interfaces:**
- Produces:
  - `type Sessions interface` — the subset of `handlers.SessionPort` the delivery uses (`Live`, `Deliver`, the state read); `handlers.SessionPort` embeds it.
  - `type HeldStore interface { Meta(key string) (string, bool, error); SetMeta(key, value string) error }` — `*state.Store` satisfies it; the key stays `handlers_held_asks`.
  - `type Deps struct { DB *db.DB; Sessions Sessions; Held HeldStore; Clock func() time.Time }`; `func New(d Deps) *Answerer`.
  - `type AnswerRequest struct { Ask *db.OwnerAsk; Answer asks.Answer; Marks []db.SpecReviewMark; Also func(tx *sql.Tx) error }`; `type Result struct { Stored bool; Delivery string }`; `func (a *Answerer) Answer(ctx context.Context, r AnswerRequest) (Result, error)` — one transaction: the guarded `UPDATE owner_asks` (today's `storeAnswer` SQL), the marks (only when the update changed a row), `Also` (only when it did); then delivery outside the transaction (`deliverAnswer`).
  - `type PermissionDecision struct { RequestID, SessionID int64; Allow bool; DecidedBy string; Also func(tx *sql.Tx) error }`; `func (a *Answerer) ClosePermission(ctx context.Context, p PermissionDecision) (bool, error)`.
  - `func (a *Answerer) DeliverLine(ctx context.Context, sessionID int64, line string) string` (delivery values unchanged: `submitted`, `typed`, `held`, `no_session`, `cannot_type`); `func (a *Answerer) DeliverHeld(ctx context.Context)`; `const ByWatchman = "watchman"`.
  - `func (db *DB) ClosePermissionRequest(id int64, status, decidedBy string, at time.Time) (bool, error)` — `decidedBy == ""` writes NULL (the hook's expiry and answered-on-Mac closes keep today's behaviour).
  - `hub.Options.Answerer *askanswer.Answerer` — nil = the hub builds its own (tests); the daemon passes the one it shares with the twin. With the hub off, `cmd/sync.go` still builds the `Answerer` over its own session-host port (`hub.NewSessionPort(ctx, db, sessionStart)`, exported from today's `wiring.sessionPort`) and the hub state store opened read-write for the held ledger.

- [ ] **Step 1: Failing tests** (new package):
  - `TestWATCHMAN02_TwinNeverOverwritesOwnerAnswer` — the owner's answer written with the Desktop's SQL first; `Answer` with the twin's → `Stored == false`, `owner_asks.answer` is the owner's, the fake session port saw no `Deliver`, `Also` was not called.
  - `TestAnswerer_MarksOnlyByWinner` — an answer that loses the CAS writes no `spec_review_marks`; a winner writes them in the same transaction (an `Also` that fails rolls back answer and marks).
  - `TestAnswerer_HeldLinesOneLedgerBothOrigins` — a hub-origin and a twin-origin line held (session in a permission prompt); a new `Answerer` over the same `HeldStore` reloads both and `DeliverHeld` delivers both once.
  - `TestAnswerer_SessionGoneStoresAnswer` — no live session → `Stored == true`, `Delivery == "no_session"`.
  - `TestAnswerer_ClosePermissionOwnerFirst` — the Mac's CAS first; `ClosePermission` → false, `decided_by` stays the Mac's.
  - `TestClosePermissionRequest_WritesDecidedBy` (db) — `"watchman"` stored; `""` stores NULL.
- [ ] **Step 2: Run** `go test ./internal/askanswer ./internal/db -run 'Answerer|WATCHMAN02|ClosePermissionRequest'` → FAIL.
- [ ] **Step 3: Implement** by moving `storeAnswer`, `deliverAnswer`, `deliverLine`, `hold`/`saveHeldLocked`/`loadHeld`/`DeliverHeld`/`takeHeld`/`stillAnswered` and the permission `UPDATE` into the package; the handlers keep their request parsing, scope checks, refusals, phone texts and `rememberDelivery`, and call `Answer`/`ClosePermission`. The hub's phone behaviour is unchanged.
- [ ] **Step 4: Run** `go test ./internal/askanswer ./internal/hub/...` (moved tests and every PROJ-16/PROJ-21 Go guard green) and the `cmd` guard row → PASS.
- [ ] **Step 5: Commit** `refactor(hub): the ask/permission answer core moves to internal/askanswer, shared with Watchman`.

### Task 5: Arming, the mode, the sidecar and the daemon upkeep

**Status:** the Mode rule for away-without-the-sleep-test is **pending owner choice (ask #1581)**; everything else in the task is ready.

**Depends on:** Task 3

**Files:**
- Create: `internal/watchman/mode.go`, `internal/watchman/mode_test.go`, `internal/watchmanact/sidecar.go`, `internal/watchmanact/sidecar_test.go`, `internal/watchmanact/main_test.go`, `cmd/watchman_arm.go`, `cmd/watchman_arm_test.go`, `internal/daemon/watchman_upkeep.go`, `internal/daemon/watchman_upkeep_test.go`
- Modify: `internal/watchman/status.go` + `internal/watchman/testdata/status.json` (new keys), `cmd/watchman.go` (status JSON), `internal/daemon/daemon.go` (phase call, setters)

**Interfaces:**
- Produces:
  - `type TwinMode string` with `ModeOff = "off"`, `ModeSleep = "sleep"`, `ModeAway = "away"`.
  - `type ModeInputs struct { Away bool; AwayErr error; AwaySince time.Time; PresentInSession bool; SleepRequestedAt *time.Time; Window *SleepSpan; PhoneLinked bool }`, `type SleepSpan struct { Start, End time.Duration /* since local midnight */ }`.
  - `func Mode(now time.Time, in ModeInputs) (TwinMode, time.Time)` — pure. Common: `AwayErr != nil` or not away or present → Off; away and the sleep test passes (pressed, or ≥ 20 min away inside the window) → Sleep, since = the later of the press / `AwaySince+20m`. **Pending owner choice (ask #1581)** for away with the sleep test failing — one variant ships, the other's test rows are dropped:
    - **Variant A (spec D7 as written):** `PhoneLinked` → Away; no phone → Sleep, since = `AwaySince`.
    - **Variant B (sleep test only):** → Off (`PhoneLinked` → Away is kept for phase 3; nothing acts in it now).
  - `func ParseSleepSpan(text string) (*SleepSpan, bool)` over the stored `HH:MM-HH:MM`.
  - `func WriteSidecar(path string, sessions []db.ArmedSession, targetsArmed bool) error` — atomic (temp + rename), lines `session <id>` and `worktree <abs path>` and, when any target is armed, `targets-armed`; `func ReadSidecar(path string) (Sidecar, error)`; `func SidecarPath(workspace string) string` = `<workspace>/watchman.armed`.
  - `func AwayStampPath(workspace string) string` = `<workspace>/watchman.away` (RFC3339 `away_since`, written/removed by the daemon only).
  - CLI: `watchtower watchman arm (--session N | --target N | --all-running) [--check] [--json]`, `watchman disarm (--session N | --target N | --all)`, `watchman sleep (--on | --off)`; JSON `{ok, armed:[{scope,id,armed_at}], protection_warning, first_time, analytics_turned_on, learning_started, estimate, error}`; `--check` writes nothing and reports `first_time` plus the learn estimate (`decisions`, `need_labels`, `tokens`). **First arm on a workbench** that Watchman is not on for, or that is not learned: arm turns Watchman and Agent analytics on through the same code as `learn --start` (`analytics_turned_on` set once, D21 line `Agent analytics turned on — Watchman learns from your sessions`) and leaves the backfill to the daemon's learning phase (`learning_started`; arm never runs the 5-minute pass itself).
  - `watchman status --json` gains `mode`, `mode_since`, `sleep_requested`, `armed` (list as above), `daemon_running` (pinned; `TestWatchmanStatus_JSONKeysPinned` and `testdata/status.json` updated).
  - Daemon: `func (d *Daemon) SetWatchmanPlatform(away func() (bool, error), awake func(reason string) (release func(), err error))`, `func (d *Daemon) SetWatchmanHooks(ensure func(ctx context.Context, worktree string) error)` (nil until Task 6 wires it), `const WatchmanAwakeReason = "Watchtower: Watchman has a session"`; `phaseWatchmanUpkeep` every cycle.

- [ ] **Step 1: Failing tests:**
  - `TestMode` (table, `internal/watchman`) — AwayErr → Off; not away → Off; away + present in session → Off; away + pressed → Sleep since press; away 25 min inside window → Sleep since AwaySince+20m; away 25 min outside window, phone linked → Away; variant A rows: away 19 min inside window, no phone → Sleep since AwaySince; variant B rows: the same → Off, and no window (fewer than 7 days), no phone, not pressed → Off. This is the WATCHMAN-04 mode half; the acting half is Task 9.
  - `TestWriteSidecar_AtomicAndReadable`, `TestReadSidecar_MissingIsNotArmed`.
  - `TestWatchmanArm_FirstArmTurnsAnalyticsAndLearningOn` (a workbench without Watchman: one arm → `watchman_workbenches` row, `agent_analytics = 1`, `analytics_turned_on == true`; a second arm → false), `TestWatchmanArm_CheckReportsEstimateOnFirstArm`.
  - `TestWatchmanArm_JSONKeysPinned`, `TestWatchmanArm_RefusedUnderAgent`, `TestWatchmanArm_WritesRowThenSidecar` (sidecar lists the session and its worktree), `TestWatchmanArm_CheckWritesNothing`, `TestWatchmanDisarm_RemovesRowAndSidecarLine`, `TestWatchmanSleep_OnOff`, `TestWatchmanArm_AllRunningArmsEachLiveSession`.
  - `TestWatchmanUpkeep_HoldsAwakeWhileArmed` — fake `awake` records one `Hold(WatchmanAwakeReason)` while a row exists across two cycles, release when the last row goes.
  - `TestWatchmanUpkeep_ClearsSleepOnOwnerInput` — sleep row, fake away → false: row cleared; `TestWatchmanUpkeep_KeepsNewerSleepPress` — the row is replaced between read and clear → kept.
  - `TestWatchmanUpkeep_RecordsGapAfterSleep` — fake clock: cycle at 02:10, next at 07:30 while armed → one `watchman_gaps` row 02:10–07:30; a normal interval → none.
  - `TestWatchmanUpkeep_AwayStamp` — first away cycle writes the stamp, present removes it, a second away cycle keeps the first time.
  - `TestWatchmanUpkeep_HoldFailureLogsAndContinues` — `Hold` error → logged by reason only, the cycle goes on, retried next cycle.
- [ ] **Step 2: Run** the new tests → FAIL. Implement. `cmd/sync.go` wires `platform.NewAway().Away` and `platform.NewAwake().Hold` through `SetWatchmanPlatform` (the daemon's assertion carries its own reason; the hub takes none today).
- [ ] **Step 3: Run** the task tests and the guard suites (`cmd` row) → PASS.
- [ ] **Step 4: Commit** `feat(watchman): arming, the Sleep mode, the arm sidecar and the daemon upkeep`.

### Task 6: Git at the ref — chaining hooks and the branch-protection check

**Depends on:** Task 5

**Files:**
- Create: `internal/watchmanact/githooks.go`, `internal/watchmanact/githooks_test.go`, `internal/watchmanact/protection.go`, `internal/watchmanact/protection_test.go`, `internal/watchmanact/testdata/` (fake `gh` script)
- Modify: `cmd/watchman_arm.go` (install on arm, restore on disarm, `protection_warning`), `cmd/sync.go` (`SetWatchmanHooks`)

**Interfaces:**
- Produces:
  - `var ClientHookNames = []string{...}` — the `githooks(5)` client-side names of spec §5 item 1.
  - `func HooksDir(workspace string) string` = `<workspace>/watchman/hooks`.
  - `func EnsureHooks(ctx context.Context, worktree, workspace string) error` — idempotent: writes the hook scripts (POSIX sh from a Go template, the sidecar path baked in), enables `extensions.worktreeConfig`, records the previous effective hooks path once in `<workspace>/watchman/hooks-prev/<sha1(worktree)>`, sets `core.hooksPath` with `git config --worktree` only.
  - `func RestoreHooks(ctx context.Context, worktree, workspace string) error` — restores or unsets only while the current worktree value is still `HooksDir`; an unreadable record leaves the hook (pass-through) and logs.
  - `type Protection struct { DefaultBranch string; OwnerReviewRequired bool; Warning string }`; `func CheckProtection(ctx context.Context, run func(ctx context.Context, dir, name string, args ...string) ([]byte, error), folder string) Protection` — `gh api repos/{owner}/{repo}/branches/{branch}/protection`; unprotected or no required review → `Warning` = the spec text; gh missing or failing → `Could not read main's protection on GitHub — treat it as unprotected`.
- `pre-push` behaviour: armed (`worktree <toplevel>` in the sidecar) → refuse a remote ref `refs/heads/main|master`, any `refs/tags/*`, a deletion, a non-fast-forward (`git merge-base --is-ancestor <remote sha> <local sha>` fails); then, armed or not, run the previous `pre-push` with the same arguments and the saved stdin and return its exit code. Every other name `exec`s the previous hook of the same name when it exists and is executable, else exits 0.

- [ ] **Step 1: Failing tests** (real git in `t.TempDir()`, a bare remote; `TestMain` calls `gittest.DisableBackgroundGit()`):
  - `TestPrePush_RefusesMainFromNestedScript` — armed; `sh push.sh` that runs `make -f M push` that runs `git push origin HEAD:main` → non-zero, the remote's `main` unchanged.
  - `TestPrePush_RefusesTagDeleteAndNonFastForward`.
  - `TestPrePush_AllowsFeatureBranchAndChainsPrevious` — the repository's own `core.hooksPath` dir has a `pre-push` writing its args and stdin to a file; a push of `feature/x` succeeds and the file holds the same args and ref lines; the previous hook exiting 1 fails the push.
  - `TestPrePush_UnarmedPassesThrough` — sidecar without the worktree → push to `main` allowed (only the previous hook runs).
  - `TestHooks_ProxyReturnsExitCode` (`commit-msg` exiting 1 fails the commit), `TestHooks_MissingPreviousExitsZero`.
  - `TestEnsureHooks_WorktreeOnlyNeverSharedConfig` — the shared config's `core.hooksPath` is unchanged; `git config --worktree --get core.hooksPath` is `HooksDir`; a second call changes nothing.
  - `TestRestoreHooks_KeepsOwnerLaterChange`, `TestRestoreHooks_UnsetsWhenNoPrevious`, `TestRestoreHooks_UnreadableRecordLeavesHook`.
  - `TestClientHookNames_CoverInstalledGit` — every hook name in `MANPAGER=cat GIT_PAGER=cat git help hooks` output is in `ClientHookNames`, server-side names excluded; skipped with a logged reason only when git ships no documentation.
  - `TestCheckProtection_FakeGh` — protected with a required review → no warning; 404 → the spec warning verbatim; gh exits 127 → the could-not-read text.
- [ ] **Step 2: Run** `go test ./internal/watchmanact -run 'PrePush|Hooks|ClientHookNames|CheckProtection'` → FAIL; implement; wire into `arm`/`disarm` and the upkeep (`EnsureHooks` for every armed session's worktree each cycle; a failure is logged with the session id and retried next cycle).
- [ ] **Step 3: Failing then passing CLI tests** `TestWatchmanArm_InstallsHooks`, `TestWatchmanArm_ProtectionWarningInJSON` (fake gh on `PATH`), `TestWatchmanDisarm_RestoresHooks`.
- [ ] **Step 4: Run** the task tests and the guard suites (`cmd` row) → PASS.
- [ ] **Step 5: Commit** `feat(watchman): chaining git hooks per armed worktree and the branch-protection check`.

### Task 7: The guard hook and the owner's extra limits

**Depends on:** Task 1, Task 3, Task 5

**Files:**
- Create: `cmd/workbench_watchman_guard.go`, `cmd/workbench_watchman_guard_test.go`, `cmd/watchman_limits.go`, `cmd/watchman_limits_test.go`, `internal/watchman/extralimit.go`, `internal/watchman/extralimit_test.go`
- Modify: `internal/devpack/workbench_settings.go` (+ the Codex hook installer that carries the ask-guard PreToolUse block), `cmd/integrate_workbench.go` (status line), `internal/devpack/*_test.go`

**Interfaces:**
- Produces:
  - `const LimitOwner HardLimit = "owner"`; `func CheckLimits(r PermissionAsk, extra []db.WatchmanExtraLimit) (HardLimit, bool)` — built-in table first (`ParkedBy`), then the owner's rows: `command` = a shell command of the line (after wrapper strip) whose words start with the pattern's words; `tool` = the tool name equals the pattern or ends with `__<pattern>`.
  - `func watchmanGuardDecision(in hookEvent, armed bool, r watchman.PermissionAsk, extra []db.WatchmanExtraLimit) (deny bool, limit watchman.HardLimit)` (cmd, pure).
  - Hook `watchtower workbench watchman-guard --workbench N` (PreToolUse, every tool): not armed → allow after one row read; armed → `CheckLimits` on a `PermissionAsk` built with `permissionSummary(tool, input)`, the session's folder and worktrees and the live branch (`git rev-parse --abbrev-ref HEAD`, failure → `Current: ""`); deny JSON whose reason reads `Parked for the owner: <limit> — continue with other work`, and a `guard` item queued `done/parked` for **Waiting for you**. Database unreadable within 500 ms → the sidecar: deny only when it lists this session or `targets-armed`.
  - `devpack.watchmanGuardSpec = claudeHookSpec("PreToolUse", "workbench watchman-guard --workbench")`, installed and removed in `InstallAskGuardHooks`/`RemoveAskGuardHooks`'s company, reported by `integrate … status`.
  - CLI `watchman limits list [--json]` → `{ok, builtin:[name], owner:[{id,kind,pattern}]}`; `limits add --kind command|tool --pattern P`; `limits remove --id N` (owner verbs; a built-in name has no id and cannot be removed).

- [ ] **Step 1: Failing tests:**
  - `TestWATCHMAN01_HardLimitsDeniedWhileArmed` — one case per §5 row (each `HardLimit` constant, `owner` included) × armed / not armed: armed denies with the parked reason, not armed allows.
  - `TestWatchmanGuard_UnarmedReadsOneRow` (a counting DB wrapper or query log), `TestWatchmanGuard_DBUnreadableUsesSidecar` (locked database: armed sidecar denies, unarmed allows), `TestWatchmanGuard_QueuesParkedItem`, `TestWatchmanGuard_JournalFailureStillDenies`, `TestWatchmanGuard_MCPWriteToolDenied` (`mcp__watchtower-workbench__send_slack_message`).
  - `TestWATCHMAN05_GuardInstalledOnlyByIntegrate` (devpack) — install adds exactly one PreToolUse entry for the guard beside the ask-guard block; remove takes it out; a source scan shows `watchmanGuardSpec` used only by the integrate installers.
  - `TestCheckLimits_OwnerRowsAdd` (`terraform apply -auto-approve` with pattern `terraform apply` → `owner`; `terraform plan` → none), `TestWatchmanLimits_JSONKeysPinned`, `TestWatchmanLimits_RefusedUnderAgent`, `TestWatchmanLimits_RemoveUnknownIDFails`.
- [ ] **Step 2: Run** → FAIL; implement; **Step 3: Run** the task tests, the guard suites (`cmd` row) and `go test ./internal/devpack` → PASS.
- [ ] **Step 4: Commit** `feat(watchman): workbench watchman-guard hook and the owner's extra limits`.

### Task 8: Wait points queue items

**Depends on:** Task 3, Task 5

**Files:**
- Modify: `internal/tools/workbench_asks.go` (`fileAsk`), `internal/tools/workbench_finish.go`, `internal/tools/workbench_finish_gate.go`, the MCP server deps that build these tools (a `WakeWatchman func()` field), `cmd/workbench_permission_wait.go`, `internal/daemon/automation_wake.go` (capability `watchman-wake`, the wake also nudges the twin), `cmd/automations_wake.go` (sender reused), `internal/db/watchman_items.go` (`ScanWatchmanWaitPoints`)
- Test: `internal/tools/workbench_asks_watchman_test.go`, `internal/tools/workbench_finish_watchman_test.go`, `cmd/workbench_permission_wait_test.go`, `internal/db/watchman_items_test.go`, `internal/daemon/automation_wake_test.go`

**Interfaces:**
- Consumes: `db.WatchmanSessionArmed`, `db.QueueWatchmanItem`, `db.SetWatchmanItemKind` (Task 3).
- Produces:
  - Item mapping: question ask → `kind ask`; review ask → `review_doc`; check ask → `check`; permission → `permission`; armed `finish_session` → `review_code` (`ref_kind 'session'`, `ref_id` = session id) and, when `handover_ask_id` is given, `SetWatchmanItemKind('ask', id, 'ask', 'handover')`. `question` = the redacted, clipped ask text or permission summary (`watchman.Redact`, `watchman.Clip`).
  - `func (db *DB) ScanWatchmanWaitPoints(now time.Time) (int, error)` — queues open asks (not automation's) and pending permissions of armed sessions that have no item (the §7 "insert fails" recovery).
  - `const WatchmanWakeCapability = "watchman-wake"`; the SIGUSR2 watcher also ticks the twin channel.
  - Finish gate (armed session, finish check on): `watchmanReviewGate(d *db.DB, session int64, head string) (pass bool, msg string)` — passes when the session's last sent round at the current head tree is approved (by the owner or the twin), or its `review_code` item is `done/parked`; otherwise queues the item (or keeps it) and refuses with `Watchman is reviewing this session's changes; keep working on what is left and call finish_session again after its review round arrives`. Runs after the existing gates; unarmed sessions see no change.

- [ ] **Step 1: Failing tests:**
  - `TestAskOwner_ArmedSessionQueuesItem` (kinds per ask kind), `TestAskOwner_UnarmedQueuesNothing`, `TestAskOwner_QueueFailureStillFiles` (an injected insert failure: the ask is filed, the result has no error, the log names the ask id), `TestAskOwner_ArmedWakesDaemon` (fake `WakeWatchman` called once).
  - `TestPermissionWait_ArmedQueuesItem`, `TestPermissionWait_QueueFailureStillWaits`.
  - `TestProj14_FinishArmedQueuesReviewAndRefuses`, `TestProj14_FinishArmedPassesOnApprovedRoundAtHead`, `TestProj14_FinishArmedPassesWhenReviewParked`, `TestProj14_FinishUnarmedUnchanged`, `TestFinishSession_ArmedHandoverMarksItem`.
  - `TestScanWatchmanWaitPoints_QueuesMissed` (an armed session's open ask and pending permission without items → 2 queued; a second scan → 0; an automation's ask → never).
  - `TestWatchmanWake_SignalsOnlyCapableDaemon`.
- [ ] **Step 2: Run** → FAIL; implement; **Step 3: Run** the task tests and the guard suites (`cmd` and `internal/tools` rows) → PASS.
- [ ] **Step 4: Commit** `feat(watchman): wait points queue the twin's items`.

### Task 9: The twin worker — asks, checks, handovers

**Depends on:** Task 1, Task 4, Task 5, Task 8

**Files:**
- Create: `internal/watchman/asklimit.go`, `internal/watchman/asklimit_test.go`, `internal/watchmanact/twin.go`, `internal/watchmanact/twin_ask.go`, `internal/watchmanact/answer_map.go`, `internal/watchmanact/twin_test.go`, `internal/daemon/watchman_twin.go`, `internal/daemon/watchman_twin_test.go`
- Modify: `internal/daemon/daemon.go` (phase + wake), `cmd/sync.go` (wire the shared `Answerer`, the generator, `sessionstart` for handovers)

**Interfaces:**
- Consumes: `askanswer.Answerer.Answer` (Task 4), `watchman.Mode` (Task 5), `db.LeaseWatchmanItem`/`FinishWatchmanItemTx`/`RequeueWatchmanItem` (Task 3), `watchman.Decide`, `watchman.LiveContext`, `watchman.NewLLMLabeler`.
- Produces:
  - `const (MaxDeciding = 2; LeaseFor = 10 * time.Minute; MaxAttempts = 3; ProviderRetry = 15 * time.Minute)`.
  - `func AskParkedBy(text string) (HardLimit, bool)` in `internal/watchman/asklimit.go` (pure Go table, one test row per entry): merge, push or rebase onto `main`/`master`; release, tag, TestFlight; send or post a message outside the workbench (Slack, mail, a PR/issue comment); approving an inventory contract or a guard test (`docs/inventory`, `Test<Module>NN_`). Run on the question before the model and on question + choice after.
  - `type TwinDeps struct { DB *db.DB; Answerer *askanswer.Answerer; Decide func(ctx context.Context, it watchman.Item) (watchman.Decision, error); Parked func(ctx context.Context, text string) (bool, string, error) /* light-tier label: may only add a park; an error or timeout parks */; Away func() (bool, error); AwaySince func() time.Time; PhoneLinked func() bool; StartSession func(ctx context.Context, workbenchID, targetID int64, brief string) error; Clock func() time.Time }`.
  - `func NewTwin(d TwinDeps) *Twin`; `func (t *Twin) RunOnce(ctx context.Context) int` — leases while fewer than `MaxDeciding` are deciding, each item in its own goroutine, returns how many it started; `func (t *Twin) Wait()`.
  - `func answerFromDecision(p asks.Payload, dec watchman.Decision) (asks.Answer, error)` — one question: the option or "Other" text; several: the `<question>: <answer>` lines of decide v2 mapped back per question; an unmappable reply is an error.
  - Learning gate: an item of a workbench that is not learned or has `relabel_pending > 0` → outcome `parked`, `Parked for the owner: Watchman is still learning this workbench`, no model call.
  - Outcomes: answered (unsure=1); handoff → answer `Handed to the owner: <rationale>`, outcome `handed`; parked (before: `AskParkedBy` on the question, then the label call; after: the same on question + choice — either one parks, the label never un-parks) → answer `Parked for the owner: <reason>`, outcome `parked`; check → the fixed check answer, outcome `answered`, listed under **Checks nobody ran** until `check_done_at`; handover options `Continue in a new session` / `Park for the morning` / `Accept as done` (continue → `StartSession` on the item's target with the handover text; the new session is armed only through the target's arming); lost CAS → `owner_first`; delivery `no_session` → journal `session ended`.
  - `phaseWatchmanTwin`: every cycle and on the wake channel: `ScanWatchmanWaitPoints`, then `RunOnce`; on shutdown waits for running items (their leases expire if killed).

- [ ] **Step 1: Failing tests** (fakes for `Decide`, `Parked`, the session port; synctest for time):
  - `TestTwin_AnswersAskUnsure` — confidence `high` → stored answer is the option, item `answered`, `unsure == 1`, precedent ids and rationale stored, delivery `submitted`.
  - `TestTwin_OwnerFirstJournalledNothingDelivered`.
  - `TestWATCHMAN04_NothingActsWhilePresentOrUnreadable` — `Away` returns (false, nil) and (false, err) → `RunOnce == 0`, items stay `queued`, `Decide` never called.
  - `TestTwin_PresentInSessionLeavesQueued`, `TestTwin_PhoneLinkedAwayLeavesQueued` (Away mode does not act in phase 2), `TestTwin_DecidingItemFinishesAfterOwnerReturns`.
  - `TestTwin_LeaseExpiryRetakenThenParked` — a `Decide` that blocks until the lease passes (synctest), retaken; three failures → `parked` with `park_reason` naming the failures.
  - `TestTwin_ProviderRefusalRetriesOnceThenParks` — a plan-limit error → `not_before = now+15m`, no lease before it; a second refusal → `parked` with the provider's reason.
  - `TestAskParkedBy` (table, `internal/watchman`: each entry matched and a near-miss not matched, e.g. `merge feature/x into main` parked, `merge main into feature/x` not).
  - `TestTwin_HardLimitParksBeforeModel` (Go table hit, label says not parked → still parked, `Decide` not called), `TestTwin_LabelOnlyAddsPark` (Go table clean, label parked → parked), `TestTwin_LabelErrorParks` (label error and label timeout → parked with the reason, `Decide` not called), `TestTwin_ChoiceParkedAfterModel`.
  - `TestTwin_UnlearnedWorkbenchParks` (no `learned_through`, and `relabel_pending > 0` → parked with the learning text, `Decide` not called).
  - `TestTwin_HandoffAnswersHanded`, `TestTwin_CheckAnswersFixedText`, `TestTwin_HandoverContinueStartsSession`, `TestTwin_HandoverAcceptAnswersOnly`, `TestTwin_SessionGoneJournalled`, `TestTwin_AtMostTwoDeciding`, `TestTwin_UnmappableReplyParks`.
  - `TestWatchmanTwinPhase_WakeRunsWithoutWaitingForCycle` (daemon).
- [ ] **Step 2: Run** `go test ./internal/watchmanact ./internal/daemon -run 'Twin|WATCHMAN04'` → FAIL; implement; **Step 3: Run** the task tests, `go test ./internal/askanswer` and the guard suites (`cmd` row) → PASS.
- [ ] **Step 4: Commit** `feat(watchman): the twin worker answers asks, checks and handovers at night`.

### Task 10: The twin decides permission prompts

**Depends on:** Task 7, Task 9

**Files:**
- Create: `internal/watchmanact/twin_permission.go`, `internal/watchmanact/twin_permission_test.go`
- Modify: `cmd/workbench_permission_wait.go` (the deny text for `decided_by = 'watchman'`), `cmd/workbench_permission_wait_test.go`

**Interfaces:**
- Consumes: `watchman.CheckLimits` (Task 7), `askanswer.ClosePermission` (Task 4), the twin's lease loop (Task 9).
- Produces: `func (t *Twin) decidePermission(ctx context.Context, it db.WatchmanItem) (db.WatchmanOutcome, error)` — builds `PermissionAsk` from the row (tool, summary, `summary_clipped`), the session's folder and worktrees, the live branch, and `PRBase` read live (`gh pr view <n> --json baseRefName` in the session folder; unknown → parked); a hit or a clipped summary → `ClosePermission(Allow: false, DecidedBy: "watchman")`, outcome `parked`; otherwise `Decide` with options `["allow","deny"]`, category `permission`, then the after-check on the choice (an `allow` of a hard-limit request is impossible by construction; the check guards future rows); the outcome is written in `Also`.
- Hook: `permissionDeniedByWatchman = "Watchman (the owner's twin) denied this — the owner decides it in the morning; continue with other work"`; an allow by `watchman` prints the normal allow decision.

- [ ] **Step 1: Failing tests:** `TestWATCHMAN01_TwinNeverDecidesHardLimit` (one permission item per §5 row, `owner` included → parked, `decided_by='watchman'`, status `denied`, `Decide` never called), `TestTwin_PermissionAllowWritesDecidedByWatchman`, `TestTwin_PermissionOwnerFirst` (the Mac's CAS first → `owner_first`), `TestTwin_PermissionUnknownPRBaseParks` (fake gh failing), `TestProj21_WatchmanDenySaysTwin` (cmd: the hook prints `permissionDeniedByWatchman`), `TestProj21_PhoneAndMacUnchangedWithWatchman`.
- [ ] **Step 2: Run** → FAIL; implement; **Step 3: Run** the task tests and the guard suites (`cmd` and `internal/hub` rows) → PASS.
- [ ] **Step 4: Commit** `feat(watchman): the twin decides permission prompts; hard limits are denied for the owner`.

### Task 11: `specreview.AnswerMarks` — the Go dual path of `SpecReviewAnswer`

**Depends on:** none

**Files:**
- Create: `internal/specreview/answer.go`, `internal/specreview/answer_test.go`, `internal/specreview/testdata/answer_marks.json`
- Modify: `internal/hub/actions/handlers/ask_specreview.go` (calls `specreview.BuildAnswer` instead of its own `buildSpecReviewAnswer`), `WatchtowerDesktop/Tests/Core/SpecReviewAnswerFixtureTests.swift` (new), the test-resource wiring the Watchman status fixture already uses

**Interfaces:**
- Produces:
  - `type TwinMark struct { Key, State, Body string }` (`State` ∈ `ok`, `comment`, `not_useful`).
  - `func BuildAnswer(result *Result, marks map[string]db.SpecReviewMark, loop []LedgerEntry, base asks.Answer, verdict string, snapshot string) asks.Answer` — the hub's current builder moved verbatim (same output for the same input).
  - `func AnswerMarks(askID int64, result *Result, loop []LedgerEntry, twin []TwinMark, verdict string, snapshot string, at time.Time) (asks.Answer, []db.SpecReviewMark)` — unknown keys dropped (as unfound quotes are), then `BuildAnswer` over the marks it returns, so the answer's comments are exactly what the marks would produce at the Mac.
- Fixture `answer_marks.json`: a list of cases `{result, ledger, marks, base, verdict, snapshot, want}`; the Go test runs `BuildAnswer` on each, the Swift test runs `SpecReviewAnswer.build` on each, both compare with `want`.

- [ ] **Step 1: Failing tests:** `TestBuildAnswer_FixtureCases` (Go), `testFixtureCasesMatchGo` in `SpecReviewAnswerFixtureTests` (Swift), `TestAnswerMarks_DropsUnknownKeys`, `TestAnswerMarks_CommentsMatchBuildAnswer`, hub `ask_specreview_test.go` unchanged and green.
- [ ] **Step 2: Run** `go test ./internal/specreview ./internal/hub/actions/handlers` and `make test-swift FILTER=SpecReviewAnswer` → FAIL; implement; **Step 3: Run** them, `go test ./internal/tools -run SpecReview0`, `make lint-swift` → PASS.
- [ ] **Step 4: Commit** `refactor(specreview): one Go answer builder with marks, pinned against the Desktop by a shared fixture`.

### Task 12: Twin reviews — spec/plan verdicts and diff review rounds

**Depends on:** Task 8, Task 9, Task 11

**Files:**
- Create: `internal/watchmanact/twin_review.go`, `internal/watchmanact/twin_review_test.go`, `internal/watchmanact/protected.go`, `internal/watchmanact/protected_test.go`
- Modify: `internal/watchman/decide.go` (optional `marks` in the reply for `review_doc` items), `internal/prompts/defaults.go` (`watchman.decide` **v4**); the merge rule in the skill pack is Task 13's

**Interfaces:**
- Consumes: `specreview.AnswerMarks` (Task 11), `askanswer.Answer` with `Marks` and `DeliverLine` (Task 4), `db.CreateReviewRound`, `db.SendReviewRound`, `db.ApproveReviewRound`, the round delivery lines `workbench review send|approve` print (reuse their builder from `cmd/workbench_review.go`, moved to `internal/review…` if it lives in `cmd`).
- Produces:
  - `func ProtectedChange(paths []string, diff string) (string, bool)` — Go only, never the model: true when a path is under `docs/inventory/`, or a diff hunk adds, changes or removes a line declaring `func Test<Module>NN_…` / `func test<Module>NN_…` (Go and Swift; `<Module>` letters, `NN` two digits), or a changed file holds such a guard test inside a changed hunk; the string names the reason. Called before every twin Approve of a `review_code` round, on the round's diff.
  - `func ProtectedDoc(inventoryDir, snapshot string) (string, bool)` — Go only, called before every twin `approve` verdict of a `review_doc` item on the reviewed document's **whole snapshot** (not only its diff). True when:
    - anywhere in the text: a `docs/inventory/` path, or a match of `Test[A-Z][A-Za-z]*[0-9]{2}_` (unconditional);
    - one paragraph (a blank-line-separated block) or one Markdown table row names a contract id parsed at check time from the `## <ID> —` headings of `<repo>/docs/inventory/*.md` (e.g. `PROJ-12`, `WATCHMAN-01`) or a family wildcard of one of those prefixes (`REVIEW-0x`, matched as `<PREFIX>-[0-9]*x`) **and** a change word on word boundaries, case-insensitive: `change`, `changes`, `changed`, `amend*`, `relax*`, `weaken*`, `replace*`, `remove*`, `rename*`, `new contract`, `supersede*`. "follows PROJ-12 unchanged" does not park (`unchanged` is not on a word boundary of `changed`);
    - the inventory directory exists but cannot be read, or holds files yet yields no ids → reason `inventory unreadable` (fail closed). An absent `docs/inventory` → no ids, only the unconditional rule applies.
  - Either check true → outcome `parked`, `Parked for the owner: approving a change to a behavior contract or a guard test is yours` (WATCHMAN-01); the twin may still send `changes`.
  - `Decision.Marks []TwinMarkReply` (`key`, `state`, `body`) — parsed only for category `review_doc`; unknown keys dropped in Go.
  - `review_doc`: the item waits (stays `queued`, `not_before = now + 1 min`) while the spec review row is running or its author loop has not ended; then `Decide` with options `["approve","changes"]` over the findings list (keyed), `AnswerMarks` → `Answer` with marks in the same transaction.
  - `review_code`: create a round on the session's current tree; `Decide` with options `["approve","changes"]` over the reviewer's AI overview and the diff stat; `changes` → one design comment (path NULL) with the rationale, `SendReviewRound`, deliver its line, outcome `changes`; `approve` → only when the session's PR base is known and is not the default branch (`gh pr view --json baseRefName` on the session branch), `ApproveReviewRound`, deliver its approved line, outcome `approved`; base unknown/default → outcome `parked`, `Parked for the owner: merging to main is yours`. After 3 twin rounds on one session without Approve → `parked` (the finish gate then passes, Task 8).

- [ ] **Step 1: Failing tests:** `TestProtectedDoc` (a fixture inventory dir with `## PROJ-12 — …`, `## PROJ-21 — …` and `## REVIEW-01 — …`: "cites PROJ-12 unchanged" → not parked; "PROJ-12 is amended to …" → parked; a contracts table row `| PROJ-21 | relaxed … |` → parked; "REVIEW-0x replaced by …" → parked; PROJ-12 in one paragraph and "changed" only in the next → not parked; a guard-test name such as `TestWATCHMAN01_X` anywhere → parked; `docs/inventory/x.md` anywhere → parked; a plan with no contract ids → not parked; an absent inventory dir → not parked on ids (a guard-test name still parks); an unreadable inventory dir (mode 000) → parked; an inventory dir with files but no headings → parked), `TestProtectedChange` (both ways: `docs/inventory/watchman.md` touched → true; a hunk adding `func TestWATCHMAN07_X`, changing the body of `TestProj21_…`, or deleting `func testProj20_…` (Swift) → true; an ordinary `TestFoo` edit and `docs/features/x.md` → false), `TestWATCHMAN01_TwinNeverApprovesContractChange` (a `review_code` item whose diff edits `docs/inventory/**` → parked, no `ApproveReviewRound`; a `review_doc` of a plan that edits a guard test → parked, no answer verdict `approve`), `TestTwin_ReviewCodeApproveWhenNotProtected`, `TestTwin_ReviewDocWaitsForAuthorLoop`, `TestTwin_ReviewDocWritesVerdictAndMarksInOneTx`, `TestTwin_ReviewDocOwnerFirstWritesNoMarks`, `TestTwin_ReviewCodeApproveOnFeatureBase`, `TestTwin_ReviewCodeMainBaseParks`, `TestTwin_ReviewCodeChangesSendsDesignComment`, `TestTwin_ReviewCodeThirdRoundParks`, `TestTwin_ReviewRoundOwnerClosedFirst` (the owner sent the round first → `owner_first`), `TestDecide_MarksOnlyForReviewDoc`, `TestWatchmanDecidePrompt_V4Marks` (prompt registry pins the marks shape; `DefaultVersions[WatchmanDecide] == 4`).
- [ ] **Step 2: Run** → FAIL; implement; **Step 3: Run** the task tests, the guard suites (`internal/tools`, prompts rows) and `go test ./internal/review... -run Review0` → PASS.
- [ ] **Step 4: Commit** `feat(watchman): twin spec verdicts with marks and twin diff review rounds`.

### Task 13: The brief line and the skill-pack merge rule

**Depends on:** Task 5

**Files:**
- Modify: `cmd/workbench_brief.go` (`renderSessionBrief`), `cmd/workbench_brief_test.go`, `internal/devpack/workbenchskill/watchtower-flow/SKILL.md` (or the pack file that holds the finish/merge rule), the pack version constant in `internal/devpack/pack.go`, `internal/devpack/workbench_flow_skill_test.go`

**Interfaces:**
- Produces: while `WatchmanSessionArmed(session)` the brief carries the spec's line verbatim, after the owner's instructions block (PROJ-22 order unchanged); a read failure leaves the line out and logs. Pack rule: "In a session handed to Watchman, a Watchman **Approve** on the review round counts as the owner's approval for merging this session's PR into its feature or umbrella branch, never into `main`; check CI is green first." Pack version bumped.

- [ ] **Step 1: Failing tests:** `TestProj12_BriefCarriesWatchmanLineWhileArmed`, `TestProj12_BriefWithoutWatchmanLineWhenUnarmed`, `TestWorkbenchFlowSkill_WatchmanMergeRule` (the rule text present, names `main` as excluded), pack version test updated.
- [ ] **Step 2: Run** → FAIL; implement; **Step 3: Run** `go test ./cmd -run 'Proj12|Brief'`, `go test ./internal/devpack` and the guard suites → PASS.
- [ ] **Step 4: Commit** `feat(watchman): the armed session's brief line and the merge rule in the skill pack`.

### Task 14: Learning from the morning — the journal source, no self-reinforcement

**Depends on:** Task 3

**Files:**
- Create: `internal/watchman/source_journal.go`, `internal/watchman/source_journal_test.go`
- Modify: `internal/watchman/source.go` (`DBSources()` gains `journal`), `internal/db/watchman.go` (the ask, permission, spec and review source queries exclude entities the twin decided), `internal/watchman/guard_test.go`

**Interfaces:**
- Produces: source `journal` — `watchman_items` with `feedback='ok'` (choice = the twin's, weight 1) or `feedback='corrected'` (choice = `feedback_text`, weight 3), category = the item's, `source_key` = item id, decided_at = `feedback_at`; cursor like the others. The `ask`, `permission`, `spec` and `review` sources skip any entity with a `watchman_items` row whose outcome is `answered`, `handed`, `parked`, `approved` or `changes` (joined on `ref_kind`/`ref_id`, and `round_id` for rounds), and permission rows with `decided_by = 'watchman'`.

- [ ] **Step 1: Failing tests:** `TestWATCHMAN03_SourcesAreOwnerOnly` extended (closed list now includes `journal`; a twin-answered ask, a `watchman`-decided permission, twin marks and a twin round are never read), `TestJournalSource_OKBecomesPrecedent`, `TestJournalSource_CorrectionWeighsMore`, `TestJournalSource_UnreviewedItemIsNot`.
- [ ] **Step 2: Run** → FAIL; implement; **Step 3: Run** `go test ./internal/watchman` (WATCHMAN-06 still green: no acting imports) and the guard suites → PASS.
- [ ] **Step 4: Commit** `feat(watchman): OK'd and corrected journal entries become precedents; twin writes never do`.

### Task 15: Desktop — arming controls

**Depends on:** Task 5, Task 6

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WatchmanArmingCopy.swift`, `WatchtowerDesktop/Sources/Views/Workbench/WatchmanArmControl.swift`, `WatchtowerDesktop/Sources/Views/Workbench/WatchmanArmSheet.swift`, `WatchtowerDesktop/Tests/Core/WatchmanArmingCopyTests.swift`, `WatchtowerDesktop/Tests/WatchmanArmingTests.swift`
- Modify: `WatchtowerDesktop/Sources/Services/WatchmanCenter.swift` (arm/disarm/sleep/check calls, mode decoding), `WatchtowerDesktop/Sources/WatchtowerCore/Models/WatchmanStatus.swift` (tolerant `mode`, `mode_since`, `armed`, `sleep_requested`, `daemon_running`), `Views/Workbench/WorkbenchSessionStrip.swift`, `Views/Workbench/WorkbenchTargetPanel.swift`, `Views/TrayMenuView.swift`, `Tests/DesignShots/DesignShotFixtures+Watchman.swift` (strip/target/tray/arm-sheet shots render the real views), `Tests/Support/WatchmanStatusFixtures.swift`, `Tests/Core/WatchmanStatusDecodingTests.swift`, `docs/guide/features/watchman.md`

**Interfaces:**
- Consumes: `watchman arm|disarm|sleep [--check] --json`, `watchman status --json` keys (Task 5), `protection_warning`, `first_time` (Task 6); `watchman learn --workbench N --json` for the first-arm estimate.
- Produces: `WatchmanArmingCopy` (every string of the strip, panel, tray items and arm sheet, incl. the spec copy, the analytics line and the accepted residual risk of spec §5 item 4: deleting outside the worktree or messaging people from a script with its own token is not caught); `WatchmanCenter.arm(_ scope:)`, `.disarm(_:)`, `.setSleep(_:)`, `.check(_:) -> WatchmanArmCheck`.

- [ ] **Step 1: Failing tests:** `WatchmanArmingTests.testFirstArmSheetShowsAnalyticsLineAndStartsLearning` (a workbench not learned: the sheet shows the estimate, the D21 line and the parked-while-learning note `Until learning finishes, Watchman parks everything for you`; **Hand to Watchman** calls `watchman arm` once, which turns analytics and learning on), `WatchmanArmingCopyTests` (each string, `Sleep since` formatting from `mode_since`, the warning line only when `protection_warning` is non-empty), `WatchmanStatusDecodingTests.testModeKeysDecodeAndMissingIsOff`, `WatchmanArmingTests.testArmCallsCLIThenReloads`, `testFirstArmShowsSheetWithEstimateAndWarning`, `testArmFailureShowsErrorAndKeepsControl` (CLI error → the control shows the error, the strip stays unarmed), `testTrayHandAllRunningCallsAllRunning`.
- [ ] **Step 2: Run** `make test-swift FILTER='WatchmanArming|WatchmanStatusDecoding'` → FAIL; implement; render `make desktop-shots` for `watchman-strip-*`, `watchman-target-panel-*`, `watchman-tray-menu`, `watchman-arm-first-time` and compare with the spec mockups.
- [ ] **Step 3: Run** `make test-swift FILTER='Watchman|DesignShots'` and `make lint-swift` → PASS; the guide page gets a "Hand a session to Watchman" section (stay under the 8 KB page cap: `go test ./docs/guide`; split into a second page if needed).
- [ ] **Step 4: Commit** `feat(watchman): Hand to Watchman on the session strip, target panel and tray`.

### Task 16: Desktop — the journal, the Inbox entry and the Home row

**Depends on:** Task 3

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/WatchmanItem.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/WatchmanJournalQueries.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/WatchmanJournalCopy.swift`, `WatchtowerDesktop/Sources/ViewModels/WatchmanJournalViewModel.swift`, `WatchtowerDesktop/Sources/Views/Inbox/WatchmanJournalView.swift`, `WatchtowerDesktop/Sources/Views/Home/WatchmanHomeRow.swift`, `WatchtowerDesktop/Tests/Core/WatchmanJournalQueriesTests.swift`, `WatchtowerDesktop/Tests/Core/WatchmanJournalCopyTests.swift`, `WatchtowerDesktop/Tests/WatchmanJournalViewModelTests.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxFolderEntries.swift` (a `.legacy` row `watchman`, summary `· <n> waiting`), the Inbox reading pane switch, `Views/Home/HomeView.swift`, `Tests/DesignShots/DesignShotFixtures+Watchman.swift` (journal-*, home-row, inbox-entry shots render the real views), the Inbox empty-state copy key (C1)

**Interfaces:**
- Consumes: the `watchman_items`, `watchman_gaps` columns and enums (Task 3, Global Constraints). The card's "merged into `feature/x`, PR #" outcome line is not tracked in phase 2 (a v1 limit in the feature note); the card shows the decision outcome only.
- Produces: `struct WatchmanNight { date; waiting: [WatchmanItem]; checks: [WatchmanItem]; decided: [WatchmanItem]; gaps: [ClosedRange<Date>]; costUSD }` — a night is 12:00 local to 12:00 the next day; **Waiting for you** = `parked` and `handed` outcomes without feedback; **Checks nobody ran** = `check` items without `check_done_at`; `WatchmanJournalQueries.nights(db, limit:)`, `.liveDeciding(db)`; `WatchmanJournalViewModel` states `loading`, `empty`, `error(Retry)`, `night`, `busy` (a `deciding` item: `Deciding: <question>`), daemon not running (from `WatchmanCenter`'s `daemon_running`) → `Watchman is not running — the daemon is stopped`.

- [ ] **Step 1: Failing tests:** `WatchmanJournalQueriesTests.testNightBoundaryAtNoon`, `testWaitingHoldsParkedAndHanded`, `testChecksListUntilDone`, `testGapsAndCostPerNight`; `WatchmanJournalCopyTests` (Home row text, gap line, owner-first and session-ended lines, every card label); `WatchmanJournalViewModelTests.testReadFailureShowsErrorAndRetryReloads`, `testDecidingItemShowsBusyLine`, `testDaemonStoppedLine`, `testEveryPhase2DecisionShowsUnsure`; `WatchmanMockCopyTests` pins a frame for both new shots.
- [ ] **Step 2: Run** `make test-swift FILTER='WatchmanJournal'` → FAIL; implement (GRDB + MVVM per `add-desktop-feature`); render `watchman-journal-*`, `watchman-home-row`, `watchman-inbox-entry` and compare with the mockups. Two new shots in `DesignShotCatalog`, copy in `WatchmanMockCopy` and the view model with `WatchmanMockCopyTests` covering them: `watchman-journal-not-running` (the journal while the daemon is stopped: `Watchman is not running — the daemon is stopped`, last night kept below) and `watchman-journal-night-unsure` (a phase-2 night: every decided card carries **Unsure**, no sure lines).
- [ ] **Step 3: Run** `make test-swift FILTER='Watchman|Inbox|Home|DesignShots'`, `make lint-swift` → PASS; guide section "Read the night's journal".
- [ ] **Step 4: Commit** `feat(watchman): the morning journal in the Inbox and the Home row`.

### Task 17: Desktop — OK, Correct…, Open session, check done

**Depends on:** Task 16

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Inbox/WatchmanCorrectSheet.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/WatchmanFeedbackQueries.swift`, `WatchtowerDesktop/Tests/Core/WatchmanFeedbackQueriesTests.swift`, `WatchtowerDesktop/Tests/WatchmanCorrectTests.swift`
- Modify: `WatchmanJournalViewModel.swift`, `WatchmanJournalView.swift`, `WatchmanJournalCopy.swift`, `Tests/DesignShots/DesignShotFixtures+Watchman.swift` (correct-sheet shot real)

**Interfaces:**
- Produces: `WatchmanFeedbackQueries.ok(db, itemID)`, `.correct(db, itemID, text)`, `.checkDone(db, itemID)` — the only writers of `feedback*`/`check_done_at`, each `UPDATE … WHERE id = ? AND feedback = ''` (a second tap writes nothing); Correct… sends the text as a typed line through `SessionLineDelivery` (PROJ-12 gates) when the session is alive, else starts a new session on the item's target with the correction as its first instruction (the target panel's start path; not armed unless the owner arms it); the feedback row is written first, so a failed delivery keeps the correction and shows `Not sent — <reason>` with a retry.

- [ ] **Step 1: Failing tests:** `testOKWritesOnce`, `testCorrectStoresTextBeforeDelivery`, `testCorrectAliveSessionTypesLine`, `testCorrectEndedSessionStartsUnarmedSession`, `testCorrectDeliveryFailureKeepsTextAndOffersRetry`, `testCheckDoneLeavesChecksList`, `testOpenSessionSelectsSession`.
- [ ] **Step 2: Run** `make test-swift FILTER='WatchmanCorrect|WatchmanFeedback'` → FAIL; implement; render `watchman-journal-correct-sheet`.
- [ ] **Step 3: Run** `make test-swift FILTER='Watchman|DesignShots'`, `make lint-swift` → PASS; guide section "OK and Correct…".
- [ ] **Step 4: Commit** `feat(watchman): OK, Correct… and check-done from the journal`.

### Task 18: Desktop — Settings editing

**Depends on:** Task 7

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Settings/WatchmanSettingsSection.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/WatchmanSettingsCopy.swift`, `WatchtowerDesktop/Sources/Services/WatchmanCenter.swift` (`profile set|unpin`, `limits list|add|remove`), `Tests/Core/WatchmanSettingsCopyTests.swift`, `Tests/WatchmanCenterTests.swift`, `Tests/Support/WatchmanStatusFixtures.swift`, `Tests/DesignShots/DesignShotFixtures+Watchman.swift` (`watchman-settings-results` re-rendered with the editing controls)

**Interfaces:**
- Consumes: `watchman profile --json`, `profile set --key K --text-file F`, `profile unpin --key K` (phase 1), `watchman limits list|add|remove` (Task 7).
- Produces: per-category profile text **Edit** / **Unpin**, sleep window edit (`HH:MM-HH:MM`, validated in the view model before the CLI call; key `sleep_window`, pinned), extra limits list with **Add** (kind + pattern) and **Remove** on owner rows only (built-in rows shown read-only).

- [ ] **Step 1: Failing tests:** `WatchmanCenterTests.testEditProfileWritesTempFileAndCallsSet`, `testUnpinCallsUnpin`, `testSleepWindowRejectsBadText`, `testAddLimitThenListReloads`, `testBuiltinLimitHasNoRemove`, `testCLIErrorShownInline`; copy tests for every new string.
- [ ] **Step 2: Run** `make test-swift FILTER='WatchmanCenter|WatchmanSettingsCopy'` → FAIL; implement; render `watchman-settings-results`, plus two new `DesignShotCatalog` shots from status/profile fixtures with copy in `WatchmanMockCopy`/`WatchmanSettingsCopy` and tests: `watchman-settings-add-limit` (the add form: kind, pattern, a validation error) and `watchman-settings-profile-edit` (a category's profile text in the editor, **Save** / **Cancel**, the pinned note).
- [ ] **Step 3: Run** `make test-swift FILTER='Watchman|DesignShots'`, `make lint-swift` → PASS; guide section on Settings editing.
- [ ] **Step 4: Commit** `feat(watchman): edit profiles, the sleep window and extra limits in Settings`.

### Task 19: Contracts, feature note, guide

**Depends on:** Tasks 1–18

**Files:**
- Modify: `docs/inventory/watchman.md` (WATCHMAN-01, -02, -04, -05 with the guard tests named in Tasks 4, 5, 7, 9, 10; WATCHMAN-03 and -06 amended for the journal source and `internal/watchmanact`; module list; changelog), `docs/inventory/workbench.md` (PROJ-12 brief line, PROJ-14 finish gate, PROJ-21 third decider — changelog lines citing ask #1373), `docs/inventory/spec-review.md`, `docs/inventory/review.md` (twin verdict and Approve), `docs/features/watchman.md` (phase 2 section: arming, mode, layers, worker, journal, failures, v1 limits — including: the journal card has no "merged into `feature/x`, PR #" line in phase 2; the backtest reruns weekly only (D44); three twin review rounds without Approve park (D45); a night runs 12:00 to 12:00), `docs/features/go-hub.md` (`internal/askanswer`), `docs/features/README.md` (summary line), `docs/guide/features/watchman.md` (sweep), `CLAUDE.md` (feature list line unchanged unless the title changes)

- [ ] **Step 1:** Write the inventory entries; each names its guard tests exactly as they exist (`grep -rn 'func TestWATCHMAN0' internal cmd`).
- [ ] **Step 2: Run** `go test ./docs/guide`, the full Go guard suites and `make test-swift FILTER='Watchman'` → PASS.
- [ ] **Step 3: Commit** `docs(watchman): phase 2 contracts, feature note and guide`.

---

### Task 20: Renumber the Watchman migrations past `origin/main`'s latest before the umbrella merge

**Depends on:** Tasks 1–19

**Files:**
- Rename: `internal/db/migrations/00194_watchman.sql` … `00198_watchman_phase2.sql` (the five Watchman files) to the next free numbers after `origin/main`'s latest migration at that time, in the same order; update every reference (`docs/features/watchman.md`, `docs/inventory/watchman.md` module list, comments in `schema.sql`, the Go migration exception list if it names them)
- Modify: goldens and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated)
- Test: `internal/db/migrations_test.go`

- [ ] **Step 1:** `git fetch origin main`; read the latest number on `origin/main`; merge `origin/main` into the umbrella first so both sets of files are present.
- [ ] **Step 2: Failing test** `TestLoadMigrations_NoDuplicateVersions` — `loadMigrations` over the embedded set returns unique versions (fails today on the 00194/00195 clash once main is merged).
- [ ] **Step 3: Rename** with `git mv`; dev databases that applied the old numbers are throwaway (the owner's copy is recreated); regenerate `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- [ ] **Step 4: Run** `go test ./internal/db` and the full gate (`make test`, `make test-swift`, `make lint-all`) → PASS.
- [ ] **Step 5: Commit** `chore(watchman): renumber the Watchman migrations after main's`.

## Parallel lanes

- Start together: Tasks 1, 2, 3, 4, 11.
- After Task 3: Tasks 5, 14, 16. After Task 5: Tasks 6, 8, 13 (and 7 once Task 1 is in). After Task 6: Task 15. After Task 7: Tasks 10 (with 9) and 18.
- Task 9 waits for 1, 4, 5, 8; Task 12 for 8, 9, 11; Task 17 for 16; Task 19 after 1–18; Task 20 last.
- Shared files across lanes (merge carefully): `internal/prompts/defaults.go` (Tasks 2, 12), `cmd/workbench_permission_wait.go` (Tasks 1, 4, 8, 10), `cmd/sync.go` (Tasks 4, 5, 6, 9), `DesignShotFixtures+Watchman.swift` and the guide page (Tasks 15–18).

## Failures on the new paths → tests

| Path | Failure | Behaviour | Test |
|---|---|---|---|
| Wait point → queue | insert fails | the wait point stays the owner's; the cycle scan queues it | `TestAskOwner_QueueFailureStillFiles`, `TestPermissionWait_QueueFailureStillWaits`, `TestScanWatchmanWaitPoints_QueuesMissed` |
| Wake | signal lost / no capable daemon | next cycle; the journal says the daemon is stopped | `TestWatchmanWake_SignalsOnlyCapableDaemon`, `testDaemonStoppedLine` |
| Decide | crash / Mac sleeps | lease expiry, retake, park at 3 | `TestTwin_LeaseExpiryRetakenThenParked` |
| Decide | provider refuses | retry once after 15 min, then parked | `TestTwin_ProviderRefusalRetriesOnceThenParks` |
| Decide | unusable reply | parked with the reason | `TestTwin_UnmappableReplyParks` |
| Park check | label call errors or times out | parked (fail closed), no model call | `TestTwin_LabelErrorParks` |
| Decide | workbench not learned / relabel pending | parked `Watchman is still learning this workbench` | `TestTwin_UnlearnedWorkbenchParks` |
| Approve | diff touches inventory or a guard test | parked, no Approve | `TestWATCHMAN01_TwinNeverApprovesContractChange` |
| Approve | spec/plan proposes a contract change (id + change word in one paragraph/row), or names a guard test or `docs/inventory/` | parked, no `approve` verdict | `TestProtectedDoc` |
| Approve | inventory directory exists but is unreadable or yields no ids | parked (fail closed); an absent directory parks on paths/guard names only | `TestProtectedDoc` |
| Write | owner answered first | journalled, nothing delivered, no marks | `TestTwin_OwnerFirstJournalledNothingDelivered`, `TestAnswerer_MarksOnlyByWinner` |
| Deliver | prompt open / daemon restart | held in the shared ledger, reloaded | `TestAnswerer_HeldLinesOneLedgerBothOrigins` |
| Deliver | session gone | stored, journal `session ended` | `TestAnswerer_SessionGoneStoresAnswer`, `TestTwin_SessionGoneJournalled` |
| Mode | console unreadable / error | Off for new items | `TestMode`, `TestWATCHMAN04_NothingActsWhilePresentOrUnreadable` |
| Mode | Mac woke after sleep | gap recorded, items resume | `TestWatchmanUpkeep_RecordsGapAfterSleep` |
| Keep-awake | `Hold` fails | logged, retried next cycle | `TestWatchmanUpkeep_HoldFailureLogsAndContinues` |
| Git hooks | previous hook missing / failing; record unreadable | exit 0 / its code / leave pass-through | `TestHooks_*`, `TestRestoreHooks_UnreadableRecordLeavesHook` |
| Protection | gh missing or failing | the could-not-read warning | `TestCheckProtection_FakeGh` |
| Guard | database unreadable; journal insert fails | sidecar decides; deny still printed | `TestWatchmanGuard_DBUnreadableUsesSidecar`, `TestWatchmanGuard_JournalFailureStillDenies` |
| Permission | PR base unknown / branch unreadable | parked | `TestTwin_PermissionUnknownPRBaseParks`, `TestParkedBy_ResetHardOnSharedLocalBranch` |
| Review | author loop still running | item waits | `TestTwin_ReviewDocWaitsForAuthorLoop` |
| Arm | CLI fails | Desktop shows the error, stays unarmed | `testArmFailureShowsErrorAndKeepsControl` |
| Correct… | delivery fails | text kept, retry offered | `testCorrectDeliveryFailureKeepsTextAndOffersRetry` |
| Journal read | query fails | error state with Retry | `testReadFailureShowsErrorAndRetryReloads` |
