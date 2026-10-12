# Mobile design pass, Phases 1–2 (design layer, the 11 bugs, Now and Workbench) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iPhone app look like the Mac app on a phone, for the design layer, the eleven layout bugs, Now and the Workbench screens. No new features and no data change.

**Architecture:** A screenshot tour (`make mobile-shots`) comes first, so a "before" set exists. A new `Sources/DesignSystem/` layer names the Mac's values: tones, metrics, type scale, status glyphs, the priority dot, card, pill, flat row, bars and small parts. The screens then use only that layer. Every colour still comes from a screen model as a `PhoneTone` with a `ToneRole`, so `OrangeToneTests` keeps sweeping it. SwiftLint now also forbids orange inside the design layer.

**Tech Stack:** SwiftUI and UIKit (iOS 17+, Swift 5.10 language mode), the xcodegen project `WatchtowerMobile/project.yml` with its generated `.xcodeproj` committed, XCTest in `WatchtowerMobileTests`, SwiftLint `--strict`.

**Spec:** `docs/superpowers/specs/2026-10-11-mobile-design-pass-design.md` (approved; its §9 defaults stand). Read it beside this plan. Section references below (§2.5, bug 7, N4, …) point into it. Paths are relative to `WatchtowerMobile/Sources/` unless they start with another top-level directory.

## Global Constraints

- **Scope.** Phases 1 and 2 of the spec only (§4 Phase 1, Phase 2, §5, and the §7 docs that belong to them). Asks A1–A7, Calendar/Recording/Recap C1–C7, Settings SET2–SET4 and Onboarding O1–O5 belong to the next plan, except where a Phase 1 bug touches those screens.
- **Binding decisions (ask #32).** Direction A, "Mac one-to-one": dense flat rows, cards only for "Waiting for you" and detail blocks. **No card inside a card.** Medium priority has no dot; only high (red) and low (blue) do. Orange is only for waiting-for-you and ask elements. The More tab goes; Settings is a gear in Now's toolbar, and the voice note stays the Calendar's mic button.
- **§9 defaults.** (1) A session draws the dot only, everywhere; the `glyph` field stays in the models. (2) The calendar scrolls the highlighted meeting to the middle on appear and on every day change; with none it stays at the top. (3) Now, the Workbench list, Sessions, Board, Recordings and session detail use `Color(.systemBackground)` with flat rows; forms stay `insetGrouped`. (4) "N closed" on a session row is the last meta item. (5) The `UITabBarAppearance` badge colour lands even if a device already shows orange.
- **Visual language.** Use semantic SwiftUI colours, Dynamic Type and SF Symbols. The accent stays system blue: no AccentColor asset, no new SF Symbol assets. Monospaced fonts are only for counts, times, keys and code. Labels are never uppercase or monospaced ("Question", not "ASK"). `largeTitle` is only for onboarding and empty states. Emphasis is semibold. Meta lines use `.caption`; `.caption2` is only for badges and pills.
- **No new features, and no wire, Kit, replica or Mac change.** Every screen keeps its strings, routes and contracts unless a spec item says otherwise. The project gets no snapshot library and no pixel-diff assertions.
- **Orange rule.** Only `Sources/DesignSystem/PhoneTone.swift` may name `.orange` or `systemOrange` under `Sources/Features/` and `Sources/DesignSystem/`; SwiftLint `orange_outside_phone_tone` enforces this. `OrangeToneTests` stays green and its assertions are never weakened. Each new `ToneUse` goes into its model's `toneUses`.
- **Project file.** After adding, moving or deleting any file under `Sources/` or `Tests/`, run `make mobile-gen` and commit `WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj` with the change. Never hand-edit the `.xcodeproj`.
- **Per-task checks** (CLAUDE.md "Agent-driven runs"): `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=<Class>` for the touched suites (`MOBILE_FILTER='A|B'` runs several), plus `make lint-swift`. This machine's simulator is `iPhone 17 Pro`; the Makefile default `iPhone 18 Pro` is not installed, so always pass `SIM`. The full `make mobile-test SIM="iPhone 17 Pro"` and `make lint-all` run once per phase, at the phase gate, never per task. Desktop and Kit sources do not change, so `make test-swift` belongs only to the pre-PR gate.
- **How to run.** Run every build and test in the foreground, to a log with an explicit exit code: `mkdir -p build/mobile-logs; <cmd> > build/mobile-logs/<task>.log 2>&1; echo "exit=$?"`, then read the log's tail. No `run_in_background`, no `sleep`/`tail` polling turns. `build/` is gitignored.
- **Lint traps** (`WatchtowerMobile/.swiftlint.yml`, `--strict` turns warnings into errors): `implicit_return` (a single-expression body has no `return`), `force_unwrapping`, `function_body_length` 80, `closure_body_length`, `cyclomatic_complexity` 15, `line_length` 150.
- **House rules.** Before hand-back, self-review against the "Swift / Desktop conventions" section of `docs/review/review-rules.md` and §§ 3, 5, 7, 8 of the same file. Views paint only model tones; pure logic sits in models or small value types with unit tests; no new `@Observable` view model.
- **Public repo.** Use only the demo seed's neutral names (Acme, "Acme Mac", "Colleague A"): no real names, ids, emails or local absolute paths. Docs are in English.
- **Commits.** One commit per task, at the end, after its checks pass. End every message with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

These five inputs are implied by the spec but no spec-listed test exercises them. Each is the most likely to bite a person. Every line has a test in the task that owns the code.

1. **An end shot of a screen that fits.** After Phase 2, Now ends above the tab bar at rest (bug 1), so `01e` has no taller scroll view. The tour must still write `01e` (the screen at rest) and must not fail its file count. Covered by `testTheEndVariantFindsOnlyAScrollViewTallerThanItsBounds`, Task 1.
2. **A meta line too long for one line** (a long session caption, a PR line, "3 closed"). Every item stays on one line, and the last item truncates first (§9.4), so it must be last. Covered by `testTheMetaLineIsCaptionThenReportThenPRThenClosed`, Task 14.
3. **A review document without the happy shape:** no headings, an empty text, a last heading with no trailing newline, a nested list item ("    • "). The styled string must still equal `document.text`, and the hanging indent must include the nesting spaces. Covered by `testEdgeDocumentsKeepTheirTextAndIndentNestedItems`, Task 7.
4. **A chip wider than the screen** (a 120-character branch in session detail), and an empty `FlowRow`. The chip gets a line of its own at the row's width and truncates; it never overflows. The empty row takes no height. Covered by `testFlowRowWrapsClampsAndCollapses`, Task 4.
5. **A calendar day with nothing to highlight** (not today, or every meeting is over). There is no scroll, and the agenda stays at the top (§9.2). Covered by `testOnlyTodaysCurrentOrNextMeetingIsScrolledTo`, Task 9.

---

## File map

New files:

| File | Responsibility | Task |
|---|---|---|
| `WatchtowerMobile/Tests/Support/ScreenshotHost.swift` | Render a view to light and dark PNGs; end variant; INDEX.md | 1 |
| `WatchtowerMobile/Tests/ScreenshotTourTests.swift` | The tour table, the opt-in tour test, the end-variant unit test | 1 |
| `Sources/DesignSystem/PhoneTone.swift` | Moved from `Features/Workbench/`, plus `teal` and `gray` | 2 |
| `Sources/DesignSystem/Metrics.swift` | `Spacing`, `Radius`, `RowInsets` | 2 |
| `Sources/DesignSystem/TypeScale.swift` | The type scale | 2 |
| `WatchtowerMobile/Tests/DesignSystemTests.swift` | Tones, scale, status table, priority, card paints, `FlowRow` | 2–4 |
| `Sources/DesignSystem/TargetStatusStyle.swift` | Status glyph and tone (Mac model table) | 3 |
| `Sources/DesignSystem/PriorityDot.swift` | `PriorityMark`, `PriorityDot` | 3 |
| `Sources/DesignSystem/Card.swift` | `CardStyle`, `Card`, `View.card(_:padding:)` | 4 |
| `Sources/DesignSystem/Pill.swift` | `Pill`, `CountBadge`, `FilterChip` | 4 |
| `Sources/DesignSystem/FlatRow.swift` | `MetaItem`, `MetaLine`, `FlatRowIcon`, `FlatRow`, `RowDivider`, `SectionHeader` | 4 |
| `Sources/DesignSystem/Parts.swift` | `SessionDot`, `ThinProgressBar` (moved), `StepRow`, `FlowRow` | 4 |
| `Sources/DesignSystem/Bars.swift` | `BottomActionBar`, `ProminentActionStyle`, `RecordButton` | 5 |
| `Sources/Features/Asks/ReviewDocumentStyler.swift` | Bug 7 attributes over `PlainTextDocument` | 7 |
| `WatchtowerMobile/Tests/ReviewDocumentStylerTests.swift` | Bug 7 tests | 7 |
| `Sources/Features/Recording/RecorderChrome.swift` | Bug 9 phase → mark and controls | 8 |
| `Sources/Features/Settings/MacStatusRow.swift` | Bug 10 one-row Mac status | 10 |

Modified files by task are listed in each task.

---

## Phase 1: the design layer and the 11 bugs

### Task 1: The screenshot tour (`make mobile-shots`) and the before set

**Depends on:** none.

**Files:**
- Create: `WatchtowerMobile/Tests/Support/ScreenshotHost.swift`
- Create: `WatchtowerMobile/Tests/ScreenshotTourTests.swift`
- Modify: `Makefile` (the `.PHONY` list at line 37, a new `mobile-shots` target after `mobile-run`)
- Modify: `Sources/Features/Workbench/WorkbenchView.swift:25-29` (an initial-segment parameter, so the tour can render Board)
- Modify: `Sources/Features/Recordings/RecapView.swift:7-15` (an initial-tab parameter, so the tour can render Transcript)
- Modify: `docs/features/mobile-companion.md` ("Building and testing")
- Regenerate: `WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `AppRoot.demo(_:defaults:)`, `AppEnvironment.init(transport:replicaPath:transportKind:defaults:recordingsDirectory:makeRecorder:)`, `AppEnvironment.isBootstrapped`, `stop()`, `navigation`, `workbenchReplica`, `calendarReplica`, `phoneRecordings`, `recorder`; `FakeAudioEngine`, `FakeClock`, `makeReplicaPath()`, `makeDefaults()`, `makeRecordingsDirectory()`, `poll(timeout:_:_:)` from `Tests/Support/`.
- Produces:
  - `ScreenshotHost(directory: URL, env: AppEnvironment, linking: LinkingViewModel)` with `func capture(_ name: String, _ view: some View, endName: String? = nil) async throws`.
  - `static func tallScrollView(in root: UIView) -> UIScrollView?`, `static func endOffset(of scroll: UIScrollView) -> CGFloat`.
  - `static func clear(_ directory: URL) throws`, `static func writeIndex(_ rows: [IndexRow], to directory: URL) throws`, `struct IndexRow { number, view, source, reached }`.
  - `ScreenshotTourTests.Shot` and the tables `workbenchShots()`, `calendarShots()`, `onboardingShots()`. Task 12 removes row 04 from `workbenchShots()`.
  - `WorkbenchView.init(replica:writer:workbenchID:segment:)` with `segment: Segment = .sessions`.
  - `RecapView.init(transcriptID:initialTab:)` with `initialTab: Tab = .recap`.

- [ ] **Step 1: Write the failing end-variant test**

Create `WatchtowerMobile/Tests/ScreenshotTourTests.swift` with only this test for now:

```swift
import SwiftUI
import UIKit
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The design pass's screenshot tour (design pass spec §6.2): every screen
/// of the demo seed rendered to PNGs in light and dark mode, for a
/// before/after comparison by eye. Opt-in: `make mobile-shots` sets
/// WATCHTOWER_SHOTS_DIR, and every other run reports the tour skipped. It
/// asserts no pixels, only that every file was written.
@MainActor
final class ScreenshotTourTests: XCTestCase {
    /// Review focus 1: an end shot finds only a scroll view taller than its
    /// bounds; a screen that fits has none, and its end shot is the screen
    /// at rest.
    func testTheEndVariantFindsOnlyAScrollViewTallerThanItsBounds() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let fits = UIScrollView(frame: root.bounds)
        fits.contentSize = CGSize(width: 100, height: 80)
        root.addSubview(fits)
        XCTAssertNil(ScreenshotHost.tallScrollView(in: root), "content that fits has no end to scroll to")

        let tall = UIScrollView(frame: root.bounds)
        tall.contentSize = CGSize(width: 100, height: 300)
        fits.addSubview(tall)
        XCTAssertTrue(ScreenshotHost.tallScrollView(in: root) === tall)
        XCTAssertEqual(ScreenshotHost.endOffset(of: tall), 200)
    }
}
```

- [ ] **Step 2: Regenerate and run, expect a compile failure**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=ScreenshotTourTests > build/mobile-logs/t1.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild), with `cannot find 'ScreenshotHost' in scope` in the log.

- [ ] **Step 3: Write `ScreenshotHost`**

Create `WatchtowerMobile/Tests/Support/ScreenshotHost.swift`:

```swift
import SwiftUI
import UIKit
@testable import WatchtowerMobile

/// Renders a SwiftUI screen to PNGs in light and dark mode, in a window on
/// the test host's scene at the simulator's screen size and scale (design
/// pass spec §6.2). `drawHierarchy` does not draw the system's scroll-edge
/// effect, so content under the tab bar shows as plain text.
@MainActor
final class ScreenshotHost {
    /// One INDEX.md row: the screen's number, the view, its source file and
    /// how the tour reached it.
    struct IndexRow {
        let number: String
        let view: String
        let source: String
        let reached: String
    }

    enum ShotError: Error {
        case noWindowScene
        case emptyImage(String)
    }

    let directory: URL
    let env: AppEnvironment
    let linking: LinkingViewModel

    init(directory: URL, env: AppEnvironment, linking: LinkingViewModel) {
        self.directory = directory
        self.env = env
        self.linking = linking
    }

