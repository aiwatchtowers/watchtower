# Coach repository edits land as pull requests — plan

**Spec:** `docs/superpowers/specs/2026-11-19-coach-repo-edits-as-prs-design.md` (approved, ask #1618)
**Board:** #2082. **Umbrella branch:** `feature/coach-repo-prs` (task branches merge into it locally; one PR umbrella → main).

Every task: inner loop only for what it touched (`go test ./internal/<pkg>`, `make test-swift FILTER=…`,
`make lint-diff`, `make lint-swift` for Swift). Review checklist: `docs/review/review-rules.md`. Before the
umbrella → main PR, the controller runs every job of `.github/workflows/*.yml` locally once.

Guard suites every Go task also runs: `go test ./internal/coach -run 'TestCOACH01'`,
`go test ./cmd -run 'TestCoach'`; a task touching the schema also runs
`go test ./internal/db -run 'TestSchemaGolden|TestDesktopTestSchema|TestAllTablesExist'`.

---

## Task 1 — Schema: `pr_url`, `revert_pr_url`

Depends on: none.

- Migration `internal/db/migrations/00197_coach_pr_urls.sql`: `ALTER TABLE coach_proposals ADD COLUMN pr_url TEXT NOT
  NULL DEFAULT ''` and `revert_pr_url` alike (plain `ADD COLUMN`, no rebuild). Mirror into `internal/db/schema.sql`;
  regenerate the golden and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
  (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`).
- `db.CoachProposal` gains `PRURL`, `RevertPRURL`; the select in `internal/db/coach.go` reads them.
- `MarkCoachAccepted(id, after, branch, prURL, baseline, n, now)` stores `pr_url` (all callers updated, `""` on the
  old path).
- New `MarkCoachRolledBack(id, revertPRURL, now)` — compare-and-set `accepted → rolled_back` that also stores
  `revert_pr_url`; `Applier.Rollback` keeps `DecideCoachProposal` for non-PR rows or switches to it with `""`.
- `SetCoachMeasureFromAt(id, at)` is the existing `SetCoachMeasureFrom` (already takes the time); no change.
- Tests: migration up/down; `MarkCoachAccepted` stores the URL; `MarkCoachRolledBack` refuses a non-accepted row.

## Task 2 — `workbenchgit`: path choice, `Publish`, `PRState`, `ClosePR`

Depends on: none.

New file `internal/workbenchgit/publish.go` (+ `publish_test.go`), all calls through `gitbin`:

- `OriginHost(ctx, o) (host string, err error)` — `git remote get-url origin`, parses https, `ssh://` and
  `git@host:` forms. `IsGitHubFolder(ctx, o, ghLoggedIn func(host) bool) (bool, error)` per spec D8.
- `GHReady(ctx, host) error` — `gh auth status --hostname <host>`; `ErrNoGH` when missing or logged out.
- `DefaultBase(ctx, o) (branch, sha string, err error)` — `gh repo view --json defaultBranchRef`.
- `Publish(ctx, o, PublishRequest) (PublishResult, error)` exactly as spec 4.3 step 3: `git fetch
  --no-write-fetch-head origin <sha>`; remove `<scratch>/<id>` of this id; `git worktree add --detach`; compare
  `Before` (`ErrBaseDiffers`); write `After`; `commit --no-verify`; `push --no-verify --force-with-lease origin
  HEAD:refs/heads/<branch>` (`ErrPushFailed`); `gh pr list --head` → reuse, else `gh pr create` (`ErrPRFailed`);
  `defer` removes the scratch worktree.
- `PRState(ctx, o, url) (state string, mergedAt time.Time, err error)`; `ClosePR(ctx, o, url) error`
  (`gh pr close --delete-branch`).
- Credentials (spec 4.2): push and fetch with `GIT_TERMINAL_PROMPT=0`, no askpass, `-c credential.helper= -c
  'credential.helper=!gh auth git-credential'` for https, `GIT_SSH_COMMAND='ssh -o BatchMode=yes'` for ssh. A
  `gitbin` helper `ExecOwnerNetwork` holds this rule (one place).
- Budgets (D10): 60 s per network call (`context.WithTimeout`), `ErrTimeout` when it fires; the 3-min operation
  budget is the caller's (Task 4).
- `gh` path is a field of `Options` (`GHPath`, default `gh` from `PATH`), so tests use a stub script; the stub
  reaps its process group (CLAUDE.md "Tests that spawn processes reap them").
- Tests (bare origin in `t.TempDir()`, stub `gh` script): spec §7's `Publish` list, path choice for the three URL
  forms, `ErrTimeout` with a hanging stub, and the guard
  `TestCOACH01_PublishTouchesOnlyItsBranch` (working copy, `HEAD`, every local ref incl. `origin/*` and
  `FETCH_HEAD` unchanged; origin gains only `coach/proposal-<id>`). `TestMain` already calls
  `gittest.DisableBackgroundGit()`.

## Task 3 — `internal/coach`: Accept and Rollback by PR

Depends on: Task 1.

- `Applier` gains seams (no git in `internal/coach`, COACH-01 (a) unchanged):
  `RepoRoute func(folder string) (RepoRoute, error)` → `{PR bool}` or `ErrNoGH`;
  `RepoPublish func(folder string, req RepoPublishReq) (prURL, branch string, err error)`;
  `RepoPRState func(folder, url string) (state string, mergedAt time.Time, err error)`;
  `RepoClosePR func(folder, url string) error`. Error sentinels mirrored in coach (`ErrNoGH`, `ErrBaseDiffers`,
  `ErrPushFailed`, `ErrPRFailed`, `ErrTimeout`) with owner sentences, so `cmd` maps them to codes.
- `accept`: for a repo destination, `RepoRoute` first; PR route skips `checkRepo`'s dirty check and the working
  copy read/write: `Before` = `p.BeforeText`, `After` = proposed or edited text (validated against `p.BeforeText`
  as `CurrentText`), then `RepoPublish`, then `MarkCoachAccepted(..., prURL, ...)`. Old route unchanged.
- `Rollback`: a row with `PRURL` → `RepoPRState`: MERGED → `RepoPublish` swapped (`coach/revert-<id>`;
  `ErrBaseDiffers` → `ErrChangedSince` with the diff) then `MarkCoachRolledBack(id, revertURL)`; OPEN →
  `RepoClosePR` then `MarkCoachRolledBack(id, "")`; CLOSED → `MarkCoachRolledBack(id, "")`; any seam error →
  refused, still `accepted`.
- `SyncPRs(now) (int, error)` — for accepted rows with `pr_url` and no `measure_from`: `RepoPRState`, MERGED →
  `SetCoachMeasureFrom(id, mergedAt)`; a seam error skips the row. Accept and Rollback call it at their end
  (errors logged, never fail the verb).
- Tests with fake seams: spec §7's Accept, Rollback and sync lists; the old route's tests stay green.
- Guard `TestCOACH01_NoGitWrites` (b): add `workbenchgit.OriginHost`, `IsGitHubFolder`, `GHReady`, `DefaultBase`,
  `Publish`, `PRState`, `ClosePR` as allowed **only in `cmd/coach*.go`** (still forbidden in the daemon and
  `internal/tuning`), and the new seams to `seams`. Update its doc comment to the amended COACH-01. Do not relax
  any other assertion.

## Task 4 — `cmd`: wiring, codes, `coach sync-prs`

Depends on: Tasks 2, 3.

- `cmd/coach.go` fills the four seams over `workbenchgit` (scratch = `<workspace>/coach-pr`), with a 3-min
  `context.WithTimeout` around Accept and Rollback.
- `--json` failure codes: `no_gh`, `base_differs`, `push_failed`, `pr_failed`, `timeout` (same failure object as
  today); success adds `pr_url` (and `revert_pr_url` for rollback). `coach proposals --json` adds both columns.
- New verb `coach sync-prs [--json]` → `Applier.SyncPRs`; not an owner-confirmation verb (it only reads GitHub and
  sets `measure_from`), but refused under an AI agent's markers like the other coach verbs.
- `watchtower workbench cleanup` lists `<workspace>/coach-pr/*` folders older than a day (removed with `--apply`).
- Daemon: unchanged (no `gh`); assert in a test that the daemon's Applier has nil PR seams.
- Tests: `cmd/coach_test.go` codes and output fields with fake seams; `sync-prs` happy path; cleanup listing.

## Task 5 — Desktop: PR link, waiting text, revert, sync on show

Depends on: Tasks 1, 4.

- `CoachProposal` (WatchtowerCore) decodes `pr_url`, `revert_pr_url` (`CoachProposal+Row.swift`);
  `CoachWrittenFile.parse` reads `pr_url`.
- `CoachPresentation`: "PR #N" link label (number parsed from the URL), dot reason "Waiting for PR #N to merge"
  (accepted, `pr_url` set, `measure_from` empty), revert line "Revert: PR #M — merge it to remove the edit from
  main"; failure sentences for the five new codes. Tests in `Tests/Core`.
- `CoachAcceptedLogView`: the link (opens the browser via `NSWorkspace`), the revert line. Tones only through
  `Tone`.
- `CoachCenter`: runs `coach sync-prs` once when the accepted list appears (not on a timer), then reloads.
- `make desktop-shots` for the accepted card with a PR, waiting, and reverted; compare with the spec text.
- `make test-swift FILTER='CoachPresentation|CoachProposal|CoachCenter'`, `make lint-swift`.

## Task 6 — Docs and inventory

Depends on: Tasks 3, 4, 5.

- `docs/inventory/coach.md` COACH-01: the amended sentence from spec §6, the new guard, the amended (b) list.
- `docs/features/agent-coach.md`, `docs/features/tuning-chat.md` (the `repo_*` paragraph), the
  `docs/features/README.md` summary line.
- Guide: the coach card page under `docs/guide/` (PR link, `gh auth login`), `go test ./docs/guide`.
