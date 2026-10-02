# Workbench header: git branch and branch switching — plan

**Target:** board #233 (owner-approved design, artboard B with the full path; not redesigned here).
**Branch:** `feat/workbench-git-branch`, off `origin/main`.
**Delivery:** one PR. Go tasks (G*) may run as a parallel lane; Swift tasks (S*) are ONE lane, in order.
**Inner loop only per task:** `go test ./internal/<pkg>` / `go test ./cmd -run <Name>`, `make test-swift FILTER=…`, `make lint-diff`. The full gate runs once before the PR.

## Facts that shaped the design

- `ProcessCLIRunner` (`WatchtowerCore/Services/CLIRunner.swift`) drops stdout on a non-zero exit, so a refusal must come back as an exit-0 envelope, not as an error.
- `internal/workbenchcheck` is read-only by contract (PROJ-07, `TestProj07_ReadsNothingButGit`); switching lives in a new package.
- `workbenchcheck.ExecRunner` runs `git` via `PATH`, which reaches the `/usr/bin/git` xcrun shim; only `insideRepository` guards it, so a git folder on a Mac without Command Line Tools can still pop the install dialog today.
- Swift already has a shim-free lookup (`MemoryVaultGit.gitPath`: developer dir → CLT → Homebrew).
- `TerminalCenter` (rows + `liveIDs`, `TerminalSession.kind`/`projectID`/`folderPath`) is already injected into `WorkbenchesViewModel`.
- WatchtowerCore does not read `targets.branch` yet.

## Decisions (fixed for this plan)

1. **Git lives in Go.** The Desktop never runs git. Four new commands share the folder resolution and git guards of `workbench check`:
   `watchtower workbench git status|branches|switch|create --workbench N --json`.
2. **No shim, ever.** New `internal/gitbin.Locate()` checks, in order: `$DEVELOPER_DIR/usr/bin/git`; `readlink /var/db/xcode_select_link` + `/usr/bin/git` (a symlink read, no process); `/Library/Developer/CommandLineTools/usr/bin/git`; `/Applications/Xcode.app/Contents/Developer/usr/bin/git`; `/opt/homebrew/bin/git`, then `/usr/local/bin/git`. Never `/usr/bin/git`, never a bare `PATH` lookup on darwin; other OSes use `exec.LookPath`. No git at all → `git_available:false`, the header hides the button. `workbenchcheck.ExecRunner` maps `"git"` to the same located binary (hardens PROJ-07 without changing its semantics — needs owner OK).
3. **No git process outside a repository.** `gitbin.InsideRepository` (moved from `workbenchcheck.insideRepository`) runs before any git call.
4. **Guards are decided in Go, in one envelope.** `switch` refuses with `needs_confirmation: ["uncommitted_changes"|"agent_running"]` (exit 0) unless `--stash` / `--confirm-agent` are passed. The Desktop supplies the fact `--agent-running` (only it knows its live sessions); Go owns the rule, so refusal without confirmation is tested in Go.
5. **"A Claude Code session is running in the folder"** = a `TerminalCenter` row with `kind == .claude`, in `liveIDs`, and `projectID == workbench.id` or a standardized `folderPath` equal to or inside the workbench folder. A `claude` in the owner's external terminal is not detected (v1 limit, documented).
6. **"Dirty"** = any `git status --porcelain=v2` entry: staged, unstaged or untracked (ignored excluded). Stash = `git stash push --include-untracked -m "watchtower: switching from <cur> to <branch>"`. Never popped automatically after a successful switch; the result and the popover name it. If `switch` fails after the stash, it is restored at once with `git stash pop --index`.
7. **Never run:** `switch --force|--discard-changes`, `checkout -f`, `reset`, `clean`, `stash drop`.
8. **`create` has no guards:** `git switch -c <name>` from HEAD swaps no files.
9. **Badge data:** a GRDB read in WatchtowerCore when the popover opens — this workbench's targets with a non-empty `branch`, open ones first. The CLI stays DB-free beyond resolving the folder.
10. **Refresh triggers:** page appears; `NSApplication.didBecomeActiveNotification`; after switch/create; FSEvents on `git_dir` and `common_dir` (HEAD, index, packed-refs, `refs/heads/**`, `refs/remotes/**`, `worktrees/*/HEAD`; ignoring `objects/**`, `logs/**`, `*.lock`), 0.5 s latency, coalesced; a 15 s timer while the page is on screen, only for the dirty dot. At most one refresh in flight per workbench plus one queued rerun.