    /// Writes `<name>-light.png` and `<name>-dark.png`; with `endName`, also
    /// `<endName>-light.png` and `-dark.png` scrolled to the end.
    func capture(_ name: String, _ view: some View, endName: String? = nil) async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw ShotError.noWindowScene
        }
        for (style, suffix) in [(UIUserInterfaceStyle.light, "light"), (UIUserInterfaceStyle.dark, "dark")] {
            let window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
            window.overrideUserInterfaceStyle = style
            window.rootViewController = UIHostingController(rootView: view.environment(env).environment(linking))
            window.makeKeyAndVisible()
            // Replica observation and layout settle.
            try await Task.sleep(for: .milliseconds(600))
            try render(window, as: "\(name)-\(suffix)")
            if let endName {
                // Content that fits has no end to scroll to: the end shot is
                // the screen at rest.
                if let scroll = Self.tallScrollView(in: window) {
                    scroll.contentOffset.y = Self.endOffset(of: scroll)
                    try await Task.sleep(for: .milliseconds(300))
                }
                try render(window, as: "\(endName)-\(suffix)")
            }
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// The first scroll view, breadth first, whose content is taller than
    /// its bounds.
    static func tallScrollView(in root: UIView) -> UIScrollView? {
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
                return scroll
            }
            queue += view.subviews
        }
        return nil
    }

    /// The offset that shows the end of `scroll`'s content above its bottom
    /// inset.
    static func endOffset(of scroll: UIScrollView) -> CGFloat {
        scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
    }

    /// Removes an earlier run's PNGs and index, so the file count is this
    /// run's.
    static func clear(_ directory: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == "png" || file.lastPathComponent == "INDEX.md" {
            try files.removeItem(at: file)
        }
    }

    static func writeIndex(_ rows: [IndexRow], to directory: URL) throws {
        let lines = ["# Screenshot tour", "", "| No. | View | Source | Reached |", "|---|---|---|---|"]
            + rows.map { "| \($0.number) | \($0.view) | `\($0.source)` | \($0.reached) |" }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("INDEX.md"), atomically: true, encoding: .utf8)
    }

    private func render(_ window: UIWindow, as name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData(), !data.isEmpty else { throw ShotError.emptyImage(name) }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
```

- [ ] **Step 4: Regenerate and run, expect a pass**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=ScreenshotTourTests > build/mobile-logs/t1.log 2>&1; echo "exit=$?"`
Expected: `exit=0`, with `testTheEndVariantFindsOnlyAScrollViewTallerThanItsBounds` passed.

- [ ] **Step 5: Add the two render seams**

In `Sources/Features/Workbench/WorkbenchView.swift`, replace the init (lines 25-29):

```swift
    /// `segment` is for the screenshot tour; the app always opens Sessions.
    init(replica: WorkbenchReplicaModel, writer: BoardWriter, workbenchID: Int64, segment: Segment = .sessions) {
        self.replica = replica
        self.writer = writer
        _workbenchID = State(initialValue: workbenchID)
        _segment = State(initialValue: segment)
    }
```

and change line 19 to `@State private var segment: Segment`.

In `Sources/Features/Recordings/RecapView.swift`, change line 11 to `@State private var tab: Tab` and add this after the stored properties (after line 15):

```swift
    /// `initialTab` is for the screenshot tour; the app always opens Recap.
    init(transcriptID: Int, initialTab: Tab = .recap) {
        self.transcriptID = transcriptID
        _tab = State(initialValue: initialTab)
    }
```

- [ ] **Step 6: Add the tour to `ScreenshotTourTests`**

Add these members to `ScreenshotTourTests`, above the end-variant test:

```swift
    /// One screen of the tour: its review number, a file-name slug, the
    /// source file, how it is reached, and whether it gets an end shot.
    struct Shot {
        enum Reached: String {
            case fullApp = "full app"
            case bareStack = "bare stack"
            case sheet
            case leaf = "leaf view"
        }

        let number: String
        let slug: String
        let source: String
        let reached: Reached
        var hasEnd = false
        let make: @MainActor (AppEnvironment) -> AnyView
    }

    func testTheTour() async throws {
        guard let path = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_DIR"] else {
            throw XCTSkip("Screenshot tour: run make mobile-shots")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try ScreenshotHost.clear(dir)
        let root = try makeDemoRoot()
        try await poll(timeout: 20, { Self.isHydrated(root.env) }, "the demo seed hydrated")
        let host = ScreenshotHost(directory: dir, env: root.env, linking: root.linking)
        let shots = Self.workbenchShots() + Self.calendarShots() + Self.onboardingShots()
        for shot in shots {
            let end = shot.hasEnd ? "\(shot.number)e-\(shot.slug)" : nil
            try await host.capture("\(shot.number)-\(shot.slug)", shot.make(root.env), endName: end)
        }
        let recorderRows = try await captureRecorder(into: dir, linking: root.linking)
        try ScreenshotHost.writeIndex(Self.indexRows(shots) + recorderRows, to: dir)

        let pngs = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "png" }
        XCTAssertEqual(pngs.count, 2 * (shots.count + shots.filter(\.hasEnd).count + recorderRows.count))
        for png in pngs {
            XCTAssertGreaterThan(try png.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0, png.lastPathComponent)
        }
    }

    // MARK: - The demo

    private func makeDemoRoot() throws -> AppRoot {
        let defaults = try makeDefaults()
        let root = AppRoot.demo(
            try AppEnvironment(
                transport: InMemoryCloudTransport(),
                replicaPath: try makeReplicaPath(),
                transportKind: .inMemoryDemo,
                defaults: defaults,
                recordingsDirectory: try makeRecordingsDirectory()
            ),
            defaults: defaults
        )
        addTeardownBlock { @MainActor in root.env.stop() }
        return root
    }

    private static func isHydrated(_ env: AppEnvironment) -> Bool {
        env.isBootstrapped && !env.workbenchReplica.snapshot.workbenches.isEmpty
            && !env.calendarReplica.snapshot.events.isEmpty && !env.phoneRecordings.snapshot.recordings.isEmpty
    }

    /// 26b–26d: the recorder over a fake engine and clock, recording,
    /// paused and saved. The demo environment's recorder never starts (no
    /// microphone on the simulator), so it shows 26 (idle) only.
    private func captureRecorder(into dir: URL, linking: LinkingViewModel) async throws -> [ScreenshotHost.IndexRow] {
        let engine = FakeAudioEngine()
        let clock = FakeClock()
        let env = try AppEnvironment(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            transportKind: .inMemoryDemo,
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory(),
            makeRecorder: { uploader in
                PhoneRecorderController(
                    uploader: uploader, engine: engine, notificationCenter: NotificationCenter(),
                    now: { clock.now }, tickInterval: nil
                )
            }
        )
        addTeardownBlock { @MainActor in env.stop() }
        try await poll(timeout: 20, { env.isBootstrapped }, "the recorder environment booted")
        let host = ScreenshotHost(directory: dir, env: env, linking: linking)
        let recorder = env.recorder
        await recorder.recordVoiceNote()
        for step in 0..<48 {
            engine.levelValue = Float(step % 8) / 8
            clock.advance(1)
            await recorder.tick()
        }
        try await host.capture("26b-recorder-recording", RecordingView())
        recorder.pause()
        try await host.capture("26c-recorder-paused", RecordingView())
        recorder.resume()
        clock.advance(60)
        await recorder.stop()
        try await host.capture("26d-recorder-saved", RecordingView())
        return ["26b", "26c", "26d"].map {
            ScreenshotHost.IndexRow(
                number: $0, view: "RecordingView", source: "Features/Recording/RecordingView.swift",
                reached: "leaf view, fake audio engine"
            )
        }
    }

    private static func indexRows(_ shots: [Shot]) -> [ScreenshotHost.IndexRow] {
        shots.flatMap { shot in
            let view = URL(fileURLWithPath: shot.source).deletingPathExtension().lastPathComponent
            let row = ScreenshotHost.IndexRow(number: shot.number, view: view, source: shot.source, reached: shot.reached.rawValue)
            let end = ScreenshotHost.IndexRow(number: "\(shot.number)e", view: view, source: shot.source, reached: "\(shot.reached.rawValue), scrolled to the end")
            return shot.hasEnd ? [row, end] : [row]
        }
    }

    // MARK: - How a screen is reached

    /// A tab of the full app, with the Calendar stack at `path`.
    private static func app(_ tab: RootTabView.Tab, path: [CalendarRoute] = []) -> @MainActor (AppEnvironment) -> AnyView {
        { env in
            env.navigation.tab = tab
            env.navigation.calendarPath = path
            return AnyView(RootTabView())
        }
    }

    /// A Workbench push (target, session, ask) or a pushed form, in a bare
    /// stack without the tab bar.
    private static func stack<Content: View>(
        _ content: @escaping @MainActor (AppEnvironment) -> Content
    ) -> @MainActor (AppEnvironment) -> AnyView {
        { env in AnyView(NavigationStack { content(env) }) }
    }

    /// A sheet (which owns its stack) or an onboarding leaf view.
    private static func leaf<Content: View>(
        _ content: @escaping @MainActor (AppEnvironment) -> Content
    ) -> @MainActor (AppEnvironment) -> AnyView {
        { env in AnyView(content(env)) }
    }

    // MARK: - The tour table (the review's screen numbers)

    static func workbenchShots() -> [Shot] {
        let acme = DemoSeed.acmeID
        let source = "Features/Workbench/"
        return [
            Shot(number: "01", slug: "now", source: "Features/Now/NowView.swift", reached: .fullApp, hasEnd: true, make: app(.now)),
            Shot(number: "02", slug: "workbench-list", source: source + "WorkbenchListView.swift", reached: .fullApp, make: app(.workbench)),
            Shot(number: "03", slug: "calendar", source: "Features/Calendar/AgendaView.swift", reached: .fullApp, hasEnd: true, make: app(.calendar)),
            Shot(number: "04", slug: "more", source: "App/RootTabView.swift", reached: .fullApp, make: app(.more)),
            Shot(number: "05", slug: "workbench-sessions", source: source + "WorkbenchView.swift", reached: .bareStack, make: stack {
                WorkbenchView(replica: $0.workbenchReplica, writer: $0.boardWriter, workbenchID: acme, segment: .sessions)
            }),
            Shot(number: "06", slug: "workbench-board", source: source + "BoardView.swift", reached: .bareStack, make: stack {
                WorkbenchView(replica: $0.workbenchReplica, writer: $0.boardWriter, workbenchID: acme, segment: .board)
            }),
            Shot(number: "07", slug: "target-415", source: source + "BoardTargetDetailView.swift", reached: .bareStack, hasEnd: true, make: stack {
                BoardTargetDetailView(replica: $0.workbenchReplica, writer: $0.boardWriter, targetID: 415)
            }),
            Shot(number: "08", slug: "target-400-group", source: source + "BoardTargetDetailView.swift", reached: .bareStack, make: stack {
                BoardTargetDetailView(replica: $0.workbenchReplica, writer: $0.boardWriter, targetID: 400)
            })
        ] + sessionShots() + askShots() + [
            Shot(number: "18", slug: "start-session", source: source + "StartSessionSheet.swift", reached: .sheet, make: leaf { _ in
                StartSessionSheet(workbenchID: acme, target: nil, fixed: false) { _ in }
            }),
            Shot(number: "19", slug: "new-target", source: source + "NewBoardTargetSheet.swift", reached: .sheet, make: leaf {
                NewBoardTargetSheet(replica: $0.workbenchReplica, writer: $0.boardWriter, workbenchID: acme)
            })
        ]
    }

    /// 09 waiting (asks, report, chips), 10 needs approval, 11 finished,
    /// 12 failed.
    static func sessionShots() -> [Shot] {
        [("09", 11, "waiting"), ("10", 12, "needs-approval"), ("11", 13, "finished"), ("12", 16, "failed")].map { number, id, slug in
            Shot(number: number, slug: "session-\(id)-\(slug)", source: "Features/Workbench/SessionDetailView.swift", reached: .bareStack, make: stack {
                SessionDetailView(replica: $0.workbenchReplica, sessionID: id, store: $0.store, requester: $0.reportRequests)
            })
        }
    }

    /// 13 question, 14 review, 15 check, 16 answered, 17 withdrawn.
    static func askShots() -> [Shot] {
        [("13", 109, "question"), ("14", 110, "review"), ("15", 111, "check"), ("16", 105, "answered"), ("17", 107, "withdrawn")]
            .map { number, id, slug in
                Shot(number: number, slug: "ask-\(id)-\(slug)", source: "Features/Asks/AskView.swift", reached: .bareStack, make: stack {
                    AskView(replica: $0.workbenchReplica, drafts: $0.askDrafts, answerer: $0.askAnswerer, askID: id)
                })
            }
    }

    static func calendarShots() -> [Shot] {
        let event = "Features/Calendar/EventDetailView.swift"
        return [
            Shot(number: "20", slug: "event-upcoming", source: event, reached: .fullApp, hasEnd: true,
                 make: app(.calendar, path: [.event("demo-evt-roadmap")])),
            Shot(number: "21", slug: "event-past-recap", source: event, reached: .fullApp, make: app(.calendar, path: [.event("demo-evt-standup")])),
            Shot(number: "22", slug: "event-phone-recording", source: event, reached: .fullApp,
                 make: app(.calendar, path: [.event(DemoSeed.recordedEventID)])),
            Shot(number: "23", slug: "recordings", source: "Features/Recordings/RecordingsListView.swift", reached: .fullApp,
                 make: app(.calendar, path: [.recordings])),
            Shot(number: "24", slug: "recap", source: "Features/Recordings/RecapView.swift", reached: .fullApp, make: app(.calendar, path: [.recap(501)])),
            Shot(number: "25", slug: "transcript", source: "Features/Recordings/RecapView.swift", reached: .bareStack, make: stack { _ in
                RecapView(transcriptID: 501, initialTab: .transcript)
            }),
            Shot(number: "26", slug: "recorder-idle", source: "Features/Recording/RecordingView.swift", reached: .leaf, make: leaf { _ in RecordingView() }),
            Shot(number: "27", slug: "settings", source: "Features/Settings/SettingsView.swift", reached: .bareStack, make: stack { _ in SettingsView() })
        ]
    }

    static func onboardingShots() -> [Shot] {
        let source = "Features/Onboarding/"
        let mac = DemoSeed.macName
        return [
            Shot(number: "28", slug: "welcome", source: source + "WelcomeView.swift", reached: .leaf, make: leaf { _ in WelcomeView() }),
            Shot(number: "29", slug: "scan", source: source + "ScanView.swift", reached: .leaf, make: leaf { _ in
                ScanView(onCode: { _ in }, onCancel: {})
            }),
            Shot(number: "30", slug: "checking", source: source + "WelcomeView.swift", reached: .leaf, make: leaf { _ in
                LinkProgressView(text: "Checking the code…")
            }),
            Shot(number: "31", slug: "waiting", source: source + "WelcomeView.swift", reached: .leaf, make: leaf { _ in
                LinkProgressView(text: "Waiting for \(mac) to confirm…")
            }),
            Shot(number: "32", slug: "switch-mac", source: source + "LinkedView.swift", reached: .leaf, make: leaf { _ in
                SwitchMacView(old: mac, new: "Acme Studio")
            }),
            Shot(number: "33", slug: "failure", source: source + "LinkedView.swift", reached: .leaf, make: leaf { _ in
                LinkFailureView(failure: .expired)
            }),
            Shot(number: "34", slug: "linked", source: source + "LinkedView.swift", reached: .leaf, make: leaf { _ in LinkedView(macName: mac) }),
            Shot(number: "35", slug: "mac-not-showing", source: source + "MacNotShowingView.swift", reached: .bareStack, make: stack { _ in
                MacNotShowingView()
            })
        ]
    }
```

If SwiftLint reports `line_length` on a table row, wrap that row's arguments one per line. Do not shorten the slugs.

- [ ] **Step 7: Add the make target**

In `Makefile`, append ` mobile-shots` to the `.PHONY` list (line 37), and add this after the `mobile-run` recipe:

```make
# The design pass's screenshot tour (WatchtowerMobile/Tests/ScreenshotTourTests.swift):
# every demo screen in light and dark mode as PNGs plus an INDEX.md, written
# to SHOTS_DIR (under the gitignored build/). Compare a before and an after
# set by eye; nothing asserts pixels. xcodebuild hands TEST_RUNNER_-prefixed
# variables to the test process with the prefix stripped.
SHOTS_DIR ?= build/mobile-shots
mobile-shots:
	xcrun simctl boot "$(SIM)" 2>/dev/null || true
	xcrun simctl uninstall "$(SIM)" $(MOBILE_BUNDLE_ID) 2>/dev/null || true
	mkdir -p "$(SHOTS_DIR)"
	TEST_RUNNER_WATCHTOWER_SHOTS_DIR="$(abspath $(SHOTS_DIR))" xcodebuild test -project $(MOBILE_PROJ) \
		-scheme WatchtowerMobile -destination '$(MOBILE_DEST)' CODE_SIGNING_ALLOWED=NO \
		-only-testing:WatchtowerMobileTests/ScreenshotTourTests
```

- [ ] **Step 8: Run the class, expect the tour skipped**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='ScreenshotTourTests|AppRootWiringTests' > build/mobile-logs/t1.log 2>&1; echo "exit=$?"`
Expected: `exit=0`. The log shows `testTheTour` as skipped ("Screenshot tour: run make mobile-shots") and the end-variant test as passed.

- [ ] **Step 9: Lint**

Run: `make lint-swift > build/mobile-logs/t1-lint.log 2>&1; echo "exit=$?"`
Expected: `exit=0`.

- [ ] **Step 10: Document the target**

In `docs/features/mobile-companion.md`, "Building and testing", add this bullet after the **Phone.** bullet:

```markdown
- **Screenshot tour.** `make mobile-shots SIM="<simulator>" SHOTS_DIR=build/mobile-shots/<set>` runs only `ScreenshotTourTests`: every demo screen (the review's numbers 01–35, end variants `01e`, `03e`, `07e`, `20e`, and the recorder's `26b`–`26d` over a fake audio engine) in light and dark mode, as PNGs plus an `INDEX.md` (number, view, source file, how it was reached). It asserts no pixels, only that every file was written; compare a before and an after set by eye. `make mobile-test` and CI never set `WATCHTOWER_SHOTS_DIR`, so the tour reports skipped there. Tabs and Calendar pushes render in the full app, Workbench pushes in a bare stack, sheets and onboarding leaf views on their own. `drawHierarchy` does not draw the scroll-edge effect, so content under the tab bar shows as plain text. Design pass spec: `docs/superpowers/specs/2026-10-11-mobile-design-pass-design.md` §6.2.
```

- [ ] **Step 11: Commit**

```bash
git add Makefile docs/features/mobile-companion.md WatchtowerMobile/Tests/ScreenshotTourTests.swift \
  WatchtowerMobile/Tests/Support/ScreenshotHost.swift WatchtowerMobile/Sources/Features/Workbench/WorkbenchView.swift \
  WatchtowerMobile/Sources/Features/Recordings/RecapView.swift WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj
git commit -m "test(mobile): screenshot tour for the design pass (make mobile-shots)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 12: Capture the before set on this commit**

Run: `make mobile-shots SIM="iPhone 17 Pro" SHOTS_DIR=build/mobile-shots/before > build/mobile-logs/t1-shots.log 2>&1; echo "exit=$?"`
Expected: `exit=0`. `ls build/mobile-shots/before/*.png | wc -l` prints `84` (35 rows, 4 end variants and 3 recorder shots, each in light and dark). Open `01-now-light.png`, `06-workbench-board-dark.png` and `26-recorder-idle-light.png` with the Read tool. They should show the current look: Now's Sessions row under the tab bar, HIGH/LOW words on the board, and PAUSED on the idle recorder. Keep `build/mobile-shots/before/` for the two gates. If a later task changes the demo seed, this set stays the reference anyway.

---

### Task 2: The design layer's foundation (tones, metrics, type scale, lint)

**Depends on:** Task 1 (the before set must exist before any look changes).

**Files:**
- Move: `Sources/Features/Workbench/PhoneTone.swift` → `Sources/DesignSystem/PhoneTone.swift` (`git mv`)
- Create: `Sources/DesignSystem/Metrics.swift`, `Sources/DesignSystem/TypeScale.swift`
- Create: `WatchtowerMobile/Tests/DesignSystemTests.swift`
- Modify: `WatchtowerMobile/.swiftlint.yml:165-172`
- Modify: `docs/features/mobile-companion.md` (B5 "Orange only for waiting and asks", plus a new "Design layer" paragraph)
- Regenerate: `project.pbxproj`

**Interfaces:**
- Produces: `PhoneTone.teal`, `PhoneTone.gray`. `Spacing.{tight 2, small 4, compact 6, regular 8, medium 12, large 16, page 20}`, `Radius.{chip 6, row 8, card 12}`, `RowInsets.{flat, card}` (`EdgeInsets`). `TypeScale.{screenTitle, pageTitle, sectionHeader, rowTitle, rowEmphasis, meta, kind, badge, pill, time, code}` (`Font`).

- [ ] **Step 1: Write the failing tests**

Create `WatchtowerMobile/Tests/DesignSystemTests.swift`:

```swift
import SwiftUI
import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// The phone's design layer (design pass spec §2): tones, metrics, the
/// target status table, the priority dot, card paints and the wrapping row.
final class DesignSystemTests: XCTestCase {
    /// §2.2: teal (in review) and gray (dismissed) are the system colours.
    func testTheNewTonesAreTheSystemTealAndGray() {
        XCTAssertEqual(PhoneTone.teal.color, .teal)
        XCTAssertEqual(PhoneTone.gray.color, .gray)
        XCTAssertNotEqual(PhoneTone.waitingForYou, .teal)
        XCTAssertNotEqual(PhoneTone.waitingForYou, .gray)
    }

    /// §2.9: the Mac's spacing steps plus 20 for page margins; one radius
    /// per role; the flat row's insets.
    func testTheMetricsNameTheMacsSteps() {
        XCTAssertEqual(
            [Spacing.tight, Spacing.small, Spacing.compact, Spacing.regular, Spacing.medium, Spacing.large, Spacing.page],
            [2, 4, 6, 8, 12, 16, 20]
        )
        XCTAssertEqual([Radius.chip, Radius.row, Radius.card], [6, 8, 12])
        XCTAssertEqual(RowInsets.flat, EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        XCTAssertEqual(RowInsets.card, EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}
```

- [ ] **Step 2: Regenerate and run, expect a compile failure**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=DesignSystemTests > build/mobile-logs/t2.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild); `type 'PhoneTone' has no member 'teal'` and `cannot find 'Spacing' in scope`.

- [ ] **Step 3: Move `PhoneTone` and add the two tones**

Run: `mkdir -p WatchtowerMobile/Sources/DesignSystem && git mv WatchtowerMobile/Sources/Features/Workbench/PhoneTone.swift WatchtowerMobile/Sources/DesignSystem/PhoneTone.swift`

In the moved file, replace lines 5-42 (the doc comment through the end of `color`) with:

```swift
/// Every colour the phone's screens draw (mobile POC spec §14, design pass
/// spec §2.2). Session tones map exactly to `SessionStatePresentation.Tone`;
/// `accent` is system blue; `purple` is the Mac working on a phone
/// recording, or a snoozed target; `teal` is a target in review and `gray`
/// a dismissed one (the Mac's target model table).
///
/// Orange is for waiting-for-you and ask elements only. This file is the
/// only place under `Sources/Features/` and `Sources/DesignSystem/` allowed
/// to name it (SwiftLint `orange_outside_phone_tone`): screens get it as
/// `waitingForYou` or from a session record's published tone.
enum PhoneTone: Equatable, Sendable {
    case green, orange, blue, red, purple, teal, gray, secondary, accent

    /// The tone of every waiting-for-you and ask element.
    static let waitingForYou = Self.orange
    /// The tab bar's open-ask badge.
    static let waitingBadgeColor = UIColor.systemOrange

    /// The Mac's published tone; one from a newer Mac draws secondary.
    init(_ tone: TerminalSessionState.Tone) {
        switch tone {
        case .green: self = .green
        case .orange: self = .orange
        case .blue: self = .blue
        case .red: self = .red
        default: self = .secondary
        }
    }

    var color: Color {
        switch self {
        case .green: .green
        case .orange: .orange
        case .blue: .blue
        case .red: .red
        case .purple: .purple
        case .teal: .teal
        case .gray: .gray
        case .secondary: .secondary
        case .accent: .accentColor
        }
    }
}
```

`ToneRole`, `ToneUse` and `CompactAge` below it stay unchanged.

- [ ] **Step 4: Write `Metrics.swift` and `TypeScale.swift`**

Create `Sources/DesignSystem/Metrics.swift`:

```swift
import SwiftUI

/// The Mac's spacing steps (2/4/6/8/12/16) plus 20 for page margins in
/// full-screen layouts, the recorder and onboarding (design pass spec §2.9).
enum Spacing {
    static let tight: CGFloat = 2
    static let small: CGFloat = 4
    static let compact: CGFloat = 6
    static let regular: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let page: CGFloat = 20
}

/// One radius per role: an inner highlight, a row's selection fill, a card.
enum Radius {
    static let chip: CGFloat = 6
    static let row: CGFloat = 8
    static let card: CGFloat = 12
}

/// A flat row's padding, and the `listRowInsets` around a card placed in a
/// `List`.
enum RowInsets {
    static let flat = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    static let card = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
}
```

Create `Sources/DesignSystem/TypeScale.swift`:

```swift
import SwiftUI

/// The Mac's type roles at iPhone sizes (design pass spec §2.8); everything
/// else uses system styles directly. Monospaced is only for counts, times,
/// keys and code; no role is uppercase. Meta lines use `.caption`, because
/// `.caption2` is too small for a whole line on a phone; `.caption2` stays
/// for badges and pills.
enum TypeScale {
    /// Detail headers: target, ask, event.
    static let screenTitle = Font.title3.weight(.semibold)
    /// Session title, Saved recording.
    static let pageTitle = Font.title2.weight(.semibold)
    /// Section labels, never uppercase.
    static let sectionHeader = Font.footnote.weight(.semibold)
    /// A flat row's title, a card's body text.
    static let rowTitle = Font.callout
    /// Workbench name, next-meeting title.
    static let rowEmphasis = Font.callout.weight(.semibold)
    /// Meta lines and captions.
    static let meta = Font.caption
    /// An ask's kind word, the REC mark.
    static let kind = Font.caption.weight(.semibold)
    static let badge = Font.caption2.weight(.semibold)
    static let pill = Font.caption2.weight(.medium)
    /// Times, ages, counts and percentages.
    static let time = Font.caption.monospacedDigit()
    /// Branch names and document paths only.
    static let code = Font.caption.monospaced()
}
```

- [ ] **Step 5: Regenerate and run, expect a pass**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='DesignSystemTests|OrangeToneTests|SessionRowTests' > build/mobile-logs/t2.log 2>&1; echo "exit=$?"`
Expected: `exit=0`.

- [ ] **Step 6: Extend the lint rule to the design layer**

In `WatchtowerMobile/.swiftlint.yml`, replace lines 165-172 (the comment and the rule's `included`/`excluded`) with:

```yaml
# Mobile-only (mobile POC spec §14, design pass spec §2.1): orange is for
# waiting-for-you and ask elements only, so under Sources/Features/ and
# Sources/DesignSystem/ only DesignSystem/PhoneTone.swift may name it;
# screens and the design layer use `PhoneTone.waitingForYou` or a session
# record's published tone.
custom_rules:
  orange_outside_phone_tone:
    name: "Orange outside PhoneTone"
    included: ".*/Sources/(Features|DesignSystem)/.*\\.swift"
    excluded: ".*/Sources/DesignSystem/PhoneTone\\.swift"
```

The `regex`, `message` and `severity` lines stay.

- [ ] **Step 7: Prove the rule bites inside the design layer, then lint**

Run:

```bash
printf 'import SwiftUI\n\nlet lintProbe = Color.orange\n' > WatchtowerMobile/Sources/DesignSystem/LintProbe.swift
(cd WatchtowerMobile && swiftlint lint --strict Sources/DesignSystem/LintProbe.swift) > build/mobile-logs/t2-probe.log 2>&1; echo "exit=$?"
rm WatchtowerMobile/Sources/DesignSystem/LintProbe.swift
make lint-swift > build/mobile-logs/t2-lint.log 2>&1; echo "exit=$?"
```

Expected: the probe run prints a non-zero exit and `Orange outside PhoneTone` in its log; `make lint-swift` then prints `exit=0`. `git status` shows no `LintProbe.swift`.

- [ ] **Step 8: Docs**

In `docs/features/mobile-companion.md`, in the B5 bullet **Orange only for waiting and asks.** (line 279), replace "forbids naming orange under `Sources/Features/` outside `PhoneTone.swift` (`PhoneTone.waitingForYou`)" with "forbids naming orange under `Sources/Features/` and `Sources/DesignSystem/` outside `Sources/DesignSystem/PhoneTone.swift` (`PhoneTone.waitingForYou`); the design layer itself gets orange only from `PhoneTone`".

Under `## Phone app`, before `### App shell (A11)`, add:

```markdown
### Design layer (design pass)

`Sources/DesignSystem/` names the values the Mac uses, so the phone's screens stop inventing their own: `PhoneTone` (moved here), `Spacing`/`Radius`/`RowInsets`, `TypeScale`, the target status glyph and tone (`TargetStatusStyle`, the Mac's model table), `PriorityDot` (high red, low blue, medium none), `card(_:)`, `Pill`/`CountBadge`/`FilterChip`, `FlatRow`/`RowDivider`/`SectionHeader`, `BottomActionBar`/`ProminentActionStyle`/`RecordButton`, and `SessionDot`/`ThinProgressBar`/`StepRow`/`FlowRow`. There is no custom colour or font: semantic SwiftUI colours, Dynamic Type and SF Symbols, accent system blue. Spec: `docs/superpowers/specs/2026-10-11-mobile-design-pass-design.md` §2.
```

- [ ] **Step 9: Commit**

```bash
git add WatchtowerMobile/Sources/DesignSystem WatchtowerMobile/Sources/Features/Workbench WatchtowerMobile/.swiftlint.yml \
  WatchtowerMobile/Tests/DesignSystemTests.swift WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj docs/features/mobile-companion.md
git commit -m "feat(mobile): design layer foundation — tones, metrics, type scale, orange lint over DesignSystem

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Target status and priority at the model level

**Depends on:** Task 2.

**Files:**
- Create: `Sources/DesignSystem/TargetStatusStyle.swift`, `Sources/DesignSystem/PriorityDot.swift`
- Modify: `Sources/Features/Workbench/BoardModel.swift:41-130` (`BoardRowModel`)
- Modify: `Sources/Features/Workbench/BoardView.swift:137-148` (the priority word becomes the dot)
- Modify: `Sources/Features/Workbench/BoardTargetDetailView.swift:171-185` (`readOnlyLine`)
- Modify: `WatchtowerMobile/Tests/DesignSystemTests.swift`, `WatchtowerMobile/Tests/BoardFilterTests.swift:104-118`
- Regenerate: `project.pbxproj`

**Interfaces:**
- Consumes: `PhoneTone.teal`, `.gray` (Task 2).
- Produces:
  - `enum TargetStatusStyle { static func of(_ status: WorkbenchTargetStatus) -> (glyph: String, tone: PhoneTone) }`.
  - `enum PriorityMark { static func tone(_:) -> PhoneTone?; static func accessibilityLabel(_:) -> String? }`, `struct PriorityDot: View { let priority: WorkbenchTargetPriority }`.
  - `BoardRowModel.priority: WorkbenchTargetPriority`, `priorityTone: PhoneTone?` (replaces `priorityLabel` and the non-optional `priorityTone`), `progressValue: Double?`, `progressTone: PhoneTone` (`.green`).
  - `BoardRowModel.status(_:)` keeps its signature.

- [ ] **Step 1: Write the failing tests**

Append to `DesignSystemTests`:

```swift
    /// §2.3: the Mac's model table (`Target.swift:280-300`) for every known
    /// status, an unknown one draws a secondary circle, none is orange.
    func testTargetStatusFollowsTheMacsModelTable() {
        let expected: [(WorkbenchTargetStatus, String, PhoneTone)] = [
            (.todo, "circle", .secondary),
            (.inProgress, "circle.dotted.circle", .blue),
            (.inReview, "eye.circle", .teal),
            (.blocked, "exclamationmark.circle", .red),
            (.done, "checkmark.circle.fill", .green),
            (.dismissed, "xmark.circle", .gray),
            (.snoozed, "moon.circle", .purple)
        ]
        XCTAssertEqual(expected.map(\.0), WorkbenchTargetStatus.knownValues, "the table covers every known status")
        for (status, glyph, tone) in expected + [(WorkbenchTargetStatus(rawValue: "newer"), "circle", .secondary)] {
            let style = TargetStatusStyle.of(status)
            XCTAssertEqual(style.glyph, glyph, status.rawValue)
            XCTAssertEqual(style.tone, tone, status.rawValue)
            XCTAssertNotEqual(style.tone, .orange, status.rawValue)
            XCTAssertEqual(BoardRowModel.status(status).glyph, glyph, "the board row forwards")
        }
    }

    /// §2.4: medium and unknown draw no dot; high is red, low blue; never
    /// orange.
    func testOnlyHighAndLowGetAPriorityDot() {
        XCTAssertEqual(PriorityMark.tone(.high), .red)
        XCTAssertEqual(PriorityMark.tone(.low), .blue)
        XCTAssertNil(PriorityMark.tone(.medium))
        XCTAssertNil(PriorityMark.tone(WorkbenchTargetPriority(rawValue: "newer")))
        XCTAssertEqual(PriorityMark.accessibilityLabel(.high), "High priority")
        XCTAssertEqual(PriorityMark.accessibilityLabel(.low), "Low priority")
        XCTAssertNil(PriorityMark.accessibilityLabel(.medium))
    }
```

In `BoardFilterTests.testARowShowsAsksSessionPRPriorityAndProgress`, replace the two `priorityLabel`/`priorityTone` lines (108-109) with:

```swift
        XCTAssertEqual(row.priority, .high)
        XCTAssertEqual(row.priorityTone, .red)
        XCTAssertEqual(try XCTUnwrap(row.progressValue), 0.5, accuracy: 0.0001)
```

and line 117 with:

```swift
        XCTAssertNil(report.priorityTone, "medium is the default and draws no dot")
        let lowRow = try XCTUnwrap(open.roots.first { $0.id == 431 }).row
        XCTAssertEqual(lowRow.priorityTone, .blue)
        XCTAssertNil(lowRow.progressValue, "a leaf with no progress draws no bar")
        let done = try XCTUnwrap(open.roots.first { $0.id == 420 }?.children.first { $0.id == 422 }).row
        XCTAssertEqual(done.progressText, "done")
        XCTAssertNil(done.progressValue, "done is a word, not a bar")
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='DesignSystemTests|BoardFilterTests' > build/mobile-logs/t3.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild), with `cannot find 'TargetStatusStyle' in scope` and `value of type 'BoardRowModel' has no member 'priority'`.

- [ ] **Step 3: Write `TargetStatusStyle` and `PriorityDot`**

Create `Sources/DesignSystem/TargetStatusStyle.swift`:

```swift
import WatchtowerKit

/// A target status's glyph and tone, exactly the Mac's model table
/// (`WatchtowerCore/Models/Target.swift:280-300`, design pass spec §2.3).
/// The Mac's list view has no `in_review` colour; the phone follows the
/// model table (teal), the newer source. A status from a newer Mac draws a
/// secondary circle.
enum TargetStatusStyle {
    static func of(_ status: WorkbenchTargetStatus) -> (glyph: String, tone: PhoneTone) {
        switch status {
        case .todo: ("circle", .secondary)
        case .inProgress: ("circle.dotted.circle", .blue)
        case .inReview: ("eye.circle", .teal)
        case .blocked: ("exclamationmark.circle", .red)
        case .done: ("checkmark.circle.fill", .green)
        case .dismissed: ("xmark.circle", .gray)
        case .snoozed: ("moon.circle", .purple)
        default: ("circle", .secondary)
        }
    }
}
```

Create `Sources/DesignSystem/PriorityDot.swift`:

```swift
import SwiftUI
import WatchtowerKit

/// Which priorities get a dot (design pass spec §2.4): high red, low blue.
/// Medium, the default, gets none: the Mac marks it orange, and the phone's
/// orange is only for waiting and asks.
enum PriorityMark {
    static func tone(_ priority: WorkbenchTargetPriority) -> PhoneTone? {
        switch priority {
        case .high: .red
        case .low: .blue
        default: nil
        }
    }

    static func accessibilityLabel(_ priority: WorkbenchTargetPriority) -> String? {
        switch priority {
        case .high: "High priority"
        case .low: "Low priority"
        default: nil
        }
    }
}

/// A 6 pt priority dot (the Mac's `TargetsListView.swift:516-529`); nothing,
/// and no reserved space, without a tone. It sits first in a row's meta
/// line.
struct PriorityDot: View {
    let priority: WorkbenchTargetPriority

    var body: some View {
        if let tone = PriorityMark.tone(priority) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
                .accessibilityLabel(PriorityMark.accessibilityLabel(priority) ?? "")
        }
    }
}
```

- [ ] **Step 4: Change `BoardRowModel`**

In `Sources/Features/Workbench/BoardModel.swift`:

- Replace the doc comment and properties on lines 41-56 with:

```swift
/// One board row: status glyph, title, sub-line (asks, sessions, PR), the
/// priority dot and progress.
struct BoardRowModel: Equatable, Identifiable {
    let id: Int64
    let title: String
    let statusGlyph: String
    let statusTone: PhoneTone
    let details: [BoardDetail]
    let priority: WorkbenchTargetPriority
    /// Red for high, blue for low; nil (no dot) for medium and unknown.
    let priorityTone: PhoneTone?
    /// "50%", or "done" for a done target; nil for a leaf with no
    /// progress yet.
    let progressText: String?
    /// 0…1 while `progressText` is a percent; nil for "done" and no
    /// progress (no bar).
    let progressValue: Double?
    let progressTone = PhoneTone.green
    /// A done target shown for context under Open: drawn greyed.
    let isDimmed: Bool
```

- In `init`, replace lines 64-77 (from `priorityLabel = switch` to the end of the progress `if`) with:

```swift
        priority = target.priority
        priorityTone = PriorityMark.tone(target.priority)
        isDimmed = target.status == .done
        if target.status == .done {
            progressText = "done"
            progressValue = nil
        } else if target.childrenCount > 0 || target.progress > 0 {
            let value = min(1, max(0, target.progress))
            progressText = "\(Int((value * 100).rounded()))%"
            progressValue = value
        } else {
            progressText = nil
            progressValue = nil
        }
```

- Replace `static func status` (lines 96-107) with:

```swift
    /// The Mac's status glyph and tone (`TargetStatusStyle`, design pass
    /// spec §2.3).
    static func status(_ status: WorkbenchTargetStatus) -> (glyph: String, tone: PhoneTone) {
        TargetStatusStyle.of(status)
    }
```

- Replace `toneUses` (lines 122-129) with:

```swift
    var toneUses: [ToneUse] {
        var uses = [ToneUse(element: "target \(id) status", tone: statusTone, role: .status)]
        uses += details.map { ToneUse(element: "target \(id) \($0.text)", tone: $0.tone, role: $0.role) }
        if let priorityTone {
            uses.append(ToneUse(element: "target \(id) priority", tone: priorityTone, role: .priority))
        }
        if progressValue != nil {
            uses.append(ToneUse(element: "target \(id) progress", tone: progressTone, role: .progress))
        }
        return uses
    }
```

- [ ] **Step 5: Draw the dot where the word was**

In `Sources/Features/Workbench/BoardView.swift`, replace lines 138-142 (the `if let priority = row.priorityLabel { … }` block) with `PriorityDot(priority: row.priority)`. Phase 2 (Task 15) moves the dot into the meta line.

In `Sources/Features/Workbench/BoardTargetDetailView.swift`, `readOnlyLine`, replace lines 175-179 (the `priorityLabel` block) with `PriorityDot(priority: detail.row.priority)`.

- [ ] **Step 6: Regenerate and run, expect a pass**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='DesignSystemTests|BoardFilterTests|OrangeToneTests|BoardWriteWiringTests' > build/mobile-logs/t3.log 2>&1; echo "exit=$?"`
Expected: `exit=0`. `OrangeToneTests.testDataDrivenTonesAreNeverOrange` compiles unchanged through `BoardRowModel.status(_:)`.

- [ ] **Step 7: Lint, then commit**

Run: `make lint-swift > build/mobile-logs/t3-lint.log 2>&1; echo "exit=$?"` (expect `exit=0`), then:

```bash
git add WatchtowerMobile/Sources WatchtowerMobile/Tests WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj
git commit -m "feat(mobile): the Mac's target status glyphs and a priority dot in place of HIGH/LOW

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot check (at the gate): in shot 06 the in-progress targets have a blue `circle.dotted.circle` and done targets a green check. A red dot marks "Archive Closed Targets Now", a blue dot marks "Ask guard v2", and no HIGH or LOW word is left.

---

### Task 4: Components — card, pills, flat row, small parts

**Depends on:** Task 2.

**Files:**
- Create: `Sources/DesignSystem/Card.swift`, `Pill.swift`, `FlatRow.swift`, `Parts.swift`
- Modify: `Sources/Features/Workbench/WorkbenchComponents.swift:1-41` (move `SessionDot` and `ThinProgressBar` out)
- Modify: `Sources/Features/Workbench/BoardModel.swift:33-39` (`BoardDetail` becomes a typealias of `MetaItem`)
- Modify: `Sources/Features/Recording/RecordingView.swift:200-283` (the private `StepRow` goes; the shared one replaces it)
- Modify: `WatchtowerMobile/Tests/DesignSystemTests.swift`
- Regenerate: `project.pbxproj`

**Interfaces:**
- Consumes: `PhoneTone`, `Spacing`, `Radius`, `RowInsets`, `TypeScale` (Task 2).
- Produces:
  - `enum CardStyle { plain, waiting, highlighted }`; `enum Card { static let padding: EdgeInsets; struct Paint { fill: Color; stroke: Color; lineWidth: CGFloat }; static func paint(_:scheme:) -> Paint }`; `View.card(_ style: CardStyle = .plain, padding: EdgeInsets = Card.padding)`.
  - `Pill(text:tone:style:monospaced:)` with `Pill.Style { tinted, neutral }`; `CountBadge(count:tone:)`; `FilterChip(title:count:isSelected:action:)` with `count: Int?`.
  - `struct MetaItem: Equatable { text: String; tone: PhoneTone; role: ToneRole }`, `MetaLine(items:)`.
  - `enum FlatRowIcon { symbol(String, tone:), session(tone:isRing:), none }`.
  - `FlatRow<Meta, Trailing>(icon:title:titleLineLimit:isDimmed:insets:meta:trailing:)`, with an init without `trailing`.
  - `RowDivider()`, `SectionHeader(_ text: String, tone: PhoneTone = .secondary)`.
  - `SessionDot(tone:isRing:size:)` and `ThinProgressBar(value:tone:height:)`, unchanged.
  - `StepRow(state:text:)` with `StepRow.State { done, current, waiting, todo, failed }`.
  - `FlowRow(spacing: 6, lineSpacing: 4): Layout` and `static func arrange(sizes:maxWidth:spacing:lineSpacing:) -> (frames: [CGRect], size: CGSize)`.
  - `typealias BoardDetail = MetaItem`.

- [ ] **Step 1: Write the failing tests**

Append to `DesignSystemTests`:

```swift
    /// §2.5: one radius, three paints; the dark waiting fill is weaker on
    /// purpose (orange at 0.10 on black reads brown).
    func testTheCardPaints() {
        let waitingLight = Card.paint(.waiting, scheme: .light)
        let waitingDark = Card.paint(.waiting, scheme: .dark)
        XCTAssertEqual(waitingLight.fill, PhoneTone.waitingForYou.color.opacity(0.10))
        XCTAssertEqual(waitingDark.fill, PhoneTone.waitingForYou.color.opacity(0.06))
        XCTAssertEqual(waitingLight.stroke, PhoneTone.waitingForYou.color.opacity(0.45))
        XCTAssertEqual(waitingDark.stroke, PhoneTone.waitingForYou.color.opacity(0.30))
        XCTAssertEqual(waitingLight.lineWidth, 1)
        XCTAssertEqual(Card.paint(.plain, scheme: .dark).lineWidth, 0.5)
        XCTAssertEqual(Card.paint(.highlighted, scheme: .dark).fill, Color.accentColor.opacity(0.14))
        XCTAssertEqual(Card.paint(.highlighted, scheme: .light).lineWidth, 1.5)
        XCTAssertEqual(Card.padding, EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
    }

    /// §2.11 and review focus 4: items wrap 6 pt apart with 4 pt between
    /// lines; an item wider than the row gets a line of its own at the
    /// row's width (so it truncates); no items take no space.
    func testFlowRowWrapsClampsAndCollapses() {
        let item = CGSize(width: 100, height: 20)
        let wrapped = FlowRow.arrange(sizes: [item, item, item], maxWidth: 250, spacing: 6, lineSpacing: 4)
        XCTAssertEqual(wrapped.frames.map(\.origin), [CGPoint(x: 0, y: 0), CGPoint(x: 106, y: 0), CGPoint(x: 0, y: 24)])
        XCTAssertEqual(wrapped.size, CGSize(width: 206, height: 44))

        let wide = FlowRow.arrange(sizes: [item, CGSize(width: 900, height: 20)], maxWidth: 250, spacing: 6, lineSpacing: 4)
        XCTAssertEqual(wide.frames[1], CGRect(x: 0, y: 24, width: 250, height: 20))
        XCTAssertEqual(wide.size.width, 250)

        XCTAssertEqual(FlowRow.arrange(sizes: [], maxWidth: 250, spacing: 6, lineSpacing: 4).size, .zero)
    }

    /// The board's details are meta items: one type for every meta line.
    func testABoardDetailIsAMetaItem() {
        let detail: BoardDetail = MetaItem(text: "1 ask", tone: .waitingForYou, role: .ask)
        XCTAssertEqual(detail.text, "1 ask")
    }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=DesignSystemTests > build/mobile-logs/t4.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild), with `cannot find 'Card' in scope` and `cannot find 'FlowRow' in scope`.

- [ ] **Step 3: Write `Card.swift`**

```swift
import SwiftUI

/// A card's look (design pass spec §2.5): `plain` for detail blocks,
/// `waiting` for "Waiting for you" and asks, `highlighted` for the current
/// or next meeting. A card never contains another card; rows inside one are
/// flat.
enum CardStyle: Equatable {
    case plain, waiting, highlighted
}

enum Card {
    /// The default inner padding: 12 horizontal, 10 vertical.
    static let padding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)

    struct Paint: Equatable {
        let fill: Color
        let stroke: Color
        let lineWidth: CGFloat
    }

    /// The fill and stroke of `style` in `scheme`. The waiting card gets its
    /// colour from `PhoneTone.waitingForYou`; the design layer never names
    /// orange.
    static func paint(_ style: CardStyle, scheme: ColorScheme) -> Paint {
        switch style {
        case .plain:
            Paint(fill: Color(.secondarySystemBackground), stroke: Color(.separator), lineWidth: 0.5)
        case .waiting:
            Paint(
                fill: PhoneTone.waitingForYou.color.opacity(scheme == .dark ? 0.06 : 0.10),
                stroke: PhoneTone.waitingForYou.color.opacity(scheme == .dark ? 0.30 : 0.45),
                lineWidth: 1
            )
        case .highlighted:
            Paint(fill: Color.accentColor.opacity(scheme == .dark ? 0.14 : 0.10), stroke: .accentColor, lineWidth: 1.5)
        }
    }
}

private struct CardModifier: ViewModifier {
    let style: CardStyle
    let padding: EdgeInsets
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let paint = Card.paint(style, scheme: scheme)
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(paint.fill, in: shape)
            .overlay(shape.strokeBorder(paint.stroke, lineWidth: paint.lineWidth))
    }
}

extension View {
    /// The card recipe: radius 12 (continuous), the style's paint, and
    /// `padding` inside. Cards sit on `Color(.systemBackground)`.
    func card(_ style: CardStyle = .plain, padding: EdgeInsets = Card.padding) -> some View {
        modifier(CardModifier(style: style, padding: padding))
    }
}
```

- [ ] **Step 4: Write `Pill.swift`**

```swift
import SwiftUI

/// A small capsule label (design pass spec §2.6). Tinted: the tone at 0.14
/// under the tone's text. Neutral: secondary on secondary at 0.12.
/// Monospaced only for branch names.
struct Pill: View {
    enum Style {
        case tinted, neutral
    }

    let text: String
    var tone: PhoneTone = .secondary
    var style: Style = .tinted
    var monospaced = false

    var body: some View {
        Text(text)
            .font(monospaced ? Font.caption2.monospaced() : TypeScale.pill)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(style == .tinted ? tone.color : Color.secondary)
            .background(style == .tinted ? tone.color.opacity(0.14) : Color.secondary.opacity(0.12), in: Capsule())
    }
}

/// The Mac's sidebar badge (`SidebarView.swift:262-270`): a white count on a
/// solid capsule in the tone, at least 16 pt wide.
struct CountBadge: View {
    let count: Int
    let tone: PhoneTone

    var body: some View {
        Text("\(count)")
            .font(TypeScale.badge)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 16)
            .background(tone.color, in: Capsule())
    }
}

/// A filter chip: the title and its count, a capsule inset by 7 inside a
/// 44 pt tall hit area, accent when selected.
struct FilterChip: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.small) {
                Text(title)
                if let count {
                    Text("\(count)").monospacedDigit()
                }
            }
            .font(.footnote)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12), in: Capsule().inset(by: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
```

- [ ] **Step 5: Write `FlatRow.swift`**

```swift
import SwiftUI

/// One coloured item of a meta line; the role says what it is, so
/// `OrangeToneTests` can sweep it.
struct MetaItem: Equatable {
    let text: String
    let tone: PhoneTone
    let role: ToneRole
}

/// Meta items spaced 6 and joined by "·" in secondary, on one line. Earlier
/// items keep their room, so the last item truncates first.
struct MetaLine: View {
    let items: [MetaItem]

    var body: some View {
        HStack(spacing: Spacing.compact) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text("·").foregroundStyle(.secondary)
                }
                Text(item.text)
                    .foregroundStyle(item.tone.color)
                    .layoutPriority(Double(items.count - index))
            }
        }
        .lineLimit(1)
    }
}

