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
| D9 | Nothing in the owner's repository moves: the base commit is read from the remote (`gh repo view` names the default branch, `git ls-remote` gives its head commit; `DefaultBase`) and fetched by its id, `git fetch --no-write-fetch-head origin <sha>`, so neither `origin/<default>` nor `FETCH_HEAD` changes. Branch names carry a per-workspace token: `coach/<token>/proposal-<id>`, `<token>` being 8 random hex digits kept in `<workspace>/coach_branch_token`, so two workspaces pushing to one repository never collide. | Reviewer, round 2 |
| D10 | Every network call has a budget: 60 s per `git fetch`/`git push`/`gh` call, 3 min for a whole Accept or Roll Back. Over budget: refused with code `timeout`, the proposal keeps its state, the scratch folder is removed. | Reviewer, round 2 |
| D7 | Rollback of a merged edit opens a revert PR and records it apart from the original PR; the card says the revert is waiting for its merge. | Reviewer, round 1 |

## 4. Design

### 4.1 Where the git writes live

`internal/coach` still runs no git (`TestCOACH01_NoGitWrites` stays as it is). `Applier` gets four more seams,
`RepoRoute`, `RepoPublish`, `RepoPRState` and `RepoClosePR`, filled only by `cmd` (`cmd/coach_pr.go`, the one file allowed to call the PR helpers) (the `coach accept` / `coach rollback` / `coach sync-prs`
processes the owner starts; Accept and Roll Back are confirmed in the Desktop, AGENT-07). The daemon leaves them
nil. The git and `gh` calls live in a new file
`internal/workbenchgit/publish.go`, through `gitbin` like every other workbench git call:

```go
type PublishRequest struct {
    Folder, Rel   string // workbench folder, file relative to it
    Before, After string // the text the base must hold, the text to commit
    Branch        string // coach/<token>/proposal-<id> or coach/<token>/revert-<id>
    Delete        bool   // delete the file instead of writing After (reverting a created file)
    BaseBranch, BaseSHA string // the default branch and its head commit
    Title, Body   string
}
type PublishResult struct{ PRURL, Base string }
func Publish(ctx context.Context, o Options, req PublishRequest) (PublishResult, error)
func PRState(ctx context.Context, o Options, url string) (state string, mergedAt time.Time, err error)
func ClosePR(ctx context.Context, o Options, url string) error
```

`Options` gains the scratch folder, `<workspace>/coach-pr` (`<workspace>` is the active Watchtower workspace
folder, the one that holds `coach.lock`), the path of `gh` (`exec.LookPath`, then the Homebrew locations, since
the Desktop runs the CLI with a GUI PATH), and `Repo`, the GitHub repository (`HOST/OWNER/REPO`) the route chose.

`Rel` is relative to the workbench folder, which may sit below the repository's top level: `Publish` prefixes the
folder's offset (`git rev-parse --show-prefix`) before it reads, writes or deletes the file in the scratch
worktree, so a nested workbench's `CLAUDE.md` is `<sub>/CLAUDE.md` in the pull request, never the top-level one.

Accept, Decline and Roll Back of one proposal hold a per-proposal lock across processes (a non-blocking `flock`
on `<workspace>/coach-locks/<id>.lock`, taken after the owner's confirmation and held through the status read and
`MarkCoach*`): a second decision of the same proposal is refused at once with code `in_progress` ("This proposal is
already being accepted, declined or rolled back — wait for it to finish."), never queued. The kernel drops the
lock when the holder dies.

### 4.2 Credentials

Every call runs without a terminal prompt (`GIT_TERMINAL_PROMPT=0`, no askpass), as today's fetch does. Unlike
the background fetch, `push` keeps the owner's credentials: `gh` is its credential helper for an https origin
(`-c credential.helper= -c 'credential.helper=!gh auth git-credential'`), and an ssh origin uses the owner's ssh
agent with `BatchMode=yes` (`GIT_SSH_COMMAND` overrides the repository's `core.sshCommand` for the push). The push
runs only when `origin`'s push URL names the same repository as its fetch URL (a `pushurl` that points at a fork is
refused as `push_failed`) and with `--no-follow-tags`. The commit keeps the file's mode and honours the owner's
`commit.gpgSign`, so a signing prompt may appear; it is bounded by the 3-minute budget. A push that needs a prompt
fails as `push_failed` with git's message. `gh auth status`
in step 2 below checks the same login the push uses on https.

### 4.3 Accept

1. The checks that need no git run as today (state `open`, baseline, `ValidateAfter`).
2. `RepoRoute` decides the path from `origin` (D8) and, once, which of origin's URLs (configured, or rewritten by
   `url.<x>.insteadOf`) names the repository (`workbenchgit.GitHubOrigin`): `gh auth status`, `DefaultBase` and
   `Publish` all work on that one, so an alias whose own host gh is not logged in to never reads as `no_gh`. A
   `gh auth status` that cannot reach GitHub (offline) is refused retryably with code `github_unreachable`
   ("Could not reach GitHub to check your gh login; nothing changed — try again.", or `timeout` over the budget) —
   on another host too: when no host could be accepted and gh could not check one of them, the Accept is refused,
   never written to the working copy; only gh missing or not logged in to that host keeps D2. A folder that is not a git work tree keeps today's path and its
   `not_git` refusal. A remote whose host is an ssh alias (for example `github-work`) is not `github.com`, so it
   takes today's path (a known limit). No `origin`, or a host that is not GitHub: D2, today's
   path, unchanged (`dirty`/`not_git` refusals included). A GitHub folder whose `gh` is not installed or not
   logged in: refused with code `no_gh` ("Log in with `gh auth login` to let Accept open the pull request"),
   nothing written. Otherwise `DefaultBase` reads the default branch with `gh repo view --json defaultBranchRef` and its head commit with `git ls-remote`.