## Contracts (Go → Swift, JSON)

All four commands exit 0 whenever the workbench resolves; non-zero only for a bad id, a DB error or a missing folder (the `workbench check` precedent). Slices are always `[]`, never `null`. Times are RFC3339 UTC.

**`workbench git status --workbench N --json`**

```json
{"workbench_id":7,"git_available":true,"git":true,"note":"",
 "branch":"main","detached":false,"unborn":false,"head":"a1b2c3d",
 "upstream":"origin/main","ahead":2,"behind":0,
 "dirty":true,"changes":5,"operation":"",
 "top_level":"/abs","git_dir":"/abs/.git/worktrees/x","common_dir":"/abs/.git",
 "status_ok":true,"status_error":""}
```

- `operation`: `merge|rebase|cherry-pick|revert|bisect|""`, from file checks in `git_dir` (MERGE_HEAD, rebase-merge/, rebase-apply/, CHERRY_PICK_HEAD, REVERT_HEAD, BISECT_LOG).
- `git:false` → `note` says why (not a work tree, git unavailable); the Desktop shows neither `›` nor the button.
- Built from `git rev-parse --absolute-git-dir --git-common-dir --show-toplevel` plus one `git status --porcelain=v2 --branch -z --untracked-files=normal`.

**`workbench git branches --workbench N --json`**

```json
{"workbench_id":7,"git_available":true,"git":true,"current":"main",
 "branches":[{"name":"main","current":true,"head":"a1b2c3d","committed_at":"2026-10-02T09:00:00Z",
              "upstream":"origin/main","ahead":0,"behind":0,"worktree":"","worktree_name":""}],
 "branches_ok":true,"branches_error":""}
```

- One `git for-each-ref --sort=-committerdate refs/heads/` with a NUL-separated format of `%(refname) %(objectname:short) %(committerdate:unix) %(upstream:short) %(upstream:track,nobracket) %(worktreepath)`.
- `worktree` is set only when the branch is checked out in a worktree other than `top_level`; `worktree_name` is its base name.

**`workbench git switch --workbench N --branch B [--stash] [--agent-running] [--confirm-agent] --json`**

```json
{"workbench_id":7,"branch":"feature/x","switched":false,"already":false,
 "needs_confirmation":["uncommitted_changes","agent_running"],"changes":5,
 "refused":"","refused_detail":"",
 "stashed":"","stash_message":"","stash_restored":false,
 "error":"",
 "status":{}}
```

- `refused`: `unknown_branch|checked_out_elsewhere|operation_in_progress|not_git|git_unavailable`.
- `error`: git stderr, trimmed, ≤300 chars, when git failed. `status`: the status object after the call.

Order of checks (load-bearing):
1. git unavailable / not a repository → refused.
2. `B` must exactly match a `refs/heads/` name and must not start with `-`.
3. `B` == current branch → `already:true`, no git write.
4. checked out in another worktree → refused (no flag overrides it).
5. operation in progress or unmerged entries → refused.
6. collect `needs_confirmation`: dirty without `--stash`; `--agent-running` without `--confirm-agent`. Any → return, no git write.
7. `--stash` and dirty → `stash push`.
8. `git switch --no-guess B`; on failure, `stash pop --index` if this run stashed.
9. read the status again.

**`workbench git create --workbench N --name X --json`** — same envelope plus `"created":bool`; `refused` gains `invalid_name` (via `git check-ref-format --branch`; also rejects a leading `-` and empty) and `exists`. Runs `git switch -c X`. No dirty or agent guard.

