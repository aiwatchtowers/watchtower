import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

// MARK: - MeetingPrepViewModelTests

@MainActor
final class MeetingPrepViewModelTests: XCTestCase {
    private static let validJSON = Data("""
    {
      "event_id": "evt-1",
      "title": "Weekly sync",
      "start_time": "10:00",
      "talking_points": [
        {"text": "Release plan", "source_type": "track", "source_id": "7", "priority": "high"}
      ],
      "open_items": [],
      "people_notes": [],
      "suggested_prep": ["Read the release notes"]
    }
    """.utf8)

    private func runToCompletion(_ vm: MeetingPrepViewModel, _ start: () -> Void) async {
        start()
        await vm.runTask?.value
    }

    // MARK: - argv

    func testGenerateArgvMinimal() async {
        let cli = FakeCLIRunner(stdout: Self.validJSON)
        let vm = MeetingPrepViewModel(cliRunner: cli)

        await runToCompletion(vm) { vm.generate(eventID: "evt-1") }

        XCTAssertEqual(cli.invocations, [["meeting-prep", "evt-1", "--json"]])
    }

    func testRegenerateArgvCarriesForceRefreshAndNotes() async {
        let cli = FakeCLIRunner(stdout: Self.validJSON)
        let vm = MeetingPrepViewModel(cliRunner: cli)

        await runToCompletion(vm) { vm.regenerate(eventID: "evt-1", userNotes: "agenda: budget") }

        XCTAssertEqual(cli.invocations, [[
            "meeting-prep", "evt-1", "--json", "--force-refresh", "--user-notes", "agenda: budget"
        ]])
    }

    func testGenerateNextArgvUsesNextPositional() async {
        let cli = FakeCLIRunner(stdout: Self.validJSON)
        let vm = MeetingPrepViewModel(cliRunner: cli)

        await runToCompletion(vm) { vm.generateNext(userNotes: "focus on hiring") }

        XCTAssertEqual(cli.invocations, [["meeting-prep", "next", "--json", "--user-notes", "focus on hiring"]])
    }

    // MARK: - Outcomes

