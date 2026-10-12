# The session knows its worktree (board #565, WT1–WT4 = #566–#569) — design

**Status:** Proposed 2026-10-12. Contract changes to PROJ-03, PROJ-10 and PROJ-11 approved by the owner on
2026-10-12 (ask #188), together with the per-worktree Files tabs rule (§6.3).
**Business spec:** `2026-10-12-session-worktree-business.md`. **Plan:** `docs/superpowers/plans/2026-10-12-session-worktree.md`.
**Touches:** `cmd/workbench_session_state.go`, `cmd/workbench_check.go` (Stop hook state write),
`cmd/workbench_brief_session.go` (SessionStart run mark), `internal/db/terminal_sessions.go`, a new migration,
`internal/workbenchgit/`, `cmd/workbench_git.go`; WatchtowerCore `TerminalSession`, `WorkbenchGit`, new
`SessionPlace`/`CodeRoot` types and presentations; `CodeFilesCenter`, `CodeIndexCenter`, `OpenQuicklyCenter`,
`CodeNavigationCenter`, `CodeUsagesCenter`, `CodeQuestionCenter`, `WorkbenchesViewModel(+Git, +Sessions)`,
`TerminalCenter`, the Workbench page views; `docs/inventory/workbench.md` (PROJ-03, PROJ-10, PROJ-11),
`docs/features/workbench.md`, `docs/app-guide.md`.
**Related:** #563 (fetch and Remote only in the branch menu — must take `--folder` too, §5.4), #535 (worktree
cleanup on close — produces the "worktree removed" case, §7).

## 1. Problem and root cause

`terminal_sessions.folder_path` is set when the row is created (the workbench folder) and never changes. The
agent moves into a worktree (`EnterWorktree`, `cd`); nothing tells the Desktop. Every code-viewer and git surface
derives its folder from the workbench (`Workbench.folderURL`, 34 call sites; `workbench git … --workbench N` →
`workbenchWithFolder(...).FolderPath`). The session-state hook already receives `cwd` in every Claude Code hook
input (common field) but `sessionStateInput` does not read it.

## 2. Decisions

