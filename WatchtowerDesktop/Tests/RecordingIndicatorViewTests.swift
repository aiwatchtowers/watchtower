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
}
