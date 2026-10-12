# Mobile design pass, Phases 3–5 (Asks; Calendar, Recording and Recap; Settings and Onboarding) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish making the iPhone app look like the Mac app on a phone: the ask forms, the Calendar with its event detail, the recorder, the recap and the Recordings list, Settings and onboarding. The plan also folds in the minor findings deferred from the Phases 1–2 review. No new features and no data change.

**Architecture:** The design layer (`Sources/DesignSystem/`) and the Now and Workbench screens are done (Phases 1–2, PR #192). This plan moves the remaining screens onto that layer: `card(_:)`, `Pill`, `CountBadge`, `FlatRow`, `MetaLine`, `StepRow`, `FlowRow`, `BottomActionBar`, `ProminentActionStyle`, `RecordButton`, `TypeScale`, `Spacing`, `Radius` and `RowInsets`. Every new colour comes from a screen model as a `PhoneTone` with a `ToneRole`, so `OrangeToneTests` sweeps it. Each new piece of logic is a small pure value with a unit test: `AskKindStyle`, `AskFormModel.ClosedLine`/`CheckChoice`, `EventAction`, the attendee tone, `WaveformStyle`, `LastSyncText`, `AccountStatusStyle`, `LinkStepsModel`, `LinkFailure.title`/`hint`. The plan ends by deleting the design-layer API that still has no caller.

**Tech Stack:** SwiftUI and UIKit (iOS 17+, Swift 5.10 language mode), the xcodegen project `WatchtowerMobile/project.yml` with its generated `.xcodeproj` committed, XCTest in `WatchtowerMobileTests`, SwiftLint `--strict`.

**Spec:** `docs/superpowers/specs/2026-10-11-mobile-design-pass-design.md` (approved; its §9 defaults stand). Read it beside this plan. Section references below (§2.7, A5, C4, O2, …) point into it. The Phases 1–2 plan (`docs/superpowers/plans/2026-10-11-mobile-design-pass-phase-1-2.md`) is the model for conventions. Paths are relative to `WatchtowerMobile/Sources/` unless they start with another top-level directory.

## Global Constraints

- **Scope.** Phases 3, 4 and 5 of the spec: Asks A1–A7, Calendar/Recording/Recap C1–C7, Settings SET2–SET4 and Onboarding O1–O5, the §7 doc lines they change, and the minor findings deferred from the Phases 1–2 review (board targets #99–#106). Bugs 1–11 and the Phase 2 items (N, W, S, B, T, D) are done and must stay done. Do not redo them: A3 (bug 6), A4's document styling (bug 7), C2 (bug 2), C4's opaque bar (bug 8), C7's chrome and Saved steps (bug 9), SET1 (bug 10), O4 (bug 11) and SET4's doc comment are already in the code.
- **Binding decisions (ask #32).** Direction A, "Mac one-to-one": dense flat rows, and cards only for "Waiting for you" and for detail blocks. **No card inside a card.** Medium priority has no dot; only high (red) and low (blue) get one. Orange is only for waiting-for-you and ask elements. Settings is reached from Now's gear, and the voice note is the Calendar's mic button.
- **§9 defaults.** (1) A session draws only the dot. (2) The calendar scrolls the highlighted meeting to the middle once per day; with none it stays at the top. (3) The list screens, Recordings included, use `Color(.systemBackground)` with flat rows; forms stay `insetGrouped`. (4) "N closed" is the last meta item of a session row. (5) The tab badge colour fix stays.
- **Record stays 44 pt.** Every `RecordButton` keeps its default `.large` control size. C3 asks for `size: .regular`, but the Phases 1–2 final review raised Now's Record to `.large` for a 44 pt hit target, and the agenda follows that decision.
- **Visual language.** Use semantic SwiftUI colours, Dynamic Type and SF Symbols. The accent stays system blue: no AccentColor asset and no new SF Symbol assets. The app-icon image of O1 is an image asset, not a symbol. Monospaced fonts are only for counts, times, keys and code. Labels are never uppercase or monospaced ("Question", "Recommended", "Decisions"). `largeTitle` is only for onboarding and empty states. Emphasis is semibold. Meta lines use `.caption`; `.caption2` is only for badges and pills.
- **No new features, and no wire, Kit, replica or Mac change.** Every screen keeps its strings, routes and contracts unless a spec item says otherwise. The project gets no snapshot library and no pixel-diff assertions.
- **Orange rule.** Only `Sources/DesignSystem/PhoneTone.swift` may name `.orange` or `systemOrange` under `Sources/Features/` and `Sources/DesignSystem/`; SwiftLint `orange_outside_phone_tone` enforces this. `OrangeToneTests` stays green and its assertions are never weakened. Each new `ToneUse` goes into its model's `toneUses`.
- **Project file.** After adding, moving or deleting any file under `Sources/` or `Tests/`, run `make mobile-gen` and commit `WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj` with the change. Never hand-edit the `.xcodeproj`.
- **Per-task checks** (CLAUDE.md "Agent-driven runs"): run `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=<Class>` for the touched suites (`MOBILE_FILTER='A|B'` runs several), plus `make lint-swift`. This machine's simulator is `iPhone 17 Pro`; the Makefile default `iPhone 18 Pro` is not installed, so always pass `SIM`. The full `make mobile-test SIM="iPhone 17 Pro"` and `make lint-all` run once per phase, at the phase gate, never per task. Desktop and Kit sources do not change, so `make test-swift` belongs only to the pre-PR gate.
- **How to run.** Run every build and test in the foreground, to a log with an explicit exit code: `mkdir -p build/mobile-logs; <cmd> > build/mobile-logs/<task>.log 2>&1; echo "exit=$?"`, then read the log's tail. No `run_in_background`, and no turns spent polling with `sleep` or `tail`. `build/` is gitignored.
- **Lint traps** (`WatchtowerMobile/.swiftlint.yml`; `--strict` turns warnings into errors): `implicit_return` (a single-expression body has no `return`), `force_unwrapping`, `function_body_length` 80, `closure_body_length` 80, `cyclomatic_complexity` 15, `line_length` 150, and `large_tuple`, which warns at 4 members, so tuples stay at 3 or fewer.
- **House rules.** Before hand-back, self-review against the "Swift / Desktop conventions" section of `docs/review/review-rules.md` and §§ 3, 5, 7, 8 of the same file. Views paint only model tones. Pure logic sits in models or small value types with unit tests. Add no new `@Observable` view model.
- **Public repo.** Use only the demo seed's neutral names (Acme, "Acme Mac", "Acme Studio", "Colleague A"–"Colleague E", `example.com`): no real names, ids, emails or local absolute paths. Docs are in English.
- **Commits.** One commit per task, at the end, after its checks pass. End every message with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

The spec implies these five inputs, but no test it lists exercises them. They are the ones most likely to bite a person using the app. Each line has a test in the task that owns the code.

1. **A stored answer with nothing picked** for a question (no labels and an empty Other). The closed ask shows the question with "No answer" under it, never an empty second line. Covered by `testAClosedAnswerIsLabelAndValuePairs`, Task 3.
2. **A Dynamic Type change while a review is open.** The text is the same, so the old guard skipped the restyle. The document must restyle at the new size, and the anchors' text must stay `document.text`. Covered by `testADynamicTypeChangeRestylesTheSameText`, Task 5.
3. **An event that ends exactly now, or is still running, and already has a recap** (a re-run or recurring meeting). Only a finished event (`end <= now`) swaps Join and Record for Open recap. A running one keeps Record. Covered by `testAPastEventWithARecapOffersOnlyOpenRecap`, Task 7.
4. **A transcribing job whose percent is out of range** (a newer Mac, or a glitch: 140, −5). The row's bar and text clamp to 0…100. Covered by `testTheTranscribingRowClampsThePercent`, Task 8.
5. **A waiting phase with an empty Mac name, or a start time in the future** (the phone's clock jumped). Step 2 reads "Waiting for your Mac to confirm", and no hint appears before 20 real seconds. Covered by `testTheLinkStepsFollowThePhaseAndHintAfterTwentySeconds`, Task 12.

---

## File map

New files:

| File | Responsibility | Task |
|---|---|---|
| `Sources/Features/Asks/AskKindStyle.swift` | An ask kind's word and the Mac's icon, shared by ask rows and the form header | 2 |
| `Sources/Features/Settings/AccountStatusStyle.swift` | SET3: "ok", "error" or raw text, with tone and mark | 10 |
| `Sources/Assets.xcassets/AppIconImage.imageset/Contents.json` + `AppIconImage.png` | O1: the app icon as a drawable image | 11 |
| `WatchtowerMobile/Tests/WelcomeTests.swift` | O1: the image loads; the three feature lines | 11 |
| `Sources/Features/Onboarding/LinkSteps.swift` | O2: `LinkStepsModel` (steps and the 20 s hint) and `LinkStepsView` | 12 |

Modified files are listed in each task.

---

## Before Task 1: the comparison baseline

- [ ] **Check the Phase 2 after-set.** Run `ls build/mobile-shots/after-phase-2 | wc -l` from the worktree root. Expect `83` (82 PNGs plus `INDEX.md`). If the folder is missing or short, render it now, before any task changes the tour: `make mobile-shots SIM="iPhone 17 Pro" SHOTS_DIR=build/mobile-shots/after-phase-2 > build/mobile-logs/baseline-shots.log 2>&1; echo "exit=$?"` and expect `exit=0`.

---

## Phase 3: Asks

### Task 1: The Phases 1–2 review follow-ups on Workbench and the tour

**Depends on:** none.

These are the deferred minors that belong to screens no later task touches: "▸ N closed" shows two disclosure marks; a board row with a bar and no details draws an empty line above the bar; VoiceOver reads the target detail's progress twice; the Workbench list's counts line squeezes at large Dynamic Type; and the tour's end shot misses a scroll view whose insets make it scrollable.

**Files:**
- Modify: `Sources/Features/Workbench/WorkbenchModels.swift:226` (`closedLabel` without "▸")
- Modify: `Sources/Features/Workbench/BoardModel.swift:118-119` (new `hasMetaLine`)
- Modify: `Sources/Features/Workbench/BoardView.swift:119-131` (the meta line only when `hasMetaLine`)
- Modify: `Sources/Features/Workbench/BoardTargetDetailView.swift:237-244` (the progress bar hidden from VoiceOver)
- Modify: `Sources/Features/Workbench/WorkbenchListView.swift:97-110` (the counts line becomes a `FlowRow`)
- Modify: `WatchtowerMobile/Tests/Support/ScreenshotHost.swift:64-76` (`tallScrollView` counts the insets)
- Modify: `WatchtowerMobile/Tests/WorkbenchWiringTests.swift:82`, `WatchtowerMobile/Tests/SessionRowTests.swift:7`, `WatchtowerMobile/Tests/BoardFilterTests.swift`, `WatchtowerMobile/Tests/ScreenshotTourTests.swift`
- Modify: `docs/features/mobile-companion.md` (the "Views." line of the asks section: "▸ N closed")

**Interfaces:**
- Consumes: `FlowRow(spacing:)`, `ThinProgressBar`, `SessionDot`, `TypeScale`, `Spacing` (Phases 1–2).
- Produces:
  - `WorkbenchMenuModel.closedLabel: String?` is now "3 closed".
  - `BoardRowModel.hasMetaLine: Bool` (`priorityTone != nil || !details.isEmpty`).
  - `ScreenshotHost.tallScrollView(in:)` finds a scroll view whose content plus adjusted top and bottom insets is taller than its bounds.

- [ ] **Step 1: Write the failing tests**

In `WorkbenchWiringTests.swift`, replace line 82 with:

```swift
        XCTAssertEqual(menu.closedLabel, "3 closed", "the DisclosureGroup draws the only disclosure mark")
```

In `SessionRowTests.swift`, change the doc comment at line 7 to end with `the open-ask pill and "N closed".`

In `BoardFilterTests.swift`, after `testARowWithNothingToSayHasNoMetaLine`, add:

```swift
    /// Phases 1–2 review: a row whose meta is only its bar draws no empty
    /// dot-and-details line above the bar.
    func testARowWithOnlyProgressDrawsNoEmptyLineAboveItsBar() throws {
        let barOnly = try mirror(WorkbenchTarget.self, DemoSeed.JSON.target(1, workbench: 1, ["progress": 0.5, "children_count": 2]))
        let row = BoardRowModel(barOnly, snapshot: WorkbenchReplicaSnapshot())
        XCTAssertTrue(row.hasMeta, "the bar is meta")
        XCTAssertFalse(row.hasMetaLine, "medium, no details: no line above the bar")
        let high = try mirror(WorkbenchTarget.self, DemoSeed.JSON.target(2, workbench: 1, [
            "priority": "high", "progress": 0.5, "children_count": 2
        ]))
        XCTAssertTrue(BoardRowModel(high, snapshot: WorkbenchReplicaSnapshot()).hasMetaLine, "the dot needs the line")
    }
```

In `ScreenshotTourTests.swift`, after `testTheEndVariantFindsOnlyAScrollViewTallerThanItsBounds`, add:

```swift
    /// Phases 1–2 review: a list under a navigation bar and a tab bar
    /// scrolls when its content plus its insets is taller than its bounds,
    /// even when the content alone fits.
    func testAnEndShotCountsTheScrollViewsInsets() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let inset = UIScrollView(frame: root.bounds)
        inset.contentSize = CGSize(width: 100, height: 80)
        inset.contentInset = UIEdgeInsets(top: 30, left: 0, bottom: 0, right: 0)
        root.addSubview(inset)
        XCTAssertTrue(ScreenshotHost.tallScrollView(in: root) === inset, "80 + 30 is taller than 100")
        XCTAssertEqual(ScreenshotHost.endOffset(of: inset), -20, "10 pt past the resting offset of -30")
    }
```

The view is not in a window, so it has no safe area and `adjustedContentInset` equals `contentInset`.

- [ ] **Step 2: Run, expect failures**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='WorkbenchWiringTests|BoardFilterTests|ScreenshotTourTests' > build/mobile-logs/t1.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild), with `value of type 'BoardRowModel' has no member 'hasMetaLine'` in the log.

- [ ] **Step 3: The models**

In `WorkbenchModels.swift`, change line 226 to:

```swift
        closedLabel = closedAsks.isEmpty ? nil : "\(closedAsks.count) closed"
```

If the property's doc comment shows "▸", drop the mark there too.

In `BoardModel.swift`, after `var hasMeta` (line 119), add:

```swift
    /// The dot-and-details line. A row whose meta is only its bar has none,
    /// so no empty line sits above the bar (Phases 1–2 review).
    var hasMetaLine: Bool { priorityTone != nil || !details.isEmpty }
```

- [ ] **Step 4: The views**

In `BoardView.swift`, replace the body of `if row.hasMeta { … }` in `BoardRowView` (lines 120-130) with:

```swift
            if row.hasMeta {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    if row.hasMetaLine {
                        HStack(spacing: Spacing.compact) {
                            PriorityDot(priority: row.priority)
                            MetaLine(items: row.details)
                        }
                    }
                    if let value = row.progressValue {
                        ThinProgressBar(value: value, tone: row.progressTone, height: 3).frame(width: 64)
                    }
                }
            }
```

In `BoardTargetDetailView.swift`, in the Progress row (line 240), hide the bar from VoiceOver, because the percent text next to it already says the same:

```swift
                        ThinProgressBar(value: value, tone: detail.row.progressTone)
                            .frame(width: 80)
                            .accessibilityHidden(true)
```

In `WorkbenchListView.swift`, replace the counts `HStack(spacing: Spacing.regular) { … }` (lines 97-110) with a wrapping row. The bar and "1/8 done" stay one item, so the bar stays centred on its text:

```swift
            // Wraps at large Dynamic Type instead of squeezing (Phases 1–2
            // review). The bar and its text are one item, so the bar stays
            // centred on the text.
            FlowRow(spacing: Spacing.regular) {
                ForEach(card.stateCounts) { count in
                    HStack(spacing: 3) {
                        SessionDot(tone: count.tone, isRing: count.isRing, size: 7)
                        Text("\(count.amount)").font(TypeScale.time).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(count.text)
                }
                HStack(spacing: Spacing.compact) {
                    if let progress = card.progress {
                        ThinProgressBar(value: progress, tone: card.progressTone).frame(width: 64)
                    }
                    Text(card.doneLine).font(TypeScale.meta).foregroundStyle(.secondary)
                }
            }
```

- [ ] **Step 5: The tour's end shot**

In `ScreenshotHost.swift`, replace the condition in `tallScrollView(in:)` (line 70) and its doc comment:

```swift
    /// The first scroll view, breadth first, that can scroll: its content
    /// plus its adjusted top and bottom insets (navigation bar, tab bar) is
    /// taller than its bounds.
    static func tallScrollView(in root: UIView) -> UIScrollView? {
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scroll = view as? UIScrollView,
               scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom > scroll.bounds.height {
                return scroll
            }
            queue += view.subviews
        }
        return nil
    }
```

`endOffset(of:)` already adds the bottom inset and stays as it is.

- [ ] **Step 6: The doc line**

In `docs/features/mobile-companion.md`, in the asks section's "Views." line, change `from the closed asks under "▸ N closed"` to `from the closed asks under "N closed"`.

- [ ] **Step 7: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='WorkbenchWiringTests|BoardFilterTests|ScreenshotTourTests|SessionRowTests|OrangeToneTests' > build/mobile-logs/t1.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t1-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both, with `ScreenshotTourTests.testTheTour` skipped. Then run `grep -rn '▸' WatchtowerMobile docs/features/mobile-companion.md` and expect no output.

- [ ] **Step 8: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Workbench WatchtowerMobile/Tests docs/features/mobile-companion.md
git commit -m "fix(mobile): Phases 1-2 review minors — one closed mark, no empty board meta line, progress read once, wrapping counts, inset-aware end shots

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate):
- 05: "3 closed" with one disclosure chevron.
- 06: no gap above the bar of a row that has only a bar.
- 02 at the default size: the counts line is unchanged, one line.
- The end shots `01e`, `03e`, `07e` and `20e` show the ends of their lists.

---

### Task 2: The ask header — the kind icon and word, "#109", "1 of 2", focus rows (A1)

**Depends on:** none.

**Files:**
- Create: `Sources/Features/Asks/AskKindStyle.swift`
- Modify: `Sources/Features/Asks/AskFormModel.swift:42-49` (`AskText.kind` goes), `:126-129` and `:184-189` (`header` splits into four fields)
- Modify: `Sources/Features/Asks/AskView.swift:107-131` (`AskHeaderView`)
- Modify: `Sources/Features/Workbench/WorkbenchModels.swift:82-93` (`WaitingCardModel` forwards to `AskKindStyle`)
- Modify: `WatchtowerMobile/Tests/AskFormTests.swift:95`, plus a new test
- Regenerate: `project.pbxproj`

**Interfaces:**
- Consumes: `OwnerAsk.Kind`, `TypeScale.kind`/`time`/`meta`/`screenTitle`, `Spacing`.
- Produces:
  - `enum AskKindStyle { static func name(_ kind: OwnerAsk.Kind) -> String; static func icon(_ kind: OwnerAsk.Kind) -> String }`: "Question"/"Review"/"Check", and `questionmark.bubble`/`doc.text.magnifyingglass`/`checklist`.
  - `AskFormModel.kindIcon: String`, `kindName: String`, `idText: String` ("#109"), `pageText: String?` ("1 of 2"; nil with one question or none). `AskFormModel.header` and `AskText.kind` are removed.

- [ ] **Step 1: Write the failing tests**

In `AskFormTests.swift`, replace line 95 with:

```swift
        let first = try formOf(model, snapshot)
        XCTAssertEqual(first.kindIcon, "questionmark.bubble")
        XCTAssertEqual(first.kindName, "Question")
        XCTAssertEqual(first.idText, "#120")
        XCTAssertEqual(first.pageText, "1 of 2", "words, not codes (design pass A1)")
```

After `testMultiQuestionPagingKeepsAnswersAcrossPages`, add:

```swift
    /// Design pass A1: the header is the kind's icon and word, "#id" and the
    /// page; orange while open, secondary once closed. A single question has
    /// no page text.
    func testTheHeaderNamesTheKindTheIDAndThePage() async throws {
        let fixture = try await makeFixture()
        let demo = try demoSnapshot(now: now)
        func form(_ id: Int64) throws -> AskFormModel {
            try XCTUnwrap(AskViewModel(askID: id, drafts: fixture.drafts, answerer: fixture.answerer).form(snapshot: demo, now: now))
        }
        let review = try form(110)
        XCTAssertEqual([review.kindIcon, review.kindName, review.idText], ["doc.text.magnifyingglass", "Review", "#110"])
        XCTAssertNil(review.pageText)
        XCTAssertEqual(review.headerTone, .waitingForYou)
        let check = try form(111)
        XCTAssertEqual([check.kindIcon, check.kindName], ["checklist", "Check"])
        let closed = try form(105)
        XCTAssertEqual(closed.headerTone, .secondary, "a closed ask's header is not waiting for you")
        XCTAssertNil(closed.pageText, "a closed ask shows no question pages")

        let single = try makeAsk(121, [
            "kind": "question", "payload": ["questions": [["id": "q", "question": "Keep it?", "options": [["label": "Yes"], ["label": "No"]]]]]
        ])
        let model = AskViewModel(askID: 121, drafts: fixture.drafts, answerer: fixture.answerer)
        XCTAssertNil(try formOf(model, try replica([single])).pageText, "one question has no page text")
    }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=AskFormTests > build/mobile-logs/t2.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=`, with `value of type 'AskFormModel' has no member 'kindIcon'`.

- [ ] **Step 3: One place for the kind's word and icon**

Create `Sources/Features/Asks/AskKindStyle.swift`:

```swift
import WatchtowerKit

/// An ask kind's word and the Mac's kind icon
/// (`WatchtowerCore/Services/OwnerAskPresentation.swift:136-142`), shared
/// by the ask rows (design pass spec §2.7) and the ask form's header (A1).
/// A kind from a newer Mac reads as its capitalised raw value with the
/// question icon.
enum AskKindStyle {
    static func name(_ kind: OwnerAsk.Kind) -> String {
        switch kind {
        case .review: "Review"
        case .check: "Check"
        case .question: "Question"
        default: kind.rawValue.capitalized
        }
    }

    static func icon(_ kind: OwnerAsk.Kind) -> String {
        switch kind {
        case .review: "doc.text.magnifyingglass"
        case .check: "checklist"
        default: "questionmark.bubble"
        }
    }
}
```

In `WorkbenchModels.swift`, in `WaitingCardModel.init`, replace the two `switch` expressions (lines 83-93) with:

```swift
        kindLabel = AskKindStyle.name(ask.kind)
        kindIcon = AskKindStyle.icon(ask.kind)
```

- [ ] **Step 4: The model's header fields**

In `AskFormModel.swift`:
- Delete `AskText.kind(_:)` (lines 42-49). Nothing else calls it.
- Replace `/// "ASK #109 · QUESTION · 1 OF 2".` and `let header: String` (lines 127-128) with:

```swift
    /// The kind's icon and word ("Question"), drawn in `headerTone`.
    let kindIcon: String
    let kindName: String
    /// "#109".
    let idText: String
    /// "1 of 2" on a question ask with more than one question; nil otherwise.
    let pageText: String?
```

- In `init`, after `self.askID = askID`, add:

```swift
        kindIcon = AskKindStyle.icon(ask.kind)
        kindName = AskKindStyle.name(ask.kind)
        idText = "#\(ask.id)"
```

- Replace lines 187-189 (`var header = …` through `self.header = header`) with:

```swift
        pageText = questions.count > 1 ? "\(shown + 1) of \(questions.count)" : nil
```

- [ ] **Step 5: The header view**

In `AskView.swift`, replace `AskHeaderView` (lines 107-131) with:

```swift
/// The kind's icon and word, "#109" and "1 of 2"; the title, where it came
/// from, the summary, what changed since the last round and what to look
/// at (design pass A1).
private struct AskHeaderView: View {
    let form: AskFormModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Label(form.kindName, systemImage: form.kindIcon)
                    .font(TypeScale.kind)
                    .foregroundStyle(form.headerTone.color)
                Text(form.idText).font(TypeScale.time).foregroundStyle(.secondary)
                Spacer(minLength: Spacing.regular)
                if let page = form.pageText {
                    Text(page).font(TypeScale.meta).foregroundStyle(.secondary)
                }
            }
            Text(form.title).font(TypeScale.screenTitle)
            Text(form.subline).font(TypeScale.meta).foregroundStyle(.secondary)
            if !form.summary.isEmpty {
                Text(form.summary).font(.callout)
            }
            if !form.changes.isEmpty {
                Text("Changed since the last round: \(form.changes)").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(form.focus.enumerated()), id: \.offset) { _, focus in
                Label(focus, systemImage: "scope").font(TypeScale.meta).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 6: Regenerate, run, lint**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='AskFormTests|WorkbenchWiringTests|SessionDetailWiringTests|OrangeToneTests' > build/mobile-logs/t2.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t2-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both. Then run `grep -rn 'AskText.kind\|form.header\|\.header, "ASK' WatchtowerMobile` and expect no output.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Asks WatchtowerMobile/Sources/Features/Workbench/WorkbenchModels.swift \
  WatchtowerMobile/Tests/AskFormTests.swift WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj
git commit -m "feat(mobile): the ask header in words — kind icon and name, #id, 1 of 2, focus rows (A1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate): 13 shows "❓ Question #109" on the left and "1 of 2" on the right, with nothing uppercase or monospaced except "#109". 14 and 15 show "Review" and "Check" with their icons, in orange. 16 and 17 show the header in grey. Focus items are rows with a `scope` icon.

---

### Task 3: The recommended option and a closed ask's answer (A2, A6)

**Depends on:** Task 2 (both edit `AskFormModel.swift` and `AskView.swift`).

**Files:**
- Modify: `Sources/Features/Asks/QuestionAskView.swift:44-76` (`OptionLabel`)
- Modify: `Sources/Features/Asks/AskFormModel.swift:145-147` (`closedLines` type) and `:259-278` (the builder)
- Modify: `Sources/Features/Asks/AskView.swift:51-57` (the closed section)
- Modify: `WatchtowerMobile/Tests/AskFormTests.swift:302,454`, plus a new test

**Interfaces:**
- Consumes: `TypeScale.meta`, `PhoneTone.accent`, `Spacing`.
- Produces: `struct AskFormModel.ClosedLine: Equatable { let label: String; let value: String }`; `AskFormModel.closedLines: [ClosedLine]`. Label "Verdict", the question, the check step's text, the quoted comment, or "Note". Value: the answer, or "No answer" when a question has nothing picked.

- [ ] **Step 1: Write the failing tests**

In `AskFormTests.swift`, replace line 302 with:

```swift
        XCTAssertEqual(form.closedLines, [
            AskFormModel.ClosedLine(label: "Keep the counter?", value: "No"),
            AskFormModel.ClosedLine(label: "Note", value: "Not needed")
        ], "the question over its answer: no \"?:\" (design pass A6)")
```

Replace line 454 with:

```swift
        XCTAssertEqual(try form(105).closedLines, [
            AskFormModel.ClosedLine(label: "Keep the archived counter?", value: "Drop it"),
            AskFormModel.ClosedLine(label: "Note", value: "Not needed on the board.")
        ])
```

After `testAClosedAskShowsItsStoredAnswerReadOnly`, add (Review Focus 1):

```swift
    /// Design pass A6 and review focus 1: each stored part is a label over a
    /// value; a question answered with nothing reads "No answer", never an
    /// empty line.
    func testAClosedAnswerIsLabelAndValuePairs() async throws {
        let fixture = try await makeFixture()
        let snapshot = try replica([try makeAsk(161, [
            "kind": "check", "status": "answered",
            "payload": [
                "questions": [["id": "q", "question": "Keep it?", "options": [["label": "Yes"], ["label": "No"]]]],
                "checklist": [["id": "1", "text": "Open the menu"]]
            ],
            "answer": [
                "verdict": "approved", "answers": [["id": "q", "labels": [String](), "other": ""]],
                "checklist": [["id": "1", "state": "broken", "note": "The menu is empty"]], "comments": [[String: Any]](), "note": ""
            ]
        ])])
        let form = try formOf(AskViewModel(askID: 161, drafts: fixture.drafts, answerer: fixture.answerer), snapshot)
        XCTAssertEqual(form.closedLines, [
            AskFormModel.ClosedLine(label: "Verdict", value: "Approved"),
            AskFormModel.ClosedLine(label: "Keep it?", value: "No answer"),
            AskFormModel.ClosedLine(label: "Open the menu", value: "Broken — The menu is empty")
        ])
    }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=AskFormTests > build/mobile-logs/t3.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=`, with `'ClosedLine' is not a member type of struct 'WatchtowerMobile.AskFormModel'`.

- [ ] **Step 3: The model**

In `AskFormModel.swift`, after `struct CheckRow { … }`, add:

```swift
    /// One part of a closed ask's stored answer: what was asked, over what
    /// was answered (design pass A6).
    struct ClosedLine: Equatable {
        let label: String
        let value: String
    }
```

Change `let closedLines: [String]` (line 147) to `let closedLines: [ClosedLine]`. Replace `closedLines(_:)` (lines 259-278) with:

```swift
    private static func closedLines(_ ask: OwnerAsk) -> [ClosedLine] {
        guard let answer = ask.answer else { return [] }
        var lines: [ClosedLine] = []
        if let verdict = answer.verdict {
            lines.append(ClosedLine(label: "Verdict", value: verdict == .approved ? "Approved" : "Changes requested"))
        }
        let questions = Dictionary((ask.payload?.questions ?? []).map { ($0.id, $0.question) }) { first, _ in first }
        for item in answer.answers {
            let picked = (item.labels + (item.other.isEmpty ? [] : ["Other: \(item.other)"])).joined(separator: ", ")
            lines.append(ClosedLine(label: questions[item.id] ?? item.id, value: picked.isEmpty ? "No answer" : picked))
        }
        let checks = Dictionary((ask.payload?.checklist ?? []).map { ($0.id, $0.text) }) { first, _ in first }
        for item in answer.checklist {
            let note = item.note.isEmpty ? "" : " — \(item.note)"
            lines.append(ClosedLine(label: checks[item.id] ?? item.id, value: "\(AskText.check(item.state))\(note)"))
        }
        lines += answer.comments.map { ClosedLine(label: "“\($0.quote)”", value: $0.body) }
        if !answer.note.isEmpty {
            lines.append(ClosedLine(label: "Note", value: answer.note))
        }
        return lines
    }
```

- [ ] **Step 4: The views**

In `AskView.swift`, replace the closed section's body (lines 52-57) with:

```swift
                Section(status) {
                    if form.closedLines.isEmpty {
                        Text("No answer was stored").foregroundStyle(.secondary)
                    }
                    ForEach(Array(form.closedLines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(line.label).font(TypeScale.meta).foregroundStyle(.secondary)
                            Text(line.value).font(.callout)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
```

In `QuestionAskView.swift`, replace the text column of `OptionLabel` (the `VStack(alignment: .leading, spacing: 3) { … }`, lines 52-66) with:

```swift
            VStack(alignment: .leading, spacing: 3) {
                Text(option.label).font(.body.weight(.medium))
                // A word on its own line, not an outlined code badge (A2).
                if option.recommended {
                    Text("Recommended").font(TypeScale.meta).foregroundStyle(PhoneTone.accent.color)
                }
                if !option.description.isEmpty {
                    Text(option.description).font(TypeScale.meta).foregroundStyle(.secondary)
                }
            }
```

The accessibility label at line 23 already says "…, recommended" and stays.

- [ ] **Step 5: The doc line**

In `docs/features/mobile-companion.md`, in the asks section's "Form." line, after `a closed ask's stored answer (read-only)` add `, each part a label over its value ("Keep the counter?" over "No"; "No answer" when nothing was picked)`.

- [ ] **Step 6: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='AskFormTests|OrangeToneTests' > build/mobile-logs/t3.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t3-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both. Then run `grep -n 'RECOMMENDED' WatchtowerMobile/Sources/Features/Asks/QuestionAskView.swift` and expect no output.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Asks WatchtowerMobile/Tests/AskFormTests.swift docs/features/mobile-companion.md
git commit -m "feat(mobile): Recommended as a word; a closed answer as label and value pairs (A2, A6)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate): in 13, "Recommended" sits under "Archive Closed Targets Now" in accent, in regular weight with no outline. In 16, "Keep the archived counter?" is a grey caption over "Drop it", and "Note" is over "Not needed on the board.", with no "?:".

---

### Task 4: Check steps marked with one tap (A5)

**Depends on:** Task 3 (both edit `AskFormModel.swift`).

**Files:**
- Modify: `Sources/Features/Asks/AskFormModel.swift:106-114` (`CheckRow.choices`), `:200-202` (`toneUses`), `:250-257` (`checkRow`)
- Modify: `Sources/Features/Asks/AskViewModel.swift:98-100` (new `toggleCheck`)
- Modify: `Sources/Features/Asks/CheckAskView.swift` (the whole body)
- Modify: `WatchtowerMobile/Tests/AskFormTests.swift` (two new tests)
- Modify: `docs/features/mobile-companion.md` (the asks "Views." line)

**Interfaces:**
- Consumes: `AskText.check(_:)`, `PhoneTone`, `ToneUse`, `TypeScale.meta`, `Spacing`.
- Produces:
  - `struct AskFormModel.CheckChoice: Equatable, Identifiable { state: OwnerAskAnswer.CheckState; label: String; symbol: String; tone: PhoneTone; isSelected: Bool; id: String }`.
  - `AskFormModel.CheckRow.choices: [CheckChoice]`, in the order OK, Broken, Skipped.
  - `AskViewModel.toggleCheck(_ state: OwnerAskAnswer.CheckState, for itemID: String)`. `setCheck(_:for:)` stays for the existing tests.
  - `AskFormModel.toneUses` also lists every check choice, with role `.status`.

- [ ] **Step 1: Write the failing tests**

In `AskFormTests.swift`, after `testABrokenStepNeedsANoteAndUnmarkedStepsGoAsSkipped`, add:

```swift
    /// Design pass A5: three icon buttons, one tap marks a step, the marked
    /// state draws filled in its tone, and tapping it again clears it, as
    /// on the Mac (`OwnerAskChecklistBody.swift:44-57`).
    func testOneTapMarksAStepAndASecondTapClearsIt() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open the menu"]]]])
        let snapshot = try replica([ask])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        func row() throws -> AskFormModel.CheckRow {
            try XCTUnwrap(try formOf(model, snapshot).checks.first)
        }

        XCTAssertEqual(try row().choices.map(\.label), ["OK", "Broken", "Skipped"])
        XCTAssertEqual(try row().choices.map(\.symbol), ["checkmark.circle", "xmark.circle", "minus.circle"])
        XCTAssertTrue(try row().choices.allSatisfy { $0.tone == .secondary && !$0.isSelected }, "unmarked: outlines in secondary")

        model.toggleCheck(.ok, for: "1")
        XCTAssertEqual(try row().state, .ok)
        XCTAssertEqual(try row().choices.map(\.symbol), ["checkmark.circle.fill", "xmark.circle", "minus.circle"])
        XCTAssertEqual(try row().choices.map(\.tone), [.green, .secondary, .secondary])

        model.toggleCheck(.broken, for: "1")
        XCTAssertEqual(try row().state, .broken, "another state replaces the mark")
        XCTAssertEqual(try row().choices.map(\.tone), [.secondary, .red, .secondary])
        XCTAssertTrue(try row().needsNote)

        model.toggleCheck(.broken, for: "1")
        XCTAssertNil(try row().state, "tapping the marked state again clears it")

        model.toggleCheck(.skipped, for: "1")
        XCTAssertEqual(try row().choices.map(\.isSelected), [false, false, true])
        XCTAssertEqual(try row().choices.map(\.tone), [.secondary, .secondary, .secondary], "skipped stays secondary")
    }

    /// The check states are status tones in the form's `toneUses`, so the
    /// orange sweep sees them; none is orange.
    func testTheCheckStatesAreStatusTonesAndNeverOrange() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"], ["id": "2", "text": "Archive"]]]])
        let snapshot = try replica([ask])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        model.toggleCheck(.ok, for: "1")
        model.toggleCheck(.broken, for: "2")
        let steps = try formOf(model, snapshot).toneUses.filter { $0.element.contains(" step ") }
        XCTAssertEqual(steps.count, 6, "three choices per step")
        XCTAssertTrue(steps.allSatisfy { $0.role == .status })
        XCTAssertEqual(Set(steps.map(\.tone)), [.green, .red, .secondary])
    }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=AskFormTests > build/mobile-logs/t4.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=`, with `value of type 'AskViewModel' has no member 'toggleCheck'`.

- [ ] **Step 3: The model**

In `AskFormModel.swift`, before `struct CheckRow`, add:

```swift
    /// One of a check step's three buttons (design pass A5): the `.fill`
    /// symbol in its tone while marked, the outline in secondary otherwise.
    /// Green for OK, red for Broken, secondary for Skipped; never orange.
    struct CheckChoice: Equatable, Identifiable {
        let state: OwnerAskAnswer.CheckState
        /// "OK", "Broken", "Skipped": the button's VoiceOver label.
        let label: String
        let symbol: String
        let tone: PhoneTone
        let isSelected: Bool

        var id: String { state.rawValue }
    }
```

In `CheckRow`, after `let needsNote: Bool`, add:

```swift
        /// OK, Broken, Skipped.
        let choices: [CheckChoice]
```

Replace `checkRow(_:draft:)` (lines 250-257) with:

```swift
    private static let checkMarks: [(state: OwnerAskAnswer.CheckState, symbol: String, tone: PhoneTone)] = [
        (.ok, "checkmark.circle", .green), (.broken, "xmark.circle", .red), (.skipped, "minus.circle", .secondary)
    ]

    private static func checkRow(_ item: OwnerAskPayload.CheckItem, draft: AskDraft) -> CheckRow {
        let state = draft.checks[item.id]
        let note = draft.checkNotes[item.id] ?? ""
        let choices = checkMarks.map { mark in
            let selected = state == mark.state
            return CheckChoice(
                state: mark.state, label: AskText.check(mark.state),
                symbol: selected ? mark.symbol + ".fill" : mark.symbol,
                tone: selected ? mark.tone : .secondary, isSelected: selected
            )
        }
        return CheckRow(
            id: item.id, text: item.text, hint: item.hint, state: state, note: note,
            needsNote: state == .broken && AskDraft.trimmed(note).isEmpty, choices: choices
        )
    }
```

Replace `toneUses` (lines 200-202) with:

```swift
    var toneUses: [ToneUse] {
        [ToneUse(element: "ask \(askID) form header", tone: headerTone, role: .ask)]
            + checks.flatMap { row in
                row.choices.map { ToneUse(element: "ask \(askID) step \(row.id) \($0.label)", tone: $0.tone, role: .status) }
            }
    }
```

In `AskViewModel.swift`, after `setCheck(_:for:)`, add:

```swift
    /// One tap marks a step; tapping its marked state again clears it, as
    /// on the Mac (design pass A5).
    func toggleCheck(_ state: OwnerAskAnswer.CheckState, for itemID: String) {
        drafts.update(askID) { $0.checks[itemID] = $0.checks[itemID] == state ? nil : state }
    }
```

- [ ] **Step 4: The view**

Replace `CheckAskView.swift`'s struct body (its `states`, `body` and `stateBinding`) with the following. Keep `noteBinding(_:)` as it is.

```swift
/// The check steps (design pass A5): "1." and the step with its hint, then
/// OK, Broken and Skipped as 44 pt icon buttons; tapping the marked one
/// again clears it. A note goes with a broken step (required) or one that
/// has a note. A step left unmarked goes as skipped.
struct CheckAskView: View {
    let rows: [AskFormModel.CheckRow]
    let model: AskViewModel
    let isEditable: Bool

    var body: some View {
        Section {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                        Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(row.text).font(.body)
                            if !row.hint.isEmpty {
                                Text(row.hint).font(TypeScale.meta).foregroundStyle(.secondary)
                            }
                        }
                    }
                    choices(row, step: index + 1)
                    if row.state == .broken || !row.note.isEmpty {
                        TextField(row.needsNote ? "What is broken? (required)" : "Note", text: noteBinding(row), axis: .vertical)
                            .lineLimit(1...4)
                            .frame(minHeight: 44)
                            .disabled(!isEditable)
                            .accessibilityLabel("Note on step \(index + 1)")
                    }
                }
                .padding(.vertical, Spacing.small)
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("A step you leave unmarked goes as skipped.")
        }
    }

    /// Borderless buttons: in a List row, buttons of the default style all
    /// fire on a tap anywhere in the row.
    private func choices(_ row: AskFormModel.CheckRow, step: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(row.choices) { choice in
                Button {
                    model.toggleCheck(choice.state, for: row.id)
                } label: {
                    Image(systemName: choice.symbol)
                        .font(.title2)
                        .foregroundStyle(choice.tone.color)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(choice.label), step \(step)")
                .accessibilityAddTraits(choice.isSelected ? .isSelected : [])
            }
        }
        .disabled(!isEditable)
    }
```

- [ ] **Step 5: The doc line**

In `docs/features/mobile-companion.md`, in the asks section's "Views." line, add after the `AskView` sentence: `A check step is three icon buttons, OK, Broken and Skipped; one tap marks it, and tapping the marked state again clears it, as on the Mac.`

- [ ] **Step 6: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='AskFormTests|OrangeToneTests' > build/mobile-logs/t4.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t4-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both. Then run `grep -n 'Picker\|Not marked' WatchtowerMobile/Sources/Features/Asks/CheckAskView.swift` and expect no output.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Asks WatchtowerMobile/Tests/AskFormTests.swift docs/features/mobile-companion.md
git commit -m "feat(mobile): check steps marked with one tap — OK, Broken, Skipped icon buttons that toggle off (A5)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot check (at the gate): in 15, each step is "1." in grey, then the text and hint, then three outlined circle icons in a row, with no "Step 1" menu.

---

### Task 5: The review restyles on a Dynamic Type change; the path in code type (A4)

**Depends on:** none.

**Files:**
- Modify: `Sources/Features/Asks/ReviewDocumentStyler.swift` (new `needsRestyle`)
- Modify: `Sources/Features/Asks/ReviewAskView.swift:10-37` (the size category passed in; the path header in `TypeScale.code`) and `:113-153` (`SnapshotTextView`)
- Modify: `WatchtowerMobile/Tests/ReviewDocumentStylerTests.swift` (a new test)
- Modify: `docs/features/mobile-companion.md` (the asks "Views." line)

**Interfaces:**
- Consumes: `ReviewDocumentStyler.attributed(_:traits:)`, `PlainTextDocument`, `TypeScale.code`.
- Produces: `static func ReviewDocumentStyler.needsRestyle(shown: String, styledCategory: UIContentSizeCategory?, document: PlainTextDocument, category: UIContentSizeCategory) -> Bool`.

- [ ] **Step 1: Write the failing test**

In `ReviewDocumentStylerTests.swift`, after `testASelectionAnchorsAsOnThePlainText`, add (Review Focus 2):

```swift
    /// Phases 1–2 review and review focus 2: the same text at a new Dynamic
    /// Type size restyles; the attributed fonts do not follow a size change
    /// by themselves. The text stays `document.text`.
    func testADynamicTypeChangeRestylesTheSameText() {
        let document = fixture()
        XCTAssertTrue(ReviewDocumentStyler.needsRestyle(shown: "", styledCategory: nil, document: document, category: .large), "first show")
        XCTAssertFalse(ReviewDocumentStyler.needsRestyle(shown: document.text, styledCategory: .large, document: document, category: .large))
        XCTAssertTrue(
            ReviewDocumentStyler.needsRestyle(shown: document.text, styledCategory: .large, document: document, category: .accessibilityLarge),
            "same text, a new size"
        )
        XCTAssertTrue(ReviewDocumentStyler.needsRestyle(shown: "Old round", styledCategory: .large, document: document, category: .large))

        let large = ReviewDocumentStyler.attributed(document, traits: UITraitCollection(preferredContentSizeCategory: .large))
        let huge = ReviewDocumentStyler.attributed(document, traits: UITraitCollection(preferredContentSizeCategory: .accessibilityLarge))
        XCTAssertEqual(huge.string, document.text)
        XCTAssertGreaterThan(font(huge, at: 0)?.pointSize ?? 0, font(large, at: 0)?.pointSize ?? 0, "the restyle is at the new size")
    }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=ReviewDocumentStylerTests > build/mobile-logs/t5.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=`, with `type 'ReviewDocumentStyler' has no member 'needsRestyle'`.

- [ ] **Step 3: The check**

In `ReviewDocumentStyler.swift`, after `attributed(_:traits:)`, add:

```swift
    /// The text view shows `shown`, styled at `styledCategory`. It restyles
    /// when the document changed (a newer round) or the Dynamic Type size
    /// did: the attributed fonts do not follow a size change by themselves.
    static func needsRestyle(
        shown: String,
        styledCategory: UIContentSizeCategory?,
        document: PlainTextDocument,
        category: UIContentSizeCategory
    ) -> Bool {
        shown != document.text || styledCategory != category
    }
```

- [ ] **Step 4: The text view**

In `ReviewAskView.swift`:
- Add `@Environment(\.dynamicTypeSize) private var dynamicTypeSize` to `ReviewAskView`.
- Change the `SnapshotTextView` call (line 21) to `SnapshotTextView(document: document, category: UIContentSizeCategory(dynamicTypeSize), selection: $selection)`.
- Change the section header (line 37) to `Text(review.docPath).textCase(nil).font(TypeScale.code)`.
- Replace `SnapshotTextView` (lines 113-153) with:

```swift
/// The snapshot as a styled, read-only, selectable document; reports the
/// selection in UTF-16 units of `document.text` (the anchors' offsets).
private struct SnapshotTextView: UIViewRepresentable {
    let document: PlainTextDocument
    /// The Dynamic Type size to style at; a change restyles the same text.
    let category: UIContentSizeCategory
    @Binding var selection: NSRange

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        guard ReviewDocumentStyler.needsRestyle(
            shown: view.attributedText.string, styledCategory: coordinator.styledCategory, document: document, category: category
        ) else { return }
        // A size change keeps the text, so it keeps the selection. While
        // restyling, the delegate ignores the programmatic selection change,
        // so nothing writes the binding during this view update. The string
        // is `document.text` itself, so selections stay UTF-16 offsets into it.
        let kept = view.attributedText.string == document.text ? view.selectedRange : nil
        coordinator.isRestyling = true
        let traits = view.traitCollection.modifyingTraits { $0.preferredContentSizeCategory = category }
        view.attributedText = ReviewDocumentStyler.attributed(document, traits: traits)
        if let kept {
            view.selectedRange = kept
        }
        coordinator.isRestyling = false
        coordinator.styledCategory = category
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let selection: Binding<NSRange>
        /// The size the shown text was styled at; nil before the first style.
        var styledCategory: UIContentSizeCategory?
        var isRestyling = false

        init(selection: Binding<NSRange>) {
            self.selection = selection
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isRestyling else { return }
            selection.wrappedValue = textView.selectedRange
        }
    }
}
```

`UIContentSizeCategory(_: DynamicTypeSize)` and `UITraitCollection.modifyingTraits(_:)` are iOS 15 and iOS 17 API. If the compiler does not find the `DynamicTypeSize` initializer, map the size with a `switch` over `DynamicTypeSize` to `UIContentSizeCategory` in a `private static func category(_:)` in this file.

- [ ] **Step 5: The doc line**

In `docs/features/mobile-companion.md`, in the asks section's "Views." line, after `its UTF-16 selection becomes the anchor`, add `; the snapshot is restyled when Dynamic Type changes, and its text and selection stay`.

- [ ] **Step 6: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='ReviewDocumentStylerTests|AskFormTests' > build/mobile-logs/t5.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t5-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Asks WatchtowerMobile/Tests/ReviewDocumentStylerTests.swift docs/features/mobile-companion.md
git commit -m "fix(mobile): the review document restyles on a Dynamic Type change and keeps its selection; the path in code type (A4)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot check (at the gate): 14 is unchanged from after-phase-2, with headings and steps styled and the path in monospaced caption.

---

### Phase 3 gate

Run this once, by the controller, after Task 5. Change no code unless a check fails.

- [ ] **Load check.** Run `bash scripts/dev-health.sh`. If its last line is `HEALTH: overloaded`, stop and tell the owner what is holding the machine.
- [ ] **Full phone suite.** Run `make mobile-test SIM="iPhone 17 Pro" > build/mobile-logs/gate3-test.log 2>&1; echo "exit=$?"`. Expect `exit=0`, with `ScreenshotTourTests.testTheTour` skipped.
- [ ] **Full lint.** Run `make lint-all > build/mobile-logs/gate3-lint.log 2>&1; echo "exit=$?"`. Expect `exit=0`. No Go file changes in this plan. If `make lint` (golangci) fails only on issues that already exist on `origin/main`, confirm with `make lint-diff` (expect no new issues), record it, and treat `make lint-swift` as the Swift gate.
- [ ] **After shots.** Run `make mobile-shots SIM="iPhone 17 Pro" SHOTS_DIR=build/mobile-shots/after-phase-3 > build/mobile-logs/gate3-shots.log 2>&1; echo "exit=$?"`. Expect `exit=0` and 82 PNGs.
- [ ] **Compare by eye** each pair (`after-phase-2/NN-…` against `after-phase-3/NN-…`, light and dark) with the Read tool, against the shot checks of Tasks 1–5:
  - 13–17: A1, A2, A5 and A6. 14 is unchanged. 17 (withdrawn) changes only in its header (A7: no other change).
  - 02, 05 and 06: Task 1. `01e`, `03e`, `07e` and `20e` show their lists' ends.
  - Every other screen: no change.

  Fix any regression in a `fix(mobile): …` commit before Phase 4 starts.

---

## Phase 4: Calendar, Recording and Recap

### Task 6: The agenda — a Recordings button with a badge, and cards from the design layer (C1, C3)

**Depends on:** none.

**Files:**
- Modify: `Sources/Features/Calendar/AgendaView.swift:4-8` (doc comment), `:30-53` (the toolbar button), `:77-85` (row insets), `:179-246` (`AgendaEventRow`; `EventPillView` goes)
- Modify: `Sources/Features/Calendar/AgendaModel.swift:142-170` (`EventCardModel.cardStyle`)
- Modify: `Sources/Features/Calendar/EventDetailView.swift:90-92` (the recording pills become `Pill`s)
- Modify: `WatchtowerMobile/Tests/CalendarWiringTests.swift:271-283`
- Modify: `docs/features/mobile-companion.md` (the "Recordings list" line)

**Interfaces:**
- Consumes: `card(_:)`, `CardStyle`, `Pill`, `CountBadge`, `FlowRow`, `RecordButton`, `RowInsets.card`, `TypeScale.meta`, `Spacing`; `RecordingsListModel.newCount(transcripts:seen:)` and `pillText(newCount:)`.
- Produces: `EventCardModel.cardStyle: CardStyle` (`.highlighted` for the current or next meeting, otherwise `.plain`). `EventPillView` is deleted.

- [ ] **Step 1: Write the failing test**

In `CalendarWiringTests.testTheCurrentOrNextMeetingIsHighlightedWithRecordAndPrep`, before its closing brace, add:

```swift
        // Design pass C3: the highlighted card is the accent card, the others plain.
        XCTAssertEqual(agenda.cards.map(\.cardStyle), agenda.cards.map { $0.id == "next" ? CardStyle.highlighted : .plain })
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=CalendarWiringTests > build/mobile-logs/t6.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=`, with `value of type 'EventCardModel' has no member 'cardStyle'`.

- [ ] **Step 3: The model**

In `AgendaModel.swift`, in `EventCardModel`, after `var showsPrep`, add:

```swift
    /// The current or next meeting is the accent card; every other card is
    /// plain (design pass C3).
    var cardStyle: CardStyle { isHighlighted ? .highlighted : .plain }
```

- [ ] **Step 4: The Recordings button (C1)**

In `AgendaView.swift`, change the toolbar item (line 31) to `ToolbarItem(placement: .topBarTrailing) { recordingsButton }`, and replace `recordingsPill` (lines 37-53) with:

```swift
    /// C1: the waveform icon, with an accent badge counting new recaps. It
    /// speaks "Recordings · 1 new".
    private var recordingsButton: some View {
        let newCount = RecordingsListModel.newCount(
            transcripts: env.calendarReplica.snapshot.transcripts,
            seen: env.recordingsSeen.value
        )
        return Button {
            env.navigation.calendarPath.append(.recordings)
        } label: {
            Image(systemName: "waveform")
                .frame(minWidth: 44, minHeight: 44)
                .overlay(alignment: .topTrailing) {
                    if newCount > 0 {
                        CountBadge(count: newCount, tone: .accent).offset(x: 2, y: 4)
                    }
                }
                .contentShape(Rectangle())
        }
        .accessibilityLabel(RecordingsListModel.pillText(newCount: newCount))
    }
```

Change the doc comment's last line (line 8) to `/// waveform button (with a new-recap badge) to the Recordings list.`

- [ ] **Step 5: The cards (C3)**

In `content(now:)`, add `.listRowInsets(RowInsets.card)` after `AgendaEventRow(card: card) { … }` (line 80).

Replace the card column of `AgendaEventRow` (the `VStack(alignment: .leading, spacing: 6) { … }` and its modifiers through `.onTapGesture(perform: open)`, lines 192-230) with:

```swift
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(card.title).font(.subheadline.weight(.semibold))
                Text(card.detailLine).font(TypeScale.meta).foregroundStyle(.secondary)
                if !card.pills.isEmpty {
                    FlowRow {
                        ForEach(card.pills) { Pill(text: $0.text, tone: $0.tone) }
                    }
                }
                if card.isHighlighted {
                    // Leading-aligned; the 44 pt Record of Now (Global Constraints).
                    HStack(spacing: Spacing.regular) {
                        if let meeting = card.meetingEvent {
                            RecordButton {
                                Task { await env.recorder.recordMeeting(meeting) }
                            }
                        }
                        Button("Prep", action: open)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                }
            }
            .card(card.cardStyle)
            .opacity(card.isPast ? 0.75 : 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
```

Delete `EventPillView` (lines 235-246). In `EventDetailView.swift`, replace the recording pills (lines 90-92) with:

```swift
                    FlowRow {
                        ForEach(model.recordingPills) { Pill(text: $0.text, tone: $0.tone) }
                    }
```

- [ ] **Step 6: The doc line**

In `docs/features/mobile-companion.md`, in the "Recordings list" line, change `(from the Calendar's "Recordings" pill, "Recordings · N new")` to `(from the waveform button in the Calendar's toolbar, with an accent badge counting new recaps; VoiceOver reads "Recordings · N new")`.

- [ ] **Step 7: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='CalendarWiringTests|RecordingsWiringTests|OrangeToneTests' > build/mobile-logs/t6.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t6-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both. Then run `grep -rn 'EventPillView\|cornerRadius: 10' WatchtowerMobile/Sources/Features/Calendar` and expect no output.

- [ ] **Step 8: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Calendar WatchtowerMobile/Tests/CalendarWiringTests.swift docs/features/mobile-companion.md
git commit -m "feat(mobile): agenda cards from the design layer and a Recordings button with a badge (C1, C3)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate): in 03, the toolbar shows a waveform icon with a blue "1" badge and no capsule. The roadmap card is the accent card with a red Record (no blue ring) and a bordered Prep, both on the left. The other cards are plain cards with a hairline, and the pills are `Pill`s. 03e still ends above the mic button.

---

### Task 7: The event detail bar — Record, and Open recap for a past meeting (C4, part 1)

**Depends on:** Task 6 (both edit `EventDetailView.swift`).

**Files:**
- Modify: `Sources/DesignSystem/Bars.swift:48-65` (`RecordButton.fillsWidth`)
- Modify: `Sources/Features/Calendar/EventDetailModel.swift:1-57,88-95,114-117` (`EventAction`, `actions`)
- Modify: `Sources/Features/Calendar/EventDetailView.swift:4-6` (doc comment) and `:102-128` (the bar)
- Modify: `WatchtowerMobile/Tests/CalendarWiringTests.swift:81,332,339,340`, plus a new test
- Modify: `docs/features/mobile-companion.md` (the "Event detail" and "Capture" lines)

**Interfaces:**
- Consumes: `BottomActionBar`, `ProminentActionStyle`, `RecordButton`, `CalendarReplicaSnapshot.transcript(forEvent:)`, `CalendarRoute.recap(Int)`.
- Produces:
  - `enum EventAction: Hashable { case join, record, openRecap(Int); var title: String }`, with titles "Join", "Record" and "Open recap".
  - `EventDetailModel.actions: [EventAction]` replaces `actionTitles`. `showsRecord` becomes `actions.contains(.record)`.
  - `RecordButton(fillsWidth: Bool = false, action:)`: with `true`, the capsule takes the width it is given.

- [ ] **Step 1: Write the failing tests**

In `CalendarWiringTests.swift`:
- Line 81 becomes `XCTAssertFalse(detail.actions.contains(.record))`.
- Line 332 becomes `XCTAssertTrue(detail.actions.contains(.join))`.
- Line 339 becomes `XCTAssertFalse(bare.actions.contains(.join))`.
- Line 340 becomes `XCTAssertEqual(bare.actions, [.record])`.

After `testJoinOpensTheConferenceURLAndNoURLMeansNoJoin`, add (Review Focus 3):

```swift
    /// Design pass C4 and review focus 3: a finished event (end <= now) with
    /// a recap has one button, Open recap; a running one keeps Join and
    /// Record even with a recap, and a finished one without a recap keeps
    /// them too.
    func testAPastEventWithARecapOffersOnlyOpenRecap() throws {
        let url = "https://meet.example.com/abc"
        let past = event("past", start: now.addingTimeInterval(-7_200), minutes: 30, conference: url)
        let endsNow = event("ends-now", start: now.addingTimeInterval(-1_800), minutes: 30, conference: url)
        let running = event("running", start: now.addingTimeInterval(-600), minutes: 30, conference: url)
        let bare = event("bare", start: now.addingTimeInterval(-7_200), minutes: 30, conference: url)
        func recap(_ id: Int, of eventID: String) -> MeetingTranscript {
            MeetingTranscript(
                id: id, eventID: eventID, title: "Recap", durationSec: 600,
                createdAt: Self.iso.string(from: now.addingTimeInterval(-3_600)),
                updatedAt: Self.iso.string(from: now.addingTimeInterval(-3_600)), speakers: [], summary: "Done.",
                keyDecisions: [], actionItems: [], openQuestions: []
            )
        }
        let replica = snapshot([past, endsNow, running, bare], transcripts: [recap(9, of: "past"), recap(10, of: "ends-now"), recap(11, of: "running")])
        func actions(_ id: String) throws -> [EventAction] {
            try XCTUnwrap(EventDetailModel(
                eventID: id, snapshot: replica, recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
            )).actions
        }
        XCTAssertEqual(try actions("past"), [.openRecap(9)])
        XCTAssertEqual(try actions("ends-now"), [.openRecap(10)], "an event that ends now is over")
        XCTAssertEqual(try actions("running"), [.join, .record], "a running meeting still records")
        XCTAssertEqual(try actions("bare"), [.join, .record], "no recap: Join and Record stay")
        XCTAssertEqual([EventAction.join, .record, .openRecap(9)].map(\.title), ["Join", "Record", "Open recap"])
    }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=CalendarWiringTests > build/mobile-logs/t7.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=`, with `cannot find type 'EventAction' in scope`.

- [ ] **Step 3: The model**

In `EventDetailModel.swift`, before `struct EventDetailModel`, add:

```swift
/// A button of the event detail's bottom bar (design pass C4).
enum EventAction: Hashable {
    case join
    case record
    /// A finished event with a recap: the one button, which opens it.
    case openRecap(Int)

    var title: String {
        switch self {
        case .join: "Join"
        case .record: "Record"
        case .openRecap: "Open recap"
        }
    }
}
```

In the struct:
- Change the doc comment's first line to `/// The event detail (spec §13 C1, design pass C4): time, attendees, prep bullets, linked`, and its second line to end in `the Recording section, and Join and Record, or Open recap once it is over.`
- Change the `meetingEvent` comment to `/// nil for an all-day event: no Record.`
- Replace `var showsRecord` and `var actionTitles` (lines 45-50) with:

```swift
    /// The bottom bar's buttons, in order: Join (with a usable link) and
    /// Record (not all-day); a finished event with a recap has only Open
    /// recap.
    let actions: [EventAction]

    var showsRecord: Bool { actions.contains(.record) }
```

- In `allStrings`, change `+ actionTitles` to `+ actions.map(\.title)`.
- At the end of `init` (after `meetingEvent = …`, line 94), add:

```swift
        if event.endDate <= now, let recap = snapshot.transcript(forEvent: event.id) {
            actions = [.openRecap(recap.id)]
        } else {
            actions = (joinURL != nil ? [.join] : []) + (meetingEvent != nil ? [.record] : [])
        }
```

- In `toneUses`, change `"record this meeting"` to `"record button"`.

- [ ] **Step 4: `RecordButton` can fill its half of a bar**

In `Bars.swift`, replace `RecordButton` (lines 48-65) with:

```swift
/// The red Record button: the symbol forced monochrome white, so it draws
/// no accent ring inside the red capsule (shots 01 and 03). `fillsWidth`
/// for a bar's pair, where it takes its half.
struct RecordButton: View {
    var title = "Record"
    var size: ControlSize = .large
    var fillsWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "record.circle")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(PhoneTone.red.color)
        .controlSize(size)
    }
}
```

- [ ] **Step 5: The bar**

In `EventDetailView.swift`, change the doc comment (lines 4-6) to:

```swift
/// One event: the time line, attendees, the Prep card, linked targets
/// (read-only), the Recording section, and the bottom bar: Join and the red
/// Record, or Open recap once the event is over and has one.
```

Replace `bottomBar(_:)` (lines 102-128) with:

```swift
    @ViewBuilder
    private func bottomBar(_ model: EventDetailModel) -> some View {
        if !model.actions.isEmpty {
            BottomActionBar {
                HStack(spacing: Spacing.regular) {
                    ForEach(model.actions, id: \.self) { action in
                        actionButton(action, model)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: EventAction, _ model: EventDetailModel) -> some View {
        switch action {
        case .join:
            if let url = model.joinURL {
                Button {
                    openURL(url)
                } label: {
                    Label(action.title, systemImage: "video").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        case .record:
            if let meeting = model.meetingEvent {
                RecordButton(fillsWidth: true) {
                    Task { await env.recorder.recordMeeting(meeting) }
                }
            }
        case let .openRecap(id):
            Button(action.title) {
                env.navigation.calendarPath.append(.recap(id))
            }
            .buttonStyle(ProminentActionStyle())
        }
    }
```

- [ ] **Step 6: The doc lines**

In `docs/features/mobile-companion.md`:
- In the "Event detail" line, replace `Join (only with a usable meeting link) and Record this meeting (not for an all-day event).` with `Join (only with a usable meeting link) and Record (not for an all-day event); once the event is over and has a recap, one button, Open recap, opens it.`
- In the "Capture" line, change `"Record this meeting" ties the capture to its event` to `An event's Record ties the capture to its event`.

- [ ] **Step 7: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='CalendarWiringTests|OrangeToneTests|NowWiringTests' > build/mobile-logs/t7.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t7-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both. Then run `grep -rn 'Record this meeting\|actionTitles' WatchtowerMobile/Sources/Features/Calendar/EventDetail*.swift WatchtowerMobile/Tests` and expect only the agenda card's `actionTitles` in `CalendarWiringTests.swift` (lines 140 and 280, which are `EventCardModel`'s).

- [ ] **Step 8: Commit**

```bash
git add WatchtowerMobile/Sources/DesignSystem/Bars.swift WatchtowerMobile/Sources/Features/Calendar \
  WatchtowerMobile/Tests/CalendarWiringTests.swift docs/features/mobile-companion.md
git commit -m "feat(mobile): event detail bar — Record on one line, Open recap once a meeting with a recap is over (C4)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate): in 20 and 20e, the bar holds a bordered "Join" and a red "Record" on one line each, at equal widths. 21 (the standup, over, with recap 501) has one blue "Open recap" capsule and no Join or Record. 22 (the design review, over, with no transcript yet) keeps Record.

---

### Task 8: The event detail body — attendee colours, the transcribing row, the title (C4, part 2)

**Depends on:** Task 7 (both edit `EventDetailModel.swift` and `EventDetailView.swift`).

**Files:**
- Modify: `Sources/Features/Calendar/AgendaModel.swift:76-116` (`EventRecordingStatus.transcribingPercent`)
- Modify: `Sources/Features/Calendar/EventDetailModel.swift` (`Attendee.tone`, `attendeeTones`, `attendeeTone(_:)`, `transcribingPercent`, `transcribingTitle`, `toneUses`)
- Modify: `Sources/Features/Calendar/EventDetailView.swift:35-55` (title and attendees) and `:86-97` (the Recording section)
- Modify: `WatchtowerMobile/Tests/CalendarWiringTests.swift`, `WatchtowerMobile/Tests/OrangeToneTests.swift:67-93`

**Interfaces:**
- Consumes: `ThinProgressBar`, `FlowRow`, `Pill`, `TypeScale.screenTitle`/`time`, `Spacing`; `RecordingJob.status`/`percent`.
- Produces:
  - `EventRecordingStatus.transcribingPercent: Int?`: the Mac's percent clamped to 0…100 while an in-flight phone recording's job is `.transcribing`, otherwise nil. Also `static func transcribingPercent(_ job: RecordingJob) -> Int?`.
  - `EventDetailModel.Attendee.tone: PhoneTone`, `static let attendeeTones: [PhoneTone]` (blue, green, teal, purple), `static func attendeeTone(_ name: String) -> PhoneTone`.
  - `EventDetailModel.transcribingPercent: Int?` and `static let transcribingTitle = "Transcribing on Mac"`.

- [ ] **Step 1: Write the failing tests**

In `CalendarWiringTests.testATranscribingCardShowsThePercentFromRecordingJob`, after its last assertion, add:

```swift
        XCTAssertEqual(detail.transcribingPercent, 37, "design pass C4: one row with a bar and 37%")
        XCTAssertTrue(detail.toneUses.contains { $0.tone == .purple && $0.role == .progress })
```

After that test, add (Review Focus 4):

```swift
    /// Review focus 4: a percent from a newer Mac or a glitch clamps to
    /// 0…100 on the row.
    func testTheTranscribingRowClampsThePercent() async throws {
        for (sent, shown) in [(140, 100), (-5, 0)] {
            let store = try makePoolStore()
            let transport = InMemoryCloudTransport()
            let uploader = RecordingUploader(transport: transport, store: store, deviceID: DemoSeed.device.deviceID)
            try await DemoSeed.loadRecordingDemo(uploader: uploader, store: store, transport: transport, now: now, percent: sent)
            _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
            let recordings = try await store.reader.read { db in try PhoneRecordingsSnapshot.read(from: db, store: store) }
            let recorded = event(DemoSeed.recordedEventID, start: now.addingTimeInterval(-3_600), minutes: 30)
            let detail = try XCTUnwrap(EventDetailModel(
                eventID: recorded.id, snapshot: snapshot([recorded]), recordings: recordings, now: now, calendar: calendar
            ))
            XCTAssertEqual(detail.transcribingPercent, shown, "sent \(sent)")
        }
        XCTAssertNil(EventDetailModel(
            eventID: "plain", snapshot: snapshot([event("plain", start: now)]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
        )?.transcribingPercent, "no phone recording: no row")
    }

    /// Design pass C4: each attendee's initials get a tone from a stable
    /// hash of the name (the email without one), from blue, green, teal and
    /// purple; listed as info tones.
    func testAttendeesGetAStableToneFromTheirName() throws {
        let names = ["Colleague A", "Colleague B", "Colleague C", "Colleague D", "Colleague E"]
        XCTAssertEqual(names.map(EventDetailModel.attendeeTone), [.blue, .green, .teal, .purple, .blue])
        XCTAssertEqual(EventDetailModel.attendeeTone(""), .blue, "an empty name still gets a tone")

        let attendees = (1...3).map { EventAttendee(email: "colleague-\($0)@example.com", displayName: "", responseStatus: "accepted") }
        let detail = try XCTUnwrap(EventDetailModel(
            eventID: "e", snapshot: snapshot([event("e", start: now, attendees: attendees)]),
            recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
        ))
        XCTAssertEqual(detail.attendees.map(\.tone), attendees.map { EventDetailModel.attendeeTone($0.email) }, "no name: the email")
        let uses = detail.toneUses.filter { $0.element.hasPrefix("attendee ") }
        XCTAssertEqual(uses.count, 3)
        XCTAssertTrue(uses.allSatisfy { $0.role == .info })
    }
```

In `OrangeToneTests.testDataDrivenTonesAreNeverOrange`, before `var snapshot = WorkbenchReplicaSnapshot()`, add:

```swift
        XCTAssertFalse(EventDetailModel.attendeeTones.contains(.orange), "attendee initials are never orange")
        XCTAssertFalse(EventDetailModel.attendeeTones.contains(.red), "red is the recording colour")
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='CalendarWiringTests|OrangeToneTests' > build/mobile-logs/t8.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=`, with `value of type 'EventDetailModel' has no member 'transcribingPercent'`.

- [ ] **Step 3: The recording status**

In `AgendaModel.swift`, in `EventRecordingStatus`, after `let text: String?`, add:

```swift
    /// The Mac's percent, clamped to 0…100, while a phone recording of
    /// this event is on its way and its job is transcribing; nil otherwise
    /// (design pass C4's row).
    let transcribingPercent: Int?
```

Replace `init(event:snapshot:recordings:now:)` (lines 87-112) with the same branches, now also setting `transcribingPercent`:

```swift
    init(event: CalendarEvent, snapshot: CalendarReplicaSnapshot, recordings: PhoneRecordingsSnapshot, now: Date) {
        // The newest phone recording made for this event (the ledger is
        // newest first). While it is on its way or on the Mac, its state
        // wins over an older recap of the same event.
        let newest = recordings.recordings.first { $0.eventID == event.id }
        let phone = newest.map { Self.phonePill($0, recordings: recordings, now: now) }
        if let phone, phone.inFlight {
            pills = [phone.pill]
            text = phone.pill.text
            transcribingPercent = newest.flatMap { recordings.jobs[$0.id] }.flatMap(Self.transcribingPercent)
        } else if let transcript = snapshot.transcript(forEvent: event.id) {
            var pills: [EventPill] = []
            let recap = transcript.summary != nil
            pills.append(EventPill(text: recap ? "Recap ready" : "Transcript ready", tone: .green, role: .status))
            let items = transcript.actionItems.count + (transcript.actionItemsMore ?? 0)
            if items > 0 {
                pills.append(EventPill(text: items == 1 ? "1 action item" : "\(items) action items", tone: .secondary, role: .info))
            }
            self.pills = pills
            text = transcript.summary ?? "Transcript ready"
            transcribingPercent = nil
        } else if let phone {
            pills = [phone.pill]
            text = phone.pill.text
            transcribingPercent = nil
        } else {
            pills = []
            text = nil
            transcribingPercent = nil
        }
    }

    /// The job's percent while it transcribes, clamped to 0…100; nil in any
    /// other job state.
    static func transcribingPercent(_ job: RecordingJob) -> Int? {
        job.status == .transcribing ? min(100, max(0, job.percent ?? 0)) : nil
    }
```

- [ ] **Step 4: The detail model**

In `EventDetailModel.swift`:
- Add `let tone: PhoneTone` to `Attendee`, with the comment `/// From `attendeeTones` by a stable hash of the name; never red or orange.`
- After `static let noPrepText`, add:

```swift
    static let transcribingTitle = "Transcribing on Mac"
    /// Attendee initials' tones (design pass C4): never red (recording) or
    /// orange (waiting).
    static let attendeeTones: [PhoneTone] = [.blue, .green, .teal, .purple]

    /// A pick that is the same on every launch and device, unlike
    /// `hashValue`, which Swift seeds per process.
    static func attendeeTone(_ name: String) -> PhoneTone {
        let hash = name.utf8.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) }
        return attendeeTones[Int(hash % UInt64(attendeeTones.count))]
    }
```

- After `let recordingPills: [EventPill]`, add `/// The Recording section's progress row; nil without one.` and `let transcribingPercent: Int?`.
- Replace the `attendees = …` statement (lines 73-75) with:

```swift
        attendees = event.attendees.prefix(Self.avatarLimit).map {
            let name = $0.displayName.isEmpty ? $0.email : $0.displayName
            return Attendee(id: $0.email, initials: Self.initials(name), tone: Self.attendeeTone(name))
        }
```

- After `recordingPills = status.pills`, add `transcribingPercent = status.transcribingPercent`.
- Replace `toneUses` with:

```swift
    var toneUses: [ToneUse] {
        recordingPills.map { ToneUse(element: "recording \($0.text)", tone: $0.tone, role: $0.role) }
            + (transcribingPercent != nil ? [ToneUse(element: "transcribing on mac", tone: .purple, role: .progress)] : [])
            + attendees.map { ToneUse(element: "attendee \($0.id)", tone: $0.tone, role: .info) }
            + (showsRecord ? [ToneUse(element: "record button", tone: .red, role: .recording)] : [])
    }
```

- [ ] **Step 5: The view**

In `EventDetailView.swift`:
- Change the title (line 37) to `Text(model.title).font(TypeScale.screenTitle)`.
- Replace the initials (lines 45-49) with:

```swift
                                Text(attendee.initials)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(attendee.tone.color)
                                    .frame(width: 32, height: 32)
                                    .background(attendee.tone.color.opacity(0.2), in: Circle())
                                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
```

- Replace the Recording section (lines 86-97) with:

```swift
            Section("Recording") {
                if let percent = model.transcribingPercent {
                    HStack(spacing: Spacing.regular) {
                        Image(systemName: "waveform").foregroundStyle(PhoneTone.purple.color)
                        Text(EventDetailModel.transcribingTitle).font(.callout)
                        Spacer(minLength: Spacing.regular)
                        ThinProgressBar(value: Double(percent) / 100, tone: .purple)
                            .frame(width: 80)
                            .accessibilityHidden(true)
                        Text("\(percent)%").font(TypeScale.time)
                    }
                    .accessibilityElement(children: .combine)
                } else if model.recordingPills.isEmpty {
                    Text(model.recordingText).foregroundStyle(.secondary)
                } else {
                    FlowRow {
                        ForEach(model.recordingPills) { Pill(text: $0.text, tone: $0.tone) }
                    }
                    if model.recordingText != model.recordingPills.first?.text {
                        Text(model.recordingText).font(.callout)
                    }
                }
            }
```

`EventDetailModel.allStrings` reads `recordingText`, which still holds "Transcribing on Mac · 37%", so the "Make target" guard still sees the transcribing text.

- [ ] **Step 6: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='CalendarWiringTests|OrangeToneTests|RecordingsWiringTests' > build/mobile-logs/t8.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t8-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Calendar WatchtowerMobile/Tests/CalendarWiringTests.swift WatchtowerMobile/Tests/OrangeToneTests.swift
git commit -m "feat(mobile): event detail — coloured attendee initials and one transcribing row with a bar (C4)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate): in 20, the five initials are 32 pt circles tinted blue, green, teal, purple and blue. In 22, the Recording section is one row: a purple waveform, "Transcribing on Mac", a purple bar and "60%".

---

### Task 9: The recorder, the recap and the Recordings list (C5, C6, C7)

**Depends on:** none.

**Files:**
- Modify: `Sources/Features/Recording/RecorderChrome.swift` (new `WaveformStyle`)
- Modify: `Sources/Features/Recording/RecordingView.swift:24-25,92-111,124-135,170-190,204-206`
- Modify: `Sources/Features/Recordings/RecapView.swift:135-153,186-189`
- Modify: `Sources/Features/Recordings/RecordingsListView.swift:25-41`
- Modify: `WatchtowerMobile/Tests/RecorderTests.swift` (a new test)

**Interfaces:**
- Consumes: `RecorderChrome`, `PhoneTone.red`, `TypeScale.kind`/`pageTitle`/`sectionHeader`, `Spacing.page`/`medium`/`large`/`small`, `Radius.row`/`chip`.
- Produces: `enum WaveformStyle { static let silence: Float; static let minHeight: CGFloat; static func isSilent(_ level: Float) -> Bool; static func height(_ level: Float, in maxHeight: CGFloat) -> CGFloat }`.

C5 says the Recordings list's "pills become `Pill`s", but `RecordingsListView` draws no pill today (its state is a coloured text line), so C5 leaves nothing to replace. §2.7 and §9.3 list Recordings among the list screens on `systemBackground` with flat rows, so the list becomes `.plain`, with sentence-case section headers. Nothing else in it changes.

- [ ] **Step 1: Write the failing test**

In `RecorderTests.swift`, after `testTheCaptureChromeFollowsThePhase`, add:

```swift
    /// Design pass C7: a level under 0.05 is silence and draws a grey bar,
    /// so silence reads as a line, not a red dashed one; every bar is at
    /// least 4 pt and never taller than the waveform.
    func testSilenceDrawsAGreyLineAndLevelsDrawRedBars() {
        XCTAssertTrue(WaveformStyle.isSilent(0))
        XCTAssertTrue(WaveformStyle.isSilent(0.049))
        XCTAssertFalse(WaveformStyle.isSilent(0.05))
        XCTAssertEqual(WaveformStyle.height(0, in: 64), 4, "silence keeps a 4 pt line")
        XCTAssertEqual(WaveformStyle.height(0.5, in: 64), 32)
        XCTAssertEqual(WaveformStyle.height(1.5, in: 64), 64, "a level over 1 never overflows")
        XCTAssertEqual(WaveformStyle.height(-1, in: 64), 4)
    }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=RecorderTests > build/mobile-logs/t9.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=`, with `cannot find 'WaveformStyle' in scope`.

- [ ] **Step 3: The waveform style**

At the end of `RecorderChrome.swift`, add:

```swift
/// The recorder's level bars (design pass C7). A level under `silence`
/// draws a quaternary bar, so silence reads as a grey line instead of a
/// red dashed one; the others draw red at 0.85. The engine already maps dB
/// to 0…1 (`AVAudioCaptureEngine`), so no display curve goes on top.
enum WaveformStyle {
    static let silence: Float = 0.05
    static let minHeight: CGFloat = 4

    static func isSilent(_ level: Float) -> Bool {
        level < silence
    }

    static func height(_ level: Float, in maxHeight: CGFloat) -> CGFloat {
        max(minHeight, maxHeight * CGFloat(min(1, max(0, level))))
    }
}
```

- [ ] **Step 4: The recorder view (C7)**

In `RecordingView.swift`:
- In `RecordingView.body` (lines 24-25), change the padding to `.padding(.horizontal, Spacing.page)` and `.padding(.vertical, Spacing.medium)`.
- In `markView(_:)` (lines 92-111), change the three `.font(.footnote.weight(.bold))` to `.font(TypeScale.kind)`.
- In the Stop button (line 128), change `Circle().fill(.red)` to `Circle().fill(PhoneTone.red.color)`. `RecorderChrome` disables Stop only in `.idle` and `.saving`, so it is solid red whenever it works.
- In `WaveformBars` (lines 182-185), replace the `Capsule()` with:

```swift
                    Capsule()
                        .fill(
                            WaveformStyle.isSilent(padded[index])
                                ? AnyShapeStyle(HierarchicalShapeStyle.quaternary)
                                : AnyShapeStyle(PhoneTone.red.color.opacity(0.85))
                        )
                        .frame(width: width, height: WaveformStyle.height(padded[index], in: proxy.size.height))
```

  Change its doc comment to `/// The waveform: recent input levels, newest on the right; silence is a grey line (`WaveformStyle`).`
- In `RecordingSavedView` (line 205), change `.font(.title2.weight(.semibold))` to `.font(TypeScale.pageTitle)`.

- [ ] **Step 5: The recap (C6)**

In `RecapView.swift`, replace the section block in `recap(_:)` (lines 135-153) with:

```swift
        ForEach(model.sections) { section in
            VStack(alignment: .leading, spacing: 0) {
                // C6: a headline as written, not an uppercase caption.
                Text(section.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, Spacing.small)
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                    Divider()
                }
                if let more = section.moreText {
                    Text(more).font(.footnote).foregroundStyle(.secondary).padding(.top, Spacing.regular)
                }
            }
            .padding(.top, Spacing.large)
        }
```

In `transcriptLines(_:loading:)` (line 188), change `RoundedRectangle(cornerRadius: 8)` to `RoundedRectangle(cornerRadius: Radius.row)`, the row-highlight radius.

- [ ] **Step 6: The Recordings list (C5, §2.7)**

In `RecordingsListView.swift`, replace `content(_:)` (lines 25-41) with:

```swift
    private func content(_ model: RecordingsListModel) -> some View {
        List {
            if let empty = model.emptyText {
                Text(empty).foregroundStyle(.secondary)
            }
            if !model.inProgress.isEmpty {
                Section {
                    ForEach(model.inProgress) { row($0) }
                } header: {
                    Text("In progress").font(TypeScale.sectionHeader).textCase(nil)
                }
            }
            if !model.earlier.isEmpty {
                Section {
                    ForEach(model.earlier) { row($0) }
                } header: {
                    Text("Earlier").font(TypeScale.sectionHeader).textCase(nil)
                }
            }
        }
        // A list screen on systemBackground (design pass §2.7, §9.3).
        .listStyle(.plain)
    }
```

- [ ] **Step 7: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='RecorderTests|RecordingsWiringTests|RecordingUploadWiringTests' > build/mobile-logs/t9.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t9-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both. Then run `grep -n 'uppercased()\|cornerRadius: 8' WatchtowerMobile/Sources/Features/Recordings/RecapView.swift` and expect no output.

- [ ] **Step 8: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Recording WatchtowerMobile/Sources/Features/Recordings WatchtowerMobile/Tests/RecorderTests.swift
git commit -m "feat(mobile): a grey line for silence, a solid red Stop; recap headlines; a plain Recordings list (C5-C7)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate):
- 26 (idle) shows a flat grey line where the red dashes were.
- 26b shows red bars for the fake levels, grey where the level is under 0.05, and a solid red Stop.
- 26d shows "Saved · 01:48" in the page title style.
- 24 shows "Action items" and "Decisions" as headlines, with 16 pt above each.
- 23 is a plain list on white or black, with "In progress" and "Earlier" in sentence case.

---

### Phase 4 gate

Run this once, by the controller, after Task 9.

- [ ] **Load check.** Run `bash scripts/dev-health.sh`. If its last line is `HEALTH: overloaded`, stop and report.
- [ ] **Full phone suite.** Run `make mobile-test SIM="iPhone 17 Pro" > build/mobile-logs/gate4-test.log 2>&1; echo "exit=$?"`. Expect `exit=0`.
- [ ] **Full lint.** Run `make lint-all > build/mobile-logs/gate4-lint.log 2>&1; echo "exit=$?"`. Expect `exit=0`, or only the Phase 3 gate's recorded pre-existing Go issues, confirmed by `make lint-diff`.
- [ ] **After shots.** Run `make mobile-shots SIM="iPhone 17 Pro" SHOTS_DIR=build/mobile-shots/after-phase-4 > build/mobile-logs/gate4-shots.log 2>&1; echo "exit=$?"`. Expect `exit=0` and 82 PNGs.
- [ ] **Compare by eye** against `after-phase-3/` and `after-phase-2/`, light and dark:
  - 03 and 03e: C1 and C3, with bug 2's fix intact (the mic button never covers the highlighted card).
  - 20, 20e, 21 and 22: C4, with bug 8's opaque bar intact.
  - 23: C5. 24 and 25: C6. 26, 26b, 26c and 26d: C7, with bug 9's chrome intact.
  - 01 (Now): the next-meeting card is unchanged, and Record is 44 pt with no ring.
  - Dark mode: the highlighted agenda card reads blue, not grey, and no card sits inside a card.
  - Screens outside this phase: no change from `after-phase-3/`.

  Fix any regression in a `fix(mobile): …` commit, then re-run the suites for the touched classes.

---

## Phase 5: Settings and Onboarding

### Task 10: Settings — Last sync in words, account status marks, a long Mac name (SET2, SET3, SET4)

**Depends on:** none.

SET4's doc comment already says Settings is pushed from Now's gear (Phases 1–2, Task 12), and `insetGrouped` stays. This task only checks it. The one-row Mac status from bug 10 truncates a long Mac name next to "Offline · seen …"; this task folds that review minor in.

**Files:**
- Create: `Sources/Features/Settings/AccountStatusStyle.swift`
- Modify: `Sources/Features/Settings/MacStatusRow.swift` (adds `MacStatusRowView` and `LastSyncText`)
- Modify: `Sources/Features/Settings/SettingsView.swift:36-91`
- Modify: `WatchtowerMobile/Tests/SettingsWiringTests.swift`, `WatchtowerMobile/Tests/OrangeToneTests.swift:67-93`
- Modify: `docs/features/mobile-companion.md` (the "Settings." line)
- Regenerate: `project.pbxproj`

**Interfaces:**
- Consumes: `MacStatusRow` (Phase 1), `PhoneTone`, `ToneUse`, `Spacing`.
- Produces:
  - `enum LastSyncText { static func string(_ last: Date?, locale: Locale = .current) -> String }`: "3 min. ago", or "Never".
  - `struct MacStatusRowView: View { let row: MacStatusRow }`: one row, or the name over the status when they do not fit.
  - `struct AccountStatusStyle: Equatable { enum Mark: Equatable { case dot, symbol(String), textOnly }; let mark: Mark; let text: String; let tone: PhoneTone; let textTone: PhoneTone; init(status: String); var toneUses: [ToneUse] }`.

- [ ] **Step 1: Write the failing tests**

In `SettingsWiringTests.swift`, add `import SwiftUI` and `import UIKit` to the imports. After `testTheMacRowIsOneRowForEveryStatus`, add:

```swift
    /// Phases 1–2 review: a Mac name too long to share its row with
    /// "Offline · seen …" puts the status on a second line under it instead
    /// of truncating either.
    func testALongMacNameWrapsTheStatusUnderTheName() {
        let now = Date()
        func height(_ name: String) -> CGFloat {
            let row = MacStatusRow(status: .offline(macName: name, lastSeen: now.addingTimeInterval(-180)), now: now)
            return UIHostingController(rootView: MacStatusRowView(row: row))
                .sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)).height
        }
        XCTAssertGreaterThan(height("Acme Mac in the second-floor meeting room"), height("Acme Mac") + 10)
    }

    /// Design pass SET2: "3 min. ago", not a ticking "2 min, 39 sec".
    func testLastSyncSaysHowLongAgoInWords() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(LastSyncText.string(Date().addingTimeInterval(-159), locale: english), "3 min. ago")
        XCTAssertEqual(LastSyncText.string(nil), "Never")
    }

    /// Design pass SET3: "ok" a green dot and OK, "error" a red mark and a
    /// red Error, anything else (a newer Mac's status) its own text in
    /// secondary. Role info; never orange.
    func testAnAccountStatusIsADotAMarkOrItsText() {
        let ok = AccountStatusStyle(status: "ok")
        XCTAssertEqual(ok.mark, .dot)
        XCTAssertEqual(ok.text, "OK")
        XCTAssertEqual([ok.tone, ok.textTone], [.green, .secondary])
        let error = AccountStatusStyle(status: "error")
        XCTAssertEqual(error.mark, .symbol("exclamationmark.circle.fill"))
        XCTAssertEqual(error.text, "Error")
        XCTAssertEqual([error.tone, error.textTone], [.red, .red])
        let newer = AccountStatusStyle(status: "expired")
        XCTAssertEqual(newer.mark, .textOnly)
        XCTAssertEqual(newer.text, "expired")
        XCTAssertEqual([newer.tone, newer.textTone], [.secondary, .secondary])
        XCTAssertTrue(error.toneUses.allSatisfy { $0.role == .info })
    }
```

If the simulator's ICU prints the en_US abbreviated unit differently from "3 min. ago", read the real output in the log. Keep `.abbreviated`, and change the literal only when the printed text is still an abbreviated relative age.

In `OrangeToneTests.testDataDrivenTonesAreNeverOrange`, after the `MacStatusRow` loop, add:

```swift
        for status in ["ok", "error", "expired", ""] {
            XCTAssertTrue(AccountStatusStyle(status: status).toneUses.allSatisfy { $0.tone != .orange }, "account status \(status)")
        }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='SettingsWiringTests|OrangeToneTests' > build/mobile-logs/t10.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=`, with `cannot find 'MacStatusRowView' in scope`.

- [ ] **Step 3: The values**

Create `Sources/Features/Settings/AccountStatusStyle.swift`:

```swift
/// An account's status in Settings → Accounts (design pass SET3): "ok" is
/// an 8 pt green dot and "OK", "error" a red exclamation mark and a red
/// "Error", and any other value (a newer Mac's) its raw text in secondary.
/// Role `.info`; never orange.
struct AccountStatusStyle: Equatable {
    enum Mark: Equatable {
        case dot
        case symbol(String)
        case textOnly
    }

    let mark: Mark
    let text: String
    let tone: PhoneTone
    let textTone: PhoneTone

    init(status: String) {
        switch status {
        case "ok":
            (mark, text, tone, textTone) = (.dot, "OK", .green, .secondary)
        case "error":
            (mark, text, tone, textTone) = (.symbol("exclamationmark.circle.fill"), "Error", .red, .red)
        default:
            (mark, text, tone, textTone) = (.textOnly, status, .secondary, .secondary)
        }
    }

    var toneUses: [ToneUse] {
        [
            ToneUse(element: "settings account status mark", tone: tone, role: .info),
            ToneUse(element: "settings account status text", tone: textTone, role: .info)
        ]
    }
}
```

The four-member tuples are assignment targets, not a declared tuple type, so `large_tuple` does not apply to them. If SwiftLint flags them, assign the four properties one by one in each case.

At the end of `MacStatusRow.swift`, add:

```swift
/// The Your Mac row (bug 10): the name on the left and the dot and state on
/// the right, on one line. A name too long for that gets the state on a
/// second line under it, instead of either truncating (Phases 1–2 review).
struct MacStatusRowView: View {
    let row: MacStatusRow

    var body: some View {
        ViewThatFits(in: .horizontal) {
            LabeledContent {
                status
            } label: {
                Text(row.label).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(row.label)
                status.foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var status: some View {
        HStack(spacing: Spacing.compact) {
            Circle().fill(row.tone.color).frame(width: 8, height: 8)
            Text(row.value).lineLimit(1)
        }
    }
}

/// Settings' Last sync value (design pass SET2): "3 min. ago", or "Never".
/// Relative to the moment it is drawn; the row's 30 s TimelineView redraws
/// it.
enum LastSyncText {
    static func string(_ last: Date?, locale: Locale = .current) -> String {
        guard let last else { return "Never" }
        return last.formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .abbreviated, locale: locale))
    }
}
```

`MacStatusRow.swift` imports only `Foundation`. Add `import SwiftUI`.

- [ ] **Step 4: The view**

In `SettingsView.swift`:
- In `yourMacSection`, replace the `LabeledContent { … } label: { … }` inside the `TimelineView` (lines 43-50) with `MacStatusRowView(row: row)`.
- Replace the "Last sync" row (lines 58-64) with its own timeline, so it does not join the status row's cell:

```swift
            // Its own TimelineView: a Form lays one TimelineView's views out
            // in one cell, and "3 min. ago" moves with the clock alone.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                LabeledContent("Last sync", value: LastSyncText.string(env.lastSyncAt))
            }
```

- In `accountsSection`, replace the `LabeledContent { Text(account.status) } label: { … }` (lines 79-83) with:

```swift
                    LabeledContent {
                        AccountStatusLabel(style: AccountStatusStyle(status: account.status))
                    } label: {
                        Label(account.label, systemImage: Self.symbol(for: account.kind))
                    }
```

- At the end of the file, add:

```swift
/// SET3's mark and text, in the style's tones.
private struct AccountStatusLabel: View {
    let style: AccountStatusStyle

    var body: some View {
        HStack(spacing: Spacing.compact) {
            switch style.mark {
            case .dot:
                Circle().fill(style.tone.color).frame(width: 8, height: 8)
            case let .symbol(name):
                Image(systemName: name).foregroundStyle(style.tone.color)
            case .textOnly:
                EmptyView()
            }
            Text(style.text).foregroundStyle(style.textTone.color)
        }
    }
}
```

- Check that the doc comment at line 4 reads "Settings (pushed from Now's gear): …" (SET4). Change nothing there.

- [ ] **Step 5: The doc line**

In `docs/features/mobile-companion.md`, in the "Settings." line:
- Change `Last sync, the hub's accounts read-only.` to `Last sync ("3 min. ago"), the hub's accounts read-only (a green dot and OK, a red mark and Error, or the Mac's own word).`
- After `with a dot)`, add `; a name too long for the row puts the status on a line under it`.

- [ ] **Step 6: Regenerate, run, lint**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='SettingsWiringTests|OrangeToneTests' > build/mobile-logs/t10.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t10-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both. Then run `grep -n 'style: .relative' WatchtowerMobile/Sources/Features/Settings/SettingsView.swift` and expect no output.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Settings WatchtowerMobile/Tests/SettingsWiringTests.swift \
  WatchtowerMobile/Tests/OrangeToneTests.swift WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj docs/features/mobile-companion.md
git commit -m "feat(mobile): Settings — Last sync in words, account status marks, a long Mac name wraps (SET2, SET3)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot check (at the gate): in 27, "Acme Mac" and "● Online" are on one row. "Last sync" reads "… ago" or "Never". The "Acme Jira" row shows a red exclamation mark and a red "Error", and the other accounts show a green dot and "OK".

---

### Task 11: Welcome — the app icon, three feature lines, the notice as a card (O1)

**Depends on:** none.

**Files:**
- Create: `Sources/Assets.xcassets/AppIconImage.imageset/Contents.json`
- Create: `Sources/Assets.xcassets/AppIconImage.imageset/AppIconImage.png` (a copy of `AppIcon.appiconset/AppIcon-1024.png`)
- Create: `WatchtowerMobile/Tests/WelcomeTests.swift`
- Modify: `Sources/Features/Onboarding/WelcomeView.swift:33-84`
- Regenerate: `project.pbxproj`

**Interfaces:**
- Consumes: `FlatRow`, `FlatRowIcon.symbol`, `card(.plain)`, `Spacing.page`/`regular`/`medium`/`large`.
- Produces: `struct WelcomeFeature: Equatable { let symbol: String; let text: String; static let all: [WelcomeFeature] }`, and the `AppIconImage` image asset.

- [ ] **Step 1: Write the failing test**

Create `WatchtowerMobile/Tests/WelcomeTests.swift`:

```swift
import UIKit
import XCTest
@testable import WatchtowerMobile

/// Design pass O1: Welcome shows the app icon and three lines on what the
/// phone does.
final class WelcomeTests: XCTestCase {
    func testTheAppIconImageShipsInTheAssetCatalog() {
        XCTAssertNotNil(UIImage(named: "AppIconImage"), "the drawable copy of the app icon")
    }

    func testWelcomeNamesThreeThingsThePhoneDoes() {
        XCTAssertEqual(WelcomeFeature.all.map(\.symbol), ["questionmark.bubble", "terminal", "calendar"])
        XCTAssertEqual(
            WelcomeFeature.all.map(\.text),
            ["Answer your agents' asks", "Follow and start sessions", "Record and recap meetings"]
        )
    }
}
```

- [ ] **Step 2: Regenerate and run, expect a compile failure**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=WelcomeTests > build/mobile-logs/t11.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=`, with `cannot find 'WelcomeFeature' in scope`.

- [ ] **Step 3: The image asset**

From the worktree root, run:

```bash
mkdir -p WatchtowerMobile/Sources/Assets.xcassets/AppIconImage.imageset
cp WatchtowerMobile/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png \
  WatchtowerMobile/Sources/Assets.xcassets/AppIconImage.imageset/AppIconImage.png
```

Create `WatchtowerMobile/Sources/Assets.xcassets/AppIconImage.imageset/Contents.json`:

```json
{
  "images" : [
    {
      "filename" : "AppIconImage.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

An app icon set cannot be drawn as an image, so the copy is needed. The view draws it resizable at 72 pt.

- [ ] **Step 4: The view**

In `WelcomeView.swift`, before `struct WelcomeView`, add:

```swift
/// One line of Welcome's "what the phone does" (design pass O1).
struct WelcomeFeature: Equatable {
    let symbol: String
    let text: String

    static let all = [
        WelcomeFeature(symbol: "questionmark.bubble", text: "Answer your agents' asks"),
        WelcomeFeature(symbol: "terminal", text: "Follow and start sessions"),
        WelcomeFeature(symbol: "calendar", text: "Record and recap meetings")
    ]
}
```

Replace `WelcomeView.body` (lines 38-83) with:

```swift
    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.page) {
                Spacer()
                Image("AppIconImage")
                    .resizable()
                    .frame(width: 72, height: 72)
                    // The app icon's own corner (O1), not a card radius.
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                VStack(spacing: Spacing.regular) {
                    Text("Watchtower")
                        .font(.largeTitle.bold())
                    Text("Your Mac's Watchtower on this iPhone: asks, sessions, the board and your meetings.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(WelcomeFeature.all, id: \.text) { feature in
                        FlatRow(icon: .symbol(feature.symbol, tone: .accent), title: feature.text, insets: EdgeInsets()) {
                            EmptyView()
                        }
                    }
                }
                if let notice = linking.notice {
                    Text(notice.message)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .card(.plain)
                }
                Spacer()
                VStack(spacing: Spacing.medium) {
                    Text("On your Mac: Settings → Mobile → Use Watchtower on iPhone.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button {
                        linking.startScan()
                    } label: {
                        Label("Scan the code on your Mac", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    NavigationLink {
                        MacNotShowingView()
                    } label: {
                        Text("The Mac doesn't show up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
            .padding(.horizontal, Spacing.page)
            .padding(.vertical, Spacing.large)
        }
    }
```

- [ ] **Step 5: Regenerate, run, lint**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='WelcomeTests|LinkingViewModelTests' > build/mobile-logs/t11.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t11-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both. Then run `grep -n 'desktopcomputer.and.iphone\|quaternary' WatchtowerMobile/Sources/Features/Onboarding/WelcomeView.swift` and expect no output.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerMobile/Sources/Assets.xcassets/AppIconImage.imageset WatchtowerMobile/Sources/Features/Onboarding/WelcomeView.swift \
  WatchtowerMobile/Tests/WelcomeTests.swift WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj
git commit -m "feat(mobile): Welcome with the app icon, three feature lines and the notice as a card (O1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot check (at the gate): 28 shows the app icon (72 pt, rounded), "Watchtower", the description, three rows with blue icons, the hint, and the Scan button.

---

### Task 12: The link steps while checking and waiting, with the 20 s hint (O2)

**Depends on:** Task 11 (both edit `WelcomeView.swift`).

**Files:**
- Create: `Sources/Features/Onboarding/LinkSteps.swift`
- Modify: `Sources/Features/Onboarding/LinkingViewModel.swift:157` (`phase` gets a `didSet`; new `phaseStartedAt`)
- Modify: `Sources/Features/Onboarding/WelcomeView.swift:17-22` (checking and waiting use the steps) and `:86-100` (`LinkProgressView` stays for unlinking only)
- Modify: `WatchtowerMobile/Tests/LinkingViewModelTests.swift` (two new tests), `WatchtowerMobile/Tests/ScreenshotTourTests.swift:248-253` (shots 30, 31 and a new 31b)
- Regenerate: `project.pbxproj`

**Interfaces:**
- Consumes: `StepRow`/`StepRow.State`, `TypeScale.meta`, `Spacing.page`/`regular`; `LinkClock.now()`.
- Produces:
  - `LinkingViewModel.phaseStartedAt: Date?`, set from the flow's clock on every change of `phase`.
  - `struct LinkStepsModel: Equatable { struct Step: Equatable { let state: StepRow.State; let text: String }; static let hintDelay: TimeInterval; static let hintText: String; let steps: [Step]; let hint: String?; init(waitingFor macName: String?, startedAt: Date?, now: Date) }`. A nil `macName` means checking.
  - `struct LinkStepsView: View { let model: LinkStepsModel }`.

- [ ] **Step 1: Write the failing tests**

In `LinkingViewModelTests.swift`, after `testACodeArrivingMidLinkIsIgnored`, add:

```swift
    /// Design pass O2: every phase change stamps when it started, on the
    /// flow's clock; the waiting screen's hint reads it.
    func testEveryPhaseChangeStampsWhenItStarted() async throws {
        let model = makeModel()
        XCTAssertNil(model.phaseStartedAt, "nothing has started yet")
        model.startScan()
        XCTAssertEqual(model.phaseStartedAt, start)
        clock.advance(by: 5)
        model.dismiss()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.phaseStartedAt, start.addingTimeInterval(5))

        clock.parked = true
        let flow = Task { await model.open(code().url()) }
        try await poll { model.phase == .waiting(macName: "Acme Mac") }
        XCTAssertEqual(model.phaseStartedAt, clock.now(), "the wait starts when it is shown")
        flow.cancel()
        await flow.value
    }

    /// Design pass O2 and review focus 5: checking makes step 1 current;
    /// waiting makes it done and step 2 current; the hint appears after 20 s
    /// of waiting, never before (a start stamped in the future included);
    /// an empty Mac name reads "your Mac".
    func testTheLinkStepsFollowThePhaseAndHintAfterTwentySeconds() {
        let checking = LinkStepsModel(waitingFor: nil, startedAt: start, now: start.addingTimeInterval(60))
        XCTAssertEqual(checking.steps.map(\.state), [.current, .todo, .todo])
        XCTAssertEqual(checking.steps.map(\.text), ["Code read", "Waiting for your Mac to confirm", "Linked"])
        XCTAssertNil(checking.hint, "no hint while checking")

        let waiting = LinkStepsModel(waitingFor: "Acme Mac", startedAt: start, now: start.addingTimeInterval(19))
        XCTAssertEqual(waiting.steps.map(\.state), [.done, .current, .todo])
        XCTAssertEqual(waiting.steps[1].text, "Waiting for Acme Mac to confirm")
        XCTAssertNil(waiting.hint)
        let late = LinkStepsModel(waitingFor: "Acme Mac", startedAt: start, now: start.addingTimeInterval(20))
        XCTAssertEqual(late.hint, "Keep Settings → Mobile open on the Mac.")

        XCTAssertNil(LinkStepsModel(waitingFor: "Acme Mac", startedAt: start.addingTimeInterval(30), now: start).hint, "a future start")
        XCTAssertNil(LinkStepsModel(waitingFor: "Acme Mac", startedAt: nil, now: start).hint)
        XCTAssertEqual(LinkStepsModel(waitingFor: "", startedAt: nil, now: start).steps[1].text, "Waiting for your Mac to confirm")
    }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=LinkingViewModelTests > build/mobile-logs/t12.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=`, with `value of type 'LinkingViewModel' has no member 'phaseStartedAt'`.

- [ ] **Step 3: The stamp**

In `LinkingViewModel.swift`, replace `private(set) var phase: Phase = .idle` (line 157) with:

```swift
    private(set) var phase: Phase = .idle {
        didSet {
            if phase != oldValue { phaseStartedAt = clock.now() }
        }
    }
    /// When `phase` last changed, on the flow's clock; nil before the first
    /// change. The waiting screen's hint reads it (design pass O2).
    private(set) var phaseStartedAt: Date?
```

`@Observable` keeps property observers, as `DeviceSettings.newAskAlerts` already relies on.

- [ ] **Step 4: The steps model and view**

Create `Sources/Features/Onboarding/LinkSteps.swift`:

```swift
import SwiftUI

/// The link's three steps while the phone checks a code and waits for the
/// Mac (design pass O2): "Code read", "Waiting for <Mac> to confirm",
/// "Linked". Checking makes step 1 current; waiting makes it done and step
/// 2 current. After 20 s of waiting, a hint says to keep the Mac's Settings
/// open.
struct LinkStepsModel: Equatable {
    struct Step: Equatable {
        let state: StepRow.State
        let text: String
    }

    static let hintDelay: TimeInterval = 20
    static let hintText = "Keep Settings → Mobile open on the Mac."

    let steps: [Step]
    let hint: String?

    /// `macName` nil: checking the code. A name: waiting for that Mac's
    /// grant since `startedAt`.
    init(waitingFor macName: String?, startedAt: Date?, now: Date) {
        guard let macName else {
            steps = [
                Step(state: .current, text: "Code read"),
                Step(state: .todo, text: "Waiting for your Mac to confirm"),
                Step(state: .todo, text: "Linked")
            ]
            hint = nil
            return
        }
        let name = macName.isEmpty ? "your Mac" : macName
        steps = [
            Step(state: .done, text: "Code read"),
            Step(state: .current, text: "Waiting for \(name) to confirm"),
            Step(state: .todo, text: "Linked")
        ]
        let waited = startedAt.map { now.timeIntervalSince($0) } ?? 0
        hint = waited >= Self.hintDelay ? Self.hintText : nil
    }
}

/// The steps as `StepRow`s, with the hint under them.
struct LinkStepsView: View {
    let model: LinkStepsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach(Array(model.steps.enumerated()), id: \.offset) { _, step in
                StepRow(state: step.state, text: step.text)
            }
            if let hint = model.hint {
                // Under the step text: the 22 pt icon column plus its 12 pt gap.
                Text(hint)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
            }
        }
        .padding(.horizontal, Spacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

In `WelcomeView.swift`, in `OnboardingView.body`, replace the `.checking` and `.waiting` cases (lines 17-20) with:

```swift
        case .checking:
            LinkStepsScreen(macName: nil)
        case let .waiting(macName):
            LinkStepsScreen(macName: macName)
```

After `OnboardingView`, add:

```swift
/// O2's steps, re-read every second so the 20 s hint appears on time.
private struct LinkStepsScreen: View {
    @Environment(LinkingViewModel.self) private var linking
    let macName: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            LinkStepsView(model: LinkStepsModel(waitingFor: macName, startedAt: linking.phaseStartedAt, now: context.date))
        }
    }
}
```

Change `LinkProgressView`'s doc comment (line 86) to `/// Unlinking: a spinner and its line.`

- [ ] **Step 5: The tour**

In `ScreenshotTourTests.onboardingShots()`, replace shots 30 and 31 (lines 248-253) with:

```swift
            Shot(number: "30", slug: "checking", source: source + "LinkSteps.swift", reached: .leaf, make: leaf { _ in
                LinkStepsView(model: LinkStepsModel(waitingFor: nil, startedAt: nil, now: Date()))
            }),
            Shot(number: "31", slug: "waiting", source: source + "LinkSteps.swift", reached: .leaf, make: leaf { _ in
                LinkStepsView(model: LinkStepsModel(waitingFor: mac, startedAt: Date(), now: Date()))
            }),
            Shot(number: "31b", slug: "waiting-hint", source: source + "LinkSteps.swift", reached: .leaf, make: leaf { _ in
                LinkStepsView(model: LinkStepsModel(waitingFor: mac, startedAt: Date().addingTimeInterval(-25), now: Date()))
            }),
```

The tour now writes 84 PNGs.

- [ ] **Step 6: Regenerate, run, lint**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='LinkingViewModelTests|ScreenshotTourTests|AppRootWiringTests' > build/mobile-logs/t12.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t12-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Onboarding WatchtowerMobile/Tests/LinkingViewModelTests.swift \
  WatchtowerMobile/Tests/ScreenshotTourTests.swift WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj
git commit -m "feat(mobile): link steps while checking and waiting, with a hint after 20 s (O2)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate): 30 shows a spinner on "Code read" and two grey circles. 31 shows a green check on "Code read" and a spinner on "Waiting for Acme Mac to confirm". 31b adds "Keep Settings → Mobile open on the Mac." under the steps.

---

### Task 13: A failure's title and hint, and a green Linked (O3, O5)

**Depends on:** Task 12 (both edit the onboarding files).

O4 (bug 11: the numbered Mac checklist) is already done. The gate checks it in shot 35.

**Files:**
- Modify: `Sources/Features/Onboarding/LinkingViewModel.swift:62-95` (`LinkFailure.title`, `hint`, `message`)
- Modify: `Sources/Features/Onboarding/LinkedView.swift:5-20` (Linked's icon), `:51-75` (`LinkFailureView`), `:77-106` (`LinkOutcomeLayout.tone`)
- Modify: `WatchtowerMobile/Tests/LinkingViewModelTests.swift:251-254` and a new test
- Modify: `docs/features/mobile-companion.md` (the "The scan" line)

**Interfaces:**
- Consumes: `TypeScale.screenTitle`, `PhoneTone`, `Spacing`.
- Produces: `LinkFailure.title: String` and `hint: String?`. `message` is "title — hint", except for `signIn` and `updateApp`, which keep today's text, and a case with no hint, where it is the title alone. `LinkOutcomeLayout(systemImage:tone:title:detail:actions:)`, with `tone: PhoneTone = .secondary`.

- [ ] **Step 1: Write the failing tests**

In `LinkingViewModelTests.testNoGrantWithinSixtySecondsShowsDidNotAnswer`, change the expected message (lines 251-254) to:

```swift
        XCTAssertEqual(
            LinkFailure.noAnswer.message,
            "Your Mac didn't answer — Keep Settings → Mobile open on the Mac and scan again",
            "title — hint (design pass O3)"
        )
```

After `testACodeArrivingMidLinkIsIgnored`, add:

```swift
    /// Design pass O3: every failure is a title over a hint; `message` stays
    /// "title — hint" for every other reader, and signIn and updateApp keep
    /// today's exact text. An iCloud failure without a reason has no hint.
    func testEveryFailureIsATitleOverAHint() {
        let expected: [(LinkFailure, String, String?)] = [
            (.expired, "This code expired", "Show a new code on the Mac"),
            (.signIn, "Sign in to iCloud on this iPhone", "Watchtower uses iCloud to reach your Mac"),
            (.cannotShare, "This Mac can't share with another Apple ID right now", "Show a new code on the Mac"),
            (.noAnswer, "Your Mac didn't answer", "Keep Settings → Mobile open on the Mac and scan again"),
            (.refused, "This code can't be used", "Show a new code on the Mac"),
            (.updateApp, "Update Watchtower on this iPhone", nil),
            (.iCloud("The network is offline"), "Couldn't reach iCloud", "The network is offline")
        ]
        for (failure, title, hint) in expected {
            XCTAssertEqual(failure.title, title, "\(failure)")
            XCTAssertEqual(failure.hint, hint, "\(failure)")
        }
        XCTAssertEqual(LinkFailure.signIn.message, "Sign in to iCloud on this iPhone to use Watchtower", "today's exact text")
        XCTAssertEqual(LinkFailure.updateApp.message, "Update Watchtower on this iPhone")
        for (failure, title, hint) in expected where failure != .signIn && failure != .updateApp {
            XCTAssertEqual(failure.message, "\(title) — \(hint ?? "")", "\(failure)")
        }
        XCTAssertNil(LinkFailure.iCloud("").hint, "an empty reason is no hint")
        XCTAssertEqual(LinkFailure.iCloud("").message, "Couldn't reach iCloud")
    }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=LinkingViewModelTests > build/mobile-logs/t13.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=`, with `value of type 'LinkFailure' has no member 'title'`.

- [ ] **Step 3: The model**

In `LinkingViewModel.swift`, replace `LinkFailure.message` (lines 73-83) with:

```swift
    /// What went wrong, as the failure screen's title (design pass O3).
    var title: String {
        switch self {
        case .expired: "This code expired"
        case .signIn: "Sign in to iCloud on this iPhone"
        case .cannotShare: "This Mac can't share with another Apple ID right now"
        case .noAnswer: "Your Mac didn't answer"
        case .refused: "This code can't be used"
        case .updateApp: "Update Watchtower on this iPhone"
        case .iCloud: "Couldn't reach iCloud"
        }
    }

    /// What to do about it, under the title; nil when the title says it all.
    var hint: String? {
        switch self {
        case .expired, .cannotShare, .refused: "Show a new code on the Mac"
        case .signIn: "Watchtower uses iCloud to reach your Mac"
        case .noAnswer: "Keep Settings → Mobile open on the Mac and scan again"
        case .updateApp: nil
        case let .iCloud(reason): reason.isEmpty ? nil : reason
        }
    }

    /// One line, "title — hint", for any reader other than the failure
    /// screen; signIn and updateApp keep their earlier text.
    var message: String {
        switch self {
        case .signIn: "Sign in to iCloud on this iPhone to use Watchtower"
        case .updateApp: title
        default: hint.map { "\(title) — \($0)" } ?? title
        }
    }
```

- [ ] **Step 4: The views**

In `LinkedView.swift`:
- In `LinkedView.body` (line 10), change the call to `LinkOutcomeLayout(systemImage: "checkmark.circle.fill", tone: .green, title: "Linked to \(macName)") {` (O5).
- In `LinkFailureView.body` (line 57), change the call to `LinkOutcomeLayout(systemImage: "exclamationmark.triangle", title: failure.title, detail: failure.hint) {` (O3).
- Replace `LinkOutcomeLayout` (lines 77-106) with:

```swift
/// An icon in its tone, a title, an optional detail line under it, and the
/// actions at the bottom.
private struct LinkOutcomeLayout<Actions: View>: View {
    let systemImage: String
    var tone: PhoneTone = .secondary
    let title: String
    var detail: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: Spacing.page) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(tone.color)
            VStack(spacing: Spacing.regular) {
                Text(title)
                    .font(TypeScale.screenTitle)
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(spacing: Spacing.medium) {
                actions
            }
        }
        .padding(.horizontal, Spacing.page)
        .padding(.vertical, Spacing.large)
    }
}
```

- [ ] **Step 5: The doc line**

In `docs/features/mobile-companion.md`, in "The scan" line, change `"Your Mac didn't answer — keep Settings → Mobile open on the Mac and scan again"` to `"Your Mac didn't answer — Keep Settings → Mobile open on the Mac and scan again"`. Then add one sentence at the end of the line: `The failure screen shows each failure's title with its hint under it (design pass O3); the waiting screen shows the three link steps and, after 20 s, "Keep Settings → Mobile open on the Mac." (O2).`

- [ ] **Step 6: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='LinkingViewModelTests|AppRootWiringTests' > build/mobile-logs/t13.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t13-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both. Then run `grep -rn 'failure.message' WatchtowerMobile/Sources` and expect no output: the failure screen reads title and hint, and `message` stays for other readers.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Onboarding WatchtowerMobile/Tests/LinkingViewModelTests.swift docs/features/mobile-companion.md
git commit -m "feat(mobile): a link failure as a title over its hint; a green Linked (O3, O5)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate): 33 shows "This code expired" in the screen title style with "Show a new code on the Mac" under it in grey. 34 shows a filled green check over "Linked to Acme Mac". 32 keeps its layout.

---

### Task 14: Delete the design-layer API that stays unused; final doc sweep

**Depends on:** Tasks 1–13.

**Files:**
- Modify: `Sources/DesignSystem/*.swift` (only what the sweep below finds unused)
- Modify: `WatchtowerMobile/Tests/DesignSystemTests.swift` (only if a value it asserts is deleted)
- Modify: `docs/features/mobile-companion.md` (the "Design layer (design pass)" paragraph, only if it names something deleted)

**Interfaces:**
- Consumes: everything Tasks 1–13 left in the design layer.
- Produces: the design layer with no member, enum case or parameter that nothing outside `Sources/DesignSystem/` uses. A parameter with a default counts as used only if some caller passes it. The expected deletions are `FlatRowIcon.none`, `RecordButton`'s `title:` and `size:` parameters, and `FlowRow`'s settable `lineSpacing`, which becomes a constant. Every other member listed in Step 1 has a caller after Tasks 1–13.

- [ ] **Step 1: List the callers**

From the worktree root, run:

```bash
cd WatchtowerMobile && for pattern in \
  'Spacing\.tight' 'Spacing\.small' 'Spacing\.compact' 'Spacing\.regular' 'Spacing\.medium' 'Spacing\.large' 'Spacing\.page' \
  'Radius\.chip' 'Radius\.row' 'RowInsets\.flat' 'RowInsets\.card' \
  'TypeScale\.screenTitle' 'TypeScale\.pageTitle' 'TypeScale\.sectionHeader' 'TypeScale\.rowTitle' 'TypeScale\.rowEmphasis' \
  'TypeScale\.meta' 'TypeScale\.kind' 'TypeScale\.time' 'TypeScale\.code' \
  'card(\.plain\|card()' 'card(\.waiting' 'card(\.highlighted\|card(card\.cardStyle' 'padding: EdgeInsets()' \
  'Pill(' 'style: \.neutral' 'monospaced: true' 'CountBadge(' 'FilterChip(' 'MetaLine(' 'MetaItem(' \
  'FlatRow(' 'icon: \.symbol\|\.symbol(' '\.session(tone' 'icon: \.none' 'titleLineLimit:' 'isDimmed:' \
  'RowDivider()' 'SectionHeader(' 'BottomActionBar' 'ProminentActionStyle()' \
  'RecordButton' 'RecordButton(title' 'RecordButton(.*size:' 'fillsWidth: true' \
  'SessionDot(' 'ThinProgressBar(' 'height: 3' 'StepRow(' 'state: \.waiting' 'state: \.failed' 'FlowRow' 'lineSpacing:' \
  'PriorityDot(' 'PriorityMark\.' 'TargetStatusStyle\.' 'CompactAge\.'; do
  printf '%4s  %s\n' "$(grep -rn -- "$pattern" Sources | grep -v '^Sources/DesignSystem/' | wc -l | tr -d ' ')" "$pattern"
done > ../build/mobile-logs/t14-callers.txt; echo "exit=$?"
```

Read `build/mobile-logs/t14-callers.txt`. Expect `0` for `icon: \.none`, `RecordButton(title`, `RecordButton(.*size:` and `lineSpacing:`, and at least `1` everywhere else. If any other line reads `0`, read its matches by hand before deleting: a member used only inside another design-layer member that has callers stays.

- [ ] **Step 2: Delete what is unused**

For the expected deletions:
- In `FlatRow.swift`, delete `case none` from `FlatRowIcon` and the `case .none:` branch (with its `Color.clear.frame(width: 0, height: 0)`) from `FlatRow.iconView`.
- In `Bars.swift`, replace `RecordButton`'s stored properties and body with the following. Every caller uses "Record" at the 44 pt `.large` size.

```swift
struct RecordButton: View {
    var fillsWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Record", systemImage: "record.circle")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(PhoneTone.red.color)
        .controlSize(.large)
    }
}
```

  Add a line to its doc comment: `/// Always "Record" at the 44 pt large size (Now, the agenda, event detail).`
- In `Parts.swift`, no caller sets `FlowRow`'s line spacing, so change `var lineSpacing: CGFloat = 4` to `let lineSpacing: CGFloat = 4`. The memberwise init then takes only `spacing:`. The static `FlowRow.arrange(sizes:maxWidth:spacing:lineSpacing:)` keeps its parameter, which `DesignSystemTests` passes.

For anything else Step 1 shows as unused, delete it the same way, together with its doc comment and any `DesignSystemTests` assertion on its value.

- [ ] **Step 3: Doc sweep**

Run `grep -n 'FlatRowIcon\|RecordButton(title\|EventPillView\|LinkProgressView\|recordingsPill\|Record this meeting' docs/features/mobile-companion.md WatchtowerMobile/Sources`. Expect only `LinkProgressView` in `WelcomeView.swift`, which unlinking still uses. Fix any doc line that still names something this plan removed. The "Design layer (design pass)" paragraph names only types, which all remain.

- [ ] **Step 4: Regenerate, run, lint**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='DesignSystemTests|CalendarWiringTests|NowWiringTests|OrangeToneTests' > build/mobile-logs/t14.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t14-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both. `git diff --stat -- WatchtowerMobile/WatchtowerMobile.xcodeproj` shows no change, because no file was added or removed.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerMobile/Sources/DesignSystem WatchtowerMobile/Tests/DesignSystemTests.swift docs/features/mobile-companion.md
git commit -m "chore(mobile): drop the design-layer API no screen uses (FlatRowIcon.none, RecordButton title and size, FlowRow lineSpacing)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Phase 5 gate and the pre-PR checks

Run this once, by the controller, after Task 14.

- [ ] **Load check.** Run `bash scripts/dev-health.sh`. If its last line is `HEALTH: overloaded`, stop and report.
- [ ] **Full phone suite.** Run `make mobile-test SIM="iPhone 17 Pro" > build/mobile-logs/gate5-test.log 2>&1; echo "exit=$?"`. Expect `exit=0`.
- [ ] **Full lint.** Run `make lint-all > build/mobile-logs/gate5-lint.log 2>&1; echo "exit=$?"`. Expect `exit=0`, or only the recorded pre-existing Go issues, confirmed by `make lint-diff`.
- [ ] **After shots.** Run `make mobile-shots SIM="iPhone 17 Pro" SHOTS_DIR=build/mobile-shots/after-phase-5 > build/mobile-logs/gate5-shots.log 2>&1; echo "exit=$?"`. Expect `exit=0` and 84 PNGs (31b is new).
- [ ] **Compare by eye** against `after-phase-4/` and `after-phase-2/`, light and dark:
  - 27: SET2 and SET3, with bug 10's one row intact.
  - 28: O1. 30, 31 and 31b: O2. 33: O3. 34: O5. 32: unchanged (O5). 35: bug 11's numbered steps intact (O4).
  - 01, 03 and 20: the Record buttons are unchanged by Task 14.
  - Every screen, both modes: no uppercase label, no monospaced label, no card inside a card, and orange only on waiting and ask elements.

  Fix any regression in a `fix(mobile): …` commit, then re-run the suites for the touched classes.
- [ ] **Pre-PR gate** (before this branch goes to a PR): run each in the foreground to its own log with `echo "exit=$?"`. Run `make test`, then `make test-swift` (which includes the Kit), then `make lint-all`, then the full `make mobile-test SIM="iPhone 17 Pro"`. Expect `exit=0` for all four, with lint judged as at the phase gates. Then run `make hooks` once if this clone has no pre-push hook, so the push runs `scripts/leak-check.sh` over the branch's commits.

---

**Next:** the PR for the design pass. The spec's §8 lists what stays out of it, and no spec phase is left after this plan.