3. `Publish`:
   - `git fetch --no-write-fetch-head origin <sha>` (the head commit from step 2, with the push's credentials,
     4.2; no ref of the repository moves, D9);
   - remove a leftover `<scratch>/<id>` of this proposal (`git worktree remove --force`, then forget the worktree);
   - `git worktree add --detach <scratch>/<id> <sha>` — no local branch is created;
   - the file there must hold `Before` (a file missing there holds the empty text, so only `CLAUDE.md` and
     `AGENTS.md` may be created: `MayCreate`), otherwise refused with code `base_differs` ("CLAUDE.md on main differs from
     the one the chat read — pull, then ask the chat again"); the proposal stays open;
   - write `After`; `git commit --no-verify` (author = the repository's git identity, message `coach: <title>`, the file's mode kept);
   - `git push --no-verify --no-follow-tags --force-with-lease origin HEAD:refs/heads/coach/<token>/proposal-<id>`;
   - `gh pr list --head coach/<token>/proposal-<id> --state open` → reuse that PR, else `gh pr create --base <default>`;
   - remove `<scratch>/<id>` on every path (`defer`).
4. `MarkCoachAccepted` stores the PR URL in the new column `coach_proposals.pr_url` (migration, `schema.sql`,
   golden, Swift test schema). `coach accept --json` reports `pr_url`; `written_path` stays (the file the PR
   changes), `written_branch` is `coach/<token>/proposal-<id>`.

The working-copy `dirty` check does not apply to the PR path: the working copy is never written.

### 4.4 The verdict window

A row with `pr_url` is measured from its merge only, and only the owner's processes look at it (D5): the
daemon's `coachCommitCheck` and its query `ListRepoProposalsAwaitingCommit` skip rows with `pr_url`, so it stays the
one writer of `measure_from` for working-copy rows and never writes a PR row. `coach sync-prs`, which the Desktop
runs when the Coach tab's accepted list or the tuning panel is shown, reads `RepoPRState` for each accepted PR row
without `measure_from` and a verdict:

- `MERGED` within 30 days of the Accept (`repoCommitWait`): `measure_from` = the PR's `mergedAt`
  (compare-and-set on `measure_from IS NULL`);
- `MERGED` later, or still `OPEN` 30 days after the Accept: final `too_little_data`;
- `CLOSED` without merge: `rolled_back` — closing the PR is the owner's rejection;
- every rule reads `mergedAt` and the Accept time, never the sync time, so a late sync gives the same result;
- `gh` failing: the row is left as it was.

The weekly judge gives no final `too_little_data` to a PR row whose `measure_from` is empty (the daemon cannot see
GitHub); once `measure_from` is set, the row is judged like every other. Accept and Roll Back do not sync other
rows.

### 4.5 Rollback

Rollback reads the PR's state first (`PRState`):

- `MERGED`: `Publish` with `Before`/`After` swapped and branch `coach/<token>/revert-<id>` (its base must hold the
  accepted text, else `changed_since` with the diff, as today; the revert of a `CLAUDE.md`/`AGENTS.md` Accept created
  deletes the file, `Delete` (whenever `Before` is empty for those two files, so a pre-existing empty file is deleted, not restored empty); the stored PR's repository must be `origin`'s, else `origin_moved`); the proposal goes `rolled_back` and the revert PR's URL goes
  to the new column `revert_pr_url`. `pr_url` keeps the original PR.
- `OPEN`: `ClosePR` (`gh pr close`, then the remote branch only is deleted, never a local one), then `rolled_back`.
- `CLOSED` (closed without merge, by hand, or by an earlier Roll Back whose branch deletion failed): `ClosePR`
  again, which does not close a closed PR but deletes its coach branch from origin if it is still there (only
  `coach/<token>/proposal-<id>`, only when origin is the PR's repository and the URL git really pushes to —
  after `insteadOf`/`pushInsteadOf` — names that repository, else the branch is left and logged; a branch already
  gone is fine); a failure there is logged, not fatal; then `rolled_back`.
- A `coach sync-prs` that marked the row `rolled_back` between the close and `MarkCoachRolledBack` (it saw the
  close) wins the row; Roll Back reads it back and reports success.
- `gh` fails, the push of the revert branch fails, or `ClosePR` fails: refused with that error (`pr_unreadable` when
  the state cannot be read), the proposal stays `accepted`, nothing recorded.

### 4.6 Desktop

The accepted card shows "PR #N" as a link (opens the browser) instead of "written to CLAUDE.md on <branch>". The
yellow dot's reason reads "Waiting for the merge" beside the link (folded: "Accepted · waiting for the PR to merge") while `measure_from` is empty and `pr_url` is set. A rolled
back card with `revert_pr_url` shows "Revert: PR #M — merge it to remove the edit." and keeps showing it after the
revert PR merges (nothing syncs the revert PR's state; a v1 limit). An open card of a `repo_*` edit names only the
file, no branch: the route (PR or working copy) is not known before Accept. `coach sync-prs` failures show as one
owner sentence built from the sync code, never gh's raw output. A Roll Back of a merged PR whose file moved on the
default branch (`changed_since`) opens the sheet with the diff, "The file changed since the merge" and
"<file> on the default branch changed since the merge — revert it by hand in a pull request.", and only Close:
no Roll Back Anyway, since `--force` cannot revert a pull request. The texts live in
`CoachPresentation` with a test. No new screen.

## 5. Failures and races

| Event | Result |
|---|---|
| Accept killed after the push, before `MarkCoachAccepted` | Proposal stays open with a pushed branch and maybe a PR. The next Accept of it pushes the same commit again (`--force-with-lease`) and finds the PR with `gh pr list --head`. |
| Accept killed while its scratch worktree exists | The next Accept of the same proposal removes `<scratch>/<id>` first. A leftover of a proposal never accepted again stays until `watchtower workbench cleanup` removes it (it lists `<scratch>` folders older than a day; the Desktop's `--stream` cleanup does not list them). |
| Two Accepts of different proposals at once | Different scratch folders and branches; neither removes the other's folder (cleanup is per id). `git worktree add` takes git's own lock on the repository's worktree list. |
| Two Accepts (or an Accept and a Roll Back) of the same proposal at once | The per-proposal lock (4.1) refuses the second with `in_progress` before it reads the status; nothing of the first is touched. A CLI killed while holding it frees it (the kernel drops a dead process's `flock`). |
| Accept racing a Decline of the same proposal | Same lock: the Decline (or the Accept) is refused with `in_progress`, so no pull request is opened for a proposal declined meanwhile. |
| Push rejected (no rights, protected branch name, needs a prompt, a `pushurl` to another repository) | `push_failed` with git's message; proposal stays open. |
| The stored PR belongs to another repository than `origin` now (Roll Back) | `origin_moved`; nothing published. |
| `gh pr view` fails (Roll Back, `coach sync-prs`) | `pr_unreadable`; the row stays as it was. |
| `gh pr create` fails after the push | `pr_failed`; proposal stays open; the branch stays on origin and the next Accept reuses it. |
| Rollback: `gh` fails, the revert push or `ClosePR` fails | Refused, proposal stays `accepted` (4.5). |
| Rollback: PR closed by hand | Its leftover coach branch is deleted if origin still has it (logged on failure), then `rolled_back`. |
| Rollback closed the PR, the branch deletion failed | Refused, proposal stays `accepted`; the retry sees `CLOSED`, deletes the branch and rolls back (4.5). |
| Rollback closed the PR; `coach sync-prs` saw the close and marked `rolled_back` first | Roll Back's compare-and-set fails, it reads the row back as `rolled_back` and reports success. |
| `gh auth status` cannot reach GitHub (Accept route check, any host) | `github_unreachable` (or `timeout`), retryable; nothing tried, never a working-copy write. |
| `insteadOf`/`pushInsteadOf` sends origin's push to another repository | ClosePR leaves the branch (logged); the close itself still counts. |
| Workbench folder below the repository's top level | `Publish` prefixes the folder's offset (4.1): the nested file is edited, created or deleted. |
| A network call hangs | Over its budget (D10): `timeout`, state unchanged, scratch folder removed. |
| Owner edits the file again after the merge | Measuring starts at the merge regardless; the verdict compares the period, as for every other edit. |

Writers of `pr_url` and `revert_pr_url`: only `MarkCoachAccepted` and `MarkCoachRolledBack`, both behind the
status compare-and-set; writer of `measure_from`: `coachCommitCheck` (daemon, `HEAD`) for rows without `pr_url`, `coach
sync-prs` (`mergedAt`) for rows with it — never both for one row; each a compare-and-set on `measure_from IS NULL`.
Writers of a PR row's `too_little_data`: only `coach sync-prs`.

## 6. Contracts

- **COACH-01** changes. "Watchtower never runs a git command that writes, and the owner commits the change"
  becomes: on Accept or Roll Back of a workbench repository file in a GitHub folder, Watchtower commits the one
  file in a detached scratch worktree, pushes it to `coach/<token>/proposal-<id>` or `coach/<token>/revert-<id>` and opens or
  closes a pull request; it never writes the owner's working copy or local refs, never pushes another branch and
  never merges. New guard: `internal/workbenchgit/publish_test.go::TestCOACH01_PublishTouchesOnlyItsBranch` (a bare
  origin, a folder with a dirty working copy and a second branch: after `Publish` the working copy, `HEAD` and
  every local ref — `origin/*` and `FETCH_HEAD` included — are unchanged, and origin gains only
  `coach/<token>/proposal-<id>`). `TestCOACH01_NoGitWrites` also scans the module: the PR helpers
  (`workbenchgit.Publish`, `PRState`, `ClosePR`, `GitHubOrigin`, `GHReady`, `DefaultBase`,
  `PRRepository`) are called from `cmd/coach*.go` only, and `TestCoachDaemon_NoPullRequestSeams` pins that the daemon
  names none of the PR seams.
- **AGENT-07** unchanged: Accept and Roll Back still run only on the owner's confirmation in the Desktop.
- **PROJ-10** and the workbench git rules (`workbench.md`) unchanged: no branch switch, no stash, no write in the
  owner's working tree; the new calls go through `gitbin` and add the push credential rule of 4.2.

## 7. Tests

- `Publish` (bare origin, stub `gh`): happy path; `base_differs`; push failure → `push_failed`; `gh pr create`
  failure → `pr_failed`, then a rerun reuses the branch and finds the PR; a leftover scratch folder of the same id is
  removed; two parallel `Publish` of different ids both succeed; no local ref is created.
- `Applier.Accept`: PR path stores `pr_url` and never writes the working copy; non-GitHub path unchanged; `no_gh`.
- `Applier.Rollback`: `MERGED` → revert PR in `revert_pr_url`; `OPEN` → closed; `CLOSED` → the leftover branch
  deleted (a failure logged), then the status; a row `coach sync-prs` rolled back meanwhile counts as done;
  `gh` failure and push failure leave it `accepted`; base moved → `changed_since`.
- `coach sync-prs`: a merged PR sets `measure_from` to `mergedAt`; an open PR under 30 days sets nothing; a PR
  closed unmerged ends `rolled_back`; one merged after 30 days or open past 30 days ends `too_little_data`; `gh` failure leaves the row; the daemon's
  `coachCommitCheck` skips PR rows and runs no `gh`; the judge gives no final verdict to a PR row without
  `measure_from`.
- Path choice (D8): github.com https/ssh/scp URLs → PR path; another host without `gh` login → old path; github.com
  without `gh` → `no_gh`.
- Budgets (D10): a stub `gh` that hangs → `timeout`, proposal still open.
- Desktop: `CoachPresentation` texts for the PR link, the waiting reason and the revert.
- Failure codes (`coach accept|rollback --json`): `no_gh`, `base_differs`, `push_failed`, `pr_failed`, `timeout`,
  `pr_unreadable`, `origin_moved`, `github_unreachable`, `in_progress`; a rollback whose base moved is
  `changed_since` with the diff, and the Desktop's sheet for it offers no Roll Back Anyway for a PR edit (it names
  the file and says to revert it by hand in a pull request).
- Nested workbench folder: the edit, a created file and a deletion land under the folder's offset.
- Lock: a second Accept, Decline or Roll Back of a held proposal is refused with `in_progress`.
- An `insteadOf` alias to a host gh is logged in to: routing, `GHReady` and `Publish` use that host.
- Docs: `docs/features/agent-coach.md`, `docs/features/tuning-chat.md`, `docs/inventory/coach.md`, the guide page
  for the coach card.
