# Coach repository edits land as pull requests

Board #2082. Owner decision: ask #1606 ("Что делает Accept на правке файла репозитория? → Сам открывает PR").
Amends COACH-01 (`docs/inventory/coach.md`, "Workbench repository files").

## 1. Problem

The tuning chat may propose edits to five files of a workbench folder (`repo_claude_md`, `repo_agents_md`,
`repo_claude_skill`, `repo_codex_skill`, `repo_workflow`). Today Accept writes the file into the owner's working
copy and stops: the owner has to notice the uncommitted change, commit it on the right branch, push and merge.
Until that commit reaches the folder's `HEAD` the card stays yellow ("waiting for your commit") and after 30 days
the edit ends `too_little_data`. In practice the owner does not know how to finish the edit (screenshot in the
session that led to #1606).

## 2. Goal

Accept on a repository edit opens a pull request with the edit against the repository's default branch. The
owner's working copy is not touched. The card links the PR. The verdict window starts when the edit is on the
default branch.

Non-goals: merging the PR, editing an open PR, other git hosts than the one `gh` talks to.

## 3. Design

### 3.1 Where the git writes live

`internal/coach` still runs no git (`TestCOACH01_NoGitWrites` stays as it is). `Applier` gets one more seam,
`RepoPublish`, filled by `cmd` (the `coach accept` / `coach rollback` process the Desktop confirms, AGENT-07).
The git and `gh` calls live in a new file `internal/workbenchgit/publish.go`:

```go
type PublishRequest struct {
    Folder, Rel         string // workbench folder, file relative to it
    Before, After       string // the text the base must hold, the text to commit
    Branch              string // coach/proposal-<id> or coach/rollback-<id>
    Title, Body         string
}
type PublishResult struct { PRURL, Base string }
func Publish(ctx context.Context, o Options, req PublishRequest) (PublishResult, error)
```

### 3.2 Accept

1. The checks that need no git run as today (state `open`, baseline, `ValidateAfter`).
2. The folder must have an `origin` remote and `gh` must be logged in (`gh auth status`). Without a remote the
   Accept writes the working copy as today (the old path, unchanged, `dirty`/`not_git` refusals included). `gh`
   missing or logged out refuses with code `no_gh` and nothing is written.
3. `Publish`: `git fetch origin <default>`; a temporary worktree under `<workspace>/coach-pr/<id>` at
   `origin/<default>` (detached, then `-B <branch>`); the file there must hold `Before` — otherwise refused with
   code `base_differs` ("CLAUDE.md on main differs from the one the chat read — pull, then ask the chat again");
   the proposal stays open. Write `After`, commit (author = the repository's git identity, message =
   `coach: <title>`), `git push --force-with-lease origin <branch>`, `gh pr create --base <default>`. The
   temporary worktree is removed on every path (`defer`).
4. `MarkCoachAccepted` stores the PR URL in the new column `coach_proposals.pr_url` (migration, `schema.sql`,
   golden, Swift test schema). `coach accept --json` reports `pr_url`; `written_path` stays (the file the PR
   changes), `written_branch` is the PR's branch.

The working-copy `dirty` check is dropped on the PR path: the working copy is never written.

### 3.3 The verdict window

`coachCommitCheck` also accepts the edit seen on `origin/<default>` (read-only `git show
origin/<default>:<rel>`; the ref moves with the workbench's own periodic fetch): `measure_from` = the first time
either `HEAD` or `origin/<default>` holds the accepted text. The 30-day `too_little_data` rule is unchanged, so an
unmerged PR ends the same way an uncommitted edit ends today.

### 3.4 Rollback

- The default branch holds the accepted text: Rollback opens a second PR (`coach/rollback-<id>`, `Before` ←→
  `After` swapped) and marks the proposal `rolled_back` with that PR's URL in `pr_url`.
- The default branch still holds the before-text (the PR was not merged): Rollback closes the open PR
  (`gh pr close --delete-branch`) and marks it `rolled_back`.
- Anything else refuses with the existing `changed_since` diff.

### 3.5 Desktop

The accepted card shows "PR #N" as a link (opens the browser) instead of "written to CLAUDE.md on <branch>". The
yellow dot's reason reads "waiting for PR #N to merge" while `measure_from` is empty and `pr_url` is set. The text
lives in `CoachPresentation` with a test. No new screen.

## 4. Failures and races

| Event | Result |
|---|---|
| Accept killed after the push, before `MarkCoachAccepted` | Proposal stays open with a pushed branch and maybe a PR. The next Accept reuses the same branch name: `--force-with-lease` pushes the same commit; `gh pr create` finds the existing PR (`gh pr list --head <branch>`) and returns its URL. |
| Accept killed while the temporary worktree exists | The next Accept of any proposal removes `<workspace>/coach-pr/*` left over (`git worktree remove --force`, then `git worktree prune`). |
| Push rejected (no rights, protected branch name) | Refused with code `push_failed` and git's message; proposal stays open; the branch is not left behind. |
| `gh pr create` fails after a successful push | Refused with code `pr_failed`; proposal stays open; the branch stays on origin and is reused by the next Accept. |
| Two Accepts of the same proposal at once | Same branch, same commit; `MarkCoachAccepted` is a compare-and-set on `status = 'open'`, so one wins and the other returns `ErrCoachStateChanged`. |
| Owner merges, then edits the file again before the daemon looks | `measure_from` is never set; the 30-day rule ends it `too_little_data`, as today. |

Writers of `coach_proposals.pr_url`: only `MarkCoachAccepted` and `MarkCoachRolledBack`, both behind the status
compare-and-set.

## 5. Contract change (COACH-01)

"Watchtower never runs a git command that writes, and the owner commits the change" becomes: on Accept or Roll
Back of a workbench repository file in a folder with an `origin` remote, Watchtower creates a branch in a
temporary worktree, commits the one file, pushes the branch and opens or closes a pull request; it never writes
the owner's working copy, never pushes the default branch and never merges. New guard:
`internal/workbenchgit/publish_test.go::TestCOACH01_PublishTouchesOnlyItsBranch` (a bare origin, a folder with a
dirty working copy and a second branch: after `Publish` the working copy, its `HEAD`, the default branch on
origin and every other ref are unchanged; origin gains only `coach/proposal-<id>`).

## 6. Tests

- `Publish`: happy path against a bare origin with a stub `gh`; `base_differs`; push failure; rerun reuses the
  branch and the PR; leftover worktree cleaned.
- `Applier.Accept`: PR path stores `pr_url`, never writes the working copy; no-remote path unchanged; `no_gh`.
- `Applier.Rollback`: merged → second PR; unmerged → close; changed → `changed_since`.
- `coachCommitCheck`: edit seen on `origin/<default>` sets `measure_from`.
- Desktop: `CoachPresentation` texts for the PR link and the waiting reason.
- Docs: `docs/features/agent-coach.md`, `docs/features/tuning-chat.md`, guide page for the coach card.