## Tasks

### G1 — `internal/gitbin`: locate git without the shim; InsideRepository
- **Depends on:** none
- **Files:** new `internal/gitbin/gitbin.go`, `gitbin_test.go`; edit `internal/workbenchcheck/git.go` (`ExecRunner` resolves `"git"` via gitbin; `insideRepository` → `gitbin.InsideRepository`; new note "git is not available (no Command Line Tools); branch checks skipped" on `errors.Is(err, gitbin.ErrUnavailable)`); `check_test.go` (new case only).
- **Interface:** `type Locator struct{ GOOS string; Getenv func(string) string; Readlink func(string) (string, error); IsExecutable func(string) bool; LookPath func(string) (string, error) }`; `func (Locator) Locate() (string, bool)`; `func Locate() (string, bool)` (cached, default Locator); `var ErrUnavailable`; `func InsideRepository(dir string) bool`.
- **Tests:** DEVELOPER_DIR wins; xcode_select_link target used; CLT path used; Xcode.app default used; Homebrew arm64 then Intel; `/usr/bin/git` never returned even when "executable"; none → false; non-darwin uses LookPath. InsideRepository: `.git` dir, `.git` gitdir file, parent repo, non-repo. `TestProj07_GitUnavailableIsANote`: runner returns `ErrUnavailable` → `Git:false`, note present, no findings. All existing `TestProj07_*` stay green unchanged.
- **Verify:** `go test ./internal/gitbin ./internal/workbenchcheck`; `make lint-diff`

### G2 — `internal/workbenchgit`: status and branch reading
- **Depends on:** G1
- **Files:** new `internal/workbenchgit/{status.go,branches.go,run.go,status_test.go,branches_test.go,helpers_test.go}`
- **Interface:** `type Options struct{ Folder string; Run workbenchcheck.Runner /*nil = ExecRunner*/; Locate func() (string, bool) }`; `func ReadStatus(ctx, Options) Status`; `func ParseStatus(porcelainV2Z []byte) (StatusFields, error)`; `func ListBranches(ctx, Options) BranchList`; `func ParseBranches(out []byte, topLevel string) ([]Branch, error)`. `Status`/`Branch`/`BranchList` carry the contract's JSON tags. `run.go` adds `GIT_EDITOR=true`, keeps ExecRunner's env.
- **Tests (parsers on canned output):** clean on main `# branch.ab +0 -0`; dirty — modified, staged, renamed, untracked counted in `changes`; ahead/behind `+2 -1`; no upstream → 0/0, `upstream` ""; detached `(detached)` → `detached:true`, short `head`; unborn `(initial)` → `unborn:true`, name kept; unmerged `u` entries. Branches: order as given, current flagged, another worktree's `worktreepath` → `worktree`/`worktree_name`, own worktree → empty, a name with `/`, track `ahead 2, behind 1` / `gone`.
- **Tests (real git, temp repos):** linked worktree → `git_dir` ends with `worktrees/<name>`, `common_dir` is the main `.git`, main checkout's branch shows as `worktree` from the linked side; a repo subdirectory as folder works; non-repo dir → zero runner calls; Locate false → `git_available:false`, zero runner calls; `operation` detection (MERGE_HEAD).
- **Verify:** `go test ./internal/workbenchgit`; `make lint-diff`

