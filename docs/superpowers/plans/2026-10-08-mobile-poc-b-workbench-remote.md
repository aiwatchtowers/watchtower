# Mobile POC B: Workbench Remote (#424)

**Goal:** from the iPhone, the owner sees every workbench, session, board and ask live; answers asks; edits the board; starts and stops sessions; and, on an allowed phone, tells an idle session something. Every write goes through the Mac's existing code paths.

**Architecture:**
- The Mac hub publishes resolved, capped projections:
  - `workbench`, `workbench_target`, `workbench_comment`, `terminal_session`, `owner_ask`, `ask_alert`, `session_report` and `session_timeline`;
  - a fast lane driven by session-state and table changes.
- A `@MainActor` dispatcher applies phone actions through the same code the Desktop UI uses, after small extractions on main:
  - the structured `answer(_:with:)`;
  - `WorkbenchOwnerWrites`;
  - `Placement.background` plus `startForTarget`;
  - `SessionLineDelivery`;
  - a Go `workbench target add`.
- Phone input is governed by the new contract PROJ-16.

**Specs:** `docs/superpowers/specs/2026-10-07-mobile-poc-business.md` and `docs/superpowers/specs/2026-10-07-mobile-poc-design.md` (§4.2–§4.9, §5.2, §6.1–§6.3, §6.5, §6.6, §7, §11, §13 B).

**Requires plan A:** `docs/superpowers/plans/2026-10-08-mobile-poc-a-skeleton.md`.

## Global constraints (verbatim from the spec)

**Carried over from plan A**
- All of plan A's Global constraints apply: container, zones, scopes, timing, payload guard 900_000, visual rules, hygiene, English, and the inner loop only.

**Never published**
- `projects.folder_path` (raw), `terminal_sessions.claude_session_id`, `terminal_sessions.folder_path`, `agent_turn_end`, `agent_tool_run`, any token, any session transcript or terminal text (I-4).

**Clipping**
- A clipped text is cut at a grapheme boundary, ends with `…`, and sets `<field>_clipped: true`.
- A capped list sets `<list>_more: n`.

**Caps per slice**
- **workbench:** ≤ 100 workbenches. `name` 200, `description` 1000, `folder_display` 300 (home → `~`), `branch` 120. Git status is refreshed every 120 s per workbench and on a session state change, at most once per 30 s per workbench.
- **workbench_target:** non-archived ≤ 2000 per workbench; archived (closed in the last 90 days) ≤ 500. `text` 300, `intent` 4000, `branch`/`pr` 120, `session_ids` ≤ 20, `work_on_prompt` 1000.
- **workbench_comment:** newest 200 per target. `agent_label` 60, `body` 4000.
- **terminal_session:** `kind = 'claude'` only; every live session plus the newest 50 per workbench. `title` 200, `state_caption` 120, `finish_summary` 2000, `agent_error` 60, `report_pr_line` 120. The report summary runs every 60 s per workbench with live sessions.
- **owner_ask:** every open ask, plus closed asks from the last 7 days (≤ 50 per workbench). `title` 200, `summary`/`changes` 4000, `payload` ≤ 64 KiB, `doc_path` 300, `doc_snapshot` ≤ 256 KiB (cut at the last newline, with `doc_clipped` and `doc_bytes`; open asks only), `answer` ≤ 64 KiB.
- **owner_ask `quick`:** set only when the ask is a `question` with exactly one question, `multi` is false, at least one option is recommended, and it has 2–4 options.
- **ask_alert:** written once per ask, only when `created_at ≥ heartbeat.enabled_at`. Deleted when the ask leaves `open`, or after 7 days.
- **session_report:** live sessions, plus those active in the last 7 days.
  - Caps: `on_you` 30, `now` 20, `next` 20, `phases` 30 with ≤ 50 items each, `prs` 10, text 500. Whole payload ≤ 128 KiB, dropping the oldest phase items and setting `phases_clipped`.
  - Cadence: on a state change, coalesced 5 s; every 120 s with `--no-network`; on request without `--no-network`, at most once per 60 s per session.
- **session_timeline:** ≤ 100 milestones, `text` 200. The sidecar `session_milestones` keeps 100 per session for 14 days. No subagent events (OD-3).

**Relay**
- New action kinds and their `params`, `reason` codes and echo statuses are exactly as in spec §5.2.
- The idempotency key is the action `id` (UUIDv4, record `action-<id>`).
- Non-idempotent kinds are marked `begun` before they apply: `board_comment_add`, `board_comment_reply`, `board_target_create`, `session_start`, `session_input`, `session_finish_request`.
- Expiry: 24 h for `session_input`, `session_finish_request` and `session_start`; 7 days for the others.
- Board statuses come from `WorkbenchBoardCard.editableStatuses` (`todo`, `in_progress`, `in_review`, `blocked`, `done`, `dismissed`) and priorities from `editablePriorities` (`high`, `medium`, `low`).

