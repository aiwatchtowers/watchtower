# Spec review — an independent reviewer for specs and plans (2026-10-25)

Spec: `docs/superpowers/specs/2026-10-25-spec-review-design.md`; plan 1: `docs/superpowers/plans/2026-10-25-spec-review-p1-core.md`; plan 2 (Desktop): `docs/superpowers/plans/2026-10-25-spec-review-p2-desktop.md`; plan 3 (pack, guide, phone): `docs/superpowers/plans/2026-10-25-spec-review-p3-pack-guide-phone.md`. Contracts: SPECREVIEW-01..03 in `docs/inventory/spec-review.md`.

## Summary

When the agent files a `review` ask for a spec or a plan, a second, independent reviewer agent reads the document against the conversation that produced it and the workbench folder, and stores a structured, quote-checked result next to the ask. The owner opens the ask with the findings ready. The reviewer never replaces the ask: it is filed whatever the reviewer does (SPECREVIEW-02).

## Storage

Migration `00158_spec_reviews.sql` (mirrored in `schema.sql`); access in `internal/db/spec_reviews.go`.

- `owner_asks.doc_type` — `''` (not a review), `spec`, `plan`, `other`.
- `spec_reviews(ask_id PK, status queued|running|done|failed|skipped, reason, result, provider, model, doc_sha, dropped, pid, attempt, queued_at, started_at, finished_at)` — one reviewer run per review ask. `QueueSpecReview` upserts to `queued`, clears the result and adds one to `attempt`; `RelaunchQueuedSpecReview` is the sweep's conditional re-queue (only `WHERE status='queued' AND attempt < 3`); `RequeueSpecReview` (the owner's `start`) resets `attempt` to 1; `ClaimSpecReview` moves queued to running under the reviewer's pid; `FinishSpecReview` / `FailSpecReview` act only on a running row of that pid; `SkipSpecReview` records why no review runs.
- `spec_review_marks(ask_id, item_key, state, body, about, updated_at)` — the owner's per-item marks; the Desktop writes them, Go only reads them for `show` (`about` key). A comment's `about` is the finding text, so a comment whose finding a re-run drops still says what it was about; `''` when there is none.

## Starting a review

- `ask_owner` (`internal/tools/workbench_asks.go`) takes `doc_type` (`spec`, `plan`, `other`; default from the path by `specreview.ClassifyDoc`). A spec or plan queues a review row right after the ask's transaction has committed, then calls the surface's launcher.
- Neither a failed queue write nor a launcher failure fails the ask: a refusal or failure records `skipped` with the reason (`could not queue: …`, `launch failed: …`, `plan near limit`, or `no reviewer on this surface` when the surface has no launcher); the reason is always in the `spec_review` result key, also when the skip itself cannot be written. The cmd launcher (`specReviewLauncher`) skips on a Claude plan near its limit (`planusage.NearLimit`).
- Skill pack v17 (`internal/devpack`): the core skill tells the agent to pass `doc_type` on a review ask; the `watchtower-flow` preset makes every spec carry a `## Decisions` section (one line per owner decision with its source, `ask #N` or `conversation`) and commits mockups agreed in a brainstorm under `docs/design/mockups/<feature>/`, linked from the spec.
- `LaunchSpecReview` (`cmd/workbench_spec_review_launch.go`) starts `workbench spec-review run --ask N` detached in its own session, output appended to `<workspace>/logs/spec-review.log`, agent-session env markers dropped, the child reaped in the background. The binary comes from the package var `specReviewExe` (`/usr/bin/false` in cmd tests).

## The run — `internal/specreview`

The review header (`reviewHeader`) names the document's type, path, chapters and design lens; a spec's also says `decisions_section: present|absent`. A plan is never asked for a Decisions section: its agreements come from its spec, whose Decisions section is part of the spec block. A spec's Decisions section is a `## ` heading whose text starts with the word "Decisions", any case (`## Decisions (owner-approved)`): `isDecisionsHeading`, the same rule as the Desktop's `SpecReviewDecisions`.

