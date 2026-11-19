# Coach repository edits land as pull requests

Board #2082. Owner decision: ask #1606 ("Что делает Accept на правке файла репозитория? → Сам открывает PR").
Amends COACH-01 (`docs/inventory/coach.md`, "Workbench repository files").

## 1. Problem

The tuning chat may propose edits to five files of a workbench folder (`repo_claude_md`, `repo_agents_md`,
`repo_claude_skill`, `repo_codex_skill`, `repo_workflow`). Today Accept writes the file into the owner's working
copy and stops: the owner has to notice the uncommitted change, commit it on the right branch, push and merge.
Until that commit reaches the folder's `HEAD` the card stays yellow ("waiting for your commit") and after 30 days
the edit ends `too_little_data`. In practice the owner does not know how to finish the edit (the session that led
to #1606).

## 2. Goal

Accept on a repository edit opens a pull request with the edit against the repository's default branch. The
owner's working copy and local refs are not touched. The card links the PR. The verdict window starts when the PR
is merged.

Non-goals: merging the PR, editing an open PR, git hosts other than GitHub (the one `gh` talks to).

## 3. Decisions

| # | Decision | Source |
|---|---|---|
| D1 | Accept on a repository edit opens a PR instead of writing the working copy. | Owner, ask #1606 |
| D2 | A folder whose `origin` is not a GitHub repository `gh` can reach keeps today's path (write the working copy, owner commits). Without it such folders could not take repository edits at all. | This spec; flagged for the owner's review |
| D3 | `gh` missing or logged out in a GitHub folder refuses (`no_gh`) instead of falling back to the working copy: a silent fallback would bring back the problem #1606 fixes. The refusal says how to log in. | This spec; flagged for the owner's review |
| D4 | The default branch is GitHub's (`gh repo view --json defaultBranchRef`), not `origin/HEAD`, which a clone may not have set. | This spec |
| D5 | Merge is seen through `gh pr view <url> --json state,mergedAt`, not through `origin/<default>`, which only the Desktop's header fetch moves. `gh` runs only in processes the owner starts (Accept, Roll Back, the Coach tab's refresh), never in the daemon: `gh` reads its token from the Keychain, which may raise a system prompt from a background process — the same reason `gitbin` keeps credential helpers out of the background fetch. | Reviewer, rounds 1–2 |
| D6 | The commit and the push run without the repository's hooks (`--no-verify`): the commit holds one Markdown file the owner reviews in the PR, and the repository's CI runs on it there. | This spec |
| D8 | A folder is a GitHub folder when its `origin` URL's host is `github.com` (https, ssh or `git@host:` form), read with `git remote get-url origin` — no `gh` needed to decide. Another host takes the PR path only when `gh auth status --hostname <host>` succeeds; otherwise D2. So a missing or logged-out `gh` refuses (`no_gh`) on github.com and never silently drops a GitHub folder to the old path. | Reviewer, round 2 |
| D9 | Nothing in the owner's repository moves: the base commit is fetched by its id (`gh repo view --json defaultBranchRef` gives the branch and its head commit), `git fetch --no-write-fetch-head origin <sha>`, so neither `origin/<default>` nor `FETCH_HEAD` changes. | Reviewer, round 2 |
| D10 | Every network call has a budget: 60 s per `git fetch`/`git push`/`gh` call, 3 min for a whole Accept or Roll Back. Over budget: refused with code `timeout`, the proposal keeps its state, the scratch folder is removed. | Reviewer, round 2 |
| D7 | Rollback of a merged edit opens a revert PR and records it apart from the original PR; the card says the revert is waiting for its merge. | Reviewer, round 1 |

## 4. Design

### 4.1 Where the git writes live

`internal/coach` still runs no git (`TestCOACH01_NoGitWrites` stays as it is). `Applier` gets two more seams,
`RepoPublish` and `RepoPRState`, filled only by `cmd` (the `coach accept` / `coach rollback` / `coach sync-prs`
processes the owner starts; Accept and Roll Back are confirmed in the Desktop, AGENT-07). The daemon leaves both
nil. The git and `gh` calls live in a new file
`internal/workbenchgit/publish.go`, through `gitbin` like every other workbench git call:

```go
type PublishRequest struct {
    Folder, Rel   string // workbench folder, file relative to it
    Before, After string // the text the base must hold, the text to commit
    Branch        string // coach/proposal-<id> or coach/revert-<id>
    Title, Body   string
}
type PublishResult struct{ PRURL, Base string }
func Publish(ctx context.Context, o Options, req PublishRequest) (PublishResult, error)
func PRState(ctx context.Context, o Options, url string) (state string, mergedAt time.Time, err error)
func ClosePR(ctx context.Context, o Options, url string) error
```