**Fixed texts**
- Plan-first suffix, exactly: "Plan first: put the plan on the board, then ask me with ask_owner before you change any code."
- Finish line, exactly: "Please wrap up: update the board, then call finish_session with a short summary."

**PROJ-16 (approved, OD-1)**
- The wording is in spec §11.
- The phone toggle plus a one-time Allow on the Mac (OD-2).
- The phone never answers a permission prompt; it shows "Needs approval on the Mac".

**Visual rules**
- Session colours map exactly to `SessionStatePresentation.Tone`: green → working/running; orange → waiting for you, needs approval, finished with open asks; blue → finished; red → failed; secondary → stopped/not started.
- A session that is not live draws a ring.
- Orange is used only for waiting and asks.

**Contracts that must stay green, unchanged**
- PROJ-01, PROJ-05, PROJ-06, PROJ-09, PROJ-11, PROJ-12, PROJ-14 and PROJ-15 guard tests, as listed in `docs/inventory/workbench.md`.

**Docs**
- Extend `docs/features/mobile-companion.md` per task.
- `docs/app-guide.md`: the iPhone Workbench section.
- `docs/inventory/workbench.md`: PROJ-16, in Task 18.

## Review focus

Five failure modes that no task's spec-derived tests cover. Each one has a test added to the task that owns it.

1. **Workbench deleted on the Mac** while the phone still shows it and has queued actions. Its records leave the zone (PROJ-02 spirit), and the queued actions fail `not_found` → Tasks 2 and 12.
2. **Session row deleted on the Mac** while a phone line is held for it → `failed` with `session_not_running`, and the held line is dropped → Task 18.
3. **Ask superseded** (`previous_ask_id` chain) while the owner drafts on the phone. Answering the old one → `ask_not_open`, and the phone moves to the new ask with the draft kept as text → Task 9.
4. **Text at the cap boundaries:** RTL, ZWJ emoji and combining marks are clipped without breaking a grapheme, and the clipped flag is set → Task 2.
5. **Fast-lane storm:** 30 live sessions changing state every second → one send per coalescing window, ≥ 2 s apart, no rate-limit loop, and the published state is never older than one window plus one send → Task 3.

---

## Task 1: Kit mirrors for the workbench kinds

**Depends on:** A-Task 3. **Lane:** Kit.

**Files:** `WatchtowerKit/Sources/WatchtowerKit/Models/`: `Workbench.swift`, `WorkbenchTarget.swift`, `WorkbenchComment.swift`, `TerminalSessionState.swift`, `OwnerAsk.swift` (with the questions/focus/checklist payload and an `OwnerAskAnswer` mirror), `SessionReport.swift`, `SessionTimeline.swift`, plus fixtures.

**Interfaces:**
- New `SliceKind` raw values: `workbench`, `workbench_target`, `workbench_comment`, `terminal_session`, `owner_ask`, `session_report`, `session_timeline`.
- Mirror field names are exactly spec §4.2–§4.9.
- New `ActionKind`s: `ask_answer`, `board_target_status`, `board_target_priority`, `board_comment_add`, `board_comment_reply`, `board_target_create`, `session_start`, `session_input`, `session_input_cancel`, `session_finish_request`, `session_stop`, `session_report_request`.

**Tests (`WorkbenchMirrorFixtureTests`):**
- Each kind decodes a frozen fixture.
- Unknown extra keys are ignored.
- A missing optional (`target_id`, `quick`) decodes as nil.
- The `OwnerAskAnswer` mirror encodes byte-equal to `internal/asks/testdata/answers` (each fixture file).
- Each new `ActionKind`'s params round-trip.

**Checks:** `make kit-test FILTER=WorkbenchMirrorFixtureTests`, `make lint-diff`.

## Task 2: projections for workbenches, board targets and comments

**Depends on:** A-Task 6, Task 1. **Lane:** Desktop Swift. Pure logic; does not need A-Task 14.

**Files:**
- `WatchtowerDesktop/Sources/Services/MobileHub/Slices/WorkbenchSlice.swift`, `WorkbenchTargetSlice.swift`, `WorkbenchCommentSlice.swift`, and `SliceClip.swift` (the clipping helper).
- The git status refresher: through `WorkbenchCLI` (`Sources/Services/WorkbenchCLI.swift:437`).

**Sources consumed:**
- `WorkbenchQueries.switcherSummaries` (`WatchtowerCore/Database/Queries/WorkbenchQueries.swift:115`) and `board` (`:309`);
- `workbench_target_archive`;
- `TerminalLaunch.workOnTargetPrompt` (`WatchtowerCore/Services/TerminalLaunch.swift:88`);
- `target_status_history`;
- `terminal_session_targets`.

