---
type: chore
title: "Low-priority findings bundle — test coverage (Swift Desktop)"
status: open
priority: low
tags: [swift-test-coverage, review-2026-09-26, bundle]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Swift Desktop)
created: 2026-09-26
---

8 low-priority findings from the test coverage (Swift Desktop) track, bundled so the backlog
stays readable. Split any item into its own file when it gets picked up.

## UserStatsViewModel bot-override / mute-for-LLM writes untested (they change AI input)

- type: chore · confidence: high · tags: [test-coverage, statistics]
- where: WatchtowerDesktop/Sources/ViewModels/UserStatsViewModel.swift:144-175, Sources/WatchtowerCore/Database/Queries/UserStatsQueries.swift:44-64

`toggleBotOverride` collapses an override that equals Slack's own `is_bot` back to NULL (a three-state value: override-true, override-false, cleared). `toggleMuteForLLM` flips `users.is_muted_for_llm`. Both flags decide which people reach the AI pipelines, yet neither the view model nor `setBotOverride`/`setMutedForLLM` appears in any test. A regression that writes 0 instead of NULL would silently pin a user as human forever. Add Core tests for the three-state transition and the mute round trip.

## MeetingNoteQueries has no tests; note→target conversion logic lives in a View

- type: chore · confidence: high · tags: [test-coverage, grdb-write, calendar]
- where: WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/MeetingNoteQueries.swift (all 7 methods), Sources/Views/Calendar/MeetingNotesView.swift:429-480

`create`/`update`/`toggleChecked`/`setTaskID`/`delete`/`countForEvent` have zero test references. `MeetingNotesView.createTask` runs a two-statement transaction inline in the view: it creates a day-level target with `source_id = "meeting_note:<id>"`, then back-links `task_id`. This breaks the "no raw DB logic in Views" architecture rule and cannot be unit-tested where it sits. Move the conversion into `MeetingNoteQueries` (or a view model) and pin: the transaction atomicity, the `source_id` shape, and `toggleChecked` flipping twice.

## TrackChatViewModel persistence is untested and swallows every DB write error

- type: chore · confidence: med · tags: [test-coverage, chat, memory]
- where: WatchtowerDesktop/Sources/Views/Tracks/TrackChatView.swift:9-300 (class TrackChatViewModel), writes at 223, 234, 277, 295

The track Discuss chat view model is declared inside a View file. Its tests (`TrackChatMemoryPromptTests`, `TrackChatSkillsPromptTests`) cover only prompt text. Message inserts, `touch`, and `updateSessionID` all run as `_ = try? dbPool.write`, so a failed insert loses the owner's turn without any signal (review-rules §9 swallowed error). This matters beyond the UI: with `memory.sources.chats` on, `role='user'` rows in track chats are the only source of owner-rank evidence (MEM-09), so a silently dropped row is lost belief evidence. Move the class into `ViewModels/`, surface write errors, and add a send/persist/stop test like the Target/Meeting chat suites.

## Small CLI wrappers with zero tests: argv never pinned against cobra flags

- type: chore · confidence: high · tags: [test-coverage, cli]
- where: WatchtowerDesktop/Sources/WatchtowerCore/Services/TrackComposeService.swift, TargetNextStepService.swift, JiraBoardSyncManager.swift:61-65, Sources/Services/GoogleAuthService.swift:52-60, Sources/WatchtowerCore/Utilities/MemoryVaultGit.swift

These services hardcode argv (`tracks create --text --target`, `targets next-step <id>`, `jira --account N sync --board B --progress-json`, `google login --account N --app-return` / `calendar login --app-return`, `git log` in the vault) and decode CLI JSON (`TrackDraft`, `TargetNextStep`), yet none has a test. The flags do exist in `cmd/` today (verified), but review-rules require a check for every hardcoded flag ("cobra rejects unknown flags before RunE runs"), and nothing would catch a rename. The two `CLIRunnerProtocol`-based services need only a FakeCLIRunner test each. The Process-based ones should move onto `CLIRunnerProtocol` first.

## Timing-based waits in chat VM tests: fixed sleeps and spin loops that fall through silently