`Options` gains the scratch folder: `<workspace>/coach-pr`, where `<workspace>` is the active Watchtower
workspace folder (the one that holds `coach.lock`).

### 4.2 Credentials

Every call runs without a terminal prompt (`GIT_TERMINAL_PROMPT=0`, no askpass), as today's fetch does. Unlike
the background fetch, `push` keeps the owner's credentials: `gh` is its credential helper for an https origin
(`-c credential.helper= -c 'credential.helper=!gh auth git-credential'`), and an ssh origin uses the owner's ssh
agent with `BatchMode=yes`. A push that needs a prompt fails as `push_failed` with git's message. `gh auth status`
in step 2 below checks the same login the push uses on https.

### 4.3 Accept

1. The checks that need no git run as today (state `open`, baseline, `ValidateAfter`).
2. `git remote get-url origin` decides the path (D8). No `origin`, or a host that is not GitHub: D2, today's
   path, unchanged (`dirty`/`not_git` refusals included). A GitHub folder whose `gh` is not installed or not
   logged in: refused with code `no_gh` ("Log in with `gh auth login` to let Accept open the pull request"),
   nothing written. Otherwise `gh repo view --json defaultBranchRef` gives the default branch and its head commit.
3. `Publish`:
   - `git fetch --no-write-fetch-head origin <sha>` (the head commit from step 2, with the push's credentials,
     4.2; no ref of the repository moves, D9);
   - remove a leftover `<scratch>/<id>` of this proposal (`git worktree remove --force`, `git worktree prune`);
   - `git worktree add --detach <scratch>/<id> <sha>` — no local branch is created;
   - the file there must hold `Before`, otherwise refused with code `base_differs` ("CLAUDE.md on main differs from
     the one the chat read — pull, then ask the chat again"); the proposal stays open;
   - write `After`; `git commit --no-verify` (author = the repository's git identity, message `coach: <title>`);
   - `git push --no-verify --force-with-lease origin HEAD:refs/heads/coach/proposal-<id>`;
   - `gh pr list --head coach/proposal-<id> --state open` → reuse that PR, else `gh pr create --base <default>`;
   - remove `<scratch>/<id>` on every path (`defer`).
4. `MarkCoachAccepted` stores the PR URL in the new column `coach_proposals.pr_url` (migration, `schema.sql`,
   golden, Swift test schema). `coach accept --json` reports `pr_url`; `written_path` stays (the file the PR
   changes), `written_branch` is `coach/proposal-<id>`.

The working-copy `dirty` check does not apply to the PR path: the working copy is never written.

### 4.4 The verdict window

A row with `pr_url` is measured from its merge only, and only the owner's processes look at it (D5): the
daemon's `coachCommitCheck` and its query `ListRepoProposalsAwaitingCommit` skip rows with `pr_url`, so it stays the
one writer of `measure_from` for working-copy rows and never writes a PR row. `coach sync-prs`, which the Desktop
runs when the Coach tab's accepted list or the tuning panel is shown, reads `RepoPRState` for each accepted PR row
without `measure_from` and a verdict:

- `MERGED`: `measure_from` = the PR's `mergedAt` (compare-and-set on `measure_from IS NULL`);
- `CLOSED` without merge, or still `OPEN` 30 days after the Accept (`repoCommitWait`): final `too_little_data`;
- `gh` failing: the row is left as it was.

The weekly judge gives no final `too_little_data` to a PR row whose `measure_from` is empty (the daemon cannot see
GitHub); once `measure_from` is set, the row is judged like every other. Accept and Roll Back do not sync other
rows.

### 4.5 Rollback

Rollback reads the PR's state first (`PRState`):

- `MERGED`: `Publish` with `Before`/`After` swapped and branch `coach/revert-<id>` (its base must hold the accepted
  text, else `changed_since` with the diff, as today); the proposal goes `rolled_back` and the revert PR's URL goes
  to the new column `revert_pr_url`. `pr_url` keeps the original PR.
- `OPEN`: `ClosePR` (`gh pr close --delete-branch`), then `rolled_back`.
- `CLOSED` (closed without merge, by hand): only `rolled_back`.
- `gh` fails, the push of the revert branch fails, or `ClosePR` fails: refused with that error, the proposal stays
  `accepted`, nothing recorded.

### 4.6 Desktop

The accepted card shows "PR #N" as a link (opens the browser) instead of "written to CLAUDE.md on <branch>". The
yellow dot's reason reads "waiting for PR #N to merge" while `measure_from` is empty and `pr_url` is set. A rolled
back card with `revert_pr_url` shows "revert: PR #M — merge it to remove the edit from main". The texts live in
`CoachPresentation` with a test. No new screen.

## 5. Failures and races

| Event | Result |
|---|---|
| Accept killed after the push, before `MarkCoachAccepted` | Proposal stays open with a pushed branch and maybe a PR. The next Accept of it pushes the same commit again (`--force-with-lease`) and finds the PR with `gh pr list --head`. |
| Accept killed while its scratch worktree exists | The next Accept of the same proposal removes `<scratch>/<id>` first. A leftover of a proposal never accepted again is removed by `git worktree prune` once its folder is gone; `watchtower workbench cleanup` lists `<scratch>` folders older than a day. |
| Two Accepts of different proposals at once | Different scratch folders and branches; neither removes the other's folder (cleanup is per id). `git worktree add` takes git's own lock on the repository's worktree list. |
| Two Accepts of the same proposal at once | Same folder: the second's removal of `<scratch>/<id>` can break the first, which then fails and leaves the proposal open; the survivor's `MarkCoachAccepted` is a compare-and-set on `status = 'open'`. Desktop sends one Accept per card, so this needs two CLI calls. |
| Push rejected (no rights, protected branch name, needs a prompt) | `push_failed` with git's message; proposal stays open. |
| `gh pr create` fails after the push | `pr_failed`; proposal stays open; the branch stays on origin and the next Accept reuses it. |
| Rollback: `gh` fails, the revert push or `ClosePR` fails | Refused, proposal stays `accepted` (4.5). |
| Rollback: PR closed by hand | `rolled_back` without a git call. |
| A network call hangs | Over its budget (D10): `timeout`, state unchanged, scratch folder removed. |
| Owner edits the file again after the merge | Measuring starts at the merge regardless; the verdict compares the period, as for every other edit. |

Writers of `pr_url` and `revert_pr_url`: only `MarkCoachAccepted` and `MarkCoachRolledBack`, both behind the
status compare-and-set; writer of `measure_from`: `coachCommitCheck` (daemon, `HEAD`) for rows without `pr_url`, `coach
sync-prs` (`mergedAt`) for rows with it — never both for one row; each a compare-and-set on `measure_from IS NULL`.
Writers of a PR row's `too_little_data`: only `coach sync-prs`.

## 6. Contracts

- **COACH-01** changes. "Watchtower never runs a git command that writes, and the owner commits the change"
  becomes: on Accept or Roll Back of a workbench repository file in a GitHub folder, Watchtower commits the one
  file in a detached scratch worktree, pushes it to `coach/proposal-<id>` or `coach/revert-<id>` and opens or
  closes a pull request; it never writes the owner's working copy or local refs, never pushes another branch and
  never merges. New guard: `internal/workbenchgit/publish_test.go::TestCOACH01_PublishTouchesOnlyItsBranch` (a bare
  origin, a folder with a dirty working copy and a second branch: after `Publish` the working copy, `HEAD` and
  every local ref — `origin/*` and `FETCH_HEAD` included — are unchanged, and origin gains only
  `coach/proposal-<id>`).
- **AGENT-07** unchanged: Accept and Roll Back still run only on the owner's confirmation in the Desktop.
- **PROJ-10** and the workbench git rules (`workbench.md`) unchanged: no branch switch, no stash, no write in the
  owner's working tree; the new calls go through `gitbin` and add the push credential rule of 4.2.

## 7. Tests

- `Publish` (bare origin, stub `gh`): happy path; `base_differs`; push failure → `push_failed`; `gh pr create`
  failure → `pr_failed`, then a rerun reuses the branch and finds the PR; a leftover scratch folder of the same id is
  removed; two parallel `Publish` of different ids both succeed; no local ref is created.
- `Applier.Accept`: PR path stores `pr_url` and never writes the working copy; non-GitHub path unchanged; `no_gh`.
- `Applier.Rollback`: `MERGED` → revert PR in `revert_pr_url`; `OPEN` → closed; `CLOSED` → only the status;
  `gh` failure and push failure leave it `accepted`; base moved → `changed_since`.
- `coach sync-prs`: a merged PR sets `measure_from` to `mergedAt`; an open PR under 30 days sets nothing; a PR
  closed unmerged or open past 30 days ends `too_little_data`; `gh` failure leaves the row; the daemon's
  `coachCommitCheck` skips PR rows and runs no `gh`; the judge gives no final verdict to a PR row without
  `measure_from`.
- Path choice (D8): github.com https/ssh/scp URLs → PR path; another host without `gh` login → old path; github.com
  without `gh` → `no_gh`.
- Budgets (D10): a stub `gh` that hangs → `timeout`, proposal still open.
- Desktop: `CoachPresentation` texts for the PR link, the waiting reason and the revert.
- Docs: `docs/features/agent-coach.md`, `docs/features/tuning-chat.md`, `docs/inventory/coach.md`, the guide page
  for the coach card.