**Tests (`WorkbenchSliceTests`, `WorkbenchTargetSliceTests`, `SliceClipTests`):**
- **Hidden columns:** a key scan of every encoded payload finds no `folder_path`, `claude_session_id`, `agent_turn_end` or `agent_tool_run`.
- **`folder_display`:** `~/Projects/acme` for a folder under home; a folder outside home is shown as-is, clipped at 300.
- **PROJ-01:** a personal target (`project_id IS NULL`) is never published.
- **Archive window:** an archived target closed 89 days ago is published with `archived: true`; one closed 91 days ago is not.
- **Workbench caps:** 2001 non-archived targets → 2000 newest by `updated_at`, plus `targets_more: 1` on the workbench record.
- **Zero workbenches:** zero records and no error.
- **Git status failure:** keeps the last branch. Detached → `detached: true`, branch "".
- **Progress:** `done_targets` counts only non-archived done targets; zero targets → 0/0.
- **Comments:** 201 comments on one target → the newest 200.
- **Review focus 4:** RTL text, a ZWJ family emoji and a combining-accent string, each at a cap of n and n + 1, are clipped at a grapheme boundary and get `…` and the flag.
- **Review focus 1:** a workbench deleted in the DB → its workbench, target and comment records are deleted from the zone at the next diff.

**Guards that must stay green:** PROJ-01 and PROJ-15 suites (read-only use).

**Checks:** `make test-swift FILTER='WorkbenchSliceTests|WorkbenchTargetSliceTests|SliceClipTests'`, `make lint-diff`.

## Task 3: terminal_session projection and the fast lane

**Depends on:** Task 2. **Lane:** Desktop Swift.

**Files:** `Slices/TerminalSessionSlice.swift`, `Slices/SessionReportSummaryRunner.swift` (`watchtower workbench session-report --workbench N --summary --json`, as in `SessionReportCenter.swift:263`), and `MobileHub/FastLane.swift`.

**Interfaces:**
- State fields come from `SessionSwitcherPresentation.State` and `SessionStatePresentation` (`WatchtowerCore/Services/SessionStatePresentation.swift:7`): `state_kind`, `state_caption`, `state_tone`, `state_glyph`, `is_ring`.
- `live` comes from `TerminalCenter.liveIDs` (`TerminalCenter.swift:161`).
- `closed_asks` comes from `OwnerAskQueries.closedAsks`.
- Fast lane:
  - it chains onto `SessionAgentStateCenter.onChange` and `onRead` (`Sources/Services/SessionAgentStateCenter.swift:56,60`) without replacing the closures `initWorkbenches` sets;
  - GRDB `ValueObservation` over `owner_asks`, `terminal_sessions`, `project_comments` and `targets WHERE project_id IS NOT NULL`;
  - 1 s coalescing, ≥ 2 s apart, then `sendChanges()`.

**Tests (`TerminalSessionSliceTests`, `FastLaneTests`):**
- **Presentation parity:** for each kind (`working`, `running`, `waiting_on_ask`, `needs_approval`, `finished` with and without open asks, `stopped`, `failed` with an error and with an empty one, `not_started`), the published tone, caption and glyph equal `SessionStatePresentation`'s.
- **Shells:** shell sessions are not published.
- **Session window:** 60 sessions with 3 live → 50 newest plus any live outside them.
- **Report summary:** the summary JSON maps to the report fields. A summary failure keeps the last values.
- **Fast lane:** Needs approval reaches the zone within one window plus one send (fake clock), not at the 10 s tick.
- **Closure chaining:** the existing `onChange`/`onRead` closures still fire, as the PROJ-12 held-answer wiring does.
- **Review focus 5:** 30 sessions changing state every 1 s for 60 s → at most 30 sends, each ≥ 2 s apart, and the last published state equals the last DB state.

**Guards that must stay green:** `SessionAgentStateCenterTests`, every `testProj11_*`, every `testProj12_*` (their wiring is chained, not replaced).

**Checks:** `make test-swift FILTER='TerminalSessionSliceTests|FastLaneTests|SessionAgentStateCenterTests|OwnerAsksViewModelTests'`, `make lint-diff`.

## Task 4: owner_ask and ask_alert publishing

**Depends on:** Task 2. **Lane:** Desktop Swift (after Task 3, or in a lane with Task 3 merged; same files are not shared).

**Files:** `Slices/OwnerAskSlice.swift`, `Slices/AskAlertSlice.swift`, and the sidecar table `alerted_asks(ask_id, at)`.

**Sources:** `OwnerAskQueries.openAsks`/`closedAsks` (`OwnerAskQueries.swift:56,67`) and the payload shape in Go `internal/asks/asks.go`.