    func testSuccessDecodesResultAndClearsLoading() async throws {
        let cli = FakeCLIRunner(stdout: Self.validJSON)
        let vm = MeetingPrepViewModel(cliRunner: cli)
        vm.error = "stale"

        await runToCompletion(vm) { vm.generate(eventID: "evt-1") }

        let result = try XCTUnwrap(vm.result)
        XCTAssertEqual(result.eventID, "evt-1")
        XCTAssertEqual(result.talkingPoints.map(\.text), ["Release plan"])
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.statusMessage, "")
    }

    func testUndecodableOutputSurfacesParseError() async throws {
        let cli = FakeCLIRunner(stdout: Data("{\"not\": \"prep\"}".utf8))
        let vm = MeetingPrepViewModel(cliRunner: cli)

        await runToCompletion(vm) { vm.generate(eventID: "evt-1") }

        XCTAssertNil(vm.result)
        let message = try XCTUnwrap(vm.error)
        XCTAssertTrue(message.hasPrefix("Failed to parse meeting prep"), message)
        XCTAssertFalse(vm.isLoading)
    }

    func testNonZeroExitSurfacesStderr() async {
        let cli = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "event not found: evt-1"))
        let vm = MeetingPrepViewModel(cliRunner: cli)

        await runToCompletion(vm) { vm.generate(eventID: "evt-1") }

        XCTAssertEqual(vm.error, "event not found: evt-1")
        XCTAssertNil(vm.result)
        XCTAssertFalse(vm.isLoading)
    }

    func testNonZeroExitWithEmptyStderrNamesExitCode() async {
        let cli = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 2, stderr: ""))
        let vm = MeetingPrepViewModel(cliRunner: cli)

        await runToCompletion(vm) { vm.generate(eventID: "evt-1") }

        XCTAssertEqual(vm.error, "Meeting prep failed (exit 2)")
    }

    func testLongStderrIsCappedAt300Characters() async {
        let long = String(repeating: "x", count: 1000)
        let cli = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: long))
        let vm = MeetingPrepViewModel(cliRunner: cli)

        await runToCompletion(vm) { vm.generate(eventID: "evt-1") }

        XCTAssertEqual(vm.error?.count, 300)
    }

    /// Degenerate clean exit: exit 0 but nothing (or only whitespace) on
    /// stdout is a failure, not an empty success.
    func testCleanExitWithBlankStdoutIsAnError() async {
        let cli = FakeCLIRunner(stdout: Data("\n  \n".utf8))
        let vm = MeetingPrepViewModel(cliRunner: cli)

        await runToCompletion(vm) { vm.generate(eventID: "evt-1") }

        XCTAssertEqual(vm.error, "Meeting prep failed (exit 0)")
        XCTAssertNil(vm.result)
        XCTAssertFalse(vm.isLoading)
    }

    func testGenerateNextWithEmptyStderrReportsNoUpcomingMeetings() async {
        let cli = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: ""))
        let vm = MeetingPrepViewModel(cliRunner: cli)

        await runToCompletion(vm) { vm.generateNext() }

        XCTAssertEqual(vm.error, "No upcoming meetings found")
    }

    func testMissingBinaryReportsNotFoundWithoutRunning() {
        let vm = MeetingPrepViewModel(cliRunner: nil)

        vm.generate(eventID: "evt-1")

        XCTAssertEqual(vm.error, "Watchtower CLI not found")
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.runTask)
    }

    // MARK: - Survives navigation (MeetingPrepCenter)

    func testCenterHandsOutOneViewModelPerEvent() {
        let center = MeetingPrepCenter { FakeCLIRunner() }

        let first = center.viewModel(for: "evt-1")
        XCTAssertTrue(center.viewModel(for: "evt-1") === first)
        XCTAssertFalse(center.viewModel(for: "evt-2") === first)
    }

    /// The center is an AppState `let`, so every screen re-reading it after
    /// navigation gets the same per-event VM.
    func testAppStateCenterKeepsViewModelAcrossReads() {
        let appState = AppState.isolated()
        let first = appState.meetingPrepCenter.viewModel(for: "evt-1")
        XCTAssertTrue(appState.meetingPrepCenter.viewModel(for: "evt-1") === first)
    }

    /// Start prep → leave the screen (its view state is gone) → come back:
    /// the center hands back the same VM, still loading, and neither the
    /// prep view's on-appear generate nor a second click starts another run;
    /// the result then lands on the VM the returning screen shows.
    func testPrepInFlightSurvivesNavigationAndBlocksSecondRun() async throws {
        let cli = HeldCLIRunner(stdout: Self.validJSON)
        let center = MeetingPrepCenter { cli }

        let first = center.viewModel(for: "evt-1")
        first.generate(eventID: "evt-1")
        await awaitStarted(cli)

        let returned = center.viewModel(for: "evt-1")
        XCTAssertTrue(returned === first)
        XCTAssertTrue(returned.isLoading)

        returned.generate(eventID: "evt-1")
        returned.regenerate(eventID: "evt-1")
        XCTAssertTrue(returned.isLoading)

        cli.release()
        await returned.runTask?.value
        // Asserted only after the run has drained: a guard-less second call
        // would have spawned its own run task, which records on start.
        XCTAssertEqual(cli.invocations, [["meeting-prep", "evt-1", "--json"]])
        XCTAssertFalse(returned.isLoading)
        XCTAssertEqual(returned.result?.eventID, "evt-1")
        XCTAssertNil(returned.error)
    }

    /// Once a run has finished, Regenerate is allowed again.
    func testRegenerateAfterCompletionRunsAgain() async {
        let cli = FakeCLIRunner(stdout: Self.validJSON)
        let vm = MeetingPrepViewModel(cliRunner: cli)

        await runToCompletion(vm) { vm.generate(eventID: "evt-1") }
        await runToCompletion(vm) { vm.regenerate(eventID: "evt-1") }

        XCTAssertEqual(cli.invocations, [
            ["meeting-prep", "evt-1", "--json"],
            ["meeting-prep", "evt-1", "--json", "--force-refresh"]
        ])
    }

    // MARK: - startIfNeeded (the prep pane's on-appear entry)

    func testStartIfNeededRunsWhenNothingIsThere() async {
        let cli = FakeCLIRunner(stdout: Self.validJSON)
        let vm = MeetingPrepViewModel(cliRunner: cli)

        await runToCompletion(vm) { vm.startIfNeeded(eventID: "evt-1") }

        XCTAssertEqual(cli.invocations, [["meeting-prep", "evt-1", "--json"]])
        XCTAssertNotNil(vm.result)
    }

    /// Returning to an event that already has a prep shows it; no new run.
    func testStartIfNeededIsANoOpWhenAResultExists() async {
        let cli = FakeCLIRunner(stdout: Self.validJSON)
        let vm = MeetingPrepViewModel(cliRunner: cli)
        await runToCompletion(vm) { vm.generate(eventID: "evt-1") }

        vm.startIfNeeded(eventID: "evt-1")
        await vm.runTask?.value

        XCTAssertEqual(cli.invocations.count, 1)
    }

    /// Returning mid-run re-attaches to it; no second run.
    func testStartIfNeededIsANoOpWhileARunIsInFlight() async {
        let cli = HeldCLIRunner(stdout: Self.validJSON)
        let vm = MeetingPrepViewModel(cliRunner: cli)
        vm.generate(eventID: "evt-1")
        await awaitStarted(cli)
        let firstRun = vm.runTask

        vm.startIfNeeded(eventID: "evt-1")

        cli.release()
        await vm.runTask?.value
        await firstRun?.value
        XCTAssertEqual(cli.invocations, [["meeting-prep", "evt-1", "--json"]])
        XCTAssertNotNil(vm.result)
    }

    // MARK: - Lazy runner resolution

    /// A binary that could not be found once is looked up again on the next
    /// start — the VM lives for the app's lifetime, so a nil must not stick.
    func testRunnerIsResolvedAgainOnALaterStart() async {
        let cli = FakeCLIRunner(stdout: Self.validJSON)
        var available = false
        let vm = MeetingPrepViewModel { available ? cli : nil }

        vm.generate(eventID: "evt-1")
        XCTAssertEqual(vm.error, "Watchtower CLI not found")
        XCTAssertNil(vm.runTask)

        available = true
        await runToCompletion(vm) { vm.generate(eventID: "evt-1") }

        XCTAssertEqual(cli.invocations, [["meeting-prep", "evt-1", "--json"]])
        XCTAssertNotNil(vm.result)
        XCTAssertNil(vm.error)
    }

    /// Through the center too: the per-event VM it hands out resolves lazily.
    func testCenterViewModelResolvesRunnerLazily() async {
        let cli = FakeCLIRunner(stdout: Self.validJSON)
        var available = false
        let center = MeetingPrepCenter { available ? cli : nil }
        let vm = center.viewModel(for: "evt-1")

        vm.generate(eventID: "evt-1")
        XCTAssertEqual(vm.error, "Watchtower CLI not found")

        available = true
        await runToCompletion(vm) { vm.generate(eventID: "evt-1") }
        XCTAssertEqual(cli.invocations.count, 1)
    }

    // MARK: - Failed refresh keeps the old result

    /// A failed Refresh keeps the previous result AND exposes the error, so
    /// the pane can show both (banner above the old prep).
    func testFailedRefreshKeepsResultAndSetsError() async {
        let cli = FakeCLIRunner(stdout: Self.validJSON)
        let vm = MeetingPrepViewModel(cliRunner: cli)
        await runToCompletion(vm) { vm.generate(eventID: "evt-1") }

        cli.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: "provider unavailable")
        await runToCompletion(vm) { vm.regenerate(eventID: "evt-1") }

        XCTAssertEqual(vm.result?.eventID, "evt-1")
        XCTAssertEqual(vm.error, "provider unavailable")
        XCTAssertFalse(vm.isLoading)
    }
}
