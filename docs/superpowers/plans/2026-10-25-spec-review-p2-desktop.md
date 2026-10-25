# Spec review — Plan 2 of 3: the Desktop screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A review ask whose spec review exists opens a Meaning → Chapters → Wrap-up screen built from the reviewer's findings. The owner marks findings and sends a round or approves through the existing answer JSON, and **Read the spec** always opens the classic view.

**Architecture:** WatchtowerCore gets the `SpecReview` model (decoding Plan 1's `result` JSON), `SpecReviewQueries` (read `spec_reviews`, read/write `spec_review_marks`) and a pure `SpecReviewAnswer` builder (marks → `OwnerAskAnswer`). A `SpecReviewModel` (@MainActor @Observable) drives one ask's screen. It polls the row while it is queued or running, and it calls `watchtower workbench spec-review start` for **Run reviewer** and **Re-run reviewer**. `OwnerAskDrawer.reviewLayout` switches to `SpecReviewView` when a row exists and the owner has not chosen **Read the spec**. Deep review's phase strip is made model-agnostic and reused.

**Tech Stack:** SwiftUI (macOS 14+), GRDB (SQLCipher fork), WatchtowerCore / WatchtowerDesktop, DesignKit.

**Spec:** `docs/superpowers/specs/2026-10-25-spec-review-design.md` (sections 7–8). Mockup: `docs/design/mockups/spec-review/flow.html`. **Depends on:** Plan 1 (`docs/superpowers/plans/2026-10-25-spec-review-p1-core.md`): table shapes in its Task 1, the `Result` JSON golden in its Task 2 (`internal/specreview/testdata/result_keys.golden`), and the CLI in its Task 4.

## Global Constraints

- Read `docs/review/review-rules.md` "Swift / Desktop conventions" and `docs/design/desktop-style-guide.md` before any view. Build from DesignKit components (`make design-gallery`), and look at the screen with `make desktop-shots DESKTOP_SHOTS=<dir>` before review.
- The answer JSON contract (`internal/asks/answer.go`) is unchanged. Every comment carries `heading` + `quote` anchors that exist in the snapshot, or the chapter heading alone for an unanchored finding.
- Items marked **Fine as is** are not sent. The author sees only what the owner commented on.
- A failed, skipped or still-running reviewer never blocks reviewing: **Read the spec** and the classic view stay one click away.
- Copy is English (the app UI language); keep the labels exactly: **Read the spec**, **Run reviewer**, **Re-run reviewer**, **Fine as is**, **Comment**, **Viewed**, **Send round to the author**, **Approve**, section titles **As agreed**, **Differs**, **Missing**, **Decided alone**, **Blind spots**, **From the previous run**.
- Inner loop: `make test-swift FILTER=…` and `make lint-swift` per task (lint-diff is Go-only). The full gate runs at the end.

## Review Focus

- **The reviewer finishes while the owner is mid-way through the classic view.** The screen must not jump. A banner offers **Open the reviewer's findings**. Test in Task 3.
- **Re-run after marks exist.** Marks with a surviving key carry over, and the others show under **From the previous run** with their comment text. Test in Task 2.
- **A finding's anchor heading no longer matches a chapter** (the doc changed in a re-round). It goes to an **Other** chapter and is never dropped silently. Test in Task 2.
- **Approve with unmarked items** asks once ("N findings are not marked. Approve anyway?"); Send with zero comments is disabled. Test in Task 3.
- **The result JSON has a key the app does not know, or misses an optional one.** Decoding tolerates both. A wrong `status` enum value decodes as unknown and is shown neutrally. Test in Task 1.

---

### Task 1: Core — model, queries, answer builder

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SpecReview.swift`, `WatchtowerCore/Database/Queries/SpecReviewQueries.swift`, `WatchtowerCore/Services/SpecReviewAnswer.swift`
- Test: `WatchtowerDesktop/Tests/Core/SpecReviewTests.swift`, with the fixture `Tests/Core/Fixtures/spec_review_result.json` copied from Plan 1's golden

**Interfaces:**
- Produces:
  - `struct SpecReviewRow: FetchableRecord, Decodable { askID: Int64; status: Status; reason, provider, model: String; dropped, attempt: Int; result: SpecReviewResult? }` with `enum Status: String { queued, running, done, failed, skipped, unknown }`
  - `struct SpecReviewResult: Decodable, Equatable`. It mirrors Plan 1's `Result` (snake_case via `CodingKeys`) with nested `Agreement`, `DecidedAlone`, `BlindSpot`, `Check`, `Resolved`, `Idea` and `Chapter`. Each finding exposes `key`, `chapter`, `text`, `anchor: (heading, quote)?`.
  - `enum SpecReviewMarkState: String { ok, comment, viewed }`, `struct SpecReviewMark { key: String; state: SpecReviewMarkState; body: String }`
  - `enum SpecReviewQueries { static func row(_ db: Database, askID: Int64) throws -> SpecReviewRow?; static func marks(_ db: Database, askID: Int64) throws -> [String: SpecReviewMark]; static func setMark(_ db: Database, askID: Int64, mark: SpecReviewMark, now: Date) throws; static func clearMark(_ db: Database, askID: Int64, key: String) throws }`. `viewed` marks use the key `ch:<n>` of a chapter.
  - `enum SpecReviewAnswer { static func build(result: SpecReviewResult, marks: [String: SpecReviewMark], note: String, verdict: OwnerAskAnswer.Verdict, snapshot: String) -> OwnerAskAnswer; static func orphanMarks(result: SpecReviewResult, marks: [String: SpecReviewMark]) -> [SpecReviewMark] }`. A comment body is `"<finding text> — <owner body>"`. The anchor is the finding's `where`, or for an unanchored finding the chapter heading with the chapter's first non-blank line as the quote. Orphan comment marks (key not in the result) are sent too, anchored to the doc's first heading, and their body is prefixed "From the previous run:".
- [ ] **Step 1: Write the failing tests**:
  - `testDecodesPlan1Golden`;
  - `testDecodingToleratesUnknownKeysAndEnums`;
  - `testAnswerSendsOnlyCommentMarks` (one ok, one comment, one unmarked gives 1 comment);
  - `testAnswerAnchorsUnanchoredToChapter`;
  - `testOrphanMarksListed`;
  - `testMarksRoundTrip` (the GRDB test DB from `TestDatabase+Schema.swift`).
- [ ] **Step 2: Run** `make test-swift FILTER=SpecReviewTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same command and `make lint-swift`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(desktop-core): spec review model, queries and answer builder`

### Task 2: `SpecReviewModel` and CLI calls

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/SpecReviewModel.swift`
- Modify: `WatchtowerDesktop/Sources/Services/WorkbenchCLI.swift` (add `specReviewStart(askID:force:)`)
- Test: `WatchtowerDesktop/Tests/SpecReviewModelTests.swift`

**Interfaces:**
- Consumes: Task 1; `WorkbenchCLI`; `OwnerAsksViewModel.answer(_:with:)` (`ViewModels/OwnerAsksViewModel.swift:677`).
- Produces:
  - `@MainActor @Observable final class SpecReviewModel { init(ask: OwnerAsk, db: DatabaseManager, cli: WorkbenchCLI, asks: OwnerAsksViewModel); var row: SpecReviewRow?; var marks: [String: SpecReviewMark]; var phase: ReviewPhase; var chapterKey: String?; var lastError: String?; func load() async; func startPolling(); func stopPolling(); func runReviewer(force: Bool) async; func mark(_ key: String, _ state: SpecReviewMarkState, body: String) async; func unmark(_ key: String) async; func send(note: String) async -> AnswerResult; func approve(note: String) async -> AnswerResult; var chapters: [SpecReviewChapterVM]; var unmarkedCount: Int; var orphans: [SpecReviewMark] }`
  - `struct SpecReviewChapterVM { key, heading: String; excerpt: Substring; findings: [SpecReviewFinding]; checks: [SpecReviewResult.Check]; viewed: Bool }` and `enum SpecReviewFinding { agreement(…), decidedAlone(…), blindSpot(…) }`. Findings whose chapter is unknown go to a trailing chapter `other` titled **Other**.
  - Polling: every 3 s while `queued|running`, stopped on `done|failed|skipped` and on `stopPolling()`. It is a `Task` held by the model and cancelled in `stopPolling`/deinit, per the review-rules lifecycle rule.
  - `WorkbenchCLI.specReviewStart(askID: Int64, force: Bool) async throws` runs `workbench spec-review start --ask N [--force]`. Exit 3 maps to "The reviewer is already running".
- [ ] **Step 1: Write the failing tests**:
  - `testChaptersGroupFindingsAndOther`;
  - `testPollingStopsWhenDone` (an injected clock or a fake DB);
  - `testRerunCarriesMarksAndListsOrphans`;
  - `testApproveWithUnmarkedNeedsConfirmFlag` (the model exposes `needsApproveConfirm`);
  - `testSendDisabledWithoutComments`.
- [ ] **Step 2: Run** `make test-swift FILTER=SpecReviewModelTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same command and `make lint-swift`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(desktop): SpecReviewModel — chapters, marks, polling, send/approve`

### Task 3: The screen and the drawer switch

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/Review/ReviewPhaseStrip.swift`. Extract `ReviewPhasePicker(phase: Binding<ReviewPhase>, progress: String)`, used by the existing strip, so Deep review behaves exactly as before.
- Create: `WatchtowerDesktop/Sources/Views/Workbench/Asks/SpecReview/SpecReviewView.swift` (header + phase picker + phase switch), `SpecReviewMeaningView.swift`, `SpecReviewChaptersView.swift` (chapter list on the left, reused from the style of `ReviewChapterListView`; detail with a collapsed excerpt, finding cards, the checks list, **Viewed**), `SpecReviewFindingCard.swift`, `SpecReviewWrapUpView.swift`, `SpecReviewStatusView.swift` (queued/running/failed/skipped states)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/Asks/OwnerAskDrawer.swift:226` (`reviewLayout`): when `SpecReviewQueries.row` exists and `showClassic == false`, show `SpecReviewView`; otherwise show today's layout plus, when a review finished meanwhile, the banner **Open the reviewer's findings**
- Test: `WatchtowerDesktop/Tests/SpecReviewViewTests.swift` (presentation helpers), plus the existing Deep review tests still passing

**Interfaces:**
- Consumes: Task 2.
- Produces: `struct SpecReviewView: View { let model: SpecReviewModel; let onReadSpec: () -> Void }`. The pure helpers for strings and badges live in `enum SpecReviewPresentation` (tested): `countsLine(_:)` ("9 as agreed · 1 differs · 1 missing · 4 decided alone · 2 blind spots"), `statusLine(_:)` ("Reviewer is reading the spec and the discussion…", "Reviewer failed: <reason>", "Reviewer skipped: <reason>"), `badge(for:)`.
- Layout per the mockup:
  - Meaning: an idea card (owner quote | goal quote | verdict), counts, summary, notes (trimmed inputs, dropped findings, `code_read: false`) and, on a re-round, the Resolved list.
  - Chapters: an HSplit list with per-chapter badges and ✓, then the detail.
  - Wrap-up: grouped lists with marks; **From the previous run** when orphans exist; the note editor (the existing `CommentTextEditor`); **Send round to the author** and **Approve** (the confirmation sheet when `needsApproveConfirm`).
  - Header: title, `statusLine`, **Read the spec**, **Re-run reviewer**.
- [ ] **Step 1: Write the failing tests**: `testCountsLine`, `testStatusLines`, and `testPhasePickerKeepsDeepReviewBehaviour` (the existing `ReviewChangesModel` phase tests are untouched and green).
- [ ] **Step 2: Run** `make test-swift FILTER='SpecReviewViewTests|ReviewChangesModel'`. Expected: FAIL (new) / PASS (existing).
- [ ] **Step 3: Implement**, then run `make desktop-shots DESKTOP_SHOTS=<dir>` with a seeded ask and a fixture result, and compare with the mockup.
- [ ] **Step 4: Run** the same tests and `make lint-swift`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(desktop): spec review screen in the review ask drawer`
- [ ] **Phase gate (controller):** `make test-swift`, `make lint-all`.