| # | Decision | Reason |
|---|---|---|
| D1 | The source of truth is the **main agent's `cwd` from the hooks**, stored raw on the row (`agent_cwd`, `agent_cwd_at`). | The only signal that follows `EnterWorktree` and `cd` without polling; already delivered to every hook. |
| D2 | Only **main-thread** events record a cwd (no `agent_id`): `UserPromptSubmit`, main `PostToolUse`, `Notification`, `StopFailure`, the Stop hook, `SessionStart`. A subagent's / teammate's event never does. | A subagent may run in its own worktree (`isolation: "worktree"`); the session's place is the main agent's. |
| D3 | The hook runs **no git** and resolves nothing: it stores the path. Worktree root, branch and "removed" are derived later by `workbench git status --folder` (Go, `internal/gitbin`). | Hooks are async and frequent; PROJ-10's "no git outside a repository" and "no shim" rules stay in one place. |
| D4 | cwd is written **in the same UPDATE as the state** when a state write happens; otherwise one guarded cwd-only UPDATE **only when the cwd differs** from the stored one and the event is newer. A repeat writes nothing. | The #527/#531 busy lessons: the common case (every `PostToolUse` of a working turn, same folder) must not take the write lock. A `cd` mid-turn is rare. |
| D5 | Go accepts a folder for git only if it is the workbench folder, inside it, or inside a worktree that `git worktree list --porcelain -z` **run in the workbench folder** lists. git runs in the requested folder only after that check. | No git in an arbitrary path from the DB; the trusted folder decides what is "the same repository". |
| D6 | The **active root** of a page = the place of the session the page's layout holds (`.session(id)`/`.sessionReport(id)`, visible or under an expanded pane; the last focused if two). No session in the layout → the main folder. | "The session on screen" without a new selection concept; the board alone means main folder (target text). |
| D7 | Code-viewer state is **keyed by `CodeRoot` (workbench id + root URL)** instead of the workbench id; the main root keeps today's UserDefaults keys. | Per-worktree tabs (owner, ask #188); a buffer's URL is fixed at creation, so it can never write into another root (PROJ-03). |
| D8 | New sessions keep `folder_path = workbench folder`. Nothing new derives the start folder from the active root. | Target #569; already true in `startNewSession`/`startTarget` — pinned by a test. |
| D9 | PROJ-08 (knowledge index of the folder's text files) **stays on the main folder**. | Worktree copies would double the entries; the agent in a worktree reads its files directly. No contract change. |
| D10 | A row with **no cwd, or a cwd older than the live run's mark**, has place *unknown*: shown as the main folder, but counted as "maybe here" by the branch switch's agent check for every worktree. | Display stays calm; the PROJ-10 confirmation is never skipped when an agent could be in that worktree. |
| D11 | A **non-live** session shows its last recorded place, and the page follows it. | Reviewing a stopped session's files is the common reason to open it; its next run's `SessionStart` corrects the place. |

Rejected: storing the worktree root/branch in the hook (needs git per event, D3); polling `lsof`/`proc_pidinfo`
for the claude process cwd (TCC-free but racy, platform-specific, no event); a new `terminal_sessions.folder_path`
rewrite (the Desktop owns that column and relaunches in it; D8 needs it to stay the main folder).

## 3. Storage (WT1, #566)

Migration `00NNN_terminal_session_cwd.sql` — **next free number at implementation time** (00109 on this branch
today; `feat/399-codex-agent` and other in-flight branches may take numbers first):

```
agent_cwd    TEXT, -- the main agent's working directory as the last main-thread hook reported it (absolute; Go only); NULL = unknown
agent_cwd_at TEXT, -- that report's event time, agent_state_at format; NULL with agent_cwd
```

Mirrored in `schema.sql`, the golden, and `TestDatabase+Schema.swift`. Down: `DROP COLUMN` both (00102 precedent).
No index (read by row id).

Write rules (all keep `SetTerminalAgentState`'s row guards: `project_id`, `kind='claude'`, `claude_session_id`):

- `SetTerminalAgentState(..., order AgentOrder)` — `AgentOrder` gains `Cwd string` (empty = none). In the same
  UPDATE: `agent_cwd`/`agent_cwd_at` take `Cwd`/the stamp when `Cwd != ''` and the stored `agent_cwd_at` is NULL,
  unreadable or earlier; otherwise unchanged. The cwd never takes part in the "is a change" clause (a cwd alone
  never turns a repeat into a state write).
- `SetTerminalAgentCwd(id, workbenchID, sessionID, cwd string, at time.Time) (bool, error)` — new; writes only the
  two columns, only when `agent_cwd IS NOT cwd` and the stamp is newer (unreadable stamp never blocks). No other
  column changes.
- `MarkTerminalAgentRun(..., cwd string)` — the `SessionStart` run mark stores the new run's cwd stamped with the
  run mark (`''` → NULL). `ClearTerminalAgentState` (no hooks) NULLs both. `SetTerminalClaudeSessionID`
  (`/clear`, a conversation switch in the same process) keeps them — the process did not move.
- `TerminalSession` (Go) gains `Cwd string`, `CwdAt time.Time` (zero when NULL or unreadable).

Hook side (`cmd/workbench_session_state.go`, `cmd/workbench_check.go`, `cmd/workbench_brief_session.go`):
`sessionStateInput`, `stopHookInput` and `sessionStartInput` gain `Cwd string \`json:"cwd"\``. `hookCwd(in)`
returns the cwd to record or `""`: empty for an event with `agent_id`, a SubagentStart/Stop, a non-absolute path,
one longer than 4096 bytes or holding a NUL/newline; otherwise `filepath.Clean`. In `recordAgentStateOver`:

- a state write goes ahead → `order.Cwd = hookCwd(in)` rides in the UPDATE;
- a repeat or a held-back write, and `hookCwd(in) != ""`, `row.Cwd != cwd`, `at > row.CwdAt` →
  `SetTerminalAgentCwd` (busy timeout as today);
- the subagent heartbeat and agent-turn paths never touch cwd.

Output and exit code unchanged (PROJ-11 "never steer"); a failed cwd write is the usual one stderr line and never
skips the state write (`errors.Join`).

## 4. Place model (WT2, #567)

**Go — `workbench git status --folder F`** (also §5): the envelope gains

| key | meaning |
|---|---|
| `folder_requested` | F as given (`""` without `--folder`) |
| `folder_scope` | `main` (F is the workbench folder, inside it, or inside the main worktree), `worktree` (inside a linked worktree of the repo), `outside` (not under any listed worktree, or no repository), `missing` (F does not exist), `""` (unresolved: the worktrees could not be listed — git unavailable, the listing failed or the workbench folder did not resolve; no verdict, keep the last known place) |
| `folder_root` | the folder git ran in: the workbench folder for `main`/`outside`/`missing`; for `worktree`, the worktree's top level joined with the workbench folder's path relative to the main top level when that exists (a workbench in a repository subfolder), else the worktree top level |
| `worktree_name` | base name of the linked worktree's top level; `""` otherwise |

For `outside`/`missing` the rest of the envelope is the **main folder's** status (the page falls back to main),
so one call answers both "where is it" and "what to show". Without `--folder`: `folder_scope: main`,
`folder_root` = workbench folder (older Desktops decode defaults).

**Swift Core:**

- `TerminalSession.agentCwd: String?`, `agentCwdAt: String?` (read-only; Go writes).
- `SessionPlace` — `enum { unknown, main(branch: BranchLabel?), worktree(name, root: URL, branch), removed(name) }`
  built by `SessionPlace.resolve(cwd:status:)` from the row and the status envelope.
- `SessionPlace.trustedCwd(row:, runStart:, live:) -> String?` — D10/D11: nil without a cwd; for a live row, nil
  when `agent_cwd_at` is earlier than the run start (the run's `SessionStart` did not report); else the cwd.
- `SessionPlacePresentation.label(_:) -> (text, systemImage, help)`: `⑂ mobile-a · feature/x` (glyph
  `arrow.triangle.branch`), `main folder · main`, `worktree removed` (help: the last path), unknown → `main folder`
  + the main branch. Detached/unborn reuse `WorkbenchBranchPresentation.label`.

**Desktop — `SessionPlaceCenter`** (on `WorkbenchesViewModel`, AppState-owned so places survive navigation):
`place(sessionID) -> SessionPlace`; a cache keyed by trusted cwd. A worktree cwd is resolved through
`WorkbenchCLI.gitStatus(projectID:folder:)`, at most one call in flight per cwd plus one queued rerun; a cwd equal
to (or inside) the workbench folder uses the main status the header already reads (no extra process). Refreshed
when a row's cwd changes (session reload), on the workbench's `GitRefsWatcher` fire (it watches the common dir, so
`worktrees/*/HEAD` covers every worktree's branch) and on app activation — only for workbenches on screen. A failed
read keeps the last place, marked stale (same rule as the branch button).

UI: the session row (`SessionSwitcherPresentation.Row` gains `place`; `TerminalsSection`, the switcher popover)
shows the label as a secondary line; the header breadcrumbs become `📁 ~/folder › ⑂ mobile-a › ⎇ branch ▾` for a
worktree root (the worktree crumb reveals its folder in Finder).

## 5. Git per worktree (WT4, #569)

### 5.1 Folder resolution (`internal/workbenchgit`)

`ResolveFolder(ctx, o Options, requested string) (ResolvedFolder, error)` — `Options.Folder` is the workbench folder.
`gitbin.InsideRepository(workbench)` first; then `git worktree list --porcelain -z` **in the workbench folder**;
`requested` realpath'd (missing → `missing`, no git); matched against the listed paths (realpath'd, longest prefix
wins, `prunable` entries included only for the `missing` verdict). The result carries `Scope`, `Root`,
`WorktreeName`, `MainTopLevel`. Paths compare case-insensitively on macOS. git unavailable → scope `""` with no
error (the command's own git call reports git as unavailable); a failed listing → scope `""` and the error (status:
`status_ok: false`; `branches`/`switch`/`create`: `refused: "git_failed"`). git runs in `requested`'s root only
after this. The `.claude/worktrees` hidden-name
rule of the Files tree is unrelated and unchanged.

### 5.2 CLI

`status`, `branches`, `switch`, `create` (and `fetch` from #563) take `--folder F` (absolute). `workbenchGitTarget`
resolves the workbench as today, then `ResolveFolder`; `Options.Folder` becomes the root. For `branches`/`switch`/
`create`/`fetch`, scope `outside`/`missing` is a refusal envelope `refused: "folder_not_a_worktree"` with
`refused_detail` naming the scope, exit 0, no git run in F (the house rule: refusals are output, not exit code).
Exit non-zero stays reserved for an unresolvable workbench. Every PROJ-10 guard runs unchanged against the root —
"checked out in another worktree" now naturally includes the main folder.

### 5.3 Desktop branch header

`WorkbenchesViewModel+Git` keys `gitStatus`, `gitBranches`, `pendingBranchConfirmation`, `pendingBranchBase`,
`gitStashNotes` and the refs watcher by `CodeRoot` instead of the workbench id; the header reads the active root's
entry. CLI calls pass `--folder` for a worktree root (never for the main root, so the main path's argv is
unchanged). Before a switch, `CodeFilesCenter.saveEdits(root:workTree:)` saves the buffers of that root (and of any
workbench root inside its work tree) — the PROJ-10 "edits on disk first" bullet per root.

The agent fact (`TerminalCenter.hasLiveClaudeSession(workbenchID:workTree:place:)`): a live `claude` row counts
when (a) its trusted place resolves to the target work tree or inside it, (b) its place is unknown (D10), or
(c) it is not this workbench's row and its `folder_path` is in the work tree (today's rule for other rows). A live
row of this workbench whose place is known to be another worktree no longer counts. `WorkbenchBranchPresentation`
gains the `folder_not_a_worktree` text ("That session's worktree is gone — the branch menu shows the main
folder.").

### 5.4 #563 coordination

Whichever lands second adds `--folder` to `workbench git fetch` and the Remote-only list; the fetch takes the same
`ResolveFolder` refusal. Noted on both board targets.

## 6. Active root for the code viewer (WT3, #568)

### 6.1 `CodeRoot` (Core)

`struct CodeRoot: Hashable, Sendable { workbenchID: Int64; folder: URL (standardized lexically, never
symlink-resolved, so the identity does not depend on whether the folder exists); isMain: Bool }`;
`Workbench.mainCodeRoot`. `CodeRootPolicy.activeSessionID(layout:focusOrder:)` (D6) and
`CodeRootPolicy.root(workbench:worktreeFolder:folderExists:)`, given the `.worktree` place's root (nil for any other
place): that root if the directory exists and is not the workbench folder (compared symlink-resolved), else main.

### 6.2 Re-keying (no behaviour change first)

Every per-workbench dictionary of `CodeFilesCenter` (`tabsByWorkbench`, `gitByWorkbench`, `gitErrors`,
`watchErrors`, `editorErrors`, `reveals`, `cursors`, `recents`, `trees`, `watchers`, `folders`, `bridges`,
`showing`, git throttles) and `BufferKey` move to `CodeRoot`; `CodeIndexCenter`'s `indexes`/`sessions` likewise
(its 5-minute idle release now frees an inactive worktree's index and `--serve` child); `OpenQuicklyCenter`,
`CodeNavigationCenter`, `CodeUsagesCenter`, `CodeQuestionCenter` take the folder from the root they are given
instead of `project.folderURL`. With only main roots passed this step is behaviour-neutral (existing tests green).

### 6.3 Switching the active root

`WorkbenchPageView` computes the active root (D6 + `SessionPlaceCenter`) and hands it to FILES, the Files pane,
the header and Open Quickly. On a change of the active root for a workbench:

1. the editor page's unsent edits are pulled (`takePending`) **into the old root's buffers** (buffer ids are
   unique per root) before the pane shows the new root's tabs; edits that arrive late still reach their buffer;
2. the old root's tabs, buffers, models and autosave stay as they are (owner, ask #188: each worktree keeps its
   set); the new root's tabs are restored (main: `workbench.files.tabs.<id>`, unchanged key; worktree:
   `workbench.files.tabs.<id>.wt.<16-hex SHA-256 of the lexically standardized root>`; recents the same scheme);
3. FSEvents, git marks and the index are started for the new root by the views' `show`, and released for the old
   one by `stopShowing`/the index idle TTL.

A buffer writes only to the URL it was created with (`root + relPath`), so an edit is never saved into another
worktree, whatever the page shows (PROJ-03). Monaco keeps one model per buffer id, so undo survives a round trip.

## 7. Worktree removed

`folder_scope: missing` (or a root directory that vanished under FSEvents' root-changed event) → place `removed`,
the row label `worktree removed`, the page falls back to the main root with no error. That root's clean buffers and
its saved tabs key are dropped. Its **dirty buffers are never written** (the directory is gone; a write would
recreate it): they stay in memory and a banner over the Files pane lists them ("The worktree <name> was removed —
N files had unsaved edits") with **Copy** (the text to the pasteboard, per file) and **Discard**. Accepted v1
limit: the banner lives for the app session (edits not persisted across quit, as today for any unsaved buffer).

## 8. Contract changes (owner approved 2026-10-12, ask #188)

Each lands as an amendment paragraph inside the contract, a `**Status:**` suffix and a changelog line citing
"owner approved 2026-10-12, ask #188". No guard is relaxed, renamed or split; new guards are added.

### PROJ-11 — new paragraph after the 2026-10-11 chat-question paragraph

> Since 2026-10-12 (board #565/#566, owner approved 2026-10-12, ask #188): the state hooks, the Stop hook's state
> write and the `SessionStart` run mark also record the main agent's working directory — the input's `cwd` from
> an event without `agent_id` (a subagent's or teammate's event, a `SubagentStart` and a `SubagentStop` never
> record one; a relative path, one over 4096 bytes or one holding a NUL or a newline is ignored) — in `agent_cwd`
> with its event time in `agent_cwd_at`. It rides in the state write's own UPDATE when one is made; otherwise it
> is written alone only when it differs from the stored cwd and its event is later than `agent_cwd_at`, so an
> unchanged cwd writes nothing and an older report never replaces a newer one. A cwd never changes a state, its
> time, `finished_at`, the error, the turn order, the background count, the agent turns or the chat question, and
> never turns a repeat into a state write. The run mark stores the new run's cwd, the no-hooks clear removes it,
> a conversation switch keeps it. The hooks run no git; the Desktop reads the cwd of a live row only when it is
> not older than that run's start. Output and exit code are unchanged.

Status suffix: `; amended 2026-10-12 for the session's working directory, owner approved in ask #188, board #566`.
New guards: `cmd/workbench_session_state_test.go::TestProj11_CwdNeverChangesTheState`,
`TestProj11_UnchangedCwdWritesNothing`, `TestProj11_SubagentCwdIsNeverRecorded`;
`internal/db/terminal_sessions_test.go::TestProj11_OlderCwdNeverOverwritesANewerOne`,
`TestProj11_CwdWriteNeverTouchesTheState`; `TestProj11_HookNeverWritesStdoutAndExitsZero` and
`TestProj11_NestedSessionNeverMovesTheRow` extended with `cwd` in every input.

### PROJ-10 — new paragraph after the bullet list

> Since 2026-10-12 (board #565/#569, owner approved 2026-10-12, ask #188): the branch button and popover work on
> the worktree of the session the page shows — the workbench folder when the page holds no session or the
> session's place is the main folder, unknown, outside the repository or removed. `workbench git
> status|branches|switch|create` (and `fetch`) take `--folder F`; Go first lists the repository's worktrees with
> git run in the workbench folder and accepts F only when it is the workbench folder, inside it, or inside a
> listed worktree; anything else is refused (`folder_not_a_worktree`) — or, for `status`, reported as
> `outside`/`missing` with the main folder's status — before any git runs in F. Every rule above applies to that
> worktree: the code viewer's edits saved first are those of its root (and of any workbench root inside its work
> tree), the guards and confirmations are checked there, and `--agent-running` is a live embedded `claude`
> session whose recorded place is that work tree or inside it, whose place is not known, or — another
> workbench's or a standalone row — whose folder is in that work tree. A session of this workbench known to work
> in another worktree no longer counts.

Status suffix: `; amended 2026-10-12 to the session's worktree, owner approved in ask #188, board #569`.
New guards: `internal/workbenchgit/folder_test.go::TestProj10_FolderOutsideTheWorktreesIsRefusedBeforeGit`,
`TestProj10_GuardsRunInTheSessionsWorktree` (two worktrees of one repo: a dirty worktree B refuses without
`--stash` while the main folder is clean; a branch checked out in the main folder is refused in B);
`cmd/workbench_git_test.go::TestProj10_FolderFlagEnvelopeAndRefusal`;
`WatchtowerDesktop/Tests/WorkbenchesViewModelGitTests.swift::testProj10_TheBranchMenuFollowsTheSessionsWorktree`,
`testProj10_ASessionInAnotherWorktreeIsNotReportedAnUnknownOneIs`,
`testProj10_ASwitchInAWorktreeSavesThatWorktreesEdits`. Every existing `TestProj10_*`/`testProj10_*` unchanged.

### PROJ-03 — new paragraph after the 2026-10-03 R47 amendment

> Since 2026-10-12 (board #565/#568, owner approved 2026-10-12, ask #188): the code viewer works on the root the
> page's session is in — the workbench folder, or a git worktree of its repository (PROJ-10's `--folder` rule) —
> and the FILES tree's operations and the Files pane's saves write files of that root under the rules above. Each
> root has its own tabs and buffers; a buffer writes only to the file it was opened from, so switching sessions
> never moves an edit, typed or unsent, into another worktree or the main folder: the page's unsent edits are
> handed to the old root's buffers before the new root's tabs show. A root whose worktree was removed is never
> written again: its unsaved edits are offered to copy or discard.

Status suffix: `; amended 2026-10-12 to the session's worktree, owner approved in ask #188, board #568`.
New guards: `WatchtowerDesktop/Tests/CodeFilesCenterRootTests.swift::testProj03_ABufferNeverWritesIntoAnotherWorktree`,
`testProj03_UnsentEditsLandInTheOldWorktreeOnASessionSwitch`, `testProj03_ARemovedWorktreeIsNeverWritten`; every
`testProj03*` in `CodeFileBufferTests.swift` and `TestProj03_AskOwnerNeverWritesTheFolder` unchanged.

The inventory header's module list gains `internal/workbenchgit/folder.go` and the new migration.

## 9. Out of scope / v1 limits

- The mobile companion's workbench slice keeps reading the main folder's branch.
- The session's place shows with its next main-thread hook event; a `cd` inside a single long tool call shows at
  that tool's `PostToolUse`.
- A worktree outside the repository's `git worktree list` (a plain copy) is `outside` → main folder.
- Standalone terminals record no cwd (their rows have no workbench; the hooks' row guard skips them).
- Knowledge search stays on the main folder (D9).