`Run` claims the row (a row no longer queued is left alone) and fails it at once with "ask withdrawn" when the ask was withdrawn or superseded before the claim (an ask withdrawn while the agent works still gets its result), then: `BuildInputs` (the document snapshot, the conversation from the session feed trimmed to `MaxConversationRunes`, answered asks, the linked spec of a plan, mockups and the style guide when the document talks about screens, the previous round's findings), one `Agent.Review` call under `RunTimeout` (10 min, `MaxTurns` 40 on claude), `Parse` (validation: caps in `limits.go`, every quote must be a whitespace-normalised substring of its source, SPECREVIEW-03), then `FinishSpecReview`. Any failure after the claim stores `failed` with a one-line reason. Every quote's source records its `speaker` (`owner` | `agent`, set by `Parse` from `Sources.OwnerWords`, never by the model): the owner's words are an owner line, the owner's answer texts, check notes, comment bodies and note of an ask (chosen option labels count as the owner's answer; questions, check items and quoted document text do not), and owner comments; agent text, agent comments, the target, the Decisions section and the spec are `agent`. `idea.owner_source` must be the owner's; an agreement from the conversation, an ask or a comment must quote the owner, while `decisions`, `spec` and `target` sources stay allowed. The result carries `summary`, `idea`, `agreements`, `decided_alone`, `blind_spots`, `checks`, `resolved`, `notes`, `dropped`, `code_read`; items have stable keys (`ag:` + 12 hex digits) and chapters (`Chapters`). An idea with no real quotes, or none, is left out (`idea` is a pointer with `omitempty`; the Desktop also reads an idea with blank quotes as absent, for rows stored before). An anchored item's chapter is its where-quote's; a missing agreement or a blind spot without `where` keeps the `chapter` the reviewer named (key or heading) when the document has it, else `""` (the Desktop's Other).

The agent (`specReviewCLIAgent`, cmd) runs the configured provider in read-folder mode with **no MCP server at all**: claude with Read/Grep/Glob/LS only and no folder settings, codex in its read-only sandbox, both in their own process group. Ollama has no file tools: the same prompt answered from the data alone (`code_read` false). The model tier is strong (`workbench.spec_review`).

## Daemon sweep — `internal/daemon/spec_review_sweep.go`

`phaseSpecReviewSweep`, the last step of a cycle (after `phaseInstructionSuggestions`), runs only when cmd wired `SetSpecReviewLaunch` (`cmd/sync.go`):

- a `queued` row older than 60 s is re-queued by `RelaunchQueuedSpecReview` (attempt + 1, the minute restarts, only while still queued with `attempt < 3`) and launched only when that update changed the row, at most 3 per cycle — a slow reviewer that claimed the row meanwhile keeps it, no second reviewer starts; a row still queued with `attempt >= 3` is claimed under pid 0 and failed with "could not start";
- a `running` row whose pid is gone (`syscall.Kill(pid, 0)` gives ESRCH) or that started more than `RunTimeout` + 2 min ago is failed with "reviewer process ended without a result"; an overdue reviewer still alive is first sent SIGTERM to its process group (`-pid`; it leads its own session), only when the pid still leads its group and the process started no later than `started_at` (+1 s), so a reused pid is never signalled.

## CLI — `watchtower workbench spec-review`

- `run --ask N` (hidden) — the detached child; the exit status is the run's.
- `start --ask N [--force]` — `RequeueSpecReview` (attempt back to 1: the sweep's 3-launch cap counts automatic relaunches only) and launch. No plan-limit gate: the owner pressed Run. A queued review is launched again; a running one is refused (exit 3); a done, failed or skipped one needs `--force` (exit 3 without). A failed launch leaves the row queued for the sweep.
- `show --ask N [--json]` — pinned `--json` keys: `ask_id`, `status`, `reason`, `provider`, `model`, `dropped`, `attempt`, `queued_at`, `started_at`, `finished_at`, `result` (the validated result or `null`), `marks` (item key to `{state, body, about, updated_at}`; `state` is `ok`, `comment`, `viewed` or, since 2026-10-26, `not_useful`; `about`, a comment's finding text, is left out when not known). The database is opened read-only.

## Desktop — the findings screen

- `SpecReviewModel` (`WatchtowerDesktop/Sources/ViewModels/`) drives one open review ask of a spec or a plan: its `spec_reviews` row and `spec_review_marks` (read through `SpecReviewQueries`, the marks written there), the 3 s poll while the reviewer is queued or running, Run / Re-run reviewer (`workbench spec-review start --force`; exit 3 = already running), and the derived Meaning / Chapters / Wrap-up state (findings by chapter, a trailing Other, unmarked counts, orphans of a re-run, the Decisions list of a spec — a plan shows none). It is built on the app's pool by `OwnerAskDrawer`; `followReviewer` looks for a row not written yet (10 × the poll interval) and then starts the poll.
- Drawer modes (`SpecReviewPresentation.drawerMode`): `loading` until the first read returns (nothing shown, so the classic view never flashes), `review` (the screen) for a done result or a reviewer still working, `classic` with a status strip (failed, skipped, or working after **Read the spec**) or a banner (a result that arrived while the classic view was open). Under the screen the footer's verdict buttons and the draft keys stand aside.
- One answer builder. Every answer to a review ask ends in `OwnerAsksViewModel.answer(_:with:)` — the classic footer's Request changes / Approve, the screen's Send / Approve, a Quick answer and the phone's relay (`AskAnswerHandler`). For a review ask (not a dismissal) it reads the row and the marks from the database at answer time and appends `SpecReviewAnswer`'s comments: comment marks only, in findings order, placed in the rendered snapshot (off the main actor); with no result (queued, running, failed) every comment mark goes out as "From the previous run: <about> — <body>". The screen itself hands over only the draft (margin comments, question answers, note) and the verdict, so nothing is sent twice and nothing depends on the screen having been opened.
- **Not useful** (2026-10-26, agent coach #1120): a third button on a finding beside **Fine as is** and **Comment**; the mark reads "Not useful" with **Undo** (`SpecReviewMarkState.notUseful`, `SpecReviewFindingCard`, `SpecReviewWrapUpView.markGlyph`). It is the coach's noise signal (`docs/features/agent-coach.md`) and `SpecReviewAnswer` never sends it to the author. An older app reading a newer row skips the unknown state.
- The phone's `owner_ask` slice carries one `spec_review` line per review ask: one query for all the slice's review rows, a done review's counts decoded once per `finished_at` (`SpecReviewLines`).

## Rulings that changed behaviour against the spec

- An invalid `doc_type` is refused by `ask_owner` instead of being guessed.
- A surface without a launcher (not the workbench MCP server) records `skipped: no reviewer on this surface`.
- The reviewer gets no MCP servers, not even the watchtower ones, and reads one folder (the session's worktree when recorded, else the workbench folder).
- `start` has no near-limit gate; only the automatic start from `ask_owner` has.

## v1 limits

- Phone: a one-line status only; no findings screen, and it writes no marks (a Not useful mark is not counted in its line).
- `spec_reviews.findings` (migration 00160) is the number of findings in the stored result when the review finished (`-1` before the migration); the coach reads it for the first round's count because a re-run replaces `result`.
- Ollama has no file tools, so its reviews are from the data alone and are marked `code_read: false`.
- Marks are the Desktop's alone: the phone answers a review ask without seeing them (they still go with its answer).
- The sweep is the last step of `runSync`: a lost start can wait one whole cycle, and a cycle cancelled before the end skips it.
- `<workspace>/logs/spec-review.log` is appended to and never rotated.
- The reviewer's model usage is not in the usage meter yet (the read-folder `QuerySync` path does not tag its source).
- Without a running daemon, a queued row whose child died before claiming stays queued until the owner runs `start`.
