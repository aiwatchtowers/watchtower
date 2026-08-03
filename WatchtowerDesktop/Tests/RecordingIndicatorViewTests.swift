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
        let split = RecordingIndicatorView.visibleJobs(jobs)
        XCTAssertEqual(split.visible.count, jobs.count)
        XCTAssertEqual(split.overflow, 0)
    }

    func test_queueTailCollapsesIntoOverflowCount() {
        let jobs = (0..<(RecordingIndicatorView.maxVisibleJobPills + 2)).map { _ in makeJob() }
        let split = RecordingIndicatorView.visibleJobs(jobs)
        XCTAssertEqual(split.visible.count, RecordingIndicatorView.maxVisibleJobPills)
        XCTAssertEqual(split.overflow, 2)
        // The running head is always in the visible set (queue order is FIFO).
        XCTAssertEqual(split.visible.first?.id, jobs.first?.id)
    }

    func test_emptyQueueRendersNothing() {
        let split = RecordingIndicatorView.visibleJobs([])
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
        let split = RecordingIndicatorView.visibleJobs(stale + [running])

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
            let split = RecordingIndicatorView.visibleJobs(stale + [running])
            XCTAssertEqual(split.visible.first?.id, running.id, "\(phase) must stay visible")
        }
    }

    /// A queued job is NOT promoted: nothing is being worked yet, so FIFO order
    /// is the honest reading of the queue.
    func test_queuedJobIsNotPromotedOverTheQueueHead() {
        let jobs = (0..<3).map { i in makeJob(title: "Stale \(i)", phase: .failed("boom")) }
            + [makeJob(title: "Queued", phase: .queued)]
        let split = RecordingIndicatorView.visibleJobs(jobs)
        XCTAssertEqual(split.visible.map(\.id), jobs.prefix(3).map(\.id))
        XCTAssertEqual(split.overflow, 1)
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