/// A flat row's icon: an SF Symbol in a tone, a session dot, or nothing.
enum FlatRowIcon: Equatable {
    case symbol(String, tone: PhoneTone)
    case session(tone: PhoneTone, isRing: Bool)
    case none
}

/// The Mac's target row (`TargetsListView.swift:395-430`) at phone size
/// (design pass spec §2.7): a 20 pt icon column, the title (up to two
/// lines; struck through and secondary when dimmed), one meta line in
/// `.caption` secondary, and a trailing view. In a `ScrollView` it pads
/// itself with `RowInsets.flat`; in a `List` pass `insets: EdgeInsets()` and
/// let the list's row insets pad it.
struct FlatRow<Meta: View, Trailing: View>: View {
    let icon: FlatRowIcon
    let title: String
    var titleLineLimit = 2
    var isDimmed = false
    var insets = RowInsets.flat
    @ViewBuilder var meta: Meta
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            iconView.frame(width: 20)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(title)
                    .font(TypeScale.rowTitle)
                    .strikethrough(isDimmed)
                    .foregroundStyle(isDimmed ? Color.secondary : Color.primary)
                    .lineLimit(titleLineLimit)
                meta
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(insets)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case let .symbol(name, tone):
            Image(systemName: name).font(.body).foregroundStyle(tone.color)
        case let .session(tone, isRing):
            SessionDot(tone: tone, isRing: isRing, size: 10)
        case .none:
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

extension FlatRow where Trailing == EmptyView {
    init(
        icon: FlatRowIcon,
        title: String,
        titleLineLimit: Int = 2,
        isDimmed: Bool = false,
        insets: EdgeInsets = RowInsets.flat,
        @ViewBuilder meta: () -> Meta
    ) {
        self.init(icon: icon, title: title, titleLineLimit: titleLineLimit, isDimmed: isDimmed, insets: insets, meta: meta) {
            EmptyView()
        }
    }
}

/// A divider between flat rows in a `ScrollView` or a card, starting at the
/// title column (16 + 20 + 10).
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 46)
    }
}

/// A section label in a `ScrollView`: `TypeScale.sectionHeader`, never
/// uppercase. In an `insetGrouped` or `plain` `List`, keep the system header
/// and give it `.font(TypeScale.sectionHeader)` and `.textCase(nil)`.
struct SectionHeader: View {
    let text: String
    let tone: PhoneTone

    init(_ text: String, tone: PhoneTone = .secondary) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(TypeScale.sectionHeader)
            .foregroundStyle(tone.color)
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 6, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
```

- [ ] **Step 6: Write `Parts.swift`, moving the dot and the bar**

Cut `SessionDot` and `ThinProgressBar` (lines 3-41) out of `Sources/Features/Workbench/WorkbenchComponents.swift` and paste them unchanged into a new `Sources/DesignSystem/Parts.swift`, under `import SwiftUI`. Then append:

```swift
/// One step of a progress list (design pass spec §2.11): the Saved
/// recording, the session start, onboarding's link steps. The icon column
/// is 22 pt; a row is at least 44 pt tall.
struct StepRow: View {
    enum State: Equatable {
        case done, current, waiting, todo, failed
    }

    let state: State
    let text: String

    var body: some View {
        HStack(spacing: Spacing.medium) {
            icon.frame(width: 22)
            Text(text)
                .font(.body)
                .foregroundStyle(state == .todo ? Color.secondary : Color.primary)
        }
        .frame(minHeight: 44, alignment: .leading)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(PhoneTone.green.color)
        case .current: ProgressView()
        case .waiting: Image(systemName: "moon.zzz").foregroundStyle(.secondary)
        case .todo: Image(systemName: "circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(PhoneTone.red.color)
        }
    }
}

/// A wrapping row: items 6 pt apart, lines 4 pt apart. Replaces the
/// HStack-or-VStack `ViewThatFits` fallbacks, which went one item per line.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.arrange(
            sizes: subviews.map { $0.sizeThatFits(.unspecified) },
            maxWidth: proposal.width ?? .infinity, spacing: spacing, lineSpacing: lineSpacing
        ).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = Self.arrange(
            sizes: subviews.map { $0.sizeThatFits(.unspecified) },
            maxWidth: bounds.width, spacing: spacing, lineSpacing: lineSpacing
        )
        for (subview, frame) in zip(subviews, layout.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// Line breaking: an item starts a new line when it would pass
    /// `maxWidth`; an item wider than `maxWidth` gets a line of its own at
    /// `maxWidth` (so it truncates instead of overflowing).
    static func arrange(sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat, lineSpacing: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var width: CGFloat = 0
        for size in sizes {
            let item = CGSize(width: min(size.width, maxWidth), height: size.height)
            if cursorX > 0, cursorX + item.width > maxWidth {
                cursorY += lineHeight + lineSpacing
                cursorX = 0
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: cursorX, y: cursorY), size: item))
            width = max(width, cursorX + item.width)
            cursorX += item.width + spacing
            lineHeight = max(lineHeight, item.height)
        }
        return (frames, CGSize(width: width, height: frames.isEmpty ? 0 : cursorY + lineHeight))
    }
}
```

- [ ] **Step 7: One meta-item type, and the shared step row in the recorder**

In `Sources/Features/Workbench/BoardModel.swift`, replace the `BoardDetail` struct (lines 33-39) with:

```swift
/// One coloured piece of a board row's sub-line; `.ask` for the open-ask
/// count, the only detail that may be orange.
typealias BoardDetail = MetaItem
```

In `Sources/Features/Recording/RecordingView.swift`, delete the private `StepRow` (lines 257-283, including its doc comment). Replace `.working` with `.current` at its three call sites (lines 206, 230 and 250). Run `grep -n 'state: .working' WatchtowerMobile/Sources` and expect no output.

- [ ] **Step 8: Regenerate and run, expect a pass**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='DesignSystemTests|BoardFilterTests|RecorderTests|OrangeToneTests' > build/mobile-logs/t4.log 2>&1; echo "exit=$?"`
Expected: `exit=0`.

- [ ] **Step 9: Lint, then commit**

Run: `make lint-swift > build/mobile-logs/t4-lint.log 2>&1; echo "exit=$?"` (expect `exit=0`), then:

```bash
git add WatchtowerMobile/Sources WatchtowerMobile/Tests WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj
git commit -m "feat(mobile): design layer components — card, pills, flat row, step row, flow row

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Bars and buttons, with bugs 5, 6 and 8

**Depends on:** Task 4 (`StepRow`).

**Files:**
- Create: `Sources/DesignSystem/Bars.swift`
- Modify: `Sources/Features/Workbench/SessionStartModels.swift:8-23` (a new text) and `:256-284` (`startCaption`)
- Modify: `Sources/Features/Workbench/StartSessionSheet.swift:79-338` (form label, both button bars, the progress steps; `StepDot` goes)
- Modify: `Sources/Features/Asks/AskView.swift:90` and `:168-213` (`AskSendBar`)
- Modify: `Sources/Features/Calendar/EventDetailView.swift:99` and `:102-129` (`bottomBar`)
- Modify: `WatchtowerMobile/Tests/StartSheetWiringTests.swift`
- Regenerate: `project.pbxproj`

**Interfaces:**
- Consumes: `StepRow` (Task 4), `Spacing`, `TypeScale` (Task 2).
- Produces:
  - `BottomActionBar<Content>(content:)`, used in `.safeAreaInset(edge: .bottom, spacing: 0)`.
  - `ProminentActionStyle: ButtonStyle`.
  - `RecordButton(title: String = "Record", size: ControlSize = .large, action:)`, first used in Task 11.
  - `SessionStartText.chooseTarget`.

- [ ] **Step 1: Write the failing tests (bug 5)**

In `StartSheetWiringTests.testTheHeadersNewSessionPicksATarget`, after `XCTAssertFalse(model.canStart)`, add:

```swift
        XCTAssertEqual(model.startCaption, "Choose a target to start", "Start says why it is off")
```

Add a new test after `testAPhoneNotAllowedToStartCannotStart`:

```swift
    /// Bug 5 (design pass spec §3): with no target and a refused grant, the
    /// grant caption wins; a picked target on an allowed phone has none.
    func testTheGrantCaptionWinsOverTheMissingTarget() throws {
        let refused = try form(nil, try snapshot(try ReplicaStore.inMemory(), grant: grant(typing: false, start: false)))
        XCTAssertFalse(refused.canStart)
        XCTAssertEqual(refused.startCaption, "This phone is not allowed to start sessions on the Mac")
        XCTAssertNil(try form(415, try snapshot(try ReplicaStore.inMemory())).startCaption)
    }
```

- [ ] **Step 2: Run, expect failures**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=StartSheetWiringTests > build/mobile-logs/t5.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild), with `testTheHeadersNewSessionPicksATarget` failing on `("nil") is not equal to ("Optional("Choose a target to start")")`.

- [ ] **Step 3: The caption**

In `SessionStartModels.swift`, add to `SessionStartText` after `notAllowed` (line 17):

```swift
    static let chooseTarget = "Choose a target to start"
```

Replace the `startCaption` doc comment (line 256) with `/// Why starting is off: the grant first, then a missing target; nil when it is on.` and line 284 with:

```swift
        startCaption = if !grant.startSessionsAllowed {
            SessionStartText.notAllowed
        } else if target == nil {
            SessionStartText.chooseTarget
        } else {
            nil
        }
```

- [ ] **Step 4: Run, expect a pass**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=StartSheetWiringTests > build/mobile-logs/t5.log 2>&1; echo "exit=$?"`
Expected: `exit=0`.

- [ ] **Step 5: Write `Bars.swift`**

```swift
import SwiftUI

/// An opaque bottom bar (design pass spec §2.10): a hairline on top, the
/// content padded 16 × 10, on `Color(.systemBackground)` down to the screen
/// edge. Goes in `.safeAreaInset(edge: .bottom, spacing: 0)`. It replaces the
/// translucent `.background(.bar)` bars, which let the content under them
/// show through (bugs 4 and 8).
struct BottomActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, 10)
        }
        .background(Color(.systemBackground), ignoresSafeAreaEdges: .bottom)
    }
}

/// The one primary action of a bar: full width, 50 pt, a capsule in the
/// button's tint (accent by default) with a white semibold label. Disabled,
/// it keeps its shape as a grey capsule with a secondary label: on iOS 26 a
/// disabled `.borderedProminent` renders nearly transparent (bugs 5 and 6).
/// The secondary button of a pair stays `.bordered` with `.controlSize(.large)`.
struct ProminentActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProminentActionLabel(configuration: configuration)
    }
}

private struct ProminentActionLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

/// The red Record button: the symbol forced monochrome white, so it draws
/// no accent ring inside the red capsule (shots 01 and 03).
struct RecordButton: View {
    var title = "Record"
    var size: ControlSize = .large
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "record.circle")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
        }
        .buttonStyle(.borderedProminent)
        .tint(PhoneTone.red.color)
        .controlSize(size)
    }
}
```

- [ ] **Step 6: The start sheet (bug 5, plus the sheet items of Phase 2)**

In `StartSessionSheet.swift`:

- Line 85: change `.font(.callout.monospaced())` to `.font(.callout)` (the fixed target label is not code).
- Line 127: `.safeAreaInset(edge: .bottom, spacing: 0) { formButtons(model) }`; line 208: `.safeAreaInset(edge: .bottom, spacing: 0) { progressButtons(progress, model) }`.
- Replace `formButtons` (lines 143-177) with:

```swift
    private func formButtons(_ model: StartSessionFormModel) -> some View {
        BottomActionBar {
            VStack(spacing: Spacing.regular) {
                if let caption = model.startCaption {
                    Text(caption).font(TypeScale.meta).foregroundStyle(.secondary)
                }
                if let existing = model.existing {
                    Button("Open it") { openIt(model) }
                        .buttonStyle(ProminentActionStyle())
                        .disabled(!existing.isLive && !model.canStart)
                        .accessibilityHint(existing.isLive ? "Opens the running session" : "Resumes the session on the Mac")
                    secondaryButton("Start a new one") { start(.new, model) }
                        .disabled(!model.canStart)
                } else {
                    Button { start(.new, model) } label: {
                        Label("Start session", systemImage: "play.fill")
                    }
                    .buttonStyle(ProminentActionStyle())
                    .disabled(!model.canStart)
                }
            }
        }
    }

    /// The secondary button of a bar's pair.
    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
```

- In `progressView`, replace the step `HStack` (lines 185-191) with:

```swift
                    StepRow(state: Self.stepState(step.state), text: step.title)
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(Self.stepValue(step.state))
```

and add beside `stepValue`:

```swift
    private static func stepState(_ state: StartProgressModel.Step.State) -> StepRow.State {
        switch state {
        case .done: .done
        case .current: .current
        case .todo: .todo
        }
    }
```

- Replace `progressButtons` (lines 219-276) with:

```swift
    private func progressButtons(_ progress: StartProgressModel, _ model: StartSessionFormModel) -> some View {
        BottomActionBar {
            VStack(spacing: Spacing.regular) {
                if let row = progress.failedRow {
                    Button("Try again") { retry(row) }
                        .buttonStyle(ProminentActionStyle())
                        .disabled(!model.canStart)
                    secondaryButton("Dismiss") { clear(model) }
                } else if progress.isEnded {
                    Button("Start a new one") {
                        clear(model)
                        start(.new, model)
                    }
                    .buttonStyle(ProminentActionStyle())
                    .disabled(!model.canStart)
                    secondaryButton("Dismiss") { clear(model) }
                } else {
                    Button(SessionStartText.openSession) {
                        if let id = progress.openSessionID {
                            clear(model)
                            dismiss()
                            onOpenSession(id)
                        }
                    }
                    .buttonStyle(ProminentActionStyle())
                    .disabled(progress.openSessionID == nil)
                    // Done always ends the sheet's hold on the start; a save the
                    // Mac has not answered yet still shows from its overlay row.
                    secondaryButton("Done") {
                        clear(model)
                        dismiss()
                    }
                }
            }
        }
    }