### G3 — `workbenchgit`: Switch and Create with guards (PROJ-10 guard tests)
- **Depends on:** G2
- **Files:** new `internal/workbenchgit/{switch.go,switch_test.go}`
- **Interface:** `type SwitchRequest struct{ Branch string; Stash, AgentRunning, ConfirmAgent bool }`; `func Switch(ctx, Options, SwitchRequest) SwitchResult`; `func Create(ctx, Options, name string) SwitchResult`; `const NeedUncommitted = "uncommitted_changes"`, `NeedAgent = "agent_running"`; `Refused*` constants.
- **Tests (`TestProj10_…`, real git + recording runner):** `RefusesDirtyWithoutStash` (needs `[uncommitted_changes]`; HEAD, file content, `stash list` unchanged; no `switch`/`stash` argv); `RefusesAgentRunningWithoutConfirm`; `ListsBothConfirmations`; `StashAndSwitch` (stash with the message, HEAD == target, clean worktree, `stashed` named); `ConfirmedAgentSwitches`; `CheckedOutElsewhereIsRefusedWithAllFlags`; `UnknownOrOptionLikeBranchIsRefused` (`-f`, `origin/main`, `HEAD~1`, nonexistent — no write argv); `OperationInProgressIsRefused` (real conflicting merge); `FailedSwitchRestoresTheStash` (runner fails `switch` → `stash_restored:true`, changes back); `AlreadyOnBranchIsANoOp`; `NeverForcesOrDiscards` (no recorded argv ever contains `--force`, `-f`, `--discard-changes`, `reset`, `clean`, `checkout`, `drop`). Create: valid → created, on the branch, dirty changes carried; `exists`; `invalid_name` for `a..b`, `-x`, empty, `foo.lock`.
- **Verify:** `go test ./internal/workbenchgit`; `make lint-diff`

### G4 — `cmd`: `workbench git status|branches|switch|create`
- **Depends on:** G2, G3
- **Files:** new `cmd/workbench_git.go`, `cmd/workbench_git_test.go`
- **Interface:** `workbenchGitCmd` under `workbenchCmd`, four subcommands, each with `addWorkbenchIDFlag` + `--json`; switch: `--branch`, `--stash`, `--agent-running`, `--confirm-agent`; create: `--name`. Folder resolution shares `checkWorkbench`'s rules. Context budgets: status/branches 5 s, switch/create 60 s. Text output: one line per field.
- **Tests:** envelope key sets per command (guard for the Swift decoders); empty `branches`/`needs_confirmation` marshal as `[]`; a refusal exits 0 with the envelope; bad id / missing folder → non-zero; every subcommand registers `--workbench` and `--json`; non-git folder → `git:false`, exit 0.
- **Verify:** `go test ./cmd -run 'TestWorkbenchGit'`; `make lint-diff`

### S1 — Core models and decoders
- **Depends on:** G4's contract (can start against the JSON above)
- **Files:** new `WatchtowerCore/Models/WorkbenchGit.swift`, `Tests/Core/WorkbenchGitDecodingTests.swift`
- **Interface:** `WorkbenchGitStatus`, `WorkbenchGitBranch`, `WorkbenchGitBranches`, `WorkbenchGitSwitchResult` (+ `enum Confirmation: String { uncommittedChanges = "uncommitted_changes", agentRunning = "agent_running" }`). Non-core keys `decodeIfPresent` with defaults.
- **Tests:** each contract sample; empty arrays; an older CLI missing optional keys; unknown `needs_confirmation` values ignored; `committed_at` via a UTC-pinned ISO8601 formatter.
- **Verify:** `make test-swift FILTER=WorkbenchGitDecodingTests`

### S2 — Core presentation logic
- **Depends on:** S1
- **Files:** new `WatchtowerCore/Services/WorkbenchBranchPresentation.swift`, `Tests/Core/WorkbenchBranchPresentationTests.swift`
- **Interface:** `displayPath(_:home:)` (`~/…`); `label(_:)` → text + style `.branch|.detachedHash`; `counters(_:)` (`↑2`, `↓1`, `↑2 ↓1`, nil at 0/0); `showsButton(_:)` (`git_available && git && status_ok`); `filter(_:query:)` (case-insensitive substring, order kept); `disabledCaption(_:)` ("open in worktree <folder>"); `badge(for:in:)` (`#12`, `#12 +1`, with help text); `confirmation(for:)` → `BranchSwitchConfirmation?` (title, message — "the agent's files will be swapped" for an agent run, the change count when dirty; primary "Stash and switch" when dirty, else "Switch anyway"; the flags to resend).
- **Tests:** each function, incl. detached, unborn, both counters, empty query, the both-confirmations message, no confirmation for a switched result.
- **Verify:** `make test-swift FILTER=WorkbenchBranchPresentationTests`

