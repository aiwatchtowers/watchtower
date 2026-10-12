# The session knows its worktree (board #565) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each workbench session shows the worktree and branch its main agent works in; the session on screen sets
the page's folder for FILES, the Files pane (tabs per worktree), git marks, code navigation and the branch menu;
"+" always starts in the main folder; a removed worktree falls back to the main folder.

**Architecture:** The session-state hooks store the main agent's `cwd` on the row (`agent_cwd`, `agent_cwd_at`) in
the state write's own UPDATE, or alone only when it changed. Go's `workbench git … --folder F` resolves F against
`git worktree list` run in the workbench folder and reports scope/root/branch; the Desktop never runs git for this.
The Desktop resolves each session's place through that command, derives the page's active `CodeRoot`, and the
code-viewer centers are re-keyed from workbench id to `CodeRoot`.

**Tech Stack:** Go 1.25 (`cmd/`, `internal/db`, `internal/workbenchgit`, `internal/gitbin`), SQLite + goose,
SwiftUI / GRDB (WatchtowerCore + app target).

**Spec:** `docs/superpowers/specs/2026-10-12-session-worktree-design.md` (source of truth; §8 holds the approved
inventory wording) and `docs/superpowers/specs/2026-10-12-session-worktree-business.md`. Executors read both.

**Plan style (owner preference):** no code bodies. Each task gives files, interfaces, test cases (name + what it
asserts) and verification commands. Task-scope checks only; the full gate runs once, in the final task.

## Global Constraints

