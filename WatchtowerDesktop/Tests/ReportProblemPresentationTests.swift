import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Help → Report a Problem… and Settings → System → Logs (#1527): the main
/// window comes forward first, one sheet per app, every close cancels.
@MainActor
final class ReportProblemPresentationTests: XCTestCase {
    private var defaultsSuite = ""

    private func makeAppState() throws -> AppState {
        defaultsSuite = "ReportProblemPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        let features = FeatureManagerService(runner: FakeCLIRunner(stdout: Data(#"{"features":[]}"#.utf8)))
        return AppState(onboardingDefaults: defaults, featureManager: features)
    }

    override func tearDown() {
        if !defaultsSuite.isEmpty { UserDefaults().removePersistentDomain(forName: defaultsSuite) }
        super.tearDown()
    }

    /// A runner that never answers until its task is cancelled.
    private func blockingRunner() -> FakeCLIRunner {
        let runner = FakeCLIRunner()
        runner.blockUntilCancelled = true
        return runner
    }

    // MARK: - Arguments

    func testIPhoneArgumentFollowsMobileSync() throws {
        // The Go hub serves Mobile and the organization allows it.
        XCTAssertTrue(AppState.reportProblemIPhoneOn(hubState: "running", mobileSyncMode: "allowed"))
        XCTAssertTrue(AppState.reportProblemIPhoneOn(hubState: "waiting", mobileSyncMode: "workbench_only"))
        // The policy's MobileSync = off wins over a hub still reporting.
        XCTAssertFalse(AppState.reportProblemIPhoneOn(hubState: "running", mobileSyncMode: "off"))
        // Mobile turned off, or no hub status yet.
        XCTAssertFalse(AppState.reportProblemIPhoneOn(hubState: "off", mobileSyncMode: "allowed"))
        XCTAssertFalse(AppState.reportProblemIPhoneOn(hubState: nil, mobileSyncMode: "allowed"))

        // End to end: no hub center (tests have none) → `--iphone off`.
        let appState = try makeAppState()
        let runner = blockingRunner()
        appState.openMainWindow = {}
        appState.reportProblem(windows: [], activate: {}, runner: runner, buildFlavor: nil)
        let model = try XCTUnwrap(appState.reportProblemModel)
        defer { appState.closeReportProblem(model) }
        let args = try XCTUnwrap(waitForInvocation(runner))
        XCTAssertEqual(Array(args.prefix(4)), ["diagnostics", "--json", "--app-version", args[3]])
        XCTAssertEqual(Array(args.suffix(2)), ["--iphone", "off"])
    }

    func testMacOSVersionIsMajorMinor() {
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 1)
        XCTAssertEqual(AppState.reportProblemMacOS(version), "15.5")
    }

    // MARK: - Fronting the main window

    func testMenuFrontsMainWindow() throws {
        let appState = try makeAppState()
        var events: [String] = []
        appState.openMainWindow = {
            events.append(appState.reportProblemModel == nil ? "open" : "open after the sheet")
        }
        appState.reportProblem(windows: [], activate: { events.append("activate") }, runner: blockingRunner(), buildFlavor: nil)
        let model = try XCTUnwrap(appState.reportProblemModel)
        defer { appState.closeReportProblem(model) }
        XCTAssertEqual(events, ["activate", "open"], "no window: one opens before the sheet is set")
    }

    func testSettingsEntryFrontsVisibleMainWindow() throws {
        let appState = try makeAppState()
        var events: [String] = []
        let window = RecordingWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.identifier = NSUserInterfaceItemIdentifier("main-AppWindow-1")
        window.onFront = { events.append(appState.reportProblemModel == nil ? "front" : "front after the sheet") }
        appState.openMainWindow = { events.append("open") }
        appState.reportProblem(
            windows: [window],
            activate: { events.append(appState.reportProblemModel == nil ? "activate" : "activate after the sheet") },
            runner: blockingRunner(),
            buildFlavor: nil
        )
        let model = try XCTUnwrap(appState.reportProblemModel)
        defer { appState.closeReportProblem(model) }
        XCTAssertEqual(events, ["activate", "front"], "the window behind Settings comes forward, then the sheet")
    }

    func testSecondOpenReusesSheet() throws {
        let appState = try makeAppState()
        appState.openMainWindow = {}
        let runner = blockingRunner()
        appState.reportProblem(windows: [], activate: {}, runner: runner, buildFlavor: nil)
        let first = try XCTUnwrap(appState.reportProblemModel)
        defer { appState.closeReportProblem(first) }
        first.text = "The sync stopped."
        var fronted = 0
        appState.openMainWindow = { fronted += 1 }
        let second = blockingRunner()
        appState.reportProblem(windows: [], activate: {}, runner: second, buildFlavor: nil)
        XCTAssertTrue(appState.reportProblemModel === first, "the same sheet, not a second one")
        XCTAssertEqual(first.text, "The sync stopped.")
        XCTAssertEqual(fronted, 1, "the second call still brings the window forward")
        _ = waitForInvocation(runner)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertTrue(second.invocations.isEmpty, "no second collection")
    }

    func testCorpFlavorBuildsCorpModel() throws {
        for (flavor, corp) in [(nil, false), ("", false), ("dev", false), ("acme", true)] as [(String?, Bool)] {
            let appState = try makeAppState()
            appState.openMainWindow = {}
            appState.reportProblem(windows: [], activate: {}, runner: blockingRunner(), buildFlavor: flavor)
            let model = try XCTUnwrap(appState.reportProblemModel)
            XCTAssertEqual(model.isCorp, corp, "flavor \(flavor ?? "nil")")
            appState.closeReportProblem(model)
        }
    }

    // MARK: - Closing

    func testCloseCancelsTheRunAndDropsTheModel() throws {
        let appState = try makeAppState()
        appState.openMainWindow = {}
        let runner = blockingRunner()
        appState.reportProblem(windows: [], activate: {}, runner: runner, buildFlavor: nil)
        let model = try XCTUnwrap(appState.reportProblemModel)
        _ = waitForInvocation(runner)
        appState.closeReportProblem(model)
        XCTAssertNil(appState.reportProblemModel)
        XCTAssertNil(model.collection, "the run is cancelled: the runner terminates the child")
        XCTAssertEqual(model.phase, .collecting, "a cancelled run changes nothing")
    }

    /// A late `onDisappear` of a closed sheet never drops a newer one.
    func testLateCloseOfAnOldSheetKeepsTheNewOne() throws {
        let appState = try makeAppState()
        appState.openMainWindow = {}
        appState.reportProblem(windows: [], activate: {}, runner: blockingRunner(), buildFlavor: nil)
        let old = try XCTUnwrap(appState.reportProblemModel)
        appState.closeReportProblem(old)
        appState.reportProblem(windows: [], activate: {}, runner: blockingRunner(), buildFlavor: nil)
        let current = try XCTUnwrap(appState.reportProblemModel)
        defer { appState.closeReportProblem(current) }
        appState.closeReportProblem(old)
        XCTAssertTrue(appState.reportProblemModel === current)
    }

    /// Opens the sheet over a run that never answers.
    private func openCollecting(_ appState: AppState) throws -> ReportProblemModel {
        appState.openMainWindow = {}
        let runner = blockingRunner()
        appState.reportProblem(windows: [], activate: {}, runner: runner, buildFlavor: nil)
        let model = try XCTUnwrap(appState.reportProblemModel)
        _ = waitForInvocation(runner)
        XCTAssertNotNil(model.collection)
        return model
    }

    /// Esc or a programmatic dismiss: SwiftUI clears the host's binding.
    func testBindingClearedCancels() throws {
        let appState = try makeAppState()
        let model = try openCollecting(appState)
        ReportProblemSheetHost(appState: appState).presented.wrappedValue = nil
        XCTAssertNil(appState.reportProblemModel)
        XCTAssertNil(model.collection, "the run is cancelled")
    }

    /// Cancel (Esc presses it too) on the very view the host presents.
    func testCancelButtonCancels() throws {
        let appState = try makeAppState()
        let model = try openCollecting(appState)
        let sheet = ReportProblemSheetHost.sheet(for: model, appState: appState)
        try sheet.inspect().find(button: ReportProblemCopy.cancel).tap()
        XCTAssertNil(appState.reportProblemModel)
        XCTAssertNil(model.collection, "the run is cancelled")
    }

    /// The window closes under the sheet: the presented view leaves the
    /// hierarchy and its `onDisappear` closes it. The window is never
    /// ordered in.
    func testSheetLeavingTheWindowCancels() throws {
        let appState = try makeAppState()
        let model = try openCollecting(appState)
        let host = NSHostingView(rootView: AnyView(ReportProblemSheetHost.sheet(for: model, appState: appState)))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(appState.reportProblemModel === model, "on screen: nothing closed yet")
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while appState.reportProblemModel != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNil(appState.reportProblemModel)
        XCTAssertNil(model.collection, "the run is cancelled")
    }

    func testMissingCLIFailsAsMissing() async throws {
        let appState = try makeAppState()
        appState.openMainWindow = {}
        let runner = FakeCLIRunner(error: CLIRunnerError.binaryNotFound)
        appState.reportProblem(windows: [], activate: {}, runner: runner, buildFlavor: nil)
        let model = try XCTUnwrap(appState.reportProblemModel)
        defer { appState.closeReportProblem(model) }
        await model.collection?.value
        XCTAssertEqual(model.phase, .failed(.missing))
    }

    // MARK: - Helpers

    /// Spins the main run loop until the runner was called (≤ 2 s).
    @discardableResult
    private func waitForInvocation(_ runner: FakeCLIRunner) -> [String]? {
        let deadline = Date().addingTimeInterval(2)
        while runner.invocations.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return runner.invocations.first
    }
}

/// Reports itself visible and records fronting, without a real window server.
private final class RecordingWindow: NSWindow {
    var onFront: () -> Void = {}
    override var isVisible: Bool { true }
    override func makeKeyAndOrderFront(_ sender: Any?) { onFront() }
}