### S3 — Core query: targets by branch
- **Depends on:** none (lane order: after S2)
- **Files:** `WatchtowerCore/Database/Queries/WorkbenchQueries+Branches.swift`, `Tests/Core/WorkbenchBranchTargetsTests.swift`
- **Interface:** `struct WorkbenchBranchTarget: Equatable { id, title, status }`; `static func branchTargets(_ db: Database, projectID: Int64) -> [String: [WorkbenchBranchTarget]]`; SQL `project_id = ? AND TRIM(COALESCE(branch,'')) <> ''`, open (not done/dismissed) first, then by id.
- **Tests:** only this workbench; blank/NULL excluded; open before done; several targets on one branch.
- **Verify:** `make test-swift FILTER=WorkbenchBranchTargetsTests`

### S4 — CLI client methods and the session fact
- **Depends on:** S1
- **Files:** `Services/WorkbenchCLI.swift` (`gitStatus(projectID:)`, `gitBranches(projectID:)`, `gitSwitch(projectID:branch:stash:agentRunning:confirmAgent:)`, `gitCreateBranch(projectID:name:)`); `Services/TerminalCenter.swift` (`func hasLiveClaudeSession(workbenchID: Int64, folder: String) -> Bool`); tests in `Tests/WorkbenchCLITests.swift`, `Tests/TerminalCenterTests.swift`.
- **Tests:** exact argv per method (flags only when true; `--branch`/`--name` values as their own argv elements); live claude row of the workbench → true; shell row → false; exited row → false; standalone claude row in a subfolder → true; other folder → false.
- **Verify:** `make test-swift FILTER='WorkbenchCLITests|TerminalCenterTests'`

### S5 — GitRefsWatcher (FSEvents)
- **Depends on:** none (lane order: after S4)
- **Files:** new `Services/GitRefsWatcher.swift`, `Tests/GitRefsWatcherTests.swift`
- **Interface:** `@MainActor final class GitRefsWatcher { init(gitDir:commonDir:latency: = 0.5, onChange:); func stop() }`; `static func isRelevant(path:gitDir:commonDir:) -> Bool` (pure). FileEvents | NoDefer | WatchRoot; gitDir/commonDir deduped when equal.
- **Tests:** `isRelevant` table (HEAD, index, packed-refs, refs/heads/a/b, refs/remotes/origin/x, worktrees/w/HEAD → yes; objects/…, logs/…, `*.lock`, ORIG_HEAD → no); real temp dir: writing `refs/heads/x` fires once, `objects/ab/cd` does not, `stop()` silences it.
- **Verify:** `make test-swift FILTER=GitRefsWatcherTests`

### S6 — View model: refresh, watch, switch flow
- **Depends on:** S1–S5
- **Files:** new `ViewModels/WorkbenchesViewModel+Git.swift` (state on the AppState-owned VM, survives navigation); `WorkbenchesViewModel.swift` (stored state); new `Tests/WorkbenchesViewModelGitTests.swift`.
- **Interface:** `gitStatus`, `gitBranches`, `branchTargets`, `gitErrors`, `switchingBranch`, `pendingBranchConfirmation` (keyed by workbench id); `refreshGitStatus(projectID:)` (coalesced); `loadBranches(project:)` (CLI + GRDB targets); `switchBranch(_:project:)` (first call passes `agentRunning` from `terminalCenter.hasLiveClaudeSession`, no confirm flags); `confirmPendingSwitch(projectID:)`; `cancelPendingSwitch(projectID:)`; `createBranch(_:project:)`; `copyBranchName(projectID:)`; `startGitWatching(project:)` / `stopGitWatching(projectID:)` (watcher from `git_dir`/`common_dir`, re-armed when they change; didBecomeActive observer; 15 s timer gated by `isTabOnScreen`).
- **Tests (fake CLIRunner):** `needs_confirmation` → pending set and NO second CLI call until confirm; confirm → argv has `--stash`/`--confirm-agent` as needed; cancel → no call, pending cleared; live session → `--agent-running` on the first call; switch error / `refused_detail` → `gitErrors` text, status kept; success → status refreshed, branches reloaded; `git:false` → no button; concurrent refreshes coalesce to ≤ 2 CLI calls; state survives navigate away and back; stop cancels the timer and the watcher.
- **Verify:** `make test-swift FILTER=WorkbenchesViewModelGitTests`