```

- Delete `StepDot` (lines 322-338).

- [ ] **Step 7: The ask send bar (bug 6)**

In `AskView.swift`, line 90 becomes `.safeAreaInset(edge: .bottom, spacing: 0) {`. Replace `AskSendBar.body` (lines 175-209) with:

```swift
    var body: some View {
        BottomActionBar {
            VStack(spacing: Spacing.regular) {
                if form.review != nil {
                    // Equal widths: both labels fill their half.
                    HStack(spacing: Spacing.regular) {
                        Button { verdict(.changes) } label: {
                            Text(AskText.requestChanges).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityHint("Sends the answer with changes requested")
                        Button(AskText.approve) { verdict(.approved) }
                            .buttonStyle(ProminentActionStyle())
                            .accessibilityHint("Sends the answer approved")
                    }
                    .disabled(!form.canSendVerdict)
                } else if let page = form.question, !page.isLast {
                    Button(AskText.next) { model.next(of: page.count) }
                        .buttonStyle(ProminentActionStyle())
                } else {
                    Button(AskText.send) { Task { await model.send(ask) } }
                        .buttonStyle(ProminentActionStyle())
                        .disabled(!form.canSend)
                        .accessibilityLabel(AskText.send)
                }
                if let page = form.question, page.index > 0 {
                    Button(AskText.previous) { model.previous() }
                        .frame(minHeight: 44)
                }
                Text(form.footer).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
```

- [ ] **Step 8: The event detail bar (bug 8)**

In `EventDetailView.swift`, line 99 becomes `.safeAreaInset(edge: .bottom, spacing: 0) { bottomBar(model) }`. Replace `bottomBar(_:)` (lines 102-129) with:

```swift
    @ViewBuilder
    private func bottomBar(_ model: EventDetailModel) -> some View {
        if !model.actionTitles.isEmpty {
            BottomActionBar {
                HStack(spacing: 10) {
                    if let url = model.joinURL {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Join", systemImage: "video").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    if let meeting = model.meetingEvent {
                        Button {
                            Task { await env.recorder.recordMeeting(meeting) }
                        } label: {
                            Label("Record this meeting", systemImage: "record.circle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(PhoneTone.red.color)
                    }
                }
                .controlSize(.large)
            }
        }
    }
```

The buttons and the "Record this meeting" label stay. Phase 4 (C4) shortens the label to "Record" and moves it to `RecordButton`.

- [ ] **Step 9: Regenerate, run, lint**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='StartSheetWiringTests|AskFormTests|CalendarWiringTests' > build/mobile-logs/t5.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t5-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both, with `AskFormTests` unchanged.

- [ ] **Step 10: Commit**

```bash
git add WatchtowerMobile/Sources WatchtowerMobile/Tests WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj
git commit -m "fix(mobile): opaque bottom bars and a disabled primary that keeps its shape (bugs 5, 6, 8)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate):
- 18: a grey capsule "Start session" with "Choose a target to start" above it, on an opaque bar with a hairline.
- 13: a full-width grey "Send answer" capsule.
- 14: equal-width Request changes and Approve.
- 20 and 20e: the bar is opaque, and the Recording section ends above it.

---

### Task 6: Target detail — status, priority and progress rows, and an opaque composer (bugs 3, 4)

**Depends on:** Task 3 (`TargetStatusStyle`, `PriorityDot`, `progressValue`), Task 5 (`BottomActionBar`).

**Files:**
- Modify: `Sources/Features/Workbench/BoardTargetDetailView.swift:47-146` (header, breadcrumb, a new fields section), `:187-218` (`pickers` becomes `fields`), `:264-295` (`composer`)

**Interfaces:**
- Consumes: `TargetStatusStyle.of`, `PriorityDot`, `BoardRowModel.progressValue`/`progressTone` (Task 3); `ThinProgressBar` (Task 4); `BottomActionBar` (Task 5); `TypeScale.screenTitle`/`meta`/`time`.
- Produces: no new API. Task 15 builds on this layout (T1, T4–T6).

- [ ] **Step 1: Header and breadcrumb (bug 3)**

Replace `header(_:)` (lines 120-146) with:

```swift
    /// The title alone in its row; the breadcrumb is the section's header,
    /// so the row is not a link (bug 3's stray chevron).
    @ViewBuilder
    private func header(_ detail: BoardTargetDetailModel) -> some View {
        Section {
            Text(detail.title).font(TypeScale.screenTitle)
            if detail.isReadOnly {
                readOnlyLine(detail)
            }
        } header: {
            breadcrumb(detail)
        }
        if !detail.isReadOnly {
            fields(detail)
        }
    }

    @ViewBuilder
    private func breadcrumb(_ detail: BoardTargetDetailModel) -> some View {
        if !detail.breadcrumb.isEmpty {
            HStack(spacing: Spacing.small) {
                ForEach(detail.breadcrumb) { crumb in
                    NavigationLink(value: BoardTargetRoute(id: crumb.id)) {
                        Text("\(crumb.title) ›").lineLimit(1)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
            .font(TypeScale.meta)
            .foregroundStyle(.secondary)
            .textCase(nil)
            .buttonStyle(.borderless)
        }
    }
```

- [ ] **Step 2: One row each for status, priority and progress (bug 3)**

Replace `pickers(_:)` (lines 187-218) with:

```swift
    /// Status, priority and progress, one row each; a group's "status follows
    /// its sub-tasks" is the section's footer. The bindings are unchanged.
    private func fields(_ detail: BoardTargetDetailModel) -> some View {
        Section {
            Picker(selection: Binding(get: { detail.status.selection }, set: { setStatus($0, detail) })) {
                ForEach(detail.status.options, id: \.self) { Text(BoardRowModel.statusLabel($0)).tag($0) }
            } label: {
                let style = TargetStatusStyle.of(detail.status.selection)
                Label {
                    Text("Status")
                } icon: {
                    Image(systemName: style.glyph).foregroundStyle(style.tone.color)
                }
            }
            .pickerStyle(.menu)
            .disabled(!detail.status.isEnabled)
            .frame(minHeight: 44)
            .accessibilityLabel("Status")
            .accessibilityValue(BoardRowModel.statusLabel(detail.status.selection))
            Picker(selection: Binding(get: { detail.priority.selection }, set: { setPriority($0, detail) })) {
                ForEach(detail.priority.options, id: \.self) { Text(BoardRowModel.priorityName($0)).tag($0) }
            } label: {
                HStack(spacing: Spacing.compact) {
                    Text("Priority")
                    PriorityDot(priority: detail.priority.selection)
                }
            }
            .pickerStyle(.menu)
            .disabled(!detail.priority.isEnabled)
            .frame(minHeight: 44)
            .accessibilityLabel("Priority")
            .accessibilityValue(BoardRowModel.priorityName(detail.priority.selection))
            if let value = detail.row.progressValue, let text = detail.row.progressText {
                LabeledContent("Progress") {
                    HStack(spacing: Spacing.regular) {
                        ThinProgressBar(value: value, tone: detail.row.progressTone).frame(width: 80)
                        Text(text).font(TypeScale.time)
                    }
                }
            }
        } footer: {
            if let caption = detail.status.caption {
                Text(caption)
            }
        }
    }
```

- [ ] **Step 3: The opaque composer (bug 4)**

Line 106 becomes `.safeAreaInset(edge: .bottom, spacing: 0) {`. Replace `composer(_:)` (lines 264-295) with:

```swift
    /// The comment composer on an opaque bar (bug 4): nothing shows through.
    private func composer(_ detail: BoardTargetDetailModel) -> some View {
        BottomActionBar {
            VStack(alignment: .leading, spacing: Spacing.small) {
                if let replyTo {
                    HStack {
                        Text("Replying to \(replyTo.author)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { self.replyTo = nil }
                            .font(.caption)
                            .frame(minHeight: 44)
                            .accessibilityLabel("Cancel the reply")
                    }
                }
                HStack(alignment: .bottom, spacing: Spacing.regular) {
                    TextField(replyTo == nil ? "Add a comment" : "Reply", text: $draft.text, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .focused($composerFocused)
                        .accessibilityLabel(replyTo == nil ? "Comment" : "Reply")
                    Button {
                        send(detail)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(!draft.canSend || detail.composerSending(replyRoot: replyTo?.rootID))
                    .accessibilityLabel(replyTo == nil ? "Send comment" : "Send reply")
                }
            }
        }
    }
```

- [ ] **Step 4: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='BoardWriteWiringTests|BoardFilterTests|OrangeToneTests' > build/mobile-logs/t6.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t6-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both, with `BoardWriteWiringTests` unchanged.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Workbench/BoardTargetDetailView.swift
git commit -m "fix(mobile): target detail — one row each for status, priority, progress; opaque composer (bugs 3, 4)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate):
- 07 and 08: "Status" and its value share one line, "Priority" has its own row with a red dot on 415, there is no stray "50%", and the title row has no chevron.
- 08: the group caption is the section footer.
- 07 and 07e (light and dark): the composer bar is opaque with a hairline, and nothing orange shows under the field.

---

### Task 7: The review document reads as a document (bug 7)

**Depends on:** Task 1.

**Files:**
- Create: `Sources/Features/Asks/ReviewDocumentStyler.swift`
- Create: `WatchtowerMobile/Tests/ReviewDocumentStylerTests.swift`
- Modify: `Sources/Features/Asks/ReviewAskView.swift:21` and `:113-135` (`SnapshotTextView`)
- Regenerate: `project.pbxproj`

**Interfaces:**
- Consumes: `PlainTextDocument`, `PlainTextRendering`, `CommentAnchorBuilder` (WatchtowerKit, unchanged).
- Produces:
  - `enum ReviewDocumentStyler`, with `static func attributed(_ document: PlainTextDocument, traits: UITraitCollection? = nil) -> NSAttributedString`.
  - `static func headingFont(level: Int, traits: UITraitCollection?) -> UIFont`, `static func bodyFont(traits: UITraitCollection?) -> UIFont`, `static func listPrefix(of line: String) -> String?`.

- [ ] **Step 1: Write the failing tests**

Create `WatchtowerMobile/Tests/ReviewDocumentStylerTests.swift`:

```swift
import UIKit
import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// Bug 7 (design pass spec §3): the review snapshot reads as a document.
/// The styled string is exactly `document.text`, because comment anchors are
/// UTF-16 offsets into it; only attributes change.
final class ReviewDocumentStylerTests: XCTestCase {
    private let traits = UITraitCollection(preferredContentSizeCategory: .large)

    /// The demo's review #110, rendered as the form renders it.
    private func demoReview() throws -> PlainTextDocument {
        let ask = try XCTUnwrap(try demoSnapshot(now: Date()).asks.first { $0.id == 110 })
        return PlainTextRendering.render(try XCTUnwrap(ask.docSnapshot))
    }

    /// The plain text `PlainTextRendering` gives for a small plan with each
    /// list marker; heading offsets are looked up in the text.
    private func fixture() -> PlainTextDocument {
        let text = "Plan\n\nIntro text.\n\nSteps\n\n• A first item long enough to wrap onto a second line on a phone\n"
            + "• Second\n\n1. Numbered\n\n☐ Open task\n\nDetail\n\n"
        let headings = [("Plan", 1), ("Steps", 2), ("Detail", 3)].map { title, level in
            PlainTextDocument.Heading(offset: (text as NSString).range(of: title).location, level: level, title: title)
        }
        return PlainTextDocument(text: text, headings: headings)
    }

    private func font(_ styled: NSAttributedString, at offset: Int) -> UIFont? {
        styled.attribute(.font, at: offset, effectiveRange: nil) as? UIFont
    }

    private func headIndent(_ styled: NSAttributedString, at offset: Int) -> CGFloat {
        (styled.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? -1
    }

    private func width(_ prefix: String) -> CGFloat {
        (prefix as NSString).size(withAttributes: [.font: ReviewDocumentStyler.bodyFont(traits: traits)]).width
    }

    func testTheStringIsExactlyTheDocumentsText() throws {
        for document in [try demoReview(), fixture()] {
            XCTAssertEqual(ReviewDocumentStyler.attributed(document, traits: traits).string, document.text)
        }
    }

    func testEveryHeadingLineCarriesItsLevelsFont() throws {
        for document in [try demoReview(), fixture()] {
            let styled = ReviewDocumentStyler.attributed(document, traits: traits)
            XCTAssertFalse(document.headings.isEmpty)
            for heading in document.headings {
                let expected = ReviewDocumentStyler.headingFont(level: heading.level, traits: traits)
                XCTAssertEqual(font(styled, at: heading.offset), expected, heading.title)
                XCTAssertEqual(font(styled, at: heading.offset + (heading.title as NSString).length - 1), expected, "the whole line")
            }
        }
        let demo = try demoReview()
        let step = (demo.text as NSString).range(of: "Step 1").location
        XCTAssertEqual(font(ReviewDocumentStyler.attributed(demo, traits: traits), at: step), ReviewDocumentStyler.bodyFont(traits: traits))
        XCTAssertNotEqual(ReviewDocumentStyler.headingFont(level: 1, traits: traits), ReviewDocumentStyler.headingFont(level: 3, traits: traits))
    }

    func testListLinesHangTheirWrappedText() {
        let document = fixture()
        let styled = ReviewDocumentStyler.attributed(document, traits: traits)
        let text = document.text as NSString
        for marker in ["• ", "1. ", "☐ "] {
            let location = text.range(of: marker).location
            XCTAssertNotEqual(location, NSNotFound, marker)
            XCTAssertEqual(headIndent(styled, at: location), width(marker), accuracy: 0.01, marker)
        }
        XCTAssertEqual(headIndent(styled, at: text.range(of: "Intro").location), 0, "a paragraph does not hang")
        XCTAssertNil(ReviewDocumentStyler.listPrefix(of: "Step 2: the Stop hook"))
        XCTAssertEqual(ReviewDocumentStyler.listPrefix(of: "12. Twelfth"), "12. ")
    }

    /// Review focus 3: an empty document, no headings, a last heading
    /// without a newline, and a nested item whose indent includes its
    /// spaces.
    func testEdgeDocumentsKeepTheirTextAndIndentNestedItems() {
        XCTAssertEqual(ReviewDocumentStyler.attributed(PlainTextDocument(text: "", headings: []), traits: traits).length, 0)

        let plain = ReviewDocumentStyler.attributed(PlainTextDocument(text: "Just a paragraph.\n", headings: []), traits: traits)
        XCTAssertEqual(font(plain, at: 0), ReviewDocumentStyler.bodyFont(traits: traits))

        let tail = PlainTextDocument(text: "Body\n\nLast", headings: [.init(offset: 6, level: 2, title: "Last")])
        let styledTail = ReviewDocumentStyler.attributed(tail, traits: traits)
        XCTAssertEqual(styledTail.string, tail.text)
        XCTAssertEqual(font(styledTail, at: 9), ReviewDocumentStyler.headingFont(level: 2, traits: traits), "a last heading runs to the end")

        let nested = ReviewDocumentStyler.attributed(PlainTextDocument(text: "• Outer\n    • Inner item\n", headings: []), traits: traits)
        XCTAssertEqual(headIndent(nested, at: 0), width("• "), accuracy: 0.01)
        XCTAssertEqual(headIndent(nested, at: 8), width("    • "), accuracy: 0.01)
        XCTAssertGreaterThan(width("    • "), width("• "))
    }

    /// An anchor taken from a selection in the styled view is the anchor of
    /// the same range in the plain text.
    func testASelectionAnchorsAsOnThePlainText() throws {
        let document = try demoReview()
        let styled = ReviewDocumentStyler.attributed(document, traits: traits)
        let selection = (styled.string as NSString).range(of: "the Stop hook")
        XCTAssertNotEqual(selection.location, NSNotFound)
        let anchor = try XCTUnwrap(CommentAnchorBuilder.anchor(selection: selection, in: document))
        XCTAssertEqual(anchor, CommentAnchorBuilder.anchor(selection: (document.text as NSString).range(of: "the Stop hook"), in: document))
        XCTAssertEqual(anchor.heading, "Steps")
    }
}
```

- [ ] **Step 2: Regenerate and run, expect a compile failure**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=ReviewDocumentStylerTests > build/mobile-logs/t7.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild), with `cannot find 'ReviewDocumentStyler' in scope`.

- [ ] **Step 3: Write the styler**

Create `Sources/Features/Asks/ReviewDocumentStyler.swift`:

```swift
import UIKit
import WatchtowerKit

/// Styles a review snapshot for reading (design pass spec §3 bug 7):
/// headings by level, body text with 6 pt paragraph spacing, list lines
/// with a hanging indent the width of their marker. The string is exactly
/// `document.text`, because comment anchors are UTF-16 offsets into it; only
/// attributes change. Fonts follow Dynamic Type. Known limit: inline
/// emphasis and code blocks stay plain, because `PlainTextDocument` does not
/// mark them.
enum ReviewDocumentStyler {
    static let paragraphSpacing: CGFloat = 6

    static func attributed(_ document: PlainTextDocument, traits: UITraitCollection? = nil) -> NSAttributedString {
        let text = document.text as NSString
        let body = bodyFont(traits: traits)
        let styled = NSMutableAttributedString(string: document.text, attributes: [
            .font: body, .foregroundColor: UIColor.label, .paragraphStyle: paragraph(headIndent: 0)
        ])
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { line, range, _, _ in
            guard let line, let prefix = listPrefix(of: line) else { return }
            let indent = (prefix as NSString).size(withAttributes: [.font: body]).width
            styled.addAttribute(.paragraphStyle, value: paragraph(headIndent: indent), range: range)
        }
        for heading in document.headings where heading.offset < text.length {
            let rest = NSRange(location: heading.offset, length: text.length - heading.offset)
            let newline = text.range(of: "\n", options: [], range: rest)
            let end = newline.location == NSNotFound ? text.length : newline.location
            let range = NSRange(location: heading.offset, length: end - heading.offset)
            styled.addAttribute(.font, value: headingFont(level: heading.level, traits: traits), range: range)
        }
        return styled
    }

    /// The marker a list line starts with, its leading spaces included:
    /// "• ", "N. ", "☐ " or "☑ "; nil for any other line.
    static func listPrefix(of line: String) -> String? {
        let indent = String(line.prefix { $0 == " " })
        let rest = line.dropFirst(indent.count)
        if let marker = ["• ", "☐ ", "☑ "].first(where: { rest.hasPrefix($0) }) {
            return indent + marker
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return indent + digits + ". "
    }

    static func bodyFont(traits: UITraitCollection?) -> UIFont {
        UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
    }

    /// Level 1 `.title2` semibold, level 2 `.title3` semibold, deeper
    /// `.headline`.
    static func headingFont(level: Int, traits: UITraitCollection?) -> UIFont {
        switch level {
        case 1: scaled(.title2, weight: .semibold, traits: traits)
        case 2: scaled(.title3, weight: .semibold, traits: traits)
        default: UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
        }
    }

    /// A weighted system font at `style`'s default size, scaled by
    /// `UIFontMetrics` for Dynamic Type.
    private static func scaled(_ style: UIFont.TextStyle, weight: UIFont.Weight, traits: UITraitCollection?) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        return UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: base.pointSize, weight: weight), compatibleWith: traits)
    }

    private static func paragraph(headIndent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = paragraphSpacing
        style.headIndent = headIndent
        return style
    }
}
```

- [ ] **Step 4: Use it in the snapshot view**

In `ReviewAskView.swift`:
- Line 21 becomes `SnapshotTextView(document: document, selection: $selection)`.
- In `SnapshotTextView`, replace `let text: String` with `let document: PlainTextDocument`, and delete `view.font = .preferredFont(forTextStyle: .body)` in `makeUIView`.
- Replace `updateUIView` with:

```swift
    func updateUIView(_ view: UITextView, context: Context) {
        // Text only: assigning a selection here would report it back
        // through the delegate into the binding during a view update. The
        // styled string is `document.text` itself, so selections stay UTF-16
        // offsets into it.
        guard view.attributedText.string != document.text else { return }
        view.attributedText = ReviewDocumentStyler.attributed(document, traits: view.traitCollection)
    }
```

- Update the struct's doc comment to "The snapshot as a styled, read-only, selectable document; reports the selection in UTF-16 units of `document.text` (the anchors' offsets)."

- [ ] **Step 5: Regenerate, run, lint**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='ReviewDocumentStylerTests|AskFormTests' > build/mobile-logs/t7.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t7-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Asks WatchtowerMobile/Tests/ReviewDocumentStylerTests.swift \
  WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj
git commit -m "fix(mobile): the review snapshot renders headings and hanging list indents (bug 7)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot check (at the gate): in 14, "Ask guard v2" and "Steps" are headings and the steps are body text.

---

### Task 8: The recorder's chrome follows the phase (bug 9)

**Depends on:** Task 2 (`Radius`).

**Files:**
- Create: `Sources/Features/Recording/RecorderChrome.swift`
- Modify: `Sources/Features/Recording/RecordingView.swift:29-131` (`RecordingCaptureView`)
- Modify: `WatchtowerMobile/Tests/RecorderTests.swift`
- Regenerate: `project.pbxproj`

**Interfaces:**
- Consumes: `PhoneRecorderController.Phase` (`idle`, `recording`, `paused(PauseReason)`, `saving`, `saved`, `tooShort`, `denied`, `failed(String)`).
- Produces: `struct RecorderChrome: Equatable` with `init?(phase:)` (nil outside the four capture phases) and the fields `mark: Mark` (`starting`, `recording`, `paused`, `saving`), `markText`, `markTone`, `leftTitle`, `leftSystemImage`, `isLeftEnabled`, `areCaptureControlsEnabled`, `resumes: Bool`.

- [ ] **Step 1: Write the failing table test**

Append to `RecorderTests`:

```swift
    // MARK: - Bug 9: the chrome by phase

    /// Design pass spec §3 bug 9: idle (waiting for microphone permission)
    /// says Starting… with Pause disabled, never PAUSED and Resume.
    func testTheCaptureChromeFollowsThePhase() {
        let expected: [(PhoneRecorderController.Phase, RecorderChrome.Mark, String, String, Bool, Bool)] = [
            (.idle, .starting, "Starting…", "Pause", false, false),
            (.recording, .recording, "REC", "Pause", true, true),
            (.paused(.user), .paused, "PAUSED", "Resume", true, true),
            (.paused(.interruption), .paused, "PAUSED", "Resume", true, true),
            (.saving, .saving, "Saving…", "Pause", false, false)
        ]
        for (phase, mark, text, left, leftEnabled, controlsEnabled) in expected {
            let chrome = RecorderChrome(phase: phase)
            XCTAssertEqual(chrome?.mark, mark, "\(phase)")
            XCTAssertEqual(chrome?.markText, text, "\(phase)")
            XCTAssertEqual(chrome?.leftTitle, left, "\(phase)")
            XCTAssertEqual(chrome?.isLeftEnabled, leftEnabled, "\(phase)")
            XCTAssertEqual(chrome?.areCaptureControlsEnabled, controlsEnabled, "\(phase)")
            XCTAssertEqual(chrome?.resumes, mark == .paused, "\(phase)")
        }
        XCTAssertEqual(RecorderChrome(phase: .recording)?.markTone, .red)
        XCTAssertEqual(RecorderChrome(phase: .idle)?.markTone, .secondary)
        for phase: PhoneRecorderController.Phase in [.tooShort, .denied, .failed("boom")] {
            XCTAssertNil(RecorderChrome(phase: phase), "\(phase) is not a capture phase")
        }
    }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=RecorderTests > build/mobile-logs/t8.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild), with `cannot find 'RecorderChrome' in scope`.

- [ ] **Step 3: Write `RecorderChrome`**

Create `Sources/Features/Recording/RecorderChrome.swift`:

```swift
import Foundation

/// What the capture screen shows for a phase (design pass spec §3 bug 9):
/// the mark top right, the left control (Pause, or Resume while paused) and
/// whether Stop and Mark moment work. `.idle` is the screen while `start()`
/// awaits microphone permission, so it says Starting…, not PAUSED.
struct RecorderChrome: Equatable {
    enum Mark: Equatable {
        case starting, recording, paused, saving
    }

    let mark: Mark
    let markText: String
    let markTone: PhoneTone
    let leftTitle: String
    let leftSystemImage: String
    let isLeftEnabled: Bool
    /// Stop and Mark moment.
    let areCaptureControlsEnabled: Bool

    /// The left control resumes rather than pauses.
    var resumes: Bool { mark == .paused }
}

extension RecorderChrome {
    /// nil outside the capture phases (saved, too short, denied, failed).
    init?(phase: PhoneRecorderController.Phase) {
        switch phase {
        case .idle:
            self.init(mark: .starting, markText: "Starting…", markTone: .secondary, leftTitle: "Pause",
                      leftSystemImage: "pause.fill", isLeftEnabled: false, areCaptureControlsEnabled: false)
        case .recording:
            self.init(mark: .recording, markText: "REC", markTone: .red, leftTitle: "Pause",
                      leftSystemImage: "pause.fill", isLeftEnabled: true, areCaptureControlsEnabled: true)
        case .paused:
            self.init(mark: .paused, markText: "PAUSED", markTone: .secondary, leftTitle: "Resume",
                      leftSystemImage: "play.fill", isLeftEnabled: true, areCaptureControlsEnabled: true)
        case .saving:
            self.init(mark: .saving, markText: "Saving…", markTone: .secondary, leftTitle: "Pause",
                      leftSystemImage: "pause.fill", isLeftEnabled: false, areCaptureControlsEnabled: false)
        case .saved, .tooShort, .denied, .failed:
            return nil
        }
    }
}
```

- [ ] **Step 4: Lay the capture view out from the chrome only**

In `RecordingView.swift`, `RecordingCaptureView`:

- Replace lines 33-49 (from `var body` through the closing brace of the top `HStack`) with:

```swift
    var body: some View {
        let recorder = env.recorder
        let chrome = RecorderChrome(phase: recorder.phase)
        VStack(spacing: 20) {
            HStack {
                Button("Minimize") { recorder.minimize() }
                Spacer()
                if let chrome {
                    markView(chrome)
                }
            }
```

  Lines 51-89 (the context picker, label, timer, waveform, cap notice and status line) stay as they are. Replace line 91, `controls(recorder)`, with:

```swift
            if let chrome {
                controls(recorder, chrome)
            }
```

- Add:

```swift
    @ViewBuilder
    private func markView(_ chrome: RecorderChrome) -> some View {
        switch chrome.mark {
        case .recording:
            Label(chrome.markText, systemImage: "circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.footnote.weight(.bold))
                .foregroundStyle(chrome.markTone.color)
        case .starting:
            HStack(spacing: Spacing.compact) {
                ProgressView().controlSize(.small)
                Text(chrome.markText)
            }
            .font(.footnote.weight(.bold))
            .foregroundStyle(chrome.markTone.color)
        case .paused, .saving:
            Text(chrome.markText)
                .font(.footnote.weight(.bold))
                .foregroundStyle(chrome.markTone.color)
        }
    }
```

- Replace `controls(_:)` (lines 95-130) with:

```swift
    private func controls(_ recorder: PhoneRecorderController, _ chrome: RecorderChrome) -> some View {
        HStack(alignment: .center, spacing: 36) {
            RoundButton(systemImage: chrome.leftSystemImage, label: chrome.leftTitle, size: 64) {
                if chrome.resumes {
                    recorder.resume()
                } else {
                    recorder.pause()
                }
            }
            .disabled(!chrome.isLeftEnabled)

            Button {
                Task { await recorder.stop() }
            } label: {
                ZStack {
                    Circle().fill(.red)
                    RoundedRectangle(cornerRadius: Radius.chip).fill(.white).frame(width: 30, height: 30)
                }
                .frame(width: 88, height: 88)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
            .disabled(!chrome.areCaptureControlsEnabled)

            RoundButton(systemImage: "bookmark.fill", label: "Mark moment", size: 64) {
                recorder.markMoment()
            }
            .disabled(!chrome.areCaptureControlsEnabled)
        }
        .padding(.bottom, 8)
    }
```

- [ ] **Step 5: Regenerate, run, lint**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=RecorderTests > build/mobile-logs/t8.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t8-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Recording WatchtowerMobile/Tests/RecorderTests.swift \
  WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj
git commit -m "fix(mobile): the recorder says Starting… before it records, not PAUSED (bug 9)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate):
- 26 (idle): "Starting…" with a spinner, and no Resume.
- 26b: REC, Pause and an enabled Stop.
- 26c: PAUSED and Resume.

---

### Task 9: The Calendar mic button no longer covers the meeting (bug 2)

**Depends on:** Task 2 (`Spacing`).

**Files:**
- Modify: `Sources/Features/Calendar/AgendaModel.swift:187-235` (`AgendaDayModel.highlightedRowID`)
- Modify: `Sources/Features/Calendar/AgendaView.swift:28-108`
- Modify: `WatchtowerMobile/Tests/CalendarWiringTests.swift`

**Interfaces:**
- Produces: `AgendaDayModel.highlightedRowID: String?`, the `AgendaRow.id` ("event-<id>") of the highlighted card.

- [ ] **Step 1: Write the failing test**

Add to `CalendarWiringTests`, after `testTheCurrentOrNextMeetingIsHighlightedWithRecordAndPrep`:

```swift
    /// Bug 2 and review focus 5 (design pass spec §9.2): the agenda scrolls
    /// to today's current or next meeting; with none it stays at the top.
    func testOnlyTodaysCurrentOrNextMeetingIsScrolledTo() throws {
        let ended = event("ended", start: now.addingTimeInterval(-7_200), minutes: 30)
        let next = event("next", start: now.addingTimeInterval(1_500))
        let today = AgendaDayModel(
            day: now, snapshot: snapshot([next, ended]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
        )
        XCTAssertEqual(today.highlightedRowID, "event-next")
        let over = AgendaDayModel(day: now, snapshot: snapshot([ended]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar)
        XCTAssertNil(over.highlightedRowID, "every meeting is over")
        let later = event("later", start: day(1).addingTimeInterval(12 * 3_600))
        let tomorrow = AgendaDayModel(
            day: day(1), snapshot: snapshot([later]), recordings: PhoneRecordingsSnapshot(), now: now, calendar: calendar
        )
        XCTAssertNil(tomorrow.highlightedRowID, "only today highlights a meeting")
    }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=CalendarWiringTests > build/mobile-logs/t9.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild), with `value of type 'AgendaDayModel' has no member 'highlightedRowID'`.

- [ ] **Step 3: The model**

Add to `AgendaDayModel` after `nowLineText`:

```swift
    /// The highlighted card's row, scrolled to the middle on appear and on
    /// every day change (design pass spec §3 bug 2); nil when no card is
    /// highlighted, so the day stays at the top.
    var highlightedRowID: String? {
        rows.first { row in
            if case let .event(card) = row { card.isHighlighted } else { false }
        }?.id
    }
```

- [ ] **Step 4: The view**

In `AgendaView.swift`:
- Delete `.overlay(alignment: .bottomTrailing) { voiceNoteButton }` (line 32) and `.padding(20)` in `voiceNoteButton` (line 107). The clear row at lines 85-86 goes with the old `content(now:)`.
- Replace `content(now:)` (lines 54-89) with:

```swift
    private func content(now: Date) -> some View {
        let calendar = Calendar.current
        let snapshot = env.calendarReplica.snapshot
        let strip = WeekStripModel(
            selected: selectedDay,
            today: now,
            eventDays: WeekStripModel.eventDays(snapshot.events, calendar: calendar),
            calendar: calendar
        )
        let agenda = AgendaDayModel(
            day: selectedDay, snapshot: snapshot, recordings: env.phoneRecordings.snapshot, now: now, calendar: calendar
        )
        return ScrollViewReader { proxy in
            List {
                Section {
                    WeekStripView(strip: strip, select: { selectedDay = $0 }, shiftWeek: shiftWeek)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
                Section {
                    if let empty = agenda.emptyText {
                        Text(empty).foregroundStyle(.secondary)
                    }
                    ForEach(agenda.rows) { row in
                        switch row {
                        case let .event(card):
                            AgendaEventRow(card: card) { env.navigation.calendarPath.append(.event(card.id)) }
                        case let .nowLine(time):
                            NowLineView(time: time)
                        }
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            // The mic button takes room at the bottom: the list's last row
            // ends above it.
            .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                voiceNoteButton
                    .padding(.trailing, Spacing.large)
                    .padding(.bottom, Spacing.medium)
            }
            .task(id: selectedDay) {
                // The current or next meeting sits mid-screen, never under
                // the button at rest; without one the day stays at the top.
                guard let row = agenda.highlightedRowID else { return }
                proxy.scrollTo(row, anchor: .center)
            }
        }
    }
```

The rows' `ForEach(agenda.rows)` already identifies each row by `AgendaRow.id`, so `scrollTo` finds it. The card's Record and Prep stay as they are (Phase 4, C3).

- [ ] **Step 5: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='CalendarWiringTests|OrangeToneTests' > build/mobile-logs/t9.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t9-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Calendar WatchtowerMobile/Tests/CalendarWiringTests.swift
git commit -m "fix(mobile): the Calendar mic button sits in the bottom inset; the next meeting scrolls mid-screen (bug 2)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate):
- 03: the mic button does not overlap the highlighted "Acme roadmap review" card.
- 03e: the last row ends above the button.

---

### Task 10: Settings' Mac row and the numbered Mac checklist (bugs 10, 11)

**Depends on:** Task 2.

**Files:**
- Create: `Sources/Features/Settings/MacStatusRow.swift`
- Modify: `Sources/Features/Settings/SettingsView.swift:36-82` (one Mac row; `statusRow` goes)
- Modify: `Sources/Features/Onboarding/MacNotShowingView.swift:14-24`
- Modify: `WatchtowerMobile/Tests/SettingsWiringTests.swift`, `WatchtowerMobile/Tests/OrangeToneTests.swift:67-88`
- Regenerate: `project.pbxproj`

**Interfaces:**
- Consumes: `MacStatus` (`SettingsViewModel.swift:10-40`).
- Produces: `struct MacStatusRow: Equatable { label, value: String; tone: PhoneTone; init(status: MacStatus, now: Date, locale: Locale = .current); var toneUse: ToneUse }`.

- [ ] **Step 1: Write the failing tests**

Add to `SettingsWiringTests`, after `testNoHeartbeatShowsNotConnectedYet`:

```swift
    /// Bug 10 (design pass spec §3): the Mac's name on the left, its state
    /// on the right, in one row; green only while online.
    func testTheMacRowIsOneRowForEveryStatus() {
        let now = Date()
        let english = Locale(identifier: "en_US")
        let online = MacStatusRow(status: .online(macName: "Acme Mac"), now: now, locale: english)
        XCTAssertEqual([online.label, online.value], ["Acme Mac", "Online"])
        XCTAssertEqual(online.tone, .green)
        let offline = MacStatusRow(
            status: .offline(macName: "Acme Mac", lastSeen: now.addingTimeInterval(-180)), now: now, locale: english
        )
        XCTAssertEqual([offline.label, offline.value], ["Acme Mac", "Offline · seen 3 min. ago"])
        XCTAssertEqual(offline.tone, .secondary)
        let never = MacStatusRow(status: .notConnected, now: now, locale: english)
        XCTAssertEqual([never.label, never.value], ["Mac", "Not connected"])
        XCTAssertEqual(never.tone, .secondary)
        XCTAssertEqual(MacStatusRow(status: .online(macName: ""), now: now).label, "Mac", "an empty name reads Mac")
        XCTAssertEqual(online.toneUse.role, .mac)
    }
```

In `OrangeToneTests.testDataDrivenTonesAreNeverOrange`, after `let now = Date()` (line 79), add:

```swift
        for status in [MacStatus.notConnected, .online(macName: "Acme Mac"), .offline(macName: "Acme Mac", lastSeen: now)] {
            XCTAssertNotEqual(MacStatusRow(status: status, now: now).tone, .orange, "\(status)")
        }
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='SettingsWiringTests|OrangeToneTests' > build/mobile-logs/t10.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild), with `cannot find 'MacStatusRow' in scope`.

- [ ] **Step 3: Write `MacStatusRow`**

Create `Sources/Features/Settings/MacStatusRow.swift`:

```swift
import Foundation

/// Settings' one "Your Mac" row (design pass spec §3 bug 10): the Mac's
/// name, else "Mac", on the left; "Online", "Offline · seen 3 min. ago" or
/// "Not connected" with a dot in the tone on the right. Green only while
/// online, otherwise secondary; never orange.
struct MacStatusRow: Equatable {
    let label: String
    let value: String
    let tone: PhoneTone

    init(status: MacStatus, now: Date, locale: Locale = .current) {
        let name = status.macName ?? ""
        label = name.isEmpty ? "Mac" : name
        switch status {
        case .notConnected:
            value = "Not connected"
            tone = .secondary
        case .online:
            value = "Online"
            tone = .green
        case let .offline(_, lastSeen):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            formatter.dateTimeStyle = .named
            formatter.locale = locale
            value = "Offline · seen \(formatter.localizedString(for: lastSeen, relativeTo: now))"
            tone = .secondary
        }
    }

    var toneUse: ToneUse {
        ToneUse(element: "settings mac status", tone: tone, role: .mac)
    }
}
```

If the simulator's ICU prints the en_US short unit differently from "3 min. ago", look at the real output in the log. Keep `.short`, and change the test literal to the printed text only when that text is still an abbreviated relative age ("3 min ago" is acceptable; "3 minutes ago" is not).

- [ ] **Step 4: One row in Settings (bug 10)**

In `SettingsView.swift`, replace the `TimelineView` block in `yourMacSection` (lines 38-46) with:

```swift
            // The status turns offline by the clock alone, so re-evaluate it
            // periodically, not only on replica writes. One row: the Form
            // lays a TimelineView's views out in one cell.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let row = MacStatusRow(status: MacStatus(heartbeat: model.snapshot.heartbeat, now: context.date), now: context.date)
                LabeledContent {
                    HStack(spacing: Spacing.compact) {
                        Circle().fill(row.tone.color).frame(width: 8, height: 8)
                        Text(row.value)
                    }
                } label: {
                    Text(row.label)
                }
            }
```

Delete `statusRow(_:)` (lines 60-82).

- [ ] **Step 5: Numbered steps (bug 11)**

In `MacNotShowingView.swift`, replace the `Section { … } footer: { … }` (lines 16-23) with:

```swift
            Section {
                ForEach(Array(Self.checklist.enumerated()), id: \.offset) { index, item in
                    Label {
                        Text(item)
                    } icon: {
                        Image(systemName: "\(index + 1).circle").foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
            } header: {
                Text("Check on your Mac")
            } footer: {
                Text("Then choose Use Watchtower on iPhone in Settings → Mobile on the Mac, and scan the code it shows.")
            }
```

- [ ] **Step 6: Regenerate, run, lint**

Run: `make mobile-gen && make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='SettingsWiringTests|OrangeToneTests' > build/mobile-logs/t10.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t10-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Settings WatchtowerMobile/Sources/Features/Onboarding/MacNotShowingView.swift \
  WatchtowerMobile/Tests WatchtowerMobile/WatchtowerMobile.xcodeproj/project.pbxproj
git commit -m "fix(mobile): one Your Mac row in Settings; the Mac checklist is numbered steps (bugs 10, 11)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate):
- 27: "Acme Mac" on the left and "● Online" on the right, in one row.
- 35: items numbered 1–5 under "Check on your Mac", with no check marks.

---

### Phase 1 gate

Run once, by the controller, after Task 10. No code changes unless a check fails.

- [ ] **Load check.** Run `bash scripts/dev-health.sh`. If its last line is `HEALTH: overloaded`, stop and tell the owner what holds the machine.
- [ ] **Full phone suite.** Run `make mobile-test SIM="iPhone 17 Pro" > build/mobile-logs/gate1-test.log 2>&1; echo "exit=$?"`. Expect `exit=0`, with `ScreenshotTourTests.testTheTour` skipped.
- [ ] **Full lint.** Run `make lint-all > build/mobile-logs/gate1-lint.log 2>&1; echo "exit=$?"`. Expect `exit=0`. No Go file changes in this plan. If `make lint` (golangci) fails only on issues that already exist on `origin/main`, confirm with `make lint-diff` (expect no new issues), record it, and treat `make lint-swift` as the Swift gate.
- [ ] **After shots.** Run `make mobile-shots SIM="iPhone 17 Pro" SHOTS_DIR=build/mobile-shots/after-phase-1 > build/mobile-logs/gate1-shots.log 2>&1; echo "exit=$?"`. Expect `exit=0` and 84 PNGs.
- [ ] **Compare by eye** each pair (`before/NN-…` against `after-phase-1/NN-…`, light and dark) with the Read tool, against the shot checks of Tasks 3–10:
  - 06: status glyphs and priority dots.
  - 07, 07e and 08: bugs 3 and 4.
  - 13 and 14: bugs 6 and 7.
  - 18: bug 5.
  - 20 and 20e: bug 8's opaque bar. "Record this meeting" may still wrap until Phase 4 (C4).
  - 03 and 03e: bug 2.
  - 26, 26b and 26c: bug 9.
  - 27: bug 10.
  - 35: bug 11.
  - Every other screen: no unintended change.

  Bug 1 (shot 01) is checked at the Phase 2 gate. Fix any regression in a `fix(mobile): …` commit before Phase 2 starts.

---

## Phase 2: Now and Workbench

### Task 11: Now, and the shared ask rows (N1, N3–N5, bug 1)

**Depends on:** Task 4 (card, flat row, `FlowRow`), Task 5 (`RecordButton`).

**Files:**
- Modify: `Sources/Features/Workbench/WorkbenchModels.swift:78-114` (`WaitingCardModel`: `kindLabel` words, new `kindIcon`)
- Modify: `Sources/Features/Workbench/WorkbenchComponents.swift` (add `AskRow` and `WaitingStack`)
- Modify: `Sources/Features/Now/NowView.swift` (the whole file)
- Modify: `WatchtowerMobile/Tests/WorkbenchWiringTests.swift:76`, `WatchtowerMobile/Tests/SessionDetailWiringTests.swift:57`

**Interfaces:**
- Consumes: `FlatRow`, `FlatRowIcon`, `RowDivider`, `SectionHeader`, `View.card(_:padding:)`, `FlowRow` (Task 4); `RecordButton` (Task 5); `TypeScale`, `Spacing` (Task 2).
- Produces:
  - `WaitingCardModel.kindLabel` ("Review", "Check", "Question"; an unknown kind capitalized) and `WaitingCardModel.kindIcon` (`doc.text.magnifyingglass`, `checklist`, `questionmark.bubble`).
  - `AskRow(ask: WaitingCardModel, showsChevron: Bool = false, insets: EdgeInsets = RowInsets.flat)`.
  - `WaitingStack(asks:)` and `WaitingStack(asks:header:)`: one `card(.waiting)` of `AskRow` links, for a `ScrollView` only.

- [ ] **Step 1: Write the failing tests**

In `WorkbenchWiringTests.testTheMenuSublineAndWaitingStack`, replace line 76 with:

```swift
        XCTAssertEqual(menu.waiting.map(\.kindLabel), ["Check", "Question", "Review"], "words, not codes (design pass N4)")
        XCTAssertEqual(menu.waiting.map(\.kindIcon), ["checklist", "questionmark.bubble", "doc.text.magnifyingglass"])
```

In `SessionDetailWiringTests.testTheSessionsOpenAsksComeFirst`, replace line 57 with:

```swift
        XCTAssertEqual(detail.asks.map(\.kindLabel), ["Check", "Question"])
```

- [ ] **Step 2: Run, expect failures**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='WorkbenchWiringTests|SessionDetailWiringTests' > build/mobile-logs/t11.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild), with `value of type 'WaitingCardModel' has no member 'kindIcon'`.

- [ ] **Step 3: The model**

In `WorkbenchModels.swift`, change `WaitingCardModel`'s doc comment to `/// One Waiting-for-you ask: its kind (word and the Mac's icon), the title and "Session · #target · age" (Now prefixes the workbench).`. Add `let kindIcon: String` after `kindLabel`, with the doc comment `/// The Mac's kind icon (`OwnerAskPresentation.swift:136-142`).`, and replace the `kindLabel = switch` (lines 90-95) with:

```swift
        kindLabel = switch ask.kind {
        case .review: "Review"
        case .check: "Check"
        case .question: "Question"
        default: ask.kind.rawValue.capitalized
        }
        kindIcon = switch ask.kind {
        case .review: "doc.text.magnifyingglass"
        case .check: "checklist"
        default: "questionmark.bubble"
        }
```

- [ ] **Step 4: Run, expect a pass**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='WorkbenchWiringTests|SessionDetailWiringTests|NowWiringTests' > build/mobile-logs/t11.log 2>&1; echo "exit=$?"`
Expected: `exit=0`.

- [ ] **Step 5: `AskRow` and `WaitingStack`**

Append to `WorkbenchComponents.swift`:

```swift
/// One ask as a flat row (design pass spec §2.7), the Mac's "Waiting for
/// you" row: the kind icon in the waiting tone, the title, and a meta line
/// that starts with the kind word ("Question", semibold, waiting tone)
/// followed by the subline. Orange, not the Mac's accent, by the phone's
/// orange rule.
struct AskRow: View {
    let ask: WaitingCardModel
    var showsChevron = false
    var insets = RowInsets.flat

    var body: some View {
        FlatRow(icon: .symbol(ask.kindIcon, tone: ask.tone), title: ask.title, insets: insets) {
            HStack(spacing: Spacing.compact) {
                Text(ask.kindLabel).font(TypeScale.kind).foregroundStyle(ask.tone.color)
                Text("·")
                Text(ask.subline)
            }
        } trailing: {
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Waiting for you" as one waiting card of flat ask rows (design pass spec
/// N4, S2, D4): each row its own link to the ask's form, rows separated by
/// `RowDivider`s, an optional header on top. For a `ScrollView` only: one
/// `List` row cannot hold several links.
struct WaitingStack<Header: View>: View {
    let asks: [WaitingCardModel]
    @ViewBuilder var header: Header

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(asks.enumerated()), id: \.element.id) { index, ask in
                if index > 0 {
                    RowDivider()
                }
                NavigationLink(value: AskRoute(id: ask.id)) {
                    AskRow(ask: ask, showsChevron: true)
                }
                .buttonStyle(.plain)
            }
        }
        .card(.waiting, padding: EdgeInsets())
    }
}

extension WaitingStack where Header == EmptyView {
    init(asks: [WaitingCardModel]) {
        self.init(asks: asks) { EmptyView() }
    }
}
```

- [ ] **Step 6: Now as a `ScrollView`**

Replace `Sources/Features/Now/NowView.swift` with:

```swift
import SwiftUI

/// The Now tab (design pass spec §4 N1–N5): a line with the date and the
/// Mac's status, the next meeting with Record, Waiting for you across every
/// workbench as one card of flat rows, and the session summary on one
/// wrapping line. A `ScrollView`, so each ask row is its own link.
struct NowView: View {
    @Environment(AppEnvironment.self) private var env

    private var replica: WorkbenchReplicaModel { env.workbenchReplica }

    var body: some View {
        NavigationStack {
            // The Mac's status turns offline by the clock alone, and ages tick.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(NowModel(snapshot: replica.snapshot, now: context.date), date: context.date)
            }
            .navigationTitle("Now")
            .navigationDestination(for: String.self) { EventDetailView(eventID: $0) }
            .navigationDestination(for: AskRoute.self) { route in
                AskView(replica: replica, drafts: env.askDrafts, answerer: env.askAnswerer, askID: route.id)
            }
            .refreshable { await env.refresh() }
        }
    }

    private func content(_ model: NowModel, date: Date) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                statusLine(model, date: date)
                if let next = NextMeetingCardModel(events: env.calendarReplica.snapshot.events, now: date, calendar: .current) {
                    NextMeetingCardView(card: next)
                        .padding(.horizontal, Spacing.large)
                        .padding(.top, Spacing.medium)
                }
                SectionHeader("Waiting for you", tone: model.waitingHeaderTone)
                waiting(model)
                SectionHeader("Sessions")
                sessions(model)
            }
            .padding(.bottom, Spacing.large)
        }
        .background(Color(.systemBackground))
    }

    /// N1: the date on the left, the Mac's status dot and text on the right,
    /// with no card or capsule.
    private func statusLine(_ model: NowModel, date: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: Spacing.regular)
            HStack(spacing: 5) {
                Circle().fill(model.macChipTone.color).frame(width: 7, height: 7)
                Text(model.macChip).font(TypeScale.meta).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, Spacing.large)
        .padding(.top, Spacing.small)
    }

    /// N4: one waiting card, then "N more on your Mac".
    @ViewBuilder
    private func waiting(_ model: NowModel) -> some View {
        if let empty = model.emptyText {
            Text(empty)
                .font(TypeScale.rowTitle)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.large)
        } else {
            WaitingStack(asks: model.waiting)
                .padding(.horizontal, Spacing.large)
            if model.waitingMore > 0 {
                Text("\(model.waitingMore) more on your Mac")
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.large)
                    .padding(.top, Spacing.compact)
            }
        }
    }

    /// N5: the counts wrap and never stack one per line.
    private func sessions(_ model: NowModel) -> some View {
        Group {
            if model.sessionChips.isEmpty {
                Text("No sessions running").font(TypeScale.rowTitle).foregroundStyle(.secondary)
            } else {
                FlowRow {
                    ForEach(model.sessionChips) { SessionCountLabel(count: $0) }
                }
            }
        }
        .padding(.horizontal, Spacing.large)
    }
}

/// N3: "Next · in 25 min", the title, "14:00–14:45 · 5 people · prep ready"
/// and Record, in a plain card; tap the text for the event.
private struct NextMeetingCardView: View {
    @Environment(AppEnvironment.self) private var env
    let card: NextMeetingCardModel

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.medium) {
            NavigationLink(value: card.id) {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(card.header).font(TypeScale.meta).foregroundStyle(PhoneTone.accent.color)
                    Text(card.title).font(TypeScale.rowEmphasis).foregroundStyle(.primary)
                    Text(card.line).font(TypeScale.meta).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RecordButton(size: .regular) {
                Task { await env.recorder.recordMeeting(card.meetingEvent) }
            }
        }
        .card(.plain)
    }
}
```

- [ ] **Step 7: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='NowWiringTests|WorkbenchWiringTests|SessionDetailWiringTests|OrangeToneTests|CalendarWiringTests' > build/mobile-logs/t11.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t11-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both.

- [ ] **Step 8: Check bug 1 in the shots now**

Run: `make mobile-shots SIM="iPhone 17 Pro" SHOTS_DIR=build/mobile-shots/t11 > build/mobile-logs/t11-shots.log 2>&1; echo "exit=$?"` (expect `exit=0`). Open `01-now-light.png`, `01-now-dark.png` and `01e-now-light.png` with the Read tool.
- In 01, the Sessions line is entirely above the floating tab bar at rest.
- In 01e, the last row's bottom is above the tab bar's top.
- There is no card around the date, no blue ring in Record, and one orange card with three flat rows and no inner borders.
- The session counts take at most two lines.

If 01 still runs under the tab bar at rest, do not add an inset or `ignoresSafeArea` hack (spec bug 1). Stop and report it to the owner with the shot.

- [ ] **Step 9: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Now WatchtowerMobile/Sources/Features/Workbench WatchtowerMobile/Tests
git commit -m "feat(mobile): Now restyled — status line, plain next-meeting card, one waiting card of ask rows (bug 1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Remove More — Settings from Now's gear, the orange badge, the docs (§5, §7, N2)

**Depends on:** Task 11 (Now's toolbar and stack).

**Files:**
- Modify: `Sources/App/RootTabView.swift:1-62`, `:109-176` (three tabs, the badge appearance; `MoreView` goes)
- Modify: `Sources/Features/Now/NowView.swift` (`NowRoute`, the gear, the Settings destination)
- Modify: `Sources/Features/Settings/SettingsView.swift:4-6` (doc comment)
- Modify: `WatchtowerMobile/Tests/RootTabTests.swift` (the whole file), `WatchtowerMobile/Tests/ReplicaWiringTests.swift:177-179`
- Modify: `WatchtowerMobile/Tests/ScreenshotTourTests.swift` (row 04 goes)
- Modify: `docs/features/mobile-companion.md` (Tabs, Settings, Fetch loop, C6 Capture), `CLAUDE.md` (the mobile companion line)

**Interfaces:**
- Consumes: `NowView` (Task 11), `PhoneTone.waitingBadgeColor`.
- Produces:
  - `RootTabView.Tab` with `now`, `workbench` and `calendar` only.
  - `static func RootTabView.configureTabBarAppearance()`.
  - `enum NowRoute: Hashable, CaseIterable { case settings }`.

- [ ] **Step 1: Write the failing tests**

Replace `WatchtowerMobile/Tests/RootTabTests.swift` with:

```swift
import UIKit
import XCTest
@testable import WatchtowerMobile

/// The phone's tab bar (design pass spec §5, amending mobile POC spec §13
/// A4): Now, Workbench and Calendar, in that order; Settings is pushed from
/// Now's gear.
@MainActor
final class RootTabTests: XCTestCase {
    func testExactlyThreeTabsInOrder() {
        XCTAssertEqual(RootTabView.Tab.allCases.map(\.title), ["Now", "Workbench", "Calendar"])
        XCTAssertEqual(RootTabView.Tab.allCases.map(\.systemImage), ["clock", "hammer", "calendar"])
    }

    func testSettingsIsReachedFromNow() {
        XCTAssertEqual(NowRoute.allCases, [.settings])
        XCTAssertFalse(RootTabView.Tab.allCases.map(\.rawValue).contains("more"), "More is gone")
    }

    /// Spec §3: the foreground fetch runs every 5 s while Now (Settings
    /// included) or Workbench is on screen and every 30 s on Calendar.
    func testForegroundFetchIsFastOnNowAndWorkbenchOnly() {
        XCTAssertEqual(RootTabView.Tab.now.fetchInterval, .seconds(5))
        XCTAssertEqual(RootTabView.Tab.workbench.fetchInterval, .seconds(5))
        XCTAssertEqual(RootTabView.Tab.calendar.fetchInterval, .seconds(30))
    }

    /// §5: the open-ask badge is orange on every tab bar item layout, not
    /// only through `UITabBarItem.appearance()`.
    func testTheBadgeIsOrangeOnEveryTabBarLayout() {
        RootTabView.configureTabBarAppearance()
        let appearance = UITabBar.appearance().standardAppearance
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            XCTAssertEqual(layout.normal.badgeBackgroundColor, .systemOrange)
            XCTAssertEqual(layout.selected.badgeBackgroundColor, .systemOrange)
        }
        XCTAssertEqual(UITabBar.appearance().scrollEdgeAppearance?.stackedLayoutAppearance.normal.badgeBackgroundColor, .systemOrange)
    }
}
```

In `ReplicaWiringTests.testTheLoopFollowsTheTabCadenceAndPausesInTheBackground`, replace lines 177-179 with:

```swift
        env.setFetchInterval(RootTabView.Tab.calendar.fetchInterval)
        XCTAssertEqual(env.fetchInterval, .seconds(30))
        try await poll({ sleeper.requested.last == .seconds(30) && sleeper.waitingCount == 1 }, "the loop sleeps 30 s on Calendar")
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='RootTabTests|ReplicaWiringTests' > build/mobile-logs/t12.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild), with `cannot find 'NowRoute' in scope` and `type 'RootTabView' has no member 'configureTabBarAppearance'`.

