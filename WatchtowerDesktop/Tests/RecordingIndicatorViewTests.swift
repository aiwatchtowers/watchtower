import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class RecordingIndicatorViewTests: XCTestCase {

    private func makeJob(title: String? = "Retro",
                         phase: MeetingRecorderCenter.ProcessingJob.Phase = .queued)
        -> MeetingRecorderCenter.ProcessingJob {
        var job = MeetingRecorderCenter.ProcessingJob(
            audioURL: URL(fileURLWithPath: "/tmp/rec_\(UUID().uuidString).caf"),
            eventID: nil, title: title)
        job.phase = phase
        return job
    }

    // MARK: - Phase copy

    func test_phaseLabelPerPhase() {
        XCTAssertEqual(RecordingIndicatorView.jobPhaseLabel(.queued), "Queued")
        XCTAssertEqual(RecordingIndicatorView.jobPhaseLabel(.transcribing(done: 3, total: 12)),
                       "Transcribing 3/12")
        XCTAssertEqual(RecordingIndicatorView.jobPhaseLabel(.diarizing), "Identifying speakers…")
        XCTAssertEqual(RecordingIndicatorView.jobPhaseLabel(.summarizing), "Summarizing…")
        // The failed pill renders its heading through the same function, so this
        // case is reachable copy rather than a placeholder.
        XCTAssertEqual(RecordingIndicatorView.jobPhaseLabel(.failed("decode blew up")),
                       "Transcription failed")
    }

    func test_phaseLabelHidesUnknownWindowCount() {
        // The transcriber reports (0, 0) until it has planned its windows —
        // "Transcribing 0/0" would read as stuck.
        XCTAssertEqual(RecordingIndicatorView.jobPhaseLabel(.transcribing(done: 0, total: 0)),
                       "Transcribing…")
    }

    // MARK: - Queue cap

    func test_allJobsVisibleUpToTheCap() {
        let jobs = (0..<RecordingIndicatorView.maxVisibleJobPills).map { _ in makeJob() }
        let split = RecordingIndicatorView.visibleJobs(jobs, activeID: jobs.first?.id)
        XCTAssertEqual(split.visible.count, jobs.count)
        XCTAssertEqual(split.overflow, 0)
    }

    func test_queueTailCollapsesIntoOverflowCount() {
        let jobs = (0..<(RecordingIndicatorView.maxVisibleJobPills + 2)).map { _ in makeJob() }
        let split = RecordingIndicatorView.visibleJobs(jobs, activeID: jobs.first?.id)
        XCTAssertEqual(split.visible.count, RecordingIndicatorView.maxVisibleJobPills)
        XCTAssertEqual(split.overflow, 2)
        // The running head is always in the visible set (queue order is FIFO).
        XCTAssertEqual(split.visible.first?.id, jobs.first?.id)
    }

    func test_emptyQueueRendersNothing() {
        let split = RecordingIndicatorView.visibleJobs([], activeID: nil)
        XCTAssertTrue(split.visible.isEmpty)
        XCTAssertEqual(split.overflow, 0)
    }

    /// The case the cap must not lose: stale failures pile up at the head of the
    /// queue (they stay until the user acts), so plain FIFO truncation would hide
    /// the job actually being worked.
    func test_runningJobStaysVisibleBehindStaleFailures() {
        let stale = (0..<RecordingIndicatorView.maxVisibleJobPills).map { i in
            makeJob(title: "Stale \(i)", phase: .failed("boom"))
        }
        let running = makeJob(title: "Running", phase: .transcribing(done: 1, total: 4))
        let split = RecordingIndicatorView.visibleJobs(stale + [running], activeID: running.id)

        XCTAssertEqual(split.visible.first?.id, running.id, "the running job leads the visible pills")
        XCTAssertEqual(split.visible.count, RecordingIndicatorView.maxVisibleJobPills)
        XCTAssertEqual(split.visible.dropFirst().map(\.id), stale.prefix(2).map(\.id),
                       "the queue fills the remaining slots in order")
        XCTAssertEqual(split.overflow, 1)
    }

    /// Every non-failed phase the queue can be working counts as running, so a
    /// job in the diarize/summarize tail is not pushed out either.
    func test_runningJobStaysVisibleInEveryWorkingPhase() {
        let phases: [MeetingRecorderCenter.ProcessingJob.Phase] = [
            .transcribing(done: 0, total: 0), .diarizing, .summarizing
        ]
        for phase in phases {
            let stale = (0..<3).map { i in makeJob(title: "Stale \(i)", phase: .failed("boom")) }
            let running = makeJob(title: "Running", phase: phase)
            let split = RecordingIndicatorView.visibleJobs(stale + [running], activeID: running.id)
            XCTAssertEqual(split.visible.first?.id, running.id, "\(phase) must stay visible")
        }
    }

    /// Promotion keys on the Center's `activeJobID`, never on the phase: the
    /// queue claims a job before its first phase update, and with diarization
    /// off it can be working one that still reads `.queued`. Reading the phase
    /// would leave three stale failures covering it.
    func test_activeJobIsPromotedWhileItsPhaseStillReadsQueued() {
        let stale = (0..<3).map { i in makeJob(title: "Stale \(i)", phase: .failed("boom")) }
        let active = makeJob(title: "Active", phase: .queued)
        let split = RecordingIndicatorView.visibleJobs(stale + [active], activeID: active.id)
        XCTAssertEqual(split.visible.first?.id, active.id, "the job the Center is working leads")
        XCTAssertEqual(split.visible.dropFirst().map(\.id), stale.prefix(2).map(\.id))
        XCTAssertEqual(split.overflow, 1)
    }

    /// With nothing active yet, the job the queue will pick up next leads — a
    /// stale failure at the head is the one thing the user cannot act on by
    /// waiting.
    func test_queueHeadNonFailedJobLeadsWhenNothingIsActive() {
        let stale = (0..<3).map { i in makeJob(title: "Stale \(i)", phase: .failed("boom")) }
        let queued = makeJob(title: "Queued", phase: .queued)
        let split = RecordingIndicatorView.visibleJobs(stale + [queued], activeID: nil)
        XCTAssertEqual(split.visible.first?.id, queued.id)
        XCTAssertEqual(split.visible.dropFirst().map(\.id), stale.prefix(2).map(\.id))
        XCTAssertEqual(split.overflow, 1)
    }

    /// Promotion is unconditional, so the pills already on screen keep their
    /// order when the queue grows past the cap — the stack must not reshuffle
    /// under the user's cursor as one more recording is stopped.
    func test_promotionOrderIsStableAcrossTheVisibleCap() {
        let stale = (0..<2).map { i in makeJob(title: "Stale \(i)", phase: .failed("boom")) }
        let active = makeJob(title: "Active", phase: .transcribing(done: 1, total: 4))
        let atCap = RecordingIndicatorView.visibleJobs(stale + [active], activeID: active.id)
        XCTAssertEqual(atCap.visible.map(\.id), [active.id] + stale.map(\.id),
                       "the active job leads below the cap too")
        XCTAssertEqual(atCap.overflow, 0)

        let overCap = RecordingIndicatorView.visibleJobs(
            stale + [active, makeJob(title: "Queued", phase: .queued)], activeID: active.id)
        XCTAssertEqual(overCap.visible.map(\.id), atCap.visible.map(\.id),
                       "crossing the cap must not reorder the visible pills")
        XCTAssertEqual(overCap.overflow, 1)
    }

    // MARK: - Recovered copy

    func test_recoveredLabelSingularAndPlural() {
        XCTAssertEqual(RecordingIndicatorView.recoveredLabel(count: 1),
                       "Transcribe recovered recording")
        XCTAssertEqual(RecordingIndicatorView.recoveredLabel(count: 2),
                       "Transcribe 2 recovered recordings")
    }

    // MARK: - Job pill

    func test_runningPillShowsPhaseAndTitle() throws {
        let view = RecordingJobPill(
            title: "Weekly sync", phase: .transcribing(done: 3, total: 12),
            canRetry: false, canDismiss: false, retry: {}, dismiss: {})
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains("Transcribing 3/12"))
        XCTAssertTrue(texts.contains("Weekly sync"))
    }

    func test_queuedPillShowsClockAndQueued() throws {
        let view = RecordingJobPill(
            title: "Weekly sync", phase: .queued,
            canRetry: false, canDismiss: false, retry: {}, dismiss: {})
        let images = try view.inspect().findAll(ViewType.Image.self).map { try $0.actualImage().name() }
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(images.contains("clock"))
        XCTAssertTrue(texts.contains("Queued"))
        XCTAssertTrue(texts.contains("Weekly sync"))
    }

    func test_failedPillActionsReportPerJob() throws {
        var retried = false
        var dismissed = false
        let view = RecordingJobPill(
            title: "Weekly sync", phase: .failed("decode blew up"),
            canRetry: true, canDismiss: true,
            retry: { retried = true }, dismiss: { dismissed = true })
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains("decode blew up"))
        try view.inspect().find(button: "Retry").tap()
        try view.inspect().find(button: "Dismiss").tap()
        XCTAssertTrue(retried)
        XCTAssertTrue(dismissed)
    }

    func test_failedPillDisablesActionsItCannotPerform() throws {
        // The Center's retry/dismiss pair has one slot; a pill that is not the
        // one it would pick must not offer a silently no-opping button.
        let view = RecordingJobPill(
            title: "Weekly sync", phase: .failed("decode blew up"),
            canRetry: false, canDismiss: false, retry: {}, dismiss: {})
        XCTAssertTrue(try view.inspect().find(button: "Retry").isDisabled())
        XCTAssertTrue(try view.inspect().find(button: "Dismiss").isDisabled())
    }

    func test_runningPillHasNoActions() throws {
        let view = RecordingJobPill(
            title: "Weekly sync", phase: .summarizing,
            canRetry: true, canDismiss: true, retry: {}, dismiss: {})
        XCTAssertThrowsError(try view.inspect().find(ViewType.Button.self))
    }

    // Retry/dismiss eligibility now lives on the Center
    // (`retriableFailureID`/`dismissableFailureID`, so the buttons can never
    // disagree with what the Center would do); see MeetingRecorderQueueTests.

    // MARK: - Reserved inset

    /// Nothing recording, queued or failed: the empty stack measures zero and
    /// composers keep their normal layout.
    func testEmptyStackReservesNothing() {
        XCTAssertEqual(RecordingIndicatorInset.reservedHeight(stackHeight: 0), 0)
    }

    /// Visible pills reserve their own height plus the stack's gap to the
    /// window bottom, so a composer sits entirely above the topmost pill.
    func testVisibleStackReservesItsHeightPlusOuterPadding() {
        XCTAssertEqual(RecordingIndicatorInset.reservedHeight(stackHeight: 40),
                       40 + RecordingIndicatorInset.outerPadding)
        XCTAssertEqual(RecordingIndicatorInset.reservedHeight(stackHeight: 150), 166)
    }

    /// While the live panel is expanded the panel itself reserves nothing:
    /// it is a transient overlay, with the recorder pills above it.
    func testExpandedPanelReservesNothing() {
        XCTAssertEqual(RecordingIndicatorInset.reservedHeight(stackHeight: 310, expandedPanelShown: true), 0)
        XCTAssertEqual(RecordingIndicatorInset.reservedHeight(stackHeight: 360, expandedPanelShown: true), 0)
        XCTAssertEqual(RecordingIndicatorInset.reservedHeight(stackHeight: 40, expandedPanelShown: false),
                       40 + RecordingIndicatorInset.outerPadding)
    }

    /// Verify finding R1: a model-download capsule drawn BELOW the expanded
    /// panel still reserves its own height, or it would cover the composer.
    func testPillBelowTheExpandedPanelStillReserves() {
        let stack = 310 + RecordingIndicatorInset.stackSpacing + 40
        XCTAssertEqual(RecordingIndicatorInset.reservedHeight(stackHeight: stack, expandedPanelShown: true,
                                                              belowPanelHeight: 40),
                       40 + RecordingIndicatorInset.outerPadding)
        // Collapsed: the whole stack reserves, whatever sits at its bottom.
        XCTAssertEqual(RecordingIndicatorInset.reservedHeight(stackHeight: 90, expandedPanelShown: false,
                                                              belowPanelHeight: 40),
                       90 + RecordingIndicatorInset.outerPadding)
    }

    /// The inset clears every screen at once (#397): the per-window host
    /// (`RecordingIndicatorHost`, the main window's root) pads its whole
    /// content on the pills' edge, and no screen opts in on its own — the
    /// per-view `.clearsRecordingIndicator()` it replaced is gone, and the
    /// shared `ChatComposerField` (which also serves sheets, onboarding and
    /// setup assistants) never reserves anything.
    func testInsetIsAppliedOnceAtTheRoot() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var padders: [String: Int] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = Self.codeLines(try String(contentsOf: url, encoding: .utf8))
            XCTAssertFalse(lines.contains { $0.contains("clearsRecordingIndicator") },
                           "\(url.lastPathComponent) opts into the pills' inset; the root already pads every screen")
            let pads = lines.filter { $0.contains(".padding(corner.insetEdge") }.count
            if pads > 0 { padders[url.lastPathComponent, default: 0] += pads }
        }
        XCTAssertEqual(padders, ["RecordingIndicatorHost.swift": 1])
        let app = try String(contentsOf: sources.appendingPathComponent("App/WatchtowerApp.swift"), encoding: .utf8)
        XCTAssertTrue(Self.codeLines(app).contains { $0.contains("RecordingIndicatorHost {") },
                      "the main window's root wraps its content in the host")
    }

    // MARK: - Corner

    /// A release point snaps to the corner of its quadrant; the midlines go
    /// trailing and bottom, so the centre lands on the default corner, and a
    /// point dragged past the window's edge snaps to that side.
    func testReleasePointSnapsToTheNearestCorner() {
        let size = CGSize(width: 1000, height: 600)
        XCTAssertEqual(RecordingIndicatorCorner.nearest(to: CGPoint(x: 100, y: 80), in: size), .topLeading)
        XCTAssertEqual(RecordingIndicatorCorner.nearest(to: CGPoint(x: 900, y: 80), in: size), .topTrailing)
        XCTAssertEqual(RecordingIndicatorCorner.nearest(to: CGPoint(x: 100, y: 500), in: size), .bottomLeading)
        XCTAssertEqual(RecordingIndicatorCorner.nearest(to: CGPoint(x: 900, y: 500), in: size), .bottomTrailing)
        XCTAssertEqual(RecordingIndicatorCorner.nearest(to: CGPoint(x: 500, y: 300), in: size), .bottomTrailing)
        XCTAssertEqual(RecordingIndicatorCorner.nearest(to: CGPoint(x: 499, y: 299), in: size), .topLeading)
        XCTAssertEqual(RecordingIndicatorCorner.nearest(to: CGPoint(x: -40, y: 700), in: size), .bottomLeading)
        XCTAssertEqual(RecordingIndicatorCorner.nearest(to: CGPoint(x: 1200, y: -10), in: size), .topTrailing)
    }

    /// Each corner pads the content edge it sits on and aligns the stack to
    /// its own side.
    func testCornerPicksItsEdgeAndAlignment() {
        let expected: [(RecordingIndicatorCorner, Edge.Set, Alignment, HorizontalAlignment)] = [
            (.topLeading, .top, .topLeading, .leading),
            (.topTrailing, .top, .topTrailing, .trailing),
            (.bottomLeading, .bottom, .bottomLeading, .leading),
            (.bottomTrailing, .bottom, .bottomTrailing, .trailing)
        ]
        for (corner, edge, alignment, horizontal) in expected {
            XCTAssertEqual(corner.insetEdge, edge, "\(corner)")
            XCTAssertEqual(corner.alignment, alignment, "\(corner)")
            XCTAssertEqual(corner.horizontalAlignment, horizontal, "\(corner)")
        }
    }

    /// The stored corner's key, raw values and default stay stable across
    /// releases, and a raw value no corner has decodes to none (the
    /// `@AppStorage` default then applies).
    func testCornerKeyRawValuesAndDefaultAreStable() {
        XCTAssertEqual(RecordingIndicatorCorner.storageKey, "recordingIndicator.corner")
        XCTAssertEqual(RecordingIndicatorCorner.allCases.map(\.rawValue),
                       ["topLeading", "topTrailing", "bottomLeading", "bottomTrailing"])
        XCTAssertEqual(RecordingIndicatorCorner.default, .bottomTrailing)
        XCTAssertNil(RecordingIndicatorCorner(rawValue: "middle"))
    }

    /// The stack is listed top to bottom from the interior to the edge in a
    /// bottom corner and mirrored in a top one: the download pills always
    /// sit on the edge side, the recording next to them, and the chevrons
    /// point toward the interior to open and back to the edge to close.
    func testStackPartOrderAndChevronsFollowTheCorner() {
        let interiorToEdge: [RecordingIndicatorCorner.StackPart] = [.interrupted, .jobs, .recording, .downloads]
        for corner in RecordingIndicatorCorner.allCases {
            let edgeSide = corner.isTop ? corner.stackParts.first : corner.stackParts.last
            XCTAssertEqual(edgeSide, .downloads, "\(corner)")
            XCTAssertEqual(corner.stackParts, corner.isTop ? interiorToEdge.reversed() : interiorToEdge, "\(corner)")
            XCTAssertEqual(corner.expandChevron, corner.isTop ? "chevron.down" : "chevron.up", "\(corner)")
            XCTAssertEqual(corner.collapseChevron, corner.isTop ? "chevron.up" : "chevron.down", "\(corner)")
        }
    }

    /// The extract pill (always bottom-trailing) clears the whole stack,
    /// expanded panel included, only when they share the corner; the meeting
    /// banner (always top) clears the whole stack the same way, only when it
    /// sits in a top corner — also with the panel expanded, when the
    /// reserved band is 0. An empty stack moves neither.
    func testNeighboursStepAsideOnlyInTheSharedEdge() {
        for corner in RecordingIndicatorCorner.allCases {
            for (reserved, occupied) in [(CGFloat(0), CGFloat(0)), (56, 56), (0, 340)] {
                XCTAssertEqual(corner.extractPillLift(occupiedHeight: occupied),
                               corner == .bottomTrailing ? occupied : 0, "\(corner) occupied \(occupied)")
                XCTAssertEqual(corner.bannerDrop(occupiedHeight: occupied),
                               corner.isTop ? occupied : 0, "\(corner) reserved \(reserved) occupied \(occupied)")
            }
        }
    }

    /// The occupied extent counts the whole stack, expanded panel included,
    /// while the reserved band leaves the panel out.
    func testOccupiedHeightCountsTheExpandedPanel() {
        XCTAssertEqual(RecordingIndicatorInset.occupiedHeight(stackHeight: 0), 0)
        XCTAssertEqual(RecordingIndicatorInset.occupiedHeight(stackHeight: 310),
                       310 + RecordingIndicatorInset.outerPadding)
        XCTAssertEqual(RecordingIndicatorInset.reservedHeight(stackHeight: 310, expandedPanelShown: true), 0)
    }

    /// Verify finding (round 2): in a top corner with the live panel open
    /// the band reserves nothing, yet the banner still drops below the panel.
    func testBannerClearsTheExpandedPanelInATopCorner() {
        let expanded = RecordingIndicatorInset.occupiedHeight(stackHeight: 310)
        XCTAssertEqual(RecordingIndicatorInset.reservedHeight(stackHeight: 310, expandedPanelShown: true), 0)
        XCTAssertEqual(RecordingIndicatorCorner.topLeading.bannerDrop(occupiedHeight: expanded), expanded)
        XCTAssertEqual(RecordingIndicatorCorner.topTrailing.bannerDrop(occupiedHeight: expanded), expanded)
        XCTAssertEqual(RecordingIndicatorCorner.bottomLeading.bannerDrop(occupiedHeight: expanded), 0)
    }

    /// A release snaps to the nearest corner; before the window has been
    /// measured the stack stays where it is.
    func testReleaseKeepsTheCornerUntilTheWindowIsMeasured() {
        let topRight = CGPoint(x: 900, y: 50)
        for corner in RecordingIndicatorCorner.allCases {
            XCTAssertEqual(corner.snapped(releasedAt: topRight, in: .zero), corner)
            XCTAssertEqual(corner.snapped(releasedAt: topRight, in: CGSize(width: 1000, height: 0)), corner)
            XCTAssertEqual(corner.snapped(releasedAt: topRight, in: CGSize(width: 1000, height: 600)), .topTrailing)
        }
    }

    func testCodeLinesSkipsCommentLines() {
        let text = """
        // .padding(corner.insetEdge) in a comment
        /// .padding(corner.insetEdge) in a doc comment
          .padding(corner.insetEdge, inset)
        """
        XCTAssertEqual(Self.codeLines(text), ["  .padding(corner.insetEdge, inset)"])
    }

    /// Source lines minus `//` / `///` comment lines.
    private static func codeLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
    }
}