### S7 — Header breadcrumbs, branch button, popover
- **Depends on:** S6
- **Files:** `Views/Workbench/WorkbenchPageView.swift` (header); new `Views/Workbench/WorkbenchBranchButton.swift`, `Views/Workbench/WorkbenchBranchPopover.swift`; new `Tests/WorkbenchBranchViewsTests.swift` (ViewInspector).
- **Behaviour:** header row: folder icon + `displayPath` link (Show in Finder; `.lineLimit(1).truncationMode(.middle)`; `.help(full path)`; low layout priority), then `›` and the branch button only when `showsButton`, then the setup-status icon; right side unchanged. `.task(id:)` starts watching, `onDisappear` stops. Button: `arrow.triangle.branch`, bold name (detached hash in `.secondary`), orange dot when dirty, counters, chevron; width capped with tail truncation; `.help` = full name + operation in progress. Popover below: focused "Find branch" field; LOCAL BRANCHES rows (checkmark on current, name, `#id` badge, relative time; disabled rows with the worktree caption); divider; "New branch from current…" (inline name field, Create/Cancel, validation error) and "Copy branch name"; git error as red caption text; the confirmation dialog attached inside the popover content.
- **Tests:** no `›`/button for `git:false`; detached shows the hash; counters hidden at 0; worktree row disabled with caption; badge renders; error text renders; "Copy branch name" calls the VM.
- **Verify:** `make test-swift FILTER=WorkbenchBranchViewsTests`; `make lint-diff`

### D1 — Docs and inventory
- **Depends on:** all above
- **Files:** `docs/app-guide.md` (Workbench header: breadcrumbs, branch button, popover, both guards, stash naming, refresh; v1 limits — local branches only, no fetch/pull/push, external-terminal sessions not detected, stash not auto-restored, hidden without developer tools); `docs/features/workbench.md` (new bullet: CLI contract, gitbin, guards, FSEvents paths, decisions); `docs/inventory/workbench.md` (new PROJ-10 — branch switching never loses work, never switches without the owner's confirmation, never runs git where it could pop the developer-tools dialog — with the `TestProj10_*` guards; PROJ-07 changelog line for the gitbin hardening); inventory README code paths (`internal/gitbin/`, `internal/workbenchgit/`, `cmd/workbench_git.go`).
- **Verify:** `make lint-diff`

## Edge rules

- Not a repository → no git process. No git binary → no git process, no dialog. Either → no `›`, no button.
- Detached → short hash in gray; switching away works (dirty guard still applies).
- Unborn → name without hash or counters; `branches` may be `[]`.
- Linked worktree → status from that worktree; refs watched in `common_dir`; a branch open elsewhere is disabled in the UI and refused in Go.
- Operation in progress → switch refused with the reason; the button tooltip names it.
- Every git stderr shows as text in the popover; never a silent failure; never force or discard.

## Overlap with `poc/code-viewer` (#234)

That branch touches `WorkbenchPageView.swift`, `WorkbenchesViewModel(+Panel).swift`, `MemoryVaultGit.swift`, `docs/app-guide.md`, `docs/features/workbench.md` (small conflicts expected) and adds a Swift-side porcelain-v2 reader (`WatchtowerCore/Services/GitStatus.swift`). Whichever lands second reconciles: ideally the POC's git marks move onto `workbench git status` / gitbin.