**Tests (`OwnerAskSliceTests`, `AskAlertSliceTests`):**
- **Snapshot caps:**
  - A 2 MiB `doc_snapshot` → 256 KiB cut at the last newline, `doc_clipped: true`, `doc_bytes` = 2 MiB.
  - A snapshot with no newline before the cap → cut at the cap's grapheme boundary.
  - A snapshot of exactly 256 KiB → not clipped.
  - Closed asks carry no snapshot.
- **Payload cap:** a 65 KiB payload → `payload_clipped: true` and the payload is dropped.
- **`quick`:**
  - set for one single-select question with a recommended option and 3 options;
  - absent for multi-select, for no recommended option, for 1 option, for 5 options and for 2 questions.
- **Closed asks:** 51 closed asks in 7 days → 50; one closed 8 days ago is not published.
- **`ask_alert`:**
  - an ask open before `enabled_at` → no alert;
  - a new ask → exactly one;
  - a re-hydrate or epoch reset → none;
  - the ask answered → its alert is deleted;
  - an alert 7 days + 1 s old → deleted.

**Checks:** `make test-swift FILTER='OwnerAskSliceTests|AskAlertSliceTests'`, `make lint-diff`.

## Task 5: phone Workbench tab and Now tab (read-only)

**Depends on:** Task 1, A-Task 11. **Lane:** phone Swift.

**Files:**
- `WatchtowerMobile/Sources/Features/Workbench/`: `WorkbenchListView`, `WorkbenchView` (switcher header with New session, Waiting for you stack, SESSIONS list, Sessions | Board segment), `BoardView` (tree, filters), `BoardTargetDetailView` (read-only in this task), and their view models.
- `Features/Now/NowView.swift`.
- `DemoSeed`: add workbenches, sessions in every state, asks of the three kinds, and a board with archived targets.
- `docs/app-guide.md`: the iPhone Workbench section.

**Interfaces:**
- **Level 1:** name, folder, branch, waiting count, session-state counts, board progress (`done/(open+done)`).
- **Session row:** dot and label from the record, the report line `#<report_target_id> · <done>/<total> · <report_pr_line>`, mini progress, open-ask count, "▸ N closed".
- **Board filters:** Open, In progress, Blocked, Archive.
- **Now tab:** Waiting for you across workbenches (newest first, 20 shown) and session summary chips. The next meeting card comes in C.

**Tests (`WorkbenchWiringTests`, `BoardFilterTests`, `SessionRowTests`, `NowWiringTests`, plus snapshot tests):**
- Zero sessions → "No sessions yet".
- A 0-of-0 board → no progress bar.
- **Archive filter:** shows only `archived` records; the other filters never do.
- A target with 0 children → no disclosure.
- The report line renders "#415 · 1/2 · PR #175 open" from the fixture.
- A record missing `report_target_id` → no report line.
- **Tones:** every `state_tone` maps to `.green`, `.orange`, `.blue`, `.red` or `.secondary`, and a non-live session draws a ring.
- **Orange only for waiting and asks:** a snapshot test over the DemoSeed screens finds orange only on waiting or ask elements.
- Now with zero open asks → "Nothing is waiting for you".

**Checks:** `make mobile-test MOBILE_FILTER='WorkbenchWiringTests|BoardFilterTests|SessionRowTests|NowWiringTests'`, `make lint-diff`.

## Task 6: session_report and session_timeline slices

**Depends on:** Task 3. **Lane:** Desktop Swift.

**Files:** `Slices/SessionReportSlice.swift` (runs `--session S --json`, as in `SessionReportCenter.swift:283`), `Slices/SessionTimelineSlice.swift`, and the sidecar `session_milestones(session_id, at, kind, text, ref)`. The `session_report_request` handler is registered on the dispatcher.

**Tests (`SessionReportSliceTests`, `SessionTimelineSliceTests`):**
- **Report cap:** a 200 KiB report → under 128 KiB, the oldest phase items dropped, `phases_clipped`.
- **Report window:** a session active 8 days ago → no report record.
- **Request throttle:** a request twice within 60 s → the CLI runs once (network). The periodic run uses `--no-network`.
- **Timeline cap:** 150 milestones → the newest 100.
- **Timeline sources:** a state transition observed by the hub → a `state` milestone. Target status history of a linked target before the session's `created_at` → excluded.
- **Subagents:** no milestone of a subagent kind is ever produced.
- **No sources:** a session with no milestones → an empty list, not a missing record.
- **Pruning:** the sidecar prunes after 14 days.

**Guards that must stay green:** the PROJ-14 suites (the CLI is unchanged).

**Checks:** `make test-swift FILTER='SessionReportSliceTests|SessionTimelineSliceTests'`, `make lint-diff`.

## Task 7: phone session detail

**Depends on:** Tasks 5 and 6. **Lane:** phone Swift.