- Work in the worktree/branch the controller names; verify `git branch --show-current` before every git command.
- Owner decisions (ask #188, 2026-10-12): PROJ-03, PROJ-10, PROJ-11 changes approved; inventory records cite
  "owner approved 2026-10-12, ask #188". Files tabs: one set per worktree, the other set never lost.
- Guard tests (`TestProjNN_*`/`testProjNN_*`) are never weakened, renamed out of the convention or split. New
  guards follow the convention.
- Go is the only writer of `agent_cwd`/`agent_cwd_at`. The hooks run no git. The Desktop runs no git for places or
  the branch menu (the existing FILES marks reader `GitStatusSnapshot` stays the one Desktop git reader, now per
  root).
- No write in the common case: a hook event repeating the stored cwd and state takes no write lock (#527/#531).
- Hook output and exit codes unchanged (PROJ-11 "never steer"); refusals of `workbench git` are exit-0 envelopes.
- Migration number: next free at implementation time (00109 on this branch today; check
  `ls internal/db/migrations | tail -3` on the branch AND in-flight branches such as `feat/399-codex-agent`).
- Public repo: fixtures use `/tmp`-style temp dirs and placeholder names (`mobile-a`, `feature/x`), never local
  absolute paths of the owner's machine.
- UI strings English only. Async state lives on AppState-owned objects (review-rules "Lifecycle & state").
- Inner loop only per task (`go test ./internal/<pkg>`, `go test ./cmd -run '<regex>'`,
  `make test-swift FILTER=…`, `make lint-diff`); logs to a file with `echo "exit=$?"`, never piped through `tail`.
  Swift tasks run strictly one at a time; Core-level tests (`Tests/Core`) preferred.
- Commits in English, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No push by
  implementers.

## Review Focus

1. **No write lock in the common case.** A `PostToolUse` stream in one folder must never call
   `SetTerminalAgentCwd` (Task 3, `TestProj11_UnchangedCwdWritesNothing` counts writes through a DB seam).
2. **A subagent in its own worktree never moves the session's place** (Task 3, `TestProj11_SubagentCwdIsNeverRecorded`).
3. **No git in an unvetted folder.** `--folder` outside the listed worktrees runs no git there (Task 4, a fake
   runner records every `dir`).
4. **Unsent editor text lands in the old root on a switch** and a buffer never writes outside its root (Task 10).
5. **Unknown place counts as "maybe here"** for `--agent-running` (Task 11) — the only way the confirmation could
   be skipped is a known place elsewhere.

## Task list

| # | Title | Board | Depends on |
|---|---|---|---|
| 1 | Migration: `agent_cwd`, `agent_cwd_at` | WT1 #566 | none |
| 2 | DB writes: cwd in the state UPDATE, `SetTerminalAgentCwd`, run mark/clears | WT1 #566 | 1 |
| 3 | Hooks read and record `cwd` (session-state, Stop, SessionStart) | WT1 #566 | 2 |
| 4 | `workbenchgit.ResolveFolder` (worktree list, scopes) | WT4 #569 | none |
| 5 | CLI `--folder` on `workbench git status|branches|switch|create` | WT4 #569 | 4 |
| 6 | Swift Core: row cwd, status envelope fields, `SessionPlace` + presentation | WT2 #567 | 1, 5 |
| 7 | Desktop: `SessionPlaceCenter`, row label and header crumb | WT2 #567 | 6 |
| 8 | Swift Core: `CodeRoot`, `CodeRootPolicy`, per-root tab/recent keys | WT3 #568 | none |
| 9 | Re-key the code-viewer centers by `CodeRoot` (behaviour-neutral) | WT3 #568 | 8 |
| 10 | Active root on the page: FILES, Files pane, marks, navigation; removed worktree | WT3 #568 | 7, 9 |
| 11 | Branch menu per active root; agent fact by place; "+" in the main folder | WT4 #569 | 5, 7, 10 |
| 12 | Inventory (PROJ-03/10/11), feature notes, app guide | #565 (all) | 3, 5, 10, 11 |
| 13 | Final gate | #565 | all |

Parallel lanes: Go (1→2→3, 4→5) and Swift Core 8 can run in parallel worktrees; Swift tasks 6, 7, 9, 10, 11 run one
at a time. Task 5 coordinates with #563 (`workbench git fetch`): whichever lands second adds `--folder` there.

---

### Task 1: Migration — `agent_cwd`, `agent_cwd_at` (WT1, #566)

**Files:**
- Create: `internal/db/migrations/00NNN_terminal_session_cwd.sql` (next free number)
- Modify: `internal/db/schema.sql` (`terminal_sessions`, after `agent_turns`, one-line comments per spec §3)
- Regenerate: the schema golden, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
- Modify: `internal/db/terminal_sessions.go` — `TerminalSession.Cwd string`, `CwdAt time.Time`; `GetTerminalSession` selects them
- Create: `internal/db/terminal_cwd_migration_test.go`

**Interfaces:** columns `agent_cwd TEXT`, `agent_cwd_at TEXT`; Down drops both. `CwdAt` zero when NULL or
unreadable (same parse as `AgentStateAt`).

- [ ] Tests: `TestMigration00NNN_AddsTheCwdColumns` (fresh row: `Cwd == ""`, `CwdAt.IsZero()`);
  `TestMigration00NNN_DownDropsAndReUpRestores` (a row with a cwd survives Down; re-Up restores NULL columns);
  `TestGetTerminalSessionReadsTheCwd` (valid stamp parsed, unreadable stamp → zero time).
- [ ] Run, expect FAIL → implement → `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`
  → `go test ./internal/db` and `make lint-diff` PASS.
- [ ] Commit `feat(db): terminal_sessions agent_cwd columns (#566)`.

### Task 2: DB writes (WT1, #566)

**Files:** `internal/db/terminal_sessions.go`; tests in `internal/db/terminal_sessions_test.go`.

**Interfaces:**
- `AgentOrder.Cwd string` — in `SetTerminalAgentState`'s one UPDATE: `agent_cwd`/`agent_cwd_at` set when
  `Cwd != ''` and the stored `agent_cwd_at` is NULL, unreadable or earlier than the write's stamp. Not part of the
  "is a change" clause.
- `func (db *DB) SetTerminalAgentCwd(id, workbenchID int64, sessionID, cwd string, at time.Time) (bool, error)` —
  row guards of `SetTerminalAgentState` + `agent_cwd IS NOT ?` + stamp newer (unreadable never blocks); touches
  only the two columns.
- `MarkTerminalAgentRun(id, workbenchID, sessionID, at, cwd string)` — stores cwd (`''` → NULL) stamped with the
  run mark. `ClearTerminalAgentState` NULLs both. `SetTerminalClaudeSessionID` keeps both (doc comment says why).
  Update every call site (Task 3 passes the SessionStart cwd).

- [ ] Tests (guards): `TestProj11_CwdWriteNeverTouchesTheState` (every cwd write — in the state UPDATE, alone,
  run mark — leaves `agent_state`, `agent_state_at`, `finished_at`, failure columns, `agent_turn_end`,
  `agent_tool_run`, `agent_background*`, `chat_question*`, `agent_turns` byte-identical except what the state write
  itself changes; full-row snapshot helper); `TestProj11_OlderCwdNeverOverwritesANewerOne` (alone and inside a
  state write; an equal stamp writes nothing); supporting `TestSetTerminalAgentCwdWritesOnlyAChange` (same cwd →
  false, no change), `TestSetTerminalAgentCwdRowGuards` (other workbench, shell row, other conversation → false),
  `TestRunMarkStoresTheRunsCwdClearRemovesIt`, `TestConversationSwitchKeepsTheCwd`. Existing `TestProj11_*` in
  `internal/db` unchanged and green.
- [ ] Run FAIL → implement (one UPDATE per call, no transaction) → `go test ./internal/db`, `make lint-diff` PASS.
- [ ] Commit `feat(db): record the session's working directory with its state (#566)`.

### Task 3: Hooks read and record `cwd` (WT1, #566)

**Files:** `cmd/workbench_session_state.go`, `cmd/workbench_check.go` (`stopHookInput`, its state write),
`cmd/workbench_brief_session.go` (`sessionStartInput`, run mark); tests in `cmd/workbench_session_state_test.go`,
`cmd/workbench_check_test.go`, `cmd/workbench_brief_session_test.go`.

**Interfaces:**
- `Cwd string \`json:"cwd"\`` on `sessionStateInput`, `stopHookInput`, `sessionStartInput`.
- `func hookCwd(event, agentID, cwd string) string` — `""` for an event with `agent_id`, `SubagentStart`/`SubagentStop`,
  a non-absolute path, > 4096 bytes, a NUL or newline; else `filepath.Clean(cwd)`.
- `recordAgentState`/`recordAgentStateOver` gain the cwd: a state write sets `AgentOrder.Cwd`; a repeat or held-back
  write with `cwd != "" && cwd != row.Cwd && at.After(row.CwdAt)` calls `SetTerminalAgentCwd` (after
  `SetBusyTimeout`); errors joined, never skipping the state write. Subagent heartbeat and agent-turn paths: no cwd.

- [ ] Tests: `TestProj11_CwdNeverChangesTheState` (a `cd` mid-turn: PostToolUse `working` repeat with a new cwd
  writes only the cwd; Stop/idle/StopFailure/prompt write their state as before with the cwd riding along);
  `TestProj11_UnchangedCwdWritesNothing` (50 PostToolUse in one folder → zero `SetTerminalAgentCwd` calls via a
  counting seam, no row change after the first); `TestProj11_SubagentCwdIsNeverRecorded` (subagent PostToolUse over
  `approval` and over a counted `waiting`, SubagentStart/Stop with another cwd → `agent_cwd` unchanged);
  `TestHookCwdTable` (relative, empty, 4097 bytes, NUL, newline, `/a/../b` → `/b`); `TestSessionStartRecordsTheRunsCwd`;
  `TestStopHookRecordsTheCwd`. Extend `TestProj11_HookNeverWritesStdoutAndExitsZero` and
  `TestProj11_NestedSessionNeverMovesTheRow` with `cwd` in every input (a nested `claude -p` in another folder
  moves neither state nor cwd).
- [ ] Run FAIL → implement → `go test ./cmd -run 'TestProj11_|TestHookCwd|TestSessionStart|TestStopHook|TestProj07_|TestChatQuestion' > log 2>&1; echo "exit=$?"`, `make lint-diff` PASS.
- [ ] Commit `feat(workbench): session-state hooks record the main agent's cwd (#566)`.

### Task 4: `workbenchgit.ResolveFolder` (WT4, #569)

**Files:** create `internal/workbenchgit/folder.go`, `internal/workbenchgit/folder_test.go`; helper additions in
`helpers_test.go` (a repo with a linked worktree via `git worktree add` in `t.TempDir()`).

**Interfaces:**
- `type FolderScope string` — `ScopeMain`, `ScopeWorktree`, `ScopeOutside`, `ScopeMissing`.
- `type ResolvedFolder struct { Scope FolderScope; Root, WorktreeName, Requested string }`.
- `func ResolveFolder(ctx context.Context, o Options, requested string) (ResolvedFolder, error)` — `o.Folder` is the
  workbench folder; `requested == ""` → main. `gitbin.InsideRepository(o.Folder)` false → outside (no git).
  `git worktree list --porcelain -z` in `o.Folder` (through `repo.git`, the existing env rules); requested
  realpath'd (missing → `ScopeMissing`, no git); longest-prefix match on realpath'd worktree paths; `Root` per spec
  §4 (subfolder workbench maps into the worktree when that path exists). An error only when git itself fails.

- [ ] Tests: `TestProj10_FolderOutsideTheWorktreesIsRefusedBeforeGit` (outside dir, a sibling repo, a missing path:
  scope outside/missing, the recording runner saw git only in `o.Folder`); `TestResolveFolderScopes` (workbench
  folder, a subdir, main top level of a subfolder workbench → main; linked worktree and a subdir of it → worktree,
  `WorktreeName` = base name; subfolder workbench maps to `<worktree>/<rel>`); `TestResolveFolderSymlinkedPaths`
  (`/tmp` vs `/private/tmp`); `TestResolveFolderNoGitRunsNothing`.
- [ ] `go test ./internal/workbenchgit` (all `TestProj10_*` unchanged) and `make lint-diff` PASS.
- [ ] Commit `feat(workbenchgit): resolve a session folder to a worktree of the workbench repository (#569)`.

### Task 5: CLI `--folder` (WT4, #569)

**Files:** `cmd/workbench_git.go`, `internal/workbenchgit/status.go` (envelope fields), `internal/workbenchgit/switch.go`
(refusal constant), `cmd/workbench_git_test.go`, `internal/workbenchgit/switch_test.go` (new guard only).

**Interfaces:**
- Flag `--folder` (absolute path) on `status`, `branches`, `switch`, `create` (+ `fetch` if #563 is in).
- `workbenchGitTarget` → `(id, Options, ResolvedFolder, error)`; `Options.Folder = resolved.Root`.
- `Status` gains `folder_requested`, `folder_scope`, `folder_root`, `worktree_name`; for outside/missing the main
  folder's status. `branches`/`switch`/`create` with outside/missing → `refused: "folder_not_a_worktree"`,
  `refused_detail: <scope>`, exit 0.

- [ ] Tests: `TestProj10_FolderFlagEnvelopeAndRefusal` (cmd: status in a worktree reports its branch and scope;
  switch with a missing folder refused, nothing written); `TestProj10_GuardsRunInTheSessionsWorktree`
  (`internal/workbenchgit/switch_test.go`: dirty worktree B without `--stash` → `needs_confirmation` while main is
  clean; a branch checked out in main refused `checked_out_elsewhere` in B; a stash made in B carries B's changes
  only); `TestWorkbenchGitStatusWithoutFolderIsUnchanged` (envelope keys of today unchanged, new keys main/root).
- [ ] `go test ./internal/workbenchgit`, `go test ./cmd -run 'TestProj10_|TestWorkbenchGit'`, `make lint-diff` PASS.
- [ ] Commit `feat(workbench): workbench git --folder for a session's worktree (#569)`.

### Task 6: Swift Core — row cwd, envelope, `SessionPlace` (WT2, #567)

**Files:** `WatchtowerCore/Models/TerminalSession.swift` (`agentCwd`, `agentCwdAt` columns, read-only),
`WatchtowerCore/Database/Queries/TerminalSessionQueries.swift` (no writer of the columns),
`WatchtowerCore/Models/WorkbenchGit.swift` (`folderRequested`, `folderScope`, `folderRoot`, `worktreeName`, default
decode), create `WatchtowerCore/Models/SessionPlace.swift`, `WatchtowerCore/Services/SessionPlacePresentation.swift`;
`WorkbenchBranchPresentation` (`folder_not_a_worktree` text); tests in `Tests/Core/SessionPlaceTests.swift`,
`Tests/Core/WorkbenchGitDecodingTests.swift`, `Tests/Core/WorkbenchBranchPresentationTests.swift`.

**Interfaces:** `SessionPlace` (`unknown`, `main`, `worktree(name, root, status)`, `removed(name)`);
`SessionPlace.trustedCwd(row:runStart:live:) -> String?`; `SessionPlace.resolve(cwd:status:workbenchFolder:)`;
`SessionPlacePresentation.label(_:) -> (text, systemImage, help)`.

- [ ] Tests: `testTrustedCwdTable` (no cwd; live with cwd older than the run → nil; not live → last cwd);
  `testResolveTable` (scope main/worktree/outside/missing → place); `testLabels` (`⑂ mobile-a · feature/x`,
  `main folder · main`, `worktree removed`, unknown → `main folder · <branch>`, detached/unborn);
  `testOlderEnvelopeDecodesAsMain`; `testFolderNotAWorktreeRefusalText`; `TerminalSessionQueriesTests` reads the
  new columns from the regenerated schema.
- [ ] `make test-swift FILTER='SessionPlaceTests|WorkbenchGitDecodingTests|WorkbenchBranchPresentationTests|TerminalSessionQueriesTests'`, `make lint-diff` PASS.
- [ ] Commit `feat(desktop-core): session place model and labels (#567)`.

### Task 7: Desktop — `SessionPlaceCenter`, row label, header crumb (WT2, #567)

**Files:** create `Sources/Services/SessionPlaceCenter.swift`; `Sources/Services/WorkbenchCLI.swift`
(`gitStatus(projectID:folder:)`); `WorkbenchesViewModel(+Sessions, +Git)` (own the center, feed cwd changes, refs
watcher and activation); `SessionSwitcherPresentation.Row.place`; `TerminalsSection`, `SessionSwitcherPopover`,
`WorkbenchPageView` header; tests `Tests/SessionPlaceCenterTests.swift`,
`Tests/Core/SessionSwitcherPresentationTests.swift`, `Tests/WorkbenchCLITests.swift`.

**Interfaces:** `@MainActor @Observable final class SessionPlaceCenter { func place(for: TerminalSession, workbench: Workbench) -> SessionPlace; func refresh(workbenchID:) }` — one in-flight read per cwd + one queued; main-folder cwds reuse the header's status (no process); stale flag on failure.

- [ ] Tests: `testAWorktreeCwdIsResolvedOnceAndCached`; `testAMainFolderCwdRunsNoProcess`;
  `testACwdChangeRereadsThePlace`; `testARefsChangeRefreshesEveryWorktreePlace`; `testAFailedReadKeepsTheLastPlaceStale`;
  `testPlacesSurviveLeavingThePage` (start a read → navigate away → result lands); `testRowCarriesThePlace`;
  `testGitStatusPassesFolderOnlyForAWorktree` (argv).
- [ ] `make test-swift FILTER='SessionPlaceCenterTests|SessionSwitcherPresentationTests|WorkbenchCLITests'`, `make lint-diff` PASS.
- [ ] Commit `feat(desktop): session rows and header show the worktree and branch (#567)`.

### Task 8: Swift Core — `CodeRoot` and policy (WT3, #568)

**Files:** create `WatchtowerCore/Models/CodeRoot.swift`, `WatchtowerCore/Services/CodeRootPolicy.swift`;
`CodeTabs.key`, `CodeRecentFiles.key` gain the root overload (main root → today's key); `Workbench.mainCodeRoot`;
tests `Tests/Core/CodeRootPolicyTests.swift`, `Tests/Core/CodeTabsTests.swift`.

**Interfaces:** `CodeRoot { workbenchID, folder, isMain }`; `CodeRootPolicy.activeSessionID(layout:focusOrder:) -> Int64?`;
`CodeRootPolicy.root(workbench:place:folderExists:) -> CodeRoot`; `CodeTabs.key(root:)`, `CodeRecentFiles.key(root:)`
(`…<id>` for main, `…<id>.wt.<16 hex SHA-256 of the realpath>` for a worktree).

- [ ] Tests: `testActiveSessionFromLayout` (single session, split with board, expanded Files over a session split,
  two sessions → last focused, board only → nil); `testRootTable` (worktree existing → worktree root; missing,
  outside, unknown, removed → main); `testMainKeysAreUnchanged`; `testWorktreeKeysDifferPerRoot`.
- [ ] `make test-swift FILTER='CodeRootPolicyTests|CodeTabsTests'` PASS.
- [ ] Commit `feat(desktop-core): code root model and active-root policy (#568)`.

### Task 9: Re-key the code-viewer centers by `CodeRoot` (WT3, #568)

**Files:** `Sources/ViewModels/CodeFilesCenter.swift`, `Sources/Services/{CodeIndexCenter,OpenQuicklyCenter,CodeNavigationCenter,CodeUsagesCenter,CodeQuestionCenter}.swift`,
the views listed in spec §6.2 (`WorkbenchFilesSection`, `CodeFilesPaneView`, `CodeNav/*`); existing tests updated
only for the new parameter (`CodeFilesCenterTests`, `CodeIndexCenterTests`, `OpenQuicklyCenterTests`, …).

**Interfaces:** every API that took `project: Workbench` for a folder takes `root: CodeRoot` (the workbench id
stays reachable as `root.workbenchID`); `BufferKey(root:path:)`; `saveEdits(root:workTree:)`. Callers pass
`project.mainCodeRoot` — no behaviour change in this task.

- [ ] No new behaviour tests; the whole affected suites stay green with unchanged assertions, plus
  `testTwoRootsOfOneWorkbenchKeepSeparateTabsAndBuffers` (center level).
- [ ] `make test-swift FILTER='CodeFilesCenterTests|CodeIndexCenterTests|OpenQuickly|CodeNavigation|CodeUsages|CodeQuestion|CodeFileBufferTests'`, `make lint-diff` PASS.
- [ ] Commit `refactor(desktop): key the code viewer by code root (#568)`.

### Task 10: Active root on the page; removed worktree (WT3, #568)

**Files:** `WorkbenchPageView` (derive the active root from layout + `SessionPlaceCenter`), `WorkbenchFilesSection`,
`CodeFilesPaneView` (root caption `FILES — ⑂ mobile-a`, removed-worktree banner), `CodeFilesCenter`
(`activate(root:previous:)`: pull pending into the old root's buffers, restore the new root's tabs; `rootRemoved(_:)`:
drop clean buffers and the tabs key, keep dirty ones unwritable with Copy/Discard); create
`Tests/CodeFilesCenterRootTests.swift`.

- [ ] Tests (guards): `testProj03_ABufferNeverWritesIntoAnotherWorktree` (same rel path open in main and worktree A,
  edit in A saved → main's file byte-identical); `testProj03_UnsentEditsLandInTheOldWorktreeOnASessionSwitch`
  (fake bridge returns pending text for A's buffer during the switch to B → written to A's file, B untouched);
  `testProj03_ARemovedWorktreeIsNeverWritten` (dirty buffer, root deleted → no file or directory recreated by
  autosave or explicit save; Copy/Discard offered). Supporting: `testOpenInAThenBThenBackKeepsAsTabs` (the target's
  done criterion); `testBoardOnlyPageUsesTheMainFolder`; `testRemovedWorktreeFallsBackToMainWithoutError`. Every
  `testProj03*` in `CodeFileBufferTests` unchanged.
- [ ] `make test-swift FILTER='CodeFilesCenterRootTests|CodeFilesCenterTests|CodeFileBufferTests|CodeRootPolicyTests'`, `make lint-diff` PASS.
- [ ] Commit `feat(desktop): FILES, Files pane and code navigation follow the session's worktree (#568)`.

### Task 11: Branch menu per active root; agent fact; "+" in the main folder (WT4, #569)

**Files:** `WorkbenchesViewModel+Git.swift` (state keyed by `CodeRoot`, `--folder` for worktree roots, refs watcher
per root), `WorkbenchBranchButton`/`WorkbenchBranchPopover` (read the active root), `TerminalCenter.hasLiveClaudeSession`
(place-aware per spec §5.3), `WorkbenchesViewModel+Sessions.swift` (unchanged behaviour, pinned);
tests `Tests/WorkbenchesViewModelGitTests.swift`, `Tests/TerminalCenterTests.swift`, a sessions VM test file.

- [ ] Tests (guards): `testProj10_TheBranchMenuFollowsTheSessionsWorktree` (status/branches/switch argv carry
  `--folder` for a worktree session, none for main or board-only); `testProj10_ASessionInAnotherWorktreeIsNotReportedAnUnknownOneIs`;
  `testProj10_ASwitchInAWorktreeSavesThatWorktreesEdits` (a dirty buffer in main is not saved by a switch in A; one
  in A that cannot be saved holds it). Supporting: `testPlusStartsInTheMainFolderWhileAWorktreeSessionIsShown`;
  `testWorkOnItStartsInTheMainFolder`. All existing `testProj10_*` unchanged.
- [ ] `make test-swift FILTER='WorkbenchesViewModelGitTests|TerminalCenterTests|WorkbenchesViewModelSessions'`, `make lint-diff` PASS.
- [ ] Commit `feat(desktop): branch menu works on the session's worktree; new sessions start in the main folder (#569)`.

### Task 12: Inventory, feature notes, app guide (#565)

**Files:** `docs/inventory/workbench.md` — PROJ-11, PROJ-10, PROJ-03 amendment paragraphs **verbatim from spec §8**,
status suffixes, new guards in each Test guards list, module list (`internal/workbenchgit/folder.go`, the
migration), changelog line `2026-10-12 (board #565, WT1–WT4 #566–#569): … owner approved 2026-10-12, ask #188`;
`docs/features/workbench.md` (new bullet "Session worktree (2026-10-12, board #565)": cwd columns, `--folder`
envelope, `SessionPlace`, `CodeRoot`, removed-worktree banner, v1 limits from spec §9; amend the Code viewer and
Git branch bullets' "workbench folder" wording); `CLAUDE.md` workbench feature line (one clause);
`docs/app-guide.md` (session row/header label, per-worktree Files tabs, "+" in main folder).

- [ ] Check every guard name listed in the inventory exists (`grep -rn` each); no existing guard line removed.
- [ ] Commit `docs(workbench): session worktree — PROJ-03/10/11 amendments, feature notes (#565)`.

### Task 13: Final gate (#565)

- [ ] `bash scripts/dev-health.sh` not overloaded; then `make test`, `make test-swift`, `make lint-all`,
  `go test ./cmd/...` (logs + explicit exit codes).
- [ ] Manual check list for the owner's ask: agent enters a worktree → label updates on its next step; switch
  sessions A/B/back (tabs, unsaved edits); branch switch inside a worktree; "+" while a worktree session is on
  screen; delete a worktree with an unsaved file open.