- type: chore · confidence: med · tags: [test-coverage, flaky]
- where: WatchtowerDesktop/Tests/ViewModelTests.swift:542-546,563,608,624,636,693-790,970,1000,1255,1422-1564; Tests/TargetChatViewModelTests.swift:1221-1278; Tests/ChatViewModelOutcomesTests.swift:47,56; Tests/Core/AgentActionFeedTests.swift:119,172

About 15 assertions follow a fixed `Task.sleep(300ms/500ms)` with no condition. About 10 use `for _ in 0..<50 where vm.isStreaming { sleep 20ms }`, a 1 s budget that exits silently when the condition never flips, so the next assertion fails with a misleading message under CI load. This is the same spin-counter shape PR #108 replaced with deadlines elsewhere. There are also eight private copies of `waitUntil`/`waitFor` (DictationSession, ViewModel, DigestFeed, DictationButton, IdeaChat, CalendarSetupChat, CatchUp, TargetChat). Suggest one shared deadline-based `waitUntil(timeout:)` in `Tests/Support` that calls `XCTFail` on timeout, and replace the fixed sleeps with it. The negative "must NOT appear after 100 ms/250 ms" checks in `AgentActionFeedTests` are inherently timing-bound and should say so in a comment.

## Tests that cannot fail: SearchViewModel debounce trio, PromoteSubItemSheet body-touches, recorder "navigation" stand-in

- type: chore · confidence: high · tags: [test-coverage, pointless-test]
- where: WatchtowerDesktop/Tests/ViewModelTests.swift:964-1003; Tests/PromoteSubItemSheetTests.swift:56-110; Tests/MeetingRecorderCenterTests.swift:128-162

- `testSearchSetsIsSearching` never sees `isSearching == true`. It only asserts `false` 500 ms later, which is also the initial state.
- `testSearchCancelsOnNewQuery` asserts `results.isEmpty` before any debounce could fill it.
- `testSearchCancelsPreviousTask` never checks that the surviving query was "beta".

All three pass against a no-op `search()`. The four `PromoteSubItemSheetTests` do only `_ = sheet.body`, even though the comments claim the due-date control is "pre-toggled", which is never asserted. `MeetingRecorderCenterTests` models "navigate away" by allocating and dropping an unrelated `ObservingView` object while the test keeps its own strong reference to the center, so it proves nothing about AppState ownership. Rewrite each test to assert the claimed behavior, or delete it.

## SyncProgress dual path is pinned only against Swift-formatted timestamps

- type: chore · confidence: med · tags: [test-coverage, dual-path, tray]
- where: WatchtowerDesktop/Sources/WatchtowerCore/Models/SyncProgress.swift:29-54, Tests/TrayMenuViewTests.swift:94-110; Go internal/sync/heartbeat.go:21-59

CLAUDE.md declares `sync_progress.json` a Go↔Swift dual path (field names, the 2-minute `StaleAfter`, and "active but stale is not syncing"). The only Swift test builds its JSON with Swift's own `ISO8601DateFormatter` (millisecond precision, `Z`). Go's `time.Time` marshals RFC3339Nano with up to 9 fractional digits and the local offset, and `IdleProgress()` writes the zero `started_at` `0001-01-01T00:00:00Z`. No Go-emitted fixture is decoded on the Swift side, and nothing pins that `staleAfter = 120` still equals Go's `2 * time.Minute`. Add a shared fixture (Go test writes or asserts it; the Swift test decodes it) covering nanosecond precision, a +03:00 offset, and the idle zero-time case.

## Dead Swift DB code with no callers or readers

- type: chore · confidence: high · tags: [test-coverage, dead-code]
- where: WatchtowerDesktop/Sources/WatchtowerCore/Database/DatabaseObserver.swift (whole file), Sources/WatchtowerCore/Database/Queries/DigestQueries.swift:84-118, Sources/ViewModels/DigestViewModel.swift:329-334, Sources/WatchtowerCore/Database/Queries/TrackQueries.swift:114

`DatabaseObserver` (103 LOC, five Combine publishers) is referenced nowhere in Sources or Tests. `DigestQueries.markDecisionRead` has no caller. `markAllDecisionsRead` still inserts into `decision_reads` on every digest/track mark-read, although the code comment itself says the table "has no remaining reader" since the Decisions ledger moved to `ideas.seen_at`. That is untested write traffic, plus a JSON decode per mark-read, all for nothing. Delete them, or document a reader.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