- [ ] **Step 3: Three tabs and the badge appearance**

In `RootTabView.swift`:

- Replace the doc comment (lines 4-6) with `/// The three tabs (design pass spec §5, amending mobile POC spec §13 A4): Now, Workbench and Calendar. Settings is pushed from Now's gear; a voice note is the Calendar's mic button.`
- In `Tab`: change `case now, workbench, calendar, more` to `case now, workbench, calendar`, and delete the `.more` lines of `title` and `systemImage`. Replace `fetchInterval` with:

```swift
        /// Spec §3: 5 s while Now (Settings included) or Workbench is on
        /// screen, 30 s on Calendar.
        var fetchInterval: Duration {
            switch self {
            case .now, .workbench: .seconds(5)
            case .calendar: .seconds(30)
            }
        }
```

- Replace `init()` (lines 59-62) with:

```swift
    init() {
        Self.configureTabBarAppearance()
    }

    /// The only tab badge is the open-ask count: a waiting-for-you element,
    /// orange. `UITabBarItem.appearance().badgeColor` alone did not reach
    /// the iOS 26 tab bar in the review captures (it drew red), so every
    /// item layout of the tab bar's appearance carries the colour too.
    static func configureTabBarAppearance() {
        UITabBarItem.appearance().badgeColor = PhoneTone.waitingBadgeColor
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            layout.normal.badgeBackgroundColor = PhoneTone.waitingBadgeColor
            layout.selected.badgeBackgroundColor = PhoneTone.waitingBadgeColor
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
```

