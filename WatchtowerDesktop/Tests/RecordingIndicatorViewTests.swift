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

    /// A queued batch job held back by the running recording says why, rather
    /// than reading "Queued" for the length of a meeting.
    func test_queuedPillWaitingForCaptureSaysSo() throws {
        XCTAssertEqual(RecordingIndicatorView.jobPhaseLabel(.queued, waitingForCapture: true),
                       "Waiting for the recording to stop")
        XCTAssertEqual(RecordingIndicatorView.jobPhaseLabel(.diarizing, waitingForCapture: true),
                       "Identifying speakers…", "only a queued job can be waiting for the recording")
        let view = RecordingJobPill(
            title: "Weekly sync", phase: .queued, waitingForCapture: true,
            canRetry: false, canDismiss: false, retry: {}, dismiss: {})
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains("Waiting for the recording to stop"))
        XCTAssertFalse(texts.contains("Queued"))
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

    // MARK: - Floating over the content

    /// The pills float over the content (#397, amended): nothing pads the
    /// window's content on their edge, and no screen opts into an inset.
    func testNothingReservesSpaceForThePills() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = Self.codeLines(try String(contentsOf: url, encoding: .utf8))
            XCTAssertFalse(lines.contains { $0.contains("clearsRecordingIndicator") || $0.contains("reservedInset") },
                           "\(url.lastPathComponent) reserves space for the pills; they float over the content")
        }
        let app = try String(contentsOf: sources.appendingPathComponent("App/WatchtowerApp.swift"), encoding: .utf8)
        XCTAssertTrue(Self.codeLines(app).contains { $0.contains("RecordingIndicatorHost {") },
                      "the main window's root wraps its content in the host")
    }

    // MARK: - Placement

    private let window = CGSize(width: 1000, height: 600)
    private let stack = CGSize(width: 300, height: 40)
    private var pad: CGFloat { RecordingIndicatorInset.outerPadding }

    /// A drop in the middle of the window stays there: anchored to the
    /// quadrant's corner at the dropped spot.
    func testReleaseLeavesTheStackWhereItWasDropped() {
        let start = RecordingIndicatorPlacement(corner: .bottomTrailing, offset: .zero)
        // Docked bottom-trailing origin: (1000-16-300, 600-16-40) = (684, 544).
        let placed = start.released(translation: CGSize(width: -400, height: -300), stack: stack, window: window)
        // Dropped at (284, 244): centre (434, 264) is the top-leading quadrant.
        XCTAssertEqual(placed.corner, .topLeading)
        XCTAssertEqual(placed.offset, CGSize(width: 284 - pad, height: 244 - pad))
        XCTAssertEqual(placed.occupiedHeight(stack: stack, window: window), 0,
                       "a stack moved off its edge pushes no neighbour")
    }

    /// A release within `dockDistance` of a corner's spot docks on that
    /// axis; a short drag back home docks fully.
    func testReleaseNearTheCornerDocks() {
        let moved = RecordingIndicatorPlacement(corner: .bottomTrailing, offset: CGSize(width: -200, height: 0))
        let home = moved.released(translation: CGSize(width: 190, height: 10), stack: stack, window: window)
        XCTAssertEqual(home, RecordingIndicatorPlacement(corner: .bottomTrailing, offset: .zero))
        let alongEdge = RecordingIndicatorPlacement(corner: .bottomTrailing, offset: .zero)
            .released(translation: CGSize(width: -100, height: -10), stack: stack, window: window)
        XCTAssertEqual(alongEdge.offset, CGSize(width: -100, height: 0))
    }

    /// A drop past the window's edge, or a window that shrank, keeps the
    /// whole stack inside the window's padding.
    func testOffsetIsClampedIntoTheWindow() {
        let placed = RecordingIndicatorPlacement(corner: .bottomTrailing, offset: .zero)
            .released(translation: CGSize(width: -5000, height: -5000), stack: stack, window: window)
        XCTAssertEqual(placed, RecordingIndicatorPlacement(corner: .topLeading, offset: .zero))
        let far = RecordingIndicatorPlacement(corner: .topLeading, offset: CGSize(width: 900, height: 900))
        XCTAssertEqual(far.clampedOffset(stack: stack, window: window),
                       CGSize(width: 1000 - 300 - 2 * pad, height: 600 - 40 - 2 * pad))
        // Offsets pointing out of the window from the corner clamp to the edge.
        let outward = RecordingIndicatorPlacement(corner: .bottomTrailing, offset: CGSize(width: 50, height: 50))
        XCTAssertEqual(outward.clampedOffset(stack: stack, window: window), .zero)
        // A stack wider than the window has no room to move.
        XCTAssertEqual(far.clampedOffset(stack: CGSize(width: 2000, height: 900), window: window), .zero)
    }

    /// The neighbours on the stack's edge step aside while it is drawn flush
    /// with that edge — docked, slid along it, or clamped back onto it by a
    /// smaller window — and not once it is moved off the edge.
    func testNeighboursClearTheStackWhileItSitsOnItsEdge() {
        let occupied = RecordingIndicatorInset.occupiedHeight(stackHeight: stack.height)
        let slid = RecordingIndicatorPlacement(corner: .bottomTrailing, offset: CGSize(width: -100, height: 0))
        XCTAssertEqual(slid.occupiedHeight(stack: stack, window: window), occupied)
        let topSlid = RecordingIndicatorPlacement(corner: .topLeading, offset: CGSize(width: 300, height: 0))
        XCTAssertEqual(topSlid.occupiedHeight(stack: stack, window: window), occupied)
        let raised = RecordingIndicatorPlacement(corner: .bottomTrailing, offset: CGSize(width: 0, height: -100))
        XCTAssertEqual(raised.occupiedHeight(stack: stack, window: window), 0)
        // Stored off the edge, but a window with no vertical room draws it flush.
        let short = CGSize(width: 1000, height: stack.height + 2 * pad)
        XCTAssertEqual(raised.occupiedHeight(stack: stack, window: short), occupied)
    }

    /// A drag starts from where the stack is drawn, not from a stored offset
    /// a larger window allowed: no jump at the start of the drag.
    func testReleaseStartsFromTheClampedOffset() {
        let far = RecordingIndicatorPlacement(corner: .topLeading, offset: CGSize(width: 900, height: 900))
        let placed = far.released(translation: CGSize(width: -10, height: -10), stack: stack, window: window)
        // Clamped start (668, 528) minus 10: centre (824, 554) is bottom-trailing,
        // 10 pt short of that corner's spot on each axis, so it docks there.
        XCTAssertEqual(placed, RecordingIndicatorPlacement(corner: .bottomTrailing, offset: .zero))
        let mid = RecordingIndicatorPlacement(corner: .topLeading, offset: CGSize(width: 900, height: 100))
            .released(translation: CGSize(width: -200, height: 0), stack: stack, window: window)
        XCTAssertEqual(mid, RecordingIndicatorPlacement(corner: .topTrailing, offset: CGSize(width: -200, height: 100)))
    }

    /// Before the window is measured nothing moves or clamps.
    func testUnmeasuredWindowKeepsThePlacement() {
        let placement = RecordingIndicatorPlacement(corner: .topTrailing, offset: CGSize(width: -40, height: 30))
        XCTAssertEqual(placement.released(translation: CGSize(width: 500, height: 500), stack: stack, window: .zero),
                       placement)
        XCTAssertEqual(placement.clampedOffset(stack: stack, window: .zero), placement.offset)
    }

    func testOffsetKeysAreStable() {
        XCTAssertEqual(RecordingIndicatorPlacement.offsetXKey, "recordingIndicator.offsetX")
        XCTAssertEqual(RecordingIndicatorPlacement.offsetYKey, "recordingIndicator.offsetY")
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

    /// Each corner aligns the stack to its own side.
    func testCornerPicksItsAlignment() {
        let expected: [(RecordingIndicatorCorner, Alignment, HorizontalAlignment)] = [
            (.topLeading, .topLeading, .leading),
            (.topTrailing, .topTrailing, .trailing),
            (.bottomLeading, .bottomLeading, .leading),
            (.bottomTrailing, .bottomTrailing, .trailing)
        ]
        for (corner, alignment, horizontal) in expected {
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
    /// sits in a top corner. An empty stack moves neither.
    func testNeighboursStepAsideOnlyInTheSharedEdge() {
        for corner in RecordingIndicatorCorner.allCases {
            for occupied in [CGFloat(0), 56, 340] {
                XCTAssertEqual(corner.extractPillLift(occupiedHeight: occupied),
                               corner == .bottomTrailing ? occupied : 0, "\(corner) occupied \(occupied)")
                XCTAssertEqual(corner.bannerDrop(occupiedHeight: occupied),
                               corner.isTop ? occupied : 0, "\(corner) occupied \(occupied)")
            }
        }
    }

    /// The occupied extent counts the whole stack, expanded panel included.
    func testOccupiedHeightCountsTheWholeStack() {
        XCTAssertEqual(RecordingIndicatorInset.occupiedHeight(stackHeight: 0), 0)
        XCTAssertEqual(RecordingIndicatorInset.occupiedHeight(stackHeight: 310),
                       310 + RecordingIndicatorInset.outerPadding)
    }

    func testCodeLinesSkipsCommentLines() {
        let text = """
        // reservedInset in a comment
        /// reservedInset in a doc comment
          .padding(.bottom, reservedInset)
        """
        XCTAssertEqual(Self.codeLines(text), ["  .padding(.bottom, reservedInset)"])
    }

    /// Source lines minus `//` / `///` comment lines.
    private static func codeLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
    }
}
