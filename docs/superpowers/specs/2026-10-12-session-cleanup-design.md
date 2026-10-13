# Session cleanup — worktrees, branches, leftovers (board #535) — design

**Status:** Draft, 2026-10-12. Contract changes in §13 need the owner's approval.
**Business spec:** `2026-10-12-session-cleanup-business.md`. **Plan:** `docs/superpowers/plans/2026-10-12-session-cleanup.md`.
**Depends on:** board #565 (`2026-10-12-session-worktree-design.md`): the `cwd` field parsed from every
session-state hook input, its process-free worktree resolver, and its per-session "where the main agent works"
column (working name `agent_cwd` below — use whatever name #565 lands). This design adds no second cwd mechanism:
it reuses #565's parse and resolver and adds a per-session *history* of the worktrees the session's agents worked in
(#565 keeps only the main agent's latest place).
**Touches:** `cmd/workbench_session_state.go`, new `cmd/workbench_cleanup.go`, new `internal/sessioncleanup`,
`internal/db` (migration, `terminal_session_worktrees`), `internal/devpack` (permission entry, skill v7),
`cmd/workbench_brief.go`, `internal/sessionreport`, Desktop (`SessionCleanupCenter`, session dialogs, report, header
menu), `docs/inventory/workbench.md` (PROJ-02/04/11, new PROJ-16), `docs/inventory/dev-surface.md` (DEV-04
changelog), `docs/features/workbench.md`, `docs/app-guide.md`.

## 1. Scope

**v1 (this spec):**

| # | What | How |
|---|---|---|
| S1 | Record which worktrees and branches a session's agents worked in | state hook → `terminal_session_worktrees` (§3) |
| S2 | `watchtower workbench cleanup` — plan (default) then `--apply` | `internal/sessioncleanup` (§4–§8) |
| S3 | Linked worktrees of the session (their `.build` etc. go with them) | `git worktree remove` (no `--force`) |
| S4 | Local branches merged into the default branch or contained in a remote-tracking ref | `git update-ref -d` with the checked tip |
| S5 | Orphan processes in the session's worktrees (ppid 1) | SIGTERM, re-check |
| S6 | LaunchServices registrations of `.app` bundles inside removed worktrees | `lsregister -u` before removal |
| S7 | Skill step before `finish_session`; result in the summary and the session report | skill pack v7, `cleanup_result` column |
| S8 | Desktop: offer on Delete Session, **Clean Up…** per session, **Clean Up Old Worktrees…** sweep | `SessionCleanupCenter` |
| S9 | Auto-mode permission for this one command | our `permissions.allow` entry in `settings.local.json` |

**Deferred (recorded, not built):** Xcode DerivedData of `WatchtowerMobile` builds made from a worktree; scratch
files/binaries in `/tmp` and the Claude scratchpad; squash-merged branches whose remote branch is already deleted
(kept, reported "not on the remote and not in <default> — delete by hand"; a later version can match the PR cache
once it stores the head sha); LaunchServices entries of builds outside the workbench folder (sibling
`../<repo>-<name>` worktrees removed by hand earlier); an automatic prompt when a session turns Finished; fetch
inside the command; cleanup of a `kind = 'shell'` session (it has no hooks, so no ledger — the sweep covers it).

## 2. Ownership: "created by this session"

An item is the session's when **both** hold:

1. **Observed.** A `terminal_session_worktrees` row of the session names its worktree root (worktrees) or the
   branch (branches), or the branch is the `branch` of a target the session linked (`terminal_session_targets`,
   PROJ-14), or the agent declared it (`--worktree PATH` / `--branch NAME`, §6).
2. **Born after the session.** Its creation time is at or after the session row's `created_at`:
   - worktree: birth time of its admin dir `<common git dir>/worktrees/<name>/` (`Stat_t.Birthtimespec` on darwin;
     `ctime` fallback elsewhere);
   - branch: the time of the first entry of `<common git dir>/logs/refs/heads/<name>` (reflog). No reflog → the
     creation time is unknown → **kept** ("can't tell when it was created").

Reason for rule 2: an agent that merely `cd`s into the owner's long-lived worktree (`../<repo>-feature`) or checks
out the owner's branch must never get to delete it. Observation alone is not ownership. Two sessions that both
observed the same young worktree may both claim it; the in-use catches (§5 W5–W6) protect the live one.

The **sweep** (§9) drops rule 1 and 2 (the owner chooses by hand) but keeps every safety catch.

## 3. Recording — the state hook (PROJ-11)

### 3.1 Schema — migration `<next free>_session_cleanup.sql`

Next free goose number at implementation time (00109 on this branch today; #565 and other in-flight branches,
e.g. `feat/399-codex-agent`, are likely to take numbers first — renumber at merge).

```
CREATE TABLE terminal_session_worktrees (
    session_id INTEGER NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE,
    root       TEXT NOT NULL,             -- worktree root (the dir holding .git), symlink-resolved, absolute
    branch     TEXT NOT NULL DEFAULT '',  -- short branch name at the time; '' = detached HEAD / unreadable
    first_at   TEXT NOT NULL,             -- agent_state_at format
    PRIMARY KEY (session_id, root, branch)
);
ALTER TABLE terminal_sessions ADD COLUMN cleanup_result TEXT; -- JSON of the last --apply (Go only); NULL = never
ALTER TABLE terminal_sessions ADD COLUMN cleanup_at TEXT;     -- its time, agent_state_at format; NULL with it
```

Down: drop the table and both columns (follow the `DROP COLUMN` precedent of `00106`). Mirror into `schema.sql`, add
the table to `TestAllTablesExist`, regenerate the golden and `TestDatabase+Schema.swift`. Swift reads
`cleanup_result`/`cleanup_at` (report) and never writes any of these.

### 3.2 Write rule

On every session-state hook event of a resolved session (main agent **and** subagents/teammates — unlike #565's
column, which follows the main agent only): resolve `cwd` to `(root, branch)` — symlinks of the cwd (or its nearest
existing ancestor) resolved, then a walk up for `.git` (`internal/gitdir`, shared with devpack's info/exclude upkeep;
a `.git` it cannot read stops the walk — fail closed) and a read of the worktree's `HEAD` file; no git process, no
network. The branch is `""` when unknown — a detached HEAD, or a reftable repository's `refs/heads/.invalid` stub —
and the pair is still recorded with `""`. Then:

- cwd absent, unresolvable, or outside any repository → nothing.
- `(session, root, branch)` already recorded → nothing (one read-only `SELECT`; no write).
- the session already holds **64** rows → nothing (the same read says so; no write lock); the new pair is dropped
  with a stderr line at most once per run (one hook process).
- otherwise `INSERT OR IGNORE` in its **own** transaction, after the event's state write has committed. Not in the
  state write's transaction, deliberately: the state write is the hook's job and the ledger an extra — a ledger
  failure (a missing table, a lock timeout, the cap) must never roll back, delay or fail the state write, and a
  separate transaction gives that without savepoint bookkeeping across the several state-write paths. The cost is
  one more short write transaction, only on the rare event that meets a new pair.

The hook still prints nothing, never blocks, never fails the event on a ledger error (a stderr line, exit 0).
The main folder's own root is recorded too (its branches can be the session's), but the main worktree itself is
never a removal candidate (§5 W1).

## 4. The command

```
watchtower workbench cleanup [--session N] [--json]                    # plan (default): lists, writes nothing
watchtower workbench cleanup [--session N] --apply [--item KEY]... [--json]
watchtower workbench cleanup --workbench N --sweep [--live-session ID]... [--json]   # plan only
watchtower workbench cleanup --workbench N --sweep --apply --item KEY [--item KEY]...  # explicit items only
  common: [--worktree PATH]... [--branch NAME]... (session mode: declared candidates)
          [--live-session ID]... (the Desktop's live terminals)  [--no-size]
```

- `--session` defaults to `$WATCHTOWER_TERMINAL_SESSION_ID`; neither → refused (`cleanup needs a session or
  --workbench with --sweep`), exit 2, nothing done.
- **Plan and apply are separate evaluations.** `--apply` never trusts an earlier plan: it re-plans, then acts only
  on items that are `remove` now **and**, when any `--item` is given, are among them. The Desktop always passes the
  items the owner saw; the agent may apply without `--item` (everything eligible now). Sweep apply requires `--item`.
- Item keys: `worktree:<root>`, `branch:<name>`, `process:<pid>:<start time>`, `lsreg:<bundle path>`.
- No fetch, ever (like the PROJ-07 drift check). The skill tells the agent to `git fetch` first.
- git is `internal/gitbin`'s binary; no git in a folder outside a repository (`gitbin.InsideRepository`); every git
  call has a timeout (30 s; `worktree remove` 120 s).
- Exit codes: 0 = done (items may be kept — that is not a failure), 1 = could not plan (no git, DB error), 2 = usage.

### 4.1 Output (`--json`; text mode prints the same as lines)

```
{ "session_id": 12, "workbench_id": 3, "mode": "plan"|"apply", "sweep": false,
  "items": [ { "key": "worktree:/…/.claude/worktrees/x", "kind": "worktree"|"branch"|"process"|"lsreg",
               "name": "x", "branch": "feat/x", "bytes": 11811160064, "bytes_known": true,
               "action": "remove"|"keep", "reason": "" | "<reason code>", "detail": "",
               "done": false, "error": "" } ],
  "removed_bytes": 0, "summary": "2 worktrees, 4 branches removed (~14 GB); kept 1 worktree — uncommitted changes",
  "result_saved": true, "result_error": "" }
```

`items` is never `null` (`[]`). `summary` is one line, English, ready for the finish summary. `result_saved` /
`result_error` is the envelope for the best-effort write of `cleanup_result` (review-rules envelope symmetry).

## 5. Safety catches (PROJ-16)

Evaluated in this order; the first that fires sets `action: keep` and its `reason`. Re-checked immediately before
each removal (§7); git's own refusal is the last catch.

**Worktrees** (candidates come only from `git worktree list --porcelain` of the workbench repository — never an
arbitrary path, never `rm -rf`):

| # | Catch | reason |
|---|---|---|
| W1 | It is the main worktree, or any workbench's `folder_path` (`projects`), or contains one | `main_folder` / `workbench_folder` |
| W2 | Not the session's (§2), outside the sweep | `not_this_session` / `existed_before_session` |
| W3 | Locked (`git worktree lock`) | `locked` |
| W4 | `git status --porcelain` non-empty (modified, staged or untracked; ignored files do not count) | `uncommitted_changes` |
| W5 | A process has its cwd or executable inside it and is not an orphan of this session (§7) — Watchtower's own binaries and the caller included; a live current-user process whose cwd the scan could not read blocks every worktree | `process_running` / `process_unknown` |
| W6 | Another session is in it: its `agent_cwd` (#565) is inside and it is in `--live-session` or reported within 24 h and is not finished; or the calling session's own `agent_cwd` is inside (caller = `$WATCHTOWER_TERMINAL_SESSION_ID`) | `session_in_it` / `you_are_in_it` |
| W7 | HEAD (detached or branch tip) not contained in the default branch nor in any `refs/remotes/*` | `unpushed_commits` |
| W8 | A merge/rebase/cherry-pick/revert/bisect in progress | `operation_in_progress` |

A worktree whose directory is already gone (`prunable`) is removed from git's metadata (`git worktree prune`,
which only drops entries whose directory is gone) and reported `removed`, 0 bytes.

**Branches:**

| # | Catch | reason |
|---|---|---|
| B1 | It is the default branch (`origin/HEAD`, else `main`, else `master`) | `default_branch` |
| B2 | Checked out in any worktree that stays (the main folder included) | `checked_out` |
| B3 | Not the session's (§2), outside the sweep | `not_this_session` / `existed_before_session` / `created_unknown` |
| B4 | Tip not an ancestor of the default branch and not contained in any `refs/remotes/*` | `unpushed_commits` |

**Never, by construction (no code path reaches them):** `~/.claude/**`; any path that is not a linked worktree of
the repository; remote refs; the session row, its report and asks; the main folder's `WatchtowerDesktop/.build`.
Guard tests assert each (§12).

## 6. Declared candidates

`--worktree PATH` / `--branch NAME` let the agent name what it created but the ledger missed (a worktree made and
entered by a tool that sent no hook from inside it). Declared items still pass §2 rule 2 and every catch. A declared
path that is not a linked worktree is reported `keep / not_a_worktree`.

## 7. Removal order and the re-check

Per worktree, in `--apply`:
1. re-run W3–W8 (fresh `git status`, fresh process scan);
2. terminate its orphans (S5) and re-scan — a survivor → keep `process_running`;
3. `lsregister -u` each `.app` bundle found under it (depth ≤ 6, skipping `node_modules` and `.git`) — best effort,
   a failure is an item `error`, never blocks the removal;
4. `git worktree remove <root>` without `--force` — git refuses on changes it sees, which ends as keep
   `git_refused` with git's message in `detail`.

Then branches: re-run B1–B4 (B2 now sees the removed worktrees), and delete with
`git update-ref -d refs/heads/<name> <checked sha>` — a compare-and-delete: if the tip moved since the check, git
refuses and the branch is kept (`moved`). Then `git config --remove-section branch.<name>` (absent section ignored).

**Orphans (S5).** A process is an orphan of this session when its ppid is 1, it runs as the current user, it is
not the caller, and its **executable** (lsof's first `txt` entry) is inside one of the session's worktree candidates
— a build output, a test stub or a dev binary built there — and is not Watchtower's (`watchtower` CLI or daemon,
`Watchtower*.app`) nor `claude`/`codex` (that list stays as an extra guard). Orphans get SIGTERM (never SIGKILL), 5 s
grace, re-scan. Sweep mode never terminates processes (it only reports `process_running`).

**Never signalled: cwd inside, executable outside** (controller decision 2026-10-13, review of PR #223). A process
whose cwd is inside the worktree but whose executable is outside it — a tmux or screen server, a shell, an
npm-installed `claude`/`codex` (a `node` executable), a GUI app, the SPM dev binary built elsewhere — is never
signalled, whatever its ppid: it is a blocker, the worktree is kept `process_running` with detail
`process in use: <name> pid N`. A process of the current user whose cwd the scan could not see is a blocker for
every worktree under consideration (`process_unknown`): it could be working in any of them. Zombies are skipped,
and each unknown-cwd process is re-checked after lsof (`kill(pid, 0)`, then one `ps -p` over the rest): one that
exited or whose pid now has another start time is dropped; any doubt in the re-check keeps it unknown.

**Process scan.** One `ps -axo pid=,ppid=,uid=,stat=,lstart=,comm=` (executable path) and one
`lsof -a -d cwd -n -P -w -F pn -u <uid>` per evaluation. The process key carries the start time so a reused pid is
never signalled. Must raise no TCC prompt (memory rule "No TCC prompts from Watchtower"): verified in plan Task 0;
fallback if lsof is not clean — executable paths only plus the Desktop's live-session facts, and the cwd catch
becomes "unknown → keep" for worktrees with any process of unknown cwd (`process_unknown`).

## 8. Sizes

`bytes` = allocated blocks (`Stat_t.Blocks * 512`) of a `WalkDir` over the worktree, not following symlinks, 20 s
budget per worktree; over budget → `bytes_known: false`, shown as "size unknown". The Desktop and the summary say
"~": APFS clones (`cp -c` of a warm `.build`, a house habit) share blocks, so the space actually freed can be less.
`--no-size` skips the walk (the agent's plan step uses it when it only needs the list).

## 9. The sweep

`--workbench N --sweep` lists every linked worktree of the workbench repository and every local branch except
B1/B2, with every catch except W2/B3, and adds an `owner` hint per item: the session that recorded it (title, last
activity) or `unknown` (pre-feature or deleted session — the ledger rows went with it). Items whose owner session is
live (`--live-session`) or reported within **7 days** and is not finished are `keep / session_recent`. Nothing is
pre-selected in the Desktop; apply needs explicit `--item`s. Never terminates processes. LaunchServices: also lists
`lsreg:` items for registered `.app` paths under the workbench folder that no longer exist (from
`lsregister -dump`), removed with `lsregister -u`.

## 10. Install: the permission and the brief line

- **Permission (PROJ-04 amendment).** `InstallStateHooks`' sibling `InstallCleanupPermission(dir, bin, id)` adds one
  string to `permissions.allow` in `.claude/settings.local.json`: `Bash('<bin>' workbench cleanup:*)` — the same
  absolute `bin` the hooks use, quoted the same way. Recognised as ours by exact prefix match on
  `<bin> workbench cleanup`; resync replaces a stale bin's entry; removal (PROJ-02) deletes only ours; owner entries
  are never touched or reordered. Whether an allow rule lets the command pass auto mode without a prompt is checked
  in plan Task 0; if not, the skill step degrades to "list, then ask the owner to run it or use Clean Up… in the app"
  and the entry is still harmless.
- **Brief.** The SessionStart brief adds, when the terminal session is known, one line:
  `Cleanup: '<bin>' workbench cleanup --session <id>` — the exact command the allow rule matches.

## 11. Skill pack v7 (DEV-04)

Next free pack version at implementation time (v7 if nothing else bumped it). "Finishing a session" gains, before
the `finish_session` call:

> **Clean up first.** Leave any worktree you are in (`ExitWorktree`, or `cd` back to the workbench folder), `git
> fetch`, then run the brief's `Cleanup:` command to list what this session would remove, and the same command with
> `--apply` to remove it. Add `--worktree`/`--branch` for anything you created that the list misses. Never remove a
> worktree or branch by hand. Put the command's `summary` line into your `finish_session` summary. Kept items are
> not a failure: mention them only if the owner must act.

The finish summary limit grows from 2–3 to 2–4 lines (the cleanup line). The shipped v6 text joins the DEV-04
re-install fixtures (`internal/devpack/testdata/watchtower-workbench-v6.md`).

## 12. Desktop

- **`SessionCleanupCenter`** (`@Observable`, owned by `AppState`, survives navigation): runs the CLI through the
  existing CLI runner; per session or workbench holds `phase` (idle / planning / ready(plan) / applying /
  done(result) / failed(message)). Never runs git, `lsof` or `lsregister` itself; never writes the DB.
- **Delete Session** (`SessionActionDialogs`): on open, plans (`--json`, live sessions passed). While planning, the
  message says "Checking what this session left…"; with nothing removable the dialog is as today. With items:
  "Also clean up: 2 worktrees, 3 branches (~12 GB). Kept: 1 worktree — uncommitted changes." Buttons **Delete and
  Clean Up** (default, destructive), **Delete Only**, Cancel. Order: close the terminal → `--apply --item …` (the
  planned `remove` keys) → delete the row (the ledger goes by cascade). A cleanup failure is shown and the row is
  **not** deleted (the owner retries or chooses Delete Only).
- **Clean Up…** in the session row menu: a sheet with the plan — `remove` items ticked, `keep` items greyed with the
  reason in words, the total of the ticked sizes; **Clean Up** applies the ticked keys and shows the result.
- **Clean Up Old Worktrees…** in the workbench header menu: the same sheet over `--sweep`, nothing ticked.
- **Session report:** a "Cleanup" line from `cleanup_result.summary` and `cleanup_at`.
- Reason codes map to English strings in WatchtowerCore (`SessionCleanupPresentation`), tested.

## 13. Contract changes (need owner approval)

**New PROJ-16 — session cleanup never removes unsaved, unpushed, in-use or someone else's work.**
> `watchtower workbench cleanup` (`internal/sessioncleanup`) removes only linked worktrees of the workbench
> repository and local branches, and only after every catch passes, checked again immediately before the removal:
> a worktree with uncommitted or untracked changes, a HEAD not in the default branch nor on a remote, a locked
> worktree, an operation in progress, a live process in it that is not an orphan of the session, or a session working
> in it is kept and reported with its reason; a branch whose tip is in neither the default branch nor a remote ref,
> the default branch, or a branch checked out anywhere is kept. Outside the owner's sweep it removes only what the
> session observed and what was created after the session started. It never removes the main worktree, a workbench
> folder, anything under `~/.claude`, a path that is not a linked worktree, or a remote ref; never fetches; never
> uses `--force` or an unconditional ref delete; signals only orphan processes (ppid 1, the current user, inside the
> session's worktrees, not Watchtower's or Claude Code's) and only with SIGTERM. A plan writes nothing; an apply acts
> only on items eligible at that moment and, when items are named, only on those.

Guards (Go): `TestProj16_UncommittedWorktreeIsKept`, `TestProj16_UntrackedFileKeepsTheWorktree`,
`TestProj16_UnpushedCommitKeepsWorktreeAndBranch`, `TestProj16_LiveProcessKeepsTheWorktree`,
`TestProj16_SessionInTheWorktreeKeepsIt`, `TestProj16_LockedWorktreeIsKept`,
`TestProj16_WorktreeOlderThanTheSessionIsKept`, `TestProj16_BranchOlderThanTheSessionIsKept`,
`TestProj16_BranchCheckedOutElsewhereIsKept`, `TestProj16_DefaultBranchIsNeverDeleted`,
`TestProj16_MainFolderAndWorkbenchFoldersAreNeverCandidates`, `TestProj16_ClaudeHistoryAndMainBuildUntouched`,
`TestProj16_PlanWritesNothing`, `TestProj16_ApplyRechecksAndActsOnlyOnNamedItems`,
`TestProj16_BranchThatMovedAfterThePlanIsKept`, `TestProj16_OnlyOrphansAreSignalled`,
`TestProj16_MergedAndPushedWorkIsRemoved` (the positive path: business done-criterion 1).
Swift: `testProj16_DeleteAppliesOnlyThePlannedItems`, `testProj16_FailedCleanupKeepsTheSessionRow`.

**PROJ-11 amendment** (on top of #565's): add to Observable —
> The state hooks also record, for any agent of the session, the worktree root and branch its event's `cwd` resolves
> to (`terminal_session_worktrees`), only when that pair is new for the session, at most 64 pairs, resolved without
> running git; a ledger failure is one stderr line and never fails or changes the state write.

Guards: `TestProj11_LedgerRecordsANewWorktreeOnce`, `TestProj11_LedgerFailureNeverCostsTheStateWrite`,
`TestProj11_SubagentCwdIsRecordedButNeverMovesTheSessionPlace`.

**PROJ-04 amendment:** the list of entries the install writes gains "one `permissions.allow` string,
`Bash('<bin>' workbench cleanup:*)`" — added only if absent, a stale-bin copy of ours replaced, the owner's allow
and deny entries never touched or reordered. Guard: `TestProj04_CleanupPermissionKeepsOwnerPermissions`.

**PROJ-02 amendment:** the folder removal also deletes our cleanup permission entry (the owner's stay); the row
delete also removes `terminal_session_worktrees` (cascade). Guards: `TestProj02_DeleteProjectLeavesNoRows` and
`TestProj02_RemoveProjectLeavesNothingInstalled` extended (assertions added, none relaxed).

**DEV-04:** no wording change; changelog entry for pack v7 and the v6 fixture.

**PROJ-14:** unchanged — `cleanup_result` is written by the cleanup command, never by the report or `finish_session`;
the report only reads it.

## 14. Risks and verification spikes (plan Task 0)

1. Subagent hook inputs carry the subagent's own `cwd` (a worktree-isolated subagent): capture one. If they carry
   the parent's cwd, worktrees of subagents are found through targets' branches and declared items only.
2. `lsof -d cwd` from a Desktop-spawned CLI raises no TCC prompt with processes whose cwd is under `~/Documents`,
   `~/Desktop` or `~/Downloads`. Fallback in §7.
3. A `permissions.allow` entry lets the command run in auto mode without a classifier block.
4. `lsregister -u` on a bundle path that is about to be deleted / already deleted removes the duplicate entry.
5. Worktree admin dir birth time is set at `git worktree add` (not touched later).

## 15. Open questions

1. Delete dialog default button: **Delete and Clean Up** (recommended) or **Delete Only**.
2. A one-time hint on the workbench when the sweep finds over 1 GB (recommended) or the menu item only.

## Appendix: Observed (Claude Code 2.1.296, 2026-10-12)

Plan Task 0 spikes run on macOS 26 (Darwin 25.6) in a throwaway `mktemp -d` directory, removed afterwards. Paths
below are shown as `<tmp>`.

**§14.5 Worktree admin dir birth time — confirmed.** After `git worktree add -b wt1 ../wt1`,
`stat -f %B .git/worktrees/wt1` is the creation second. `git worktree list` (plain and `--porcelain`),
`git status` in the worktree, a commit in it, `git worktree lock`/`unlock` and a `checkout -b` there leave `%B`
unchanged, while `%m`/`%c` move (git status rewrites the worktree's `index` and the dir mtime follows). So
ownership must read the birth time (`%B`), never mtime. Removing the worktree and re-adding one with the same
name gives a fresh admin dir with a new `%B`, so a re-used name never inherits an older session's age. The
worktree's own top dir has the same birth second as its admin dir.

**§14.4 `lsregister -u` — confirmed, with one path rule.** A minimal bundle (`Info.plist` with a fake
`com.example.spike535.<n>` id, a stub `Contents/MacOS` script) registered with `lsregister -f` shows up in
`lsregister -dump` (~0.1 s). Two copies at different paths make two entries.
- `-u` on a bundle that still exists removes its entry (~0.02 s); the other copy stays listed.
- `-u` after the bundle was deleted, with the path as given (`/var/folders/...`, which goes through a symlink),
  fails: `failed to scan <path>: -10814`, exit 1, and the entry stays. The same `-u` with the canonical path that
  `-dump` shows (`/private/var/folders/...`) succeeds, exit 0, and the entry is gone.
- Rule for §7 step 3: unregister **before** `git worktree remove` (the bundle still exists, any path form works);
  for already-deleted bundles pass the canonical path (resolve with `filepath.EvalSymlinks` on the deepest
  existing parent, or take the path from `-dump`). A non-zero exit is an item `error`, as §7 says.

**§14.1 Subagent `cwd` in hook input — not settled without a live capture.**
- Hooks reference: the common `cwd` field "follows Claude": it "is the worktree root after Claude enters a
  worktree". Hooks fired inside a subagent carry `agent_id`/`agent_type`, and `PreToolUse`/`PostToolUse` fire there
  too. The page does not say which `cwd` a worktree-isolated subagent's hooks get.
- Sub-agents page: a subagent with `isolation: worktree` "runs its Bash and PowerShell commands inside its
  worktree", branched by default from the default branch, and the worktree is "automatically cleaned up if the
  subagent makes no changes" (kept otherwise). When a `WorktreeCreate` hook made the worktree, Claude Code keeps
  it at subagent end and does not run `WorktreeRemove`.
- Repo fixtures (`cmd/testdata/subagentstart_*.json`, `subagentstop_*.json`) come from subagents and teammates
  **without** worktree isolation; their `cwd` is the parent's. No `PostToolUse` fixture exists.
- Indirect evidence: in the owner's local Claude Code transcripts, the per-message `cwd` of worktree-isolated
  subagent transcripts (`subagents/*.jsonl`) is the agent worktree (`.claude/worktrees/agent-…`), not the parent's
  directory. That is the transcript, not hook input, so the capture is still needed before Task 3 relies on it.

**§14.2 lsof — format clean, TCC part open.** The shipped scan (Task 5) is
`lsof -a -d cwd,txt -n -P -w -F pfn -u <uid>`, run in the caller's locale (not `LC_ALL=C`; lsof's `\xNN` escapes are
decoded either way, a caret or unknown escape makes the name unknown); the owner's final manual check (Task 14)
confirms it raises no TCC prompt with `txt` included. Spike notes: `lsof -a -d cwd -n -P -w -F pn -p <pid>` against a throwaway
`sleep` whose cwd is in `<tmp>` (a name with a space) prints three lines, `p<pid>`, `fcwd`, `n<canonical path>`
(`/private<tmp>/wt cwd`, spaces unescaped, symlinks resolved), exit 0, ~0.06 s. A dead or unknown pid prints
nothing and exits 1. `ps -o comm=` is argv-based: `/bin/sleep` for a process started by absolute path, but just
`sleep` for one started through `PATH`, so the executable-path half of S5 needs `proc_pidpath` (or
`lsof -d txt`), not `comm`. The `-u <uid>` form and protected-folder cwds were not run; the TCC question is left to
the owner check below.

**§14.3 Allow rule in auto mode — not run (needs the owner's settings).** Owner steps below.

**Owner checks still open:**
1. *Desktop-spawned lsof (TCC).* In Terminal: `mkdir -p ~/Documents/spike535 && cd ~/Documents/spike535 && sleep 600 &`.
   Trigger a CLI run from the Desktop that executes `lsof -a -d cwd -n -P -w -F pn -u $(id -u)` (a dev build, or a
   temporary debug action), watch for any privacy dialog and note in whose name it appears; then
   check System Settings → Privacy & Security → Files and Folders for a new Watchtower entry.
   Repeat with `~/Desktop` and `~/Downloads`. Kill the `sleep`s and remove the dirs. Any dialog → §7 fallback.
2. *Allow rule in auto mode.* In a scratch repo's `.claude/settings.local.json` add
   `"permissions": {"allow": ["Bash('<watchtower bin>' workbench cleanup:*)"]}`; start `claude` in auto mode there,
   ask it to run `'<watchtower bin>' workbench cleanup --help` (and a `--json` dry run); record whether it runs
   with no prompt and no classifier block. Delete the scratch settings afterwards.
3. *Subagent `cwd` capture.* In a scratch repo with a `PostToolUse` + `SubagentStop` command hook that appends
   stdin to a file (`cat >> /tmp/spike535-hooks.jsonl`), ask Claude to start a subagent with
   `isolation: "worktree"` that runs one Bash command; check the `cwd` of the entries with an `agent_id`. Save one,
   redacted, as `cmd/testdata/posttooluse_subagent_worktree_cwd.json`, then remove the hook.