- In `content(for:)`, delete `case .more: MoreView()`. Delete `MoreView` (lines 124-176).

- [ ] **Step 4: The gear on Now**

In `NowView.swift`, add above `struct NowView`:

```swift
/// A screen pushed on Now's stack: Settings, from the gear (design pass
/// spec §5).
enum NowRoute: Hashable, CaseIterable {
    case settings
}
```

and, after `.navigationTitle("Now")`, add:

```swift
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: NowRoute.settings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: NowRoute.self) { _ in SettingsView() }
```

`SettingsView` reads `AppEnvironment` and `LinkingViewModel`, which `AppRootView` injects above the tabs. In `SettingsView.swift`, line 4's doc comment becomes `/// Settings (pushed from Now's gear): Your Mac, read-only accounts, the Workbench`.

- [ ] **Step 5: The tour loses row 04**

In `ScreenshotTourTests.workbenchShots()`, delete the `Shot(number: "04", slug: "more", …)` row. The tour now writes 82 PNGs.

- [ ] **Step 6: Run, expect a pass**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='RootTabTests|ReplicaWiringTests|WorkbenchWiringTests|ScreenshotTourTests|SettingsWiringTests' > build/mobile-logs/t12.log 2>&1; echo "exit=$?"`
Expected: `exit=0`. Then run `grep -rn 'MoreView\|\.more\b' WatchtowerMobile/Sources WatchtowerMobile/Tests` and expect no output.

- [ ] **Step 7: Docs (§7)**

In `docs/features/mobile-companion.md`, "App shell (A11)":
- **Tabs.** Replace the first sentence with: "Now, Workbench and Calendar (design pass §5: More is gone). Settings is pushed from the gear in Now's toolbar (`NowRoute.settings`); a free voice note is the Calendar's mic button." Then add after the badge sentence: "`RootTabView.configureTabBarAppearance()` sets the badge colour on every `UITabBarAppearance` item layout as well as `UITabBarItem.appearance()`, because the latter alone drew red on the iOS 26 tab bar in the captures."
- **Settings.** Replace "Your Mac:" with "Pushed from Now's gear. Your Mac: one row (the Mac's name, then Online, Offline · seen … ago, or Not connected, with a dot);".
- **Fetch loop.** After "5 s while Now or Workbench is on screen, 30 s otherwise", add "(Settings, pushed on Now, runs at Now's 5 s)".

In "Phone recorder and uploader (C6)", **Capture.**, replace "More's entry records a voice note (no event)" with "the Calendar's mic button records a voice note (no event)".

In `CLAUDE.md`, in the mobile companion line, replace `Now/Workbench/Calendar/More` with `Now/Workbench/Calendar, Settings from Now's gear`.

- [ ] **Step 8: Lint and commit**

Run: `make lint-swift > build/mobile-logs/t12-lint.log 2>&1; echo "exit=$?"` (expect `exit=0`), then:

```bash
git add WatchtowerMobile/Sources WatchtowerMobile/Tests docs/features/mobile-companion.md CLAUDE.md
git commit -m "feat(mobile): three tabs — Settings from Now's gear, More removed, orange badge on every tab bar layout

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: The Workbench list as flat rows (W1–W3)

**Depends on:** Task 11 (Now no longer uses `FlowCounts`).

**Files:**
- Modify: `Sources/Features/Workbench/WorkbenchModels.swift:116-190` (`WorkbenchCardModel.countsLine` becomes `doneLine`; `BoardCounts` keeps only what Task 14 needs)
- Modify: `Sources/Features/Workbench/WorkbenchListView.swift:39-113` (a plain list of three-line rows; `FlowCounts` goes)
- Modify: `WatchtowerMobile/Tests/WorkbenchWiringTests.swift:24-44`

**Interfaces:**
- Consumes: `Pill`, `SessionDot`, `ThinProgressBar` (Task 4); `TypeScale`, `Spacing`, `RowInsets`.
- Produces: `WorkbenchCardModel.doneLine: String` ("1/8 done", or "No targets" at 0 of 0). `countsLine` is removed.

- [ ] **Step 1: Write the failing tests**

In `WorkbenchWiringTests`, replace line 33 with `XCTAssertEqual(acme.doneLine, "1/8 done")` and line 41 with `XCTAssertEqual(notes.doneLine, "No targets", "0 of 0 draws no bar and says so")`.

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER=WorkbenchWiringTests > build/mobile-logs/t13.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild), with `value of type 'WorkbenchCardModel' has no member 'doneLine'`.

- [ ] **Step 3: The model**

In `WorkbenchCardModel`, replace `let countsLine: String` with:

```swift
    /// "1/8 done"; "No targets" for a 0-of-0 board (which draws no bar).
    let doneLine: String
```

and replace line 179 (`countsLine = …`) with `doneLine = total > 0 ? "\(workbench.doneTargets)/\(total) done" : "No targets"`. In `BoardCounts.parts`, drop the `includeDone` parameter and its branch. Its one remaining caller, `WorkbenchMenuModel` (line 215), passes `includeDone: false`; change that call to `BoardCounts.parts(workbench)`. Task 14 replaces `parts` with `items`.

- [ ] **Step 4: The rows**

In `WorkbenchListView.swift`, in `content`:
- Add `.listRowInsets(RowInsets.flat)` to the `NavigationLink`.
- Change the header to `Text(…).font(TypeScale.sectionHeader).textCase(nil)` and the footer to `Text(…).font(TypeScale.meta)`.
- Add `.listStyle(.plain)` after the `List`.

Replace `WorkbenchCardView` and `FlowCounts` (lines 67-113) with:

```swift
/// One Workbench list row (design pass spec W1–W3): the name and its pills,
/// the folder and the branch, then compact session counts with the board's
/// progress.
struct WorkbenchCardView: View {
    let card: WorkbenchCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Text(card.name).font(TypeScale.rowEmphasis).lineLimit(1)
                Spacer(minLength: Spacing.regular)
                ForEach(card.pills) { pill in
                    Pill(text: pill.text, tone: pill.tone, style: pill.tone == .secondary ? .neutral : .tinted)
                }
            }
            HStack(spacing: Spacing.compact) {
                Text(card.folder)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let branch = card.branch {
                    Pill(text: branch, style: .neutral, monospaced: true)
                }
            }
            HStack(spacing: Spacing.regular) {
                ForEach(card.stateCounts) { count in
                    HStack(spacing: 3) {
                        SessionDot(tone: count.tone, isRing: count.isRing, size: 7)
                        Text("\(count.amount)").font(TypeScale.time).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(count.text)
                }
                if let progress = card.progress {
                    ThinProgressBar(value: progress, tone: card.progressTone).frame(width: 64)
                }
                Text(card.doneLine).font(TypeScale.meta).foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 5: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='WorkbenchWiringTests|OrangeToneTests|NowWiringTests' > build/mobile-logs/t13.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t13-lint.log 2>&1; echo "exit=$?"`. Expect `exit=0` for both. Then run `grep -rn 'FlowCounts\|countsLine' WatchtowerMobile/Sources WatchtowerMobile/Tests` and expect no output.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Workbench WatchtowerMobile/Tests/WorkbenchWiringTests.swift
git commit -m "feat(mobile): the Workbench list as three-line flat rows with compact counts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot check (at the gate): in 02 each row is three lines, with no list of six state rows and no "3 in progress · 3 todo …". "3 waiting" is orange, "1 error" red, "idle" neutral, and the branch a monospaced neutral pill.

---

### Task 14: Workbench → Sessions (S1–S3)

**Depends on:** Task 11 (`WaitingStack`), Task 13 (the list no longer uses `CountPill`).

**Files:**
- Modify: `Sources/Features/Workbench/WorkbenchModels.swift:1-76` (`SessionRowModel`), `:116-131` (`BoardCounts`), `:192-236` (`WorkbenchMenuModel`)
- Modify: `Sources/Features/Workbench/WorkbenchComponents.swift` (`SessionRowView` becomes a `FlatRow`; `CountPill` goes)
- Modify: `Sources/Features/Workbench/WorkbenchView.swift:90-149` (the header line, Sessions as a `ScrollView`)
- Modify: `Sources/Features/Workbench/BoardTargetDetailView.swift:96-102` ("Sessions on it" passes list insets)
- Modify: `WatchtowerMobile/Tests/SessionRowTests.swift`, `WatchtowerMobile/Tests/WorkbenchWiringTests.swift:68-80`

**Interfaces:**
- Consumes: `MetaItem`, `MetaLine`, `FlatRow`, `RowDivider`, `SectionHeader`, `Pill`, `CountBadge` (Task 4); `WaitingStack` (Task 11).
- Produces:
  - `SessionRowModel.metaItems: [MetaItem]`; `reportLine`, `reportProgress`, `progressTone` and `closedLabel` are removed, while `glyph` stays.
  - `typealias BoardCountItem = MetaItem`, `BoardCounts.items(_:) -> [BoardCountItem]`.
  - `WorkbenchMenuModel.branch: String?` and `boardCounts: [BoardCountItem]` replace `subline`.
  - `SessionRowView(row:insets:)`.

- [ ] **Step 1: Write the failing tests**

In `SessionRowTests`:
- `testTheReportLineRendersTheFixtureValues`: replace its two assertions with `XCTAssertEqual(row.metaItems.dropFirst().map(\.text), ["#415 · 1/2", "PR #175 open"])`.
- `testARecordWithoutAReportTargetHasNoReportLine`: replace both assertions with `XCTAssertEqual(row.metaItems.map(\.text), [row.caption], "the caption alone")`.
- `testAReportWithoutAPRLineOrTotalsStaysShort`: `XCTAssertEqual(noPR.metaItems.dropFirst().map(\.text), ["#415 · 0/3"])` and `XCTAssertEqual(noTotals.metaItems.dropFirst().map(\.text), ["#415"])`; delete the `reportProgress` line.
- `testOpenAndClosedAskCounts`: `XCTAssertEqual(row.metaItems.last?.text, "3 closed")` and `XCTAssertFalse(none.metaItems.contains { $0.text.hasSuffix("closed") })`.
- Add:

```swift
    /// Review focus 2 (design pass S3, §9.4): the caption in the session's
    /// tone first, then the report, the PR line and "N closed" last, so it
    /// is the first to truncate; no mini progress bar.
    func testTheMetaLineIsCaptionThenReportThenPRThenClosed() throws {
        let row = SessionRowModel(try session([
            "state_kind": "waiting_on_ask", "state_caption": "Waiting for you · ask #109 · 2 asks", "state_tone": "orange",
            "open_asks": 2, "closed_asks": 2, "report_target_id": 415, "report_done": 1, "report_total": 2,
            "report_pr_line": "PR #175 open"
        ]), now: Date())
        XCTAssertEqual(row.metaItems.map(\.text), ["Waiting for you · ask #109 · 2 asks", "#415 · 1/2", "PR #175 open", "2 closed"])
        XCTAssertEqual(row.metaItems.first?.tone, .orange)
        XCTAssertEqual(row.metaItems.first?.role, .session(isWaiting: true))
        XCTAssertTrue(row.metaItems.dropFirst().allSatisfy { $0.tone == .secondary })
        XCTAssertFalse(row.toneUses.contains { $0.role == .progress }, "the mini progress bar is gone")
    }
```

In `WorkbenchWiringTests.testTheMenuSublineAndWaitingStack`, replace line 71 with:

```swift
        XCTAssertEqual(menu.branch, "main")
        XCTAssertEqual(menu.boardCounts.map(\.text), ["3 in progress", "3 todo", "1 blocked"])
        XCTAssertEqual(menu.boardCounts.map(\.tone), [.blue, .secondary, .red])
        XCTAssertTrue(menu.boardCounts.allSatisfy { $0.role == .status })
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='SessionRowTests|WorkbenchWiringTests' > build/mobile-logs/t14.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild), with `value of type 'SessionRowModel' has no member 'metaItems'`.

- [ ] **Step 3: `SessionRowModel`**

Replace lines 4-76 of `WorkbenchModels.swift` with:

```swift
/// One SESSIONS row (spec §4.5, design pass S3): the Mac's resolved dot and
/// caption drawn as given (PROJ-11 stays on the Mac), then one meta line.
struct SessionRowModel: Equatable, Identifiable {
    let id: Int64
    let title: String
    /// The Mac's caption; a session that is not live adds its age
    /// ("Stopped · 3h").
    let caption: String
    let tone: PhoneTone
    /// An SF Symbol name; nil when the Mac sent none. Kept in the model; the
    /// phone draws the dot only (design pass §9.1).
    let glyph: String?
    let isRing: Bool
    /// The caption in the session's tone, then `#<target> · <done>/<total>`,
    /// the PR line and "N closed" in secondary; the last truncates first.
    let metaItems: [MetaItem]
    let openAsks: Int
    let openAsksTone = PhoneTone.waitingForYou
    /// The Mac's orange states plus a session with open asks (finished with
    /// open asks): the only sessions whose orange is a waiting element.
    private let isWaiting: Bool

    init(_ session: TerminalSessionState, now: Date) {
        let caption = session.live
            ? session.stateCaption
            : "\(session.stateCaption) · \(CompactAge.string(from: session.lastActiveAt, now: now))"
        let tone = PhoneTone(session.stateTone)
        let isWaiting = [.waitingOnAsk, .needsApproval].contains(session.stateKind) || session.openAsks > 0
        id = session.id
        title = session.title
        self.caption = caption
        self.tone = tone
        self.isWaiting = isWaiting
        glyph = session.stateGlyph.isEmpty ? nil : session.stateGlyph
        isRing = session.isRing
        openAsks = session.openAsks

        var items = [MetaItem(text: caption, tone: tone, role: .session(isWaiting: isWaiting))]
        if let target = session.reportTargetID {
            var report = "#\(target)"
            if let done = session.reportDone, let total = session.reportTotal {
                report += " · \(done)/\(total)"
            }
            items.append(MetaItem(text: report, tone: .secondary, role: .info))
            if let pr = session.reportPRLine, !pr.isEmpty {
                items.append(MetaItem(text: pr, tone: .secondary, role: .info))
            }
        }
        if session.closedAsks > 0 {
            items.append(MetaItem(text: "\(session.closedAsks) closed", tone: .secondary, role: .info))
        }
        metaItems = items
    }

    var toneUses: [ToneUse] {
        var uses = [
            ToneUse(element: "session \(id) dot", tone: tone, role: .session(isWaiting: isWaiting)),
            ToneUse(element: "session \(id) label", tone: tone, role: .session(isWaiting: isWaiting))
        ]
        if openAsks > 0 {
            uses.append(ToneUse(element: "session \(id) open asks", tone: openAsksTone, role: .ask))
        }
        return uses
    }
}
```

- [ ] **Step 4: Board counts and the menu model**

Replace `BoardCounts` with:

```swift
/// One coloured count of the Workbench header line, role `.status`.
typealias BoardCountItem = MetaItem

