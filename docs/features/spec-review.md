# Spec review — an independent reviewer for specs and plans (2026-10-25)

Spec: `docs/superpowers/specs/2026-10-25-spec-review-design.md`; plan 1: `docs/superpowers/plans/2026-10-25-spec-review-p1-core.md`. Contracts: SPECREVIEW-01..03 in `docs/inventory/spec-review.md`.

## Summary

When the agent files a `review` ask for a spec or a plan, a second, independent reviewer agent reads the document against the conversation that produced it and the workbench folder, and stores a structured, quote-checked result next to the ask. The owner opens the ask with the findings ready. The reviewer never replaces the ask: it is filed whatever the reviewer does (SPECREVIEW-02).

## Storage

Migration `00153_spec_reviews.sql` (mirrored in `schema.sql`); access in `internal/db/spec_reviews.go`.

- `owner_asks.doc_type` — `''` (not a review), `spec`, `plan`, `other`.
- `spec_reviews(ask_id PK, status queued|running|done|failed|skipped, reason, result, provider, model, doc_sha, dropped, pid, attempt, queued_at, started_at, finished_at)` — one reviewer run per review ask. `QueueSpecReview` (inside the ask's transaction) upserts to `queued`, clears the result and adds one to `attempt`; `ClaimSpecReview` moves queued to running under the reviewer's pid; `FinishSpecReview` / `FailSpecReview` act only on a running row of that pid; `SkipSpecReview` records why no review runs.
- `spec_review_marks(ask_id, item_key, state, body, updated_at)` — the owner's per-item marks; the Desktop writes them, Go only reads them for `show`.

## Starting a review

- `ask_owner` (`internal/tools/workbench_asks.go`) takes `doc_type` (`spec`, `plan`, `other`; default from the path by `specreview.ClassifyDoc`). A spec or plan queues a review row in the ask's own transaction and then calls the surface's launcher, after the ask is committed.
- Launcher failure never fails the ask: a refusal or failure records `skipped` with the reason (`launch failed: …`, `plan near limit`, or `no reviewer on this surface` when the surface has no launcher). The cmd launcher (`specReviewLauncher`) skips on a Claude plan near its limit (`planusage.NearLimit`).
- `LaunchSpecReview` (`cmd/workbench_spec_review_launch.go`) starts `workbench spec-review run --ask N` detached in its own session, output appended to `<workspace>/logs/spec-review.log`, agent-session env markers dropped, the child reaped in the background. The binary comes from the package var `specReviewExe` (`/usr/bin/false` in cmd tests).

## The run — `internal/specreview`

`Run` claims the row (a row no longer queued is left alone), then: `BuildInputs` (the document snapshot, the conversation from the session feed trimmed to `MaxConversationRunes`, answered asks, the linked spec of a plan, mockups and the style guide when the document talks about screens, the previous round's findings), one `Agent.Review` call under `RunTimeout` (10 min, `MaxTurns` 40 on claude), `Parse` (validation: caps in `limits.go`, every quote must be a whitespace-normalised substring of its source, SPECREVIEW-03), then `FinishSpecReview`. Any failure after the claim stores `failed` with a one-line reason. The result carries `summary`, `idea`, `agreements`, `decided_alone`, `blind_spots`, `checks`, `resolved`, `notes`, `dropped`, `code_read`; items have stable keys (`ag:` + 12 hex digits) and chapters (`Chapters`).

The agent (`specReviewCLIAgent`, cmd) runs the configured provider in read-folder mode with **no MCP server at all**: claude with Read/Grep/Glob/LS only and no folder settings, codex in its read-only sandbox, both in their own process group. Ollama has no file tools: the same prompt answered from the data alone (`code_read` false). The model tier is strong (`workbench.spec_review`).

## Daemon sweep — `internal/daemon/spec_review_sweep.go`

`phaseSpecReviewSweep`, the last step of a cycle (after `phaseInstructionSuggestions`), runs only when cmd wired `SetSpecReviewLaunch` (`cmd/sync.go`):

- a `queued` row older than 60 s is queued again (attempt + 1, the minute restarts) and launched, at most 3 per cycle; a row with `attempt >= 3` is failed with "could not start";
- a `running` row whose pid is gone (`syscall.Kill(pid, 0)` gives ESRCH) or that started more than `RunTimeout` + 2 min ago is failed with "reviewer process ended without a result".

## CLI — `watchtower workbench spec-review`

- `run --ask N` (hidden) — the detached child; the exit status is the run's.
- `start --ask N [--force]` — `RequeueSpecReview` and launch. No plan-limit gate: the owner pressed Run. A queued review is launched again; a running one is refused (exit 3); a done, failed or skipped one needs `--force` (exit 3 without). A failed launch leaves the row queued for the sweep.
- `show --ask N [--json]` — pinned `--json` keys: `ask_id`, `status`, `reason`, `provider`, `model`, `dropped`, `attempt`, `queued_at`, `started_at`, `finished_at`, `result` (the validated result or `null`), `marks` (item key to `{state, body, updated_at}`). The database is opened read-only.

## Rulings that changed behaviour against the spec

- An invalid `doc_type` is refused by `ask_owner` instead of being guessed.
- A surface without a launcher (not the workbench MCP server) records `skipped: no reviewer on this surface`.
- The reviewer gets no MCP servers, not even the watchtower ones, and reads one folder (the session's worktree when recorded, else the workbench folder).
- `start` has no near-limit gate; only the automatic start from `ask_owner` has.

## v1 limits

- Phone: a one-line status only; no findings screen.
- Ollama has no file tools, so its reviews are from the data alone and are marked `code_read: false`.
- The Desktop screen for the findings and marks is a later plan; Plan 1 ends at the stored result, the CLI and the sweep.