**Files:** `Features/Workbench/SessionDetailView.swift` (header: title, target chip, branch, agent and age; its open asks on top; report progress segments plus summary; timeline; the "Tell the session…" bar, hidden until Task 18) and `SessionDetailViewModel.swift` (sends `session_report_request` on open).

**Tests (`SessionDetailWiringTests`):**
- A session with no report → header and timeline only.
- Opening the detail twice within 60 s → one request action (the phone throttle matches the Mac's).
- The view model and view have no transcript field (I-4): a compile-time check that the mirror has none, plus a snapshot test.
- A `needs_approval` session shows "Needs approval on the Mac".

**Checks:** `make mobile-test MOBILE_FILTER=SessionDetailWiringTests`, `make lint-diff`.

## Task 8: structured answer entry on the Mac

**Depends on:** none (main-only refactor). **Lane:** Desktop Swift. Can start at once.

**Files:**
- `WatchtowerDesktop/Sources/ViewModels/OwnerAsksViewModel.swift`: extract the part after the draft in `answer(_:verdict:)` (`:480`) into one shared step; add `answer(_ ask: OwnerAsk, with: OwnerAskAnswer) async -> AnswerOutcome`.
- `WatchtowerCore/Services/OwnerAskAnswerValidation.swift`: the same rules as `OwnerAskDraft.isAnswerable` (`WatchtowerCore/Services/OwnerAskDrafts.swift:46`) applied to an answer value.

**Interfaces:**
- `AnswerOutcome`: `.stored(Delivery)`, `.notOpen`, `.invalid(String)` or `.busy`.
- Validation: a review needs a verdict; every question needs a label or an Other; labels must exist among the options; checklist ids must exist; comment bodies must be non-empty.

**Tests (`OwnerAsksStructuredAnswerTests`, `OwnerAskAnswerValidationTests`):**
- A structured answer stores before typing and delivers like a draft answer (the same `Delivery` for a running session, a held one, and no session).
- An ask withdrawn meanwhile → `.notOpen`, nothing typed, and the Desktop draft is kept.
- An unknown label → `.invalid`, nothing written.
- A review without a verdict → `.invalid`.
- A Desktop draft for the same ask is discarded after a successful structured answer.
- A concurrent Desktop answer of the same ask → `.busy`, then `.notOpen` on retry.

**Guards that must stay green, unchanged:** every PROJ-12 guard listed in `docs/inventory/workbench.md` (`OwnerAsksViewModelTests`, `TerminalCenterTests`, `CodeHandoffCenterTests`, `OwnerAskPromptTests`, `OwnerAskQueriesTests`).

**Checks:** `make test-swift FILTER='OwnerAsksStructuredAnswerTests|OwnerAskAnswerValidationTests|OwnerAsksViewModelTests|TerminalCenterTests|CodeHandoffCenterTests|OwnerAskPromptTests|OwnerAskQueriesTests'`, `make lint-diff`.

## Task 9: ask answers from the phone

**Depends on:** Tasks 4, 5 and 8. **Lane:** split in two commits, Desktop first and phone second (one Swift lane at a time).

**Files:**
- Desktop: `MobileHub/Handlers/AskAnswerHandler.swift` (registered on the dispatcher; maps `AnswerOutcome` to an echo).
- Phone: `Features/Asks/QuestionAskView`, `ReviewAskView` (snapshot, select-to-comment, Approve / Request changes), `CheckAskView` (ok/broken/skipped per step), `AskViewModel`.
- Kit: `CommentAnchorBuilder` (a port of Core's `CommentAnchor`), plus a shared fixture `anchor-fixtures.json` read by both Core and Kit tests.

**Interfaces:**
- `ask_answer` params `{workbench_id, answer}`.
- Echo `result.delivery` is one of `submitted`, `typed`, `held`, `queued`, `copied` or `no_session`. Failures: `ask_not_open`, `invalid_answer`.

**Tests:**
- Desktop `AskAnswerHandlerTests`: the same action delivered twice → one store and one line.
- Kit `CommentAnchorBuilderTests` and Core `CommentAnchorFixtureTests`: the anchor built from the shared fixture is equal on both sides, including a selection at the document start, one at the end, one spanning a heading, and one in a clipped snapshot's last shown line.
- Phone `AskFormTests`:
  - multi-question paging keeps answers across pages;
  - Other with only whitespace does not count as an answer;
  - a clipped snapshot shows "Showing the first 256 KB of N";
  - `payload_clipped` → only "Open the ask on the Mac".
- **Review focus 3:** a superseded ask → the answer fails `ask_not_open`; the phone opens the new ask (via `previous_ask_id`) and keeps the old draft's text.

**Checks:** `make test-swift FILTER='AskAnswerHandlerTests|CommentAnchorFixtureTests'`, `make kit-test FILTER=CommentAnchorBuilderTests`, `make mobile-test MOBILE_FILTER=AskFormTests`, `make lint-diff`.

## Task 10: quick answer from the notification

**Depends on:** Task 9, A-Task 13. **Lane:** phone Swift.

**Files:** `WatchtowerMobile/NotifyContent/NotificationViewController.swift` (options with the recommended one badged, plus "Open the ask") and an outbox state `sent_by_extension` in the app-group `ReplicaStore`.

**Interfaces:**
- A tap enqueues `ask_answer` with `answers: [{id: question_id, labels: [label], other: ""}]`.
- The record is saved directly with a `CKModifyRecordsOperation` in the scope's database, and stored as `sent_by_extension`.

**Tests (`QuickAnswerTests`):**
- Quick answer, then an app relaunch → nothing is sent twice (the app never resends `sent_by_extension`).
- A record name collision on a resend is harmless (same name).
- `ASK` (not quick) shows only "Open the ask".
- The extension with no replica row fetches the ask by ID. A fetch failure shows "Open the ask" only.

**Checks:** `make mobile-test MOBILE_FILTER=QuickAnswerTests`, `make lint-diff`.

## Task 11: Go command `workbench target add`

**Depends on:** none. **Lane:** Go (parallel to any Swift lane).

**Files:**
- `internal/db/workbench_targets.go`: `CreateWorkbenchTargetsTx` (`:34`) gains an actor argument. `insertWorkbenchTarget` writes `status_actor` from it.
- `internal/tools/workbench_targets.go` (`:192`): passes `db.ActorAgent`.
- Create `cmd/workbench_target.go` and its test: `watchtower workbench target add --workbench N --title T [--intent I] [--priority P] [--parent ID] --json` prints `{"target_id":N}`.
- Docs: the `docs/features/workbench.md` CLI line.

**Tests:**
- `cmd/workbench_target_test.go`:
  - add → `status_actor` is `owner` in `target_status_history`, and the board defaults are set (level custom, custom_label project, source chat, status todo, priority medium);
  - title empty or whitespace → exit non-zero and no row;
  - title of 201 characters → refused;
  - a parent from another workbench → refused (PROJ-09);
  - priority `urgent` → refused;
  - a parent → parent progress is recomputed.
- `internal/tools` existing `create_targets` tests: still write `agent`.

**Cross-package checks:** `go test ./internal/db ./internal/tools ./cmd -run 'Workbench|Proj0[569]|CreateTargets'`, `make lint-diff`.

**Guards that must stay green, unchanged:** `TestProj05_*`, `TestProj06_*`, `TestProj09_*`.

## Task 12: WorkbenchOwnerWrites and the board write handlers

**Depends on:** Tasks 2 and 11. **Lane:** Desktop Swift.

**Files:**
- Create `WatchtowerCore/Services/WorkbenchOwnerWrites.swift`, extracted from `Sources/ViewModels/WorkbenchBoardViewModel.swift` `setStatus(_:for:)` (`:469`), `setPriority` (`:516`), `addComment` (`:587`) and `reply` (`:599`). It returns touched and rolled-up ids. The view model calls it.
- Create `MobileHub/Handlers/BoardHandlers.swift`: `board_target_status`, `board_target_priority`, `board_comment_add`, `board_comment_reply`, and `board_target_create` (runs Task 11's command through `CLIRunnerProtocol`).
- Every handler reports `onOwnerWrite` for touched and rolled-up ids (`AppState.swift:1752-1753` → `WorkbenchNotificationCenter.recordOwnerWrite` `:80`).

**Tests (`WorkbenchOwnerWritesTests`, `BoardHandlersTests`):**
- A status change → history actor `owner`, and no Mac notice for the owner's own edit (the rolled-up parents too).
- A status on a group → `invalid_params`.
- **Stale view:** `from_status` mismatch → `conflict` with `result.current`. Current equal to the requested value → `applied`, no write.
- A status outside `editableStatuses` → `invalid_params`.
- A reply to a resolved root → the root is reopened.
- Create with a parent from another workbench → `not_on_board`.
- Create with an empty title → `invalid_params`. With 201 characters → `invalid_params`.
- **Interrupted apply:** a crash between `begun` and the comment insert → `outcome_unknown` on restart, never a second comment.
- **Review focus 1:** an action for a workbench deleted meanwhile → `not_found`.

**Guards that must stay green, unchanged:** the `WorkbenchBoardViewModel` suites, PROJ-05, PROJ-06 and PROJ-09.

**Checks:** `make test-swift FILTER='WorkbenchOwnerWritesTests|BoardHandlersTests|WorkbenchBoardViewModel'`, `make lint-diff`.

## Task 13: board writes on the phone

**Depends on:** Tasks 5 and 12. **Lane:** phone Swift.

**Files:** `BoardTargetDetailView` (breadcrumb, status and priority pickers, intent, sub-targets, sessions on it, comments, composer, "Work on it in a session" button wired in Task 15), `NewBoardTargetSheet`, and `ConflictPrompt`.

**Tests (`BoardWriteWiringTests`):**
- A group's picker is disabled and shows "A group's status follows its sub-tasks".
- A conflict echo shows "Changed on the Mac to X — apply anyway?", and Yes sends a new action with `from_status` = X.
- The composer refuses whitespace only.
- New target: the title is capped at 200 in the field, and the parent picker lists only the workbench's own targets.
- Offline (stale heartbeat): the row shows "Waiting for your Mac".

**Checks:** `make mobile-test MOBILE_FILTER=BoardWriteWiringTests`, `make lint-diff`.

## Task 14: background start on the Mac

**Depends on:** none (main-only). **Lane:** Desktop Swift.

**Files:** `Sources/ViewModels/WorkbenchesViewModel+Sessions.swift`:
- add `Placement.background` (enum `:20`);
- `activate` (`:470`) with `.background` takes no `beginSwitch` ticket, never calls `focus` (`TerminalCenter.swift:218`) or `setLayout`, and never refreshes the previous title;
- add `startForTarget(targetID:prompt:mode:placement:)`, which shares `workOn`'s (`:198`) read and `createAndStart` (`:449`).

Also add `TerminalLaunch.planFirstSuffix` with the exact text above.

**Tests (`BackgroundStartTests`):**
- A background start leaves `focusOrder`, the selected workbench and the layout unchanged, and the process runs (fake process).
- `.keeping(.board)` behaves as Work on it today.
- `open_existing` with an existing session → opens it, no new row. `new` → a new row.
- `plan_first` appends exactly `planFirstSuffix`.
- A brief starting with `-` reaches the launch argv intact.
- A start during an owner's switch does not change which session the owner sees.

**Guards that must stay green, unchanged:** the `WorkbenchesViewModel` session suites (fast session switches, board #187).

**Checks:** `make test-swift FILTER='BackgroundStartTests|WorkbenchesViewModel'`, `make lint-diff`.

## Task 15: start and stop from the phone

**Depends on:** Tasks 13 and 14. **Lane:** Desktop handler first, then the phone sheet.

**Files:**
- Desktop: `MobileHub/Handlers/SessionStartStopHandlers.swift`. `session_start` echoes `received`, then `applied` with `{session_id, stage: starting}`. `session_stop` calls `TerminalCenter.close(sessionID:)` (`:652`).
- Phone: `StartSessionSheet` (workbench, target, agent Claude Code, brief prefilled from `work_on_prompt` and editable only on a typing-allowed device, "Bring the window forward on the Mac" off, "Plan first, then ask me" on), the progress states, and the session actions menu (Stop with confirmation; Finish hidden until Task 18).

**Interfaces:** progress stages:
1. "Sent to your Mac" — the save succeeded;
2. "Mac picked it up" — `received`;
3. "Starting Claude Code" — `applied` / `starting`;
4. "Open session" — the `terminal_session` record is `live` and `state_kind ≠ not_started`.

**Tests (`SessionStartHandlerTests`, `StartSheetWiringTests`):**
- An edited brief from a device without typing → ignored, and the base prompt is used.
- `start_sessions_allowed = false` → `device_not_allowed`.
- Exit 127 → `claude_not_found`.
- **Age:** a request 24 h + 1 s old → `expired`; one 23 h old is applied.
- A target not on a board → `not_on_board`.
- Stop on a stopped session → `applied`, no signal.
- The sheet stays at "Sent to your Mac" while the heartbeat is stale.
- A target with an existing session → the sheet offers "Open it" or "Start a new one".

**Checks:** `make test-swift FILTER=SessionStartHandlerTests`, `make mobile-test MOBILE_FILTER=StartSheetWiringTests`, `make lint-diff`.

## Task 16: B device check — OWNER-RUN, filed as an ask with a checklist

**Depends on:** Tasks 1–15 and A-Task 14.

**Checklist:**
- A new ask arrives on the lock screen.
- Quick answer from the long-press, and the agent continues.
- A review answered with a comment on a selected passage.
- A board status change shows on the Mac with no self-notice.
- A new board target.
- A background start: the Mac's screen does not change, and the session reaches Open session.
- Finished shows on the phone within 15 s of `finish_session`.
- Stop.
- All of the above in `private` scope and in `shared` scope.

## Task 17: SessionLineDelivery extraction

**Depends on:** Task 8. **Lane:** Desktop Swift.

**Files:**
- Create `Sources/Services/SessionLineDelivery.swift`, owned by `AppState`. It takes `OwnerAsksViewModel.deliver` (`:575`), the held/queued bookkeeping and `deliverHeldAnswers` (`:525`), with one queue per session.
- `OwnerAsksViewModel` uses it. `TerminalCenter.submitPrompt` (`:326`) is unchanged.
- Docs: add one line to the PROJ-12 changelog in `docs/inventory/workbench.md`: "deliver moved into SessionLineDelivery, guards unchanged".

**Tests (`SessionLineDeliveryTests`):**
- An ask answer and a non-ask line to one session go one after the other, never in one prompt.
- A held line goes on the next successful read, never on a timer.
- A line held for a session that started a new run → `noSession`.

**Guards that must stay green, unchanged:** every PROJ-12 guard (the same filter as Task 8).

**Checks:** `make test-swift FILTER='SessionLineDeliveryTests|OwnerAsksViewModelTests|TerminalCenterTests|CodeHandoffCenterTests'`, `make lint-diff`.

## Task 18: session input from the phone (PROJ-16)

**Depends on:** Tasks 7, 15 and 17, A-Task 9 (Allow and Revoke). **Lane:** Desktop handler, inventory and Mac notification first; then the phone.

**Files:**
- Desktop: `MobileHub/Handlers/SessionInputHandlers.swift` (`session_input`, `session_input_cancel`, `session_finish_request` with the exact finish line), the Mac notification "Allow "<name>" to type into Claude Code sessions?" when a `device` record sets `typing_requested`, and held lines re-queued at hub start.
- Phone: the "Tell the session…" bar, the Finish menu item, the toggle status ("Waiting for your Mac to confirm" / "Allowed").
- `docs/inventory/workbench.md`: add **PROJ-16** with the spec §11 wording (heading, Observable with condition (0), Why locked, Test guards, Locked since), plus a changelog entry. This goes in the **same commit** as the code and guards (inventory protocol).
- `docs/features/workbench.md` and `docs/features/mobile-companion.md`: a PROJ-16 note.

**Interfaces:**
- **Idle:** `state_kind ∈ {stopped, finished, waiting_on_ask, failed}` for the current run, or a marked run with no turn yet.
- **Held reasons:** `agent_busy`, `needs_approval`, `prompt_has_text`, `state_unknown`.
- **Text:** trimmed, control characters and newlines turned into spaces, ≤ 4000, `keepingLineBreaks: false`.
- **Outcomes:**
  - `submitted` → `applied`;
  - `typed` → `applied` with `delivery: typed`, and the phone shows "Typed into the session — press Return on the Mac";
  - `copied` → `cannot_type`;
  - `noSession` → `session_not_running`.

**Guard tests (exact names, in `WatchtowerDesktop/Tests/MobileHub/SessionInputHandlersTests.swift`):**
- `testProj16_AnUnallowedDeviceTypesNothing`
- `testProj16_AWorkingSessionHoldsTheLineUntilItStops`
- `testProj16_NeedsApprovalNeverGetsAPhoneLine`
- `testProj16_ADraftHoldsTheLineAndNothingIsPasted`
- `testProj16_AHeldLineExpiresAfter24h`
- `testProj16_AnEditedBriefFromAnUnallowedDeviceIsIgnored`
- `testProj16_RevokeFailsHeldLines`
- `testProj16_AnUnlinkedDeviceTypesNothing` (condition 0)

**Other tests:**
- Empty or whitespace text → `invalid_params`.
- Text with `\n`, `\r` and ESC → one line.
- 4001 characters → `invalid_params`.
- Cancel after delivery → a no-op, and the original stays `applied`.
- Cancel while held → the original is `cancelled`.
- A held line survives a hub restart and goes on idle.
- **Review focus 2:** the session row is deleted while a line is held → `session_not_running`.
- Phone `SessionInputWiringTests`: the toggle off hides the bar and Finish; a held echo shows its reason; `needs_approval` shows "Needs approval on the Mac" and no send button.

**Guards that must stay green, unchanged:** every PROJ-12 guard.

**Checks:** `make test-swift FILTER='SessionInputHandlersTests|SessionLineDeliveryTests|OwnerAsksViewModelTests|TerminalCenterTests'`, `make mobile-test MOBILE_FILTER=SessionInputWiringTests`, `make lint-diff`.

## Task 19: session input device check — OWNER-RUN, filed as an ask with a checklist

**Depends on:** Task 18.

**Checklist:**
- Turn typing on on the phone, and Allow on the Mac.
- A line to a Stopped session is submitted.
- A line to a Working session is held, then goes when it stops.
- A session at a permission prompt gets nothing, and the phone shows Needs approval on the Mac.
- Half-typed text on the Mac holds the line.
- Revoke on the Mac fails a held line.
- Finish: the agent calls `finish_session`.