/// The board's counts for the Workbench header (design pass S1): "3 in
/// progress" blue, "3 todo" secondary, "1 blocked" red (only when there is
/// one). "todo" is the open targets that are neither in progress nor
/// blocked (in review counts there too).
enum BoardCounts {
    static func items(_ workbench: Workbench) -> [BoardCountItem] {
        let todo = max(0, workbench.openTargets - workbench.inProgressTargets - workbench.blockedTargets)
        var items = [
            BoardCountItem(text: "\(workbench.inProgressTargets) in progress", tone: .blue, role: .status),
            BoardCountItem(text: "\(todo) todo", tone: .secondary, role: .status)
        ]
        if workbench.blockedTargets > 0 {
            items.append(BoardCountItem(text: "\(workbench.blockedTargets) blocked", tone: .red, role: .status))
        }
        return items
    }
}
```

In `WorkbenchMenuModel`, replace `let subline: String` with:

```swift
    /// The branch, "detached", or nil when the Mac has none yet.
    let branch: String?
    let boardCounts: [BoardCountItem]
```

Replace lines 214-215 (`let branch = …` and `subline = …`) with:

```swift
        let branchName = workbench.detached ? "detached" : workbench.branch
        branch = branchName.isEmpty ? nil : branchName
        boardCounts = BoardCounts.items(workbench)
```

and `toneUses` with:

```swift
    var toneUses: [ToneUse] {
        [ToneUse(element: "workbench \(id) waiting header", tone: waitingHeaderTone, role: .waiting)]
            + boardCounts.map { ToneUse(element: "workbench \(id) \($0.text)", tone: $0.tone, role: $0.role) }
            + waiting.map(\.toneUse) + sessions.flatMap(\.toneUses)
    }
```

Update the struct's doc comment to "Level 2 of the Workbench tab: the branch and board counts, the Waiting-for-you stack with its closed asks, and the SESSIONS list."

- [ ] **Step 5: `SessionRowView` as a flat row**

In `WorkbenchComponents.swift`, delete `CountPill`, and replace `SessionRowView` with:

```swift
/// One SESSIONS row (design pass S3): the session dot, the title on one
/// line, one meta line, and the open-ask count as a badge. In a `List`, pass
/// `insets: EdgeInsets()`.
struct SessionRowView: View {
    let row: SessionRowModel
    var insets = RowInsets.flat

    var body: some View {
        FlatRow(icon: .session(tone: row.tone, isRing: row.isRing), title: row.title, titleLineLimit: 1, insets: insets) {
            MetaLine(items: row.metaItems)
        } trailing: {
            if row.openAsks > 0 {
                CountBadge(count: row.openAsks, tone: row.openAsksTone)
                    .accessibilityLabel(row.openAsks == 1 ? "1 open ask" : "\(row.openAsks) open asks")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
```

In `BoardTargetDetailView.swift`, "Sessions on it" (line 99), use `SessionRowView(row: row, insets: EdgeInsets())`.

- [ ] **Step 6: The Workbench screen**

In `WorkbenchView.swift`, in `content(_:now:)`, replace the monospaced subline `Text` (lines 92-96) with:

```swift
            HStack(spacing: Spacing.regular) {
                if let branch = menu.branch {
                    Pill(text: branch, style: .neutral, monospaced: true)
                }
                MetaLine(items: menu.boardCounts).font(TypeScale.meta)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.large)
```

Replace `sessions(_:)` (lines 109-149) with:

```swift
    /// Sessions (design pass S2, S3): a `ScrollView`, so each ask row of the
    /// waiting card is its own link.
    private func sessions(_ menu: WorkbenchMenuModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !menu.waiting.isEmpty {
                    SectionHeader(menu.waitingHeader, tone: menu.waitingHeaderTone)
                    WaitingStack(asks: menu.waiting)
                        .padding(.horizontal, Spacing.large)
                }
                if let closed = menu.closedLabel {
                    DisclosureGroup(closed, isExpanded: $showClosed) {
                        ForEach(menu.closedAsks) { ask in
                            NavigationLink(value: AskRoute(id: ask.id)) {
                                VStack(alignment: .leading, spacing: Spacing.tight) {
                                    Text(ask.title).font(TypeScale.rowTitle).foregroundStyle(.primary)
                                    Text(AskText.status(ask)).font(TypeScale.meta).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .padding(RowInsets.flat)
                }
                SectionHeader("Sessions")
                if let empty = menu.sessionsEmptyText {
                    Text(empty).foregroundStyle(.secondary).padding(.horizontal, Spacing.large)
                } else {
                    ForEach(Array(menu.sessions.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            RowDivider()
                        }
                        NavigationLink(value: SessionRoute(id: row.id)) { SessionRowView(row: row) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, Spacing.large)
        }
        .background(Color(.systemBackground))
    }
```

The Sessions/Board segment and the switcher stay (S4). Update the struct's doc comment: "the branch and board counts" in place of "the mono subline".

- [ ] **Step 7: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='SessionRowTests|WorkbenchWiringTests|OrangeToneTests|StartSheetWiringTests|SessionDetailWiringTests|BoardFilterTests' > build/mobile-logs/t14.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t14-lint.log 2>&1; echo "exit=$?"`. Expect `exit=0` for both. Then run `grep -rn 'CountPill\|reportLine\|reportProgress\|menu\.subline' WatchtowerMobile/Sources WatchtowerMobile/Tests` and expect no output.

- [ ] **Step 8: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Workbench WatchtowerMobile/Tests
git commit -m "feat(mobile): Workbench Sessions — branch pill and coloured counts, one waiting card, two-line session rows

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate):
- 05: the header line shows a monospaced "main" pill, then "3 in progress" in blue, "3 todo" and "1 blocked" in red.
- 05: there is one orange card with no card inside it, and "▸ 3 closed" below it.
- 05: every session row is two lines, with an orange badge on rows that have open asks.

---

### Task 15: Board and target detail (B1, B2, T1, T4–T6)

**Depends on:** Task 6 (target detail layout), Task 14 (`MetaLine` in use; target detail's sessions).

**Files:**
- Modify: `Sources/Features/Workbench/BoardModel.swift` (`BoardRowModel.hasMeta`)
- Modify: `Sources/Features/Workbench/BoardView.swift` (a plain list, chips, flat rows)
- Modify: `Sources/Features/Workbench/BoardTargetDetailModel.swift:70` and `:233-235` (`asksHeaderTone` and its `ToneUse`)
- Modify: `Sources/Features/Workbench/BoardTargetDetailView.swift` (principal title, Work on it, asks section, read-only line)
- Modify: `Sources/Features/Workbench/WorkbenchComponents.swift` (`WaitingCardView` goes)
- Modify: `WatchtowerMobile/Tests/BoardFilterTests.swift`

**Interfaces:**
- Consumes: `FilterChip`, `FlatRow`, `MetaLine`, `PriorityDot`, `ThinProgressBar` (Tasks 3–4); `AskRow` (Task 11).
- Produces: `BoardRowModel.hasMeta: Bool` and `BoardTargetDetailModel.asksHeaderTone: PhoneTone`.

- [ ] **Step 1: Write the failing test**

Add to `BoardFilterTests`:

```swift
    /// Design pass B2: a row draws a meta line only when it has a dot,
    /// details or a progress bar.
    func testARowWithNothingToSayHasNoMetaLine() throws {
        let open = try board(.open)
        XCTAssertTrue(try XCTUnwrap(open.roots.first { $0.id == 400 }?.children.first { $0.id == 415 }).row.hasMeta)
        let dismissed = try XCTUnwrap(try board(.archive).roots.first { $0.id == 391 }).row
        XCTAssertFalse(dismissed.hasMeta, "medium, no details, no progress")
    }
```

Add to `OrangeToneTests.testOrangeOnlyOnWaitingAndAskElementsAcrossTheDemoScreens`, after the target loop (line 26), a check that the header is swept:

```swift
        let target415 = try XCTUnwrap(BoardTargetDetailModel(targetID: 415, snapshot: snapshot, now: now))
        XCTAssertTrue(target415.toneUses.contains { $0.element == "target 415 waiting header" && $0.role == .waiting })
```

- [ ] **Step 2: Run, expect a compile failure**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='BoardFilterTests|OrangeToneTests' > build/mobile-logs/t15.log 2>&1; echo "exit=$?"`
Expected: a non-zero `exit=` (make reports `Error 65` from xcodebuild), with `value of type 'BoardRowModel' has no member 'hasMeta'`.

- [ ] **Step 3: The models**

In `BoardRowModel`, add:

```swift
    /// A meta line is drawn only with something on it.
    var hasMeta: Bool { priorityTone != nil || !details.isEmpty || progressValue != nil }
```

In `BoardTargetDetailModel`, add `let asksHeaderTone = PhoneTone.waitingForYou` after `let asks`, and change `toneUses` to:

```swift
    var toneUses: [ToneUse] {
        row.toneUses + children.flatMap(\.toneUses) + sessions.flatMap(\.toneUses) + asks.map(\.toneUse)
            + (asks.isEmpty ? [] : [ToneUse(element: "target \(id) waiting header", tone: asksHeaderTone, role: .waiting)])
    }
```

- [ ] **Step 4: Run, expect a pass**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='BoardFilterTests|OrangeToneTests' > build/mobile-logs/t15.log 2>&1; echo "exit=$?"`
Expected: `exit=0`.

- [ ] **Step 5: The board (B1, B2)**

In `BoardView.swift`:

- `.listStyle(.insetGrouped)` becomes `.listStyle(.plain)`.
- Replace `chips(_:)` with:

```swift
    /// B1: the chips in one row when they fit, else a horizontal scroll whose
    /// trailing 24 pt fade shows that they scroll.
    private func chips(_ board: BoardModel) -> some View {
        ViewThatFits(in: .horizontal) {
            chipRow(board).padding(.horizontal, Spacing.large)
            ScrollView(.horizontal, showsIndicators: false) {
                chipRow(board).padding(.horizontal, Spacing.large)
            }
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
                }
            }
        }
    }

    private func chipRow(_ board: BoardModel) -> some View {
        HStack(spacing: Spacing.compact) {
            ForEach(BoardFilter.allCases) { chip in
                FilterChip(title: chip.title, count: board.count(chip), isSelected: chip == filter) { filter = chip }
            }
        }
    }
```

- In `BoardNodeView.link`, add `.listRowInsets(RowInsets.flat)` to the `NavigationLink`.
- Replace `BoardRowView` with:

```swift
/// A board row (design pass B2): the status glyph in its tone, the title (two
/// lines; struck through and secondary when done), a meta line with the
/// priority dot first, and a thin bar under it when the progress is a
/// percent. Nothing on the right but the list's chevron.
struct BoardRowView: View {
    let row: BoardRowModel

    var body: some View {
        FlatRow(icon: .symbol(row.statusGlyph, tone: row.statusTone), title: row.title, isDimmed: row.isDimmed, insets: EdgeInsets()) {
            if row.hasMeta {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    HStack(spacing: Spacing.compact) {
                        PriorityDot(priority: row.priority)
                        MetaLine(items: row.details)
                    }
                    if let value = row.progressValue {
                        ThinProgressBar(value: value, tone: row.progressTone, height: 3).frame(width: 64)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 6: Target detail (T1, T4, T5, T6)**

In `BoardTargetDetailView.swift`:

- T1: after `.navigationBarTitleDisplayMode(.inline)`, add:

```swift
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: Spacing.small) {
                    if let title = replica.snapshot.targets.first(where: { $0.id == targetID })?.text {
                        Text(title).font(.headline).lineLimit(1)
                    }
                    Text("#\(targetID)").font(TypeScale.time).foregroundStyle(.secondary)
                }
            }
        }
```

`.navigationTitle("#\(targetID)")` stays, for the next screen's back button.

- T4: replace the button in `workOnIt` (lines 152-159) with:

```swift
            Button {
                startingSession = true
            } label: {
                Label("Work on it in a session", systemImage: "play")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.borderless)
```

and its caption's `.font(.caption)` with `.font(TypeScale.meta)`.

- T5: replace the "Waiting for you" section (lines 73-80) with:

```swift
            if !detail.asks.isEmpty {
                Section {
                    ForEach(detail.asks) { card in
                        NavigationLink(value: AskRoute(id: card.id)) { AskRow(ask: card, insets: EdgeInsets()) }
                    }
                } header: {
                    Text("Waiting for you")
                        .font(TypeScale.sectionHeader)
                        .textCase(nil)
                        .foregroundStyle(detail.asksHeaderTone.color)
                }
            }
```

- T6: in `readOnlyLine`, change `HStack(spacing: 6)` to `HStack(spacing: Spacing.compact)`, the progress `Text` to `.font(TypeScale.time).foregroundStyle(.secondary)`, and the trailing `.font(.subheadline)` to `.font(TypeScale.meta)`.

In `WorkbenchComponents.swift`, delete `WaitingCardView`. Then run `grep -rn 'WaitingCardView' WatchtowerMobile/Sources` and expect no output.

- [ ] **Step 7: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='BoardFilterTests|OrangeToneTests|BoardWriteWiringTests|WorkbenchWiringTests' > build/mobile-logs/t15.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t15-lint.log 2>&1; echo "exit=$?"`.
Expected: `exit=0` for both.

- [ ] **Step 8: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Workbench WatchtowerMobile/Tests
git commit -m "feat(mobile): Board as flat rows with filter chips; target detail title, Work on it and ask rows

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate):
- 06: on the 402 pt screen all four chips are visible, Archive included.
- 06: nothing is on the right of a row except the disclosure chevron, the priority dot comes first in the meta line, and there is a thin bar under "Archive Closed Targets Now".
- 07: the bar shows "Archive Closed Targets Now #415", Work on it is a leading accent row (no blue full-width capsule), and the asks are flat rows under an orange header with no orange card.

---

### Task 16: Session detail (D1–D7)

**Depends on:** Task 11 (`WaitingStack`), Task 14 (`SessionRowModel` without the report line).

**Files:**
- Modify: `Sources/Features/Workbench/SessionDetailView.swift` (title, state line, chips, asks box, notice, report card, timeline, tell bar; `InfoPill` goes)

**Interfaces:**
- Consumes: `WaitingStack(asks:header:)` (Task 11); `FlowRow`, `Pill`, `RowDivider`, `card(_:)` (Task 4); `BottomActionBar` (Task 5); `TypeScale`.
- Produces: no new API.

- [ ] **Step 1: The screen**

In `SessionDetailView.swift`:

- D1: after `.navigationBarTitleDisplayMode(.inline)` (line 47), add the following before the existing actions-menu `.toolbar` (two `.toolbar` modifiers compose):

```swift
        .toolbar {
            // The bar is not an empty strip with a lone "⋯".
            ToolbarItem(placement: .principal) {
                if let title = replica.snapshot.session(viewModel.sessionID)?.title {
                    Text(title).font(.headline).lineLimit(1)
                }
            }
        }
```

  The body keeps the title: in `header`, line 133 becomes `.font(TypeScale.pageTitle)`.
- D2: in `header`, delete the `if let glyph = detail.state.glyph { … }` block (lines 137-139). The dot and the caption in the session's tone stay.
- D3: replace the `ViewThatFits { … }` (lines 145-148) with `FlowRow { chips(detail) }`, and replace `chips(_:)` with:

```swift
    @ViewBuilder
    private func chips(_ detail: SessionDetailModel) -> some View {
        if let target = detail.target {
            NavigationLink(value: BoardTargetRoute(id: target.id)) {
                Pill(text: target.label, tone: .accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Target \(target.label)")
        }
        if let branch = detail.branch {
            Pill(text: branch, style: .neutral, monospaced: true)
                .frame(minHeight: 44)
                .accessibilityLabel("Branch \(branch)")
        }
        Pill(text: detail.agentLine, style: .neutral).frame(minHeight: 44)
    }
```

  Delete `InfoPill` (lines 232-250).
- Background: in `content(_:now:)`, line 127 becomes `.background(Color(.systemBackground))`.
- D4: replace `SessionAsksBox.body` with:

```swift
    var body: some View {
        WaitingStack(asks: asks) {
            VStack(spacing: 0) {
                HStack(spacing: Spacing.regular) {
                    SessionDot(tone: .waitingForYou, isRing: false, size: 8)
                    Text("Waiting for you").font(TypeScale.rowEmphasis).foregroundStyle(PhoneTone.waitingForYou.color)
                    Spacer(minLength: Spacing.regular)
                    if let since {
                        Text(since).font(TypeScale.meta).foregroundStyle(.secondary)
                    }
                }
                .padding(RowInsets.flat)
                .accessibilityAddTraits(.isHeader)
                Divider()
            }
        }
    }
```

- D5: replace `ApprovalNoticeView.body` with:

```swift
    var body: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "hand.raised.fill").accessibilityHidden(true)
            Text(text).font(TypeScale.rowEmphasis)
            Spacer(minLength: 0)
        }
        .foregroundStyle(PhoneTone.waitingForYou.color)
        .frame(minHeight: 44)
        .card(.waiting)
        .accessibilityElement(children: .combine)
    }
```

- D6: replace `SessionReportCard.body` (lines 323-350) with the following; `segments` stays:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Report")
                    .font(TypeScale.sectionHeader)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(report.progressLabel)
                    .font(TypeScale.time)
                    .foregroundStyle(.secondary)
            }
            if !report.segments.isEmpty {
                segments
            }
            ForEach(report.summary, id: \.self) { line in
                Text(line).font(TypeScale.rowTitle)
            }
            ForEach(report.prLines, id: \.self) { line in
                Text(line)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .card(.plain)
    }
```
- D7: in `timeline(_:)`, replace the "Timeline" `Text` and its four modifiers (lines 170-174) with:

```swift
            Text("Timeline")
                .font(TypeScale.sectionHeader)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
```

  In `MilestoneRowView`, `.font(.caption2.monospaced())` (line 380) becomes `.font(TypeScale.time)` and `.font(.subheadline)` (line 385) becomes `.font(TypeScale.rowTitle)`. The dots stay.
- The hidden tell bar (§2.10): line 48 becomes `.safeAreaInset(edge: .bottom, spacing: 0) {`. Replace `TellSessionBar.body` (lines 406-428) with:

```swift
    var body: some View {
        BottomActionBar {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(spacing: Spacing.regular) {
                    TextField("Tell the session…", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Message to the session")
                    Button {} label: {
                        Image(systemName: "arrow.right")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .accessibilityLabel("Send")
                }
                Text("Delivered when the agent is idle · opt-in in Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
```

- [ ] **Step 2: Run and lint**

Run: `make mobile-test SIM="iPhone 17 Pro" MOBILE_FILTER='SessionDetailWiringTests|OrangeToneTests|StartSheetWiringTests' > build/mobile-logs/t16.log 2>&1; echo "exit=$?"`, then `make lint-swift > build/mobile-logs/t16-lint.log 2>&1; echo "exit=$?"`. Expect `exit=0` for both, with `SessionDetailWiringTests.testTheTellBarIsHidden` unchanged. Then run `grep -rn 'InfoPill\|\.background(\.bar)' WatchtowerMobile/Sources/Features/Workbench` and expect no output.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerMobile/Sources/Features/Workbench/SessionDetailView.swift
git commit -m "feat(mobile): session detail — title in the bar, dot-only state, wrapping chips, cards from the design layer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Shot checks (at the gate):
- 09: the bar shows "Archive closed targets", all three chips sit on one line, and the waiting card has flat rows.
- 10: the approval notice is a waiting card.
- 11: one icon (the dot) for Finished, not two.
- 09 and 10: Report and Timeline headers are not uppercase, and PR lines are not monospaced.

---

### Phase 2 gate

Run once, by the controller, after Task 16.

- [ ] **Load check.** Run `bash scripts/dev-health.sh`. If its last line is `HEALTH: overloaded`, stop and report.
- [ ] **Full phone suite.** Run `make mobile-test SIM="iPhone 17 Pro" > build/mobile-logs/gate2-test.log 2>&1; echo "exit=$?"`. Expect `exit=0`.
- [ ] **Full lint.** Run `make lint-all > build/mobile-logs/gate2-lint.log 2>&1; echo "exit=$?"`. Expect `exit=0`, or the Phase 1 gate's recorded pre-existing Go issues only, confirmed by `make lint-diff`.
- [ ] **After shots.** Run `make mobile-shots SIM="iPhone 17 Pro" SHOTS_DIR=build/mobile-shots/after-phase-2 > build/mobile-logs/gate2-shots.log 2>&1; echo "exit=$?"`. Expect `exit=0` and 82 PNGs (no 04).
- [ ] **Compare by eye** against `before/` and `after-phase-1/`, light and dark:
  - 01 and 01e: bug 1, N1–N5, and an orange Workbench tab badge (not red), with a gear in Now's toolbar.
  - 02: W1–W3.
  - 05: S1–S3.
  - 06: B1 and B2.
  - 07 and 08: T1, T4–T6, with Phase 1's bug 3 and 4 fixes intact.
  - 09–12: D1–D7.
  - 18: the start sheet's step rows. Only reachable after a start; the form is what the tour shows.
  - Dark mode: the waiting card reads light, not brown (0.06 fill), and no card sits inside a card anywhere.
  - Screens outside this plan (13–17, 19–35) show only Phase 1's bug fixes.

  Fix any regression in a `fix(mobile): …` commit, then re-run the suites for the touched classes.
- [ ] **Pre-PR gate** (when this branch goes to a PR): run `make test`, `make test-swift` (includes the Kit), `make lint-all`, and the full `make mobile-test SIM="iPhone 17 Pro"`.

---

**Next plan:** Phases 3–5 of the spec: Asks (A1–A7), then Calendar, Recording and Recap (C1–C7, including C4's "Record" label and `RecordButton` in event detail), then Settings and Onboarding (SET2–SET4, O1–O5).
