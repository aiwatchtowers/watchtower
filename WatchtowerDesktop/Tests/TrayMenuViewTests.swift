import XCTest
import ViewInspector
import SwiftUI
@testable import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

@MainActor
final class TrayMenuViewTests: XCTestCase {
    // `TrayMenuView` itself reads @Environment(AppState.self), which
    // ViewInspector (0.10.3, this repo) cannot populate without a real render
    // pass — it hits an uncatchable fatal error, not a throwable Swift error.
    // `TrayMenuContent` is the environment-free split that carries the actual
    // rendering (see RecordingIndicatorView/RecordingJobPill for the same
    // pattern), so it's what gets exercised here.

    /// Every parameter defaulted to an inert value — a call only spells out
    /// what that test cares about, keeping the growing parameter list from
    /// forcing every call site onto one long line.
    private static func content(
        isRunning: Bool = true,
        syncProgress: SyncProgress? = nil,
        daemonError: String? = nil,
        cliStoreError: String? = nil,
        voicesPendingCount: Int = 0,
        updateVersion: String? = nil,
        updateAction: @escaping () -> Void = {},
        syncNowAction: @escaping () -> Void = {},
        runAutomationSections: [TrayRunAutomationMenu.Section]? = nil,
        runAutomationAction: @escaping (Int64) -> Void = { _ in },
        openAutomationsAction: @escaping () -> Void = {},
        quickCaptureAction: @escaping () -> Void = {},
        voicesAction: @escaping () -> Void = {},
        reviewVoicesAction: @escaping () -> Void = {},
        trainVoicesAction: @escaping () -> Void = {},
        openAction: @escaping () -> Void = {},
        settingsAction: @escaping () -> Void = {}
    ) -> TrayMenuContent {
        TrayMenuContent(
            isRunning: isRunning, syncProgress: syncProgress, daemonError: daemonError, cliStoreError: cliStoreError,
            voicesPendingCount: voicesPendingCount, updateVersion: updateVersion, updateAction: updateAction,
            syncNowAction: syncNowAction, runAutomationSections: runAutomationSections,
            runAutomationAction: runAutomationAction, openAutomationsAction: openAutomationsAction,
            quickCaptureAction: quickCaptureAction,
            voicesAction: voicesAction, reviewVoicesAction: reviewVoicesAction, trainVoicesAction: trainVoicesAction,
            openAction: openAction, settingsAction: settingsAction)
    }

    /// A found update gets its own tray item — the app lives in the tray for
    /// weeks, so the sidebar badge alone is rarely seen.
    func testUpdateItemShowsAndFiresWhenAnUpdateIsKnown() throws {
        var fired = false
        // swiftlint:disable:next trailing_closure
        let view = Self.content(updateVersion: "v9.9.9", updateAction: { fired = true })
        let button = try view.inspect().find(button: "Update to v9.9.9 available…")
        try button.tap()
        XCTAssertTrue(fired)
    }

    func testNoUpdateItemWithoutAKnownUpdate() {
        let view = Self.content()
        XCTAssertThrowsError(try view.inspect().find { text, _ in text.hasPrefix("Update to") })
    }

    func testMenuOffersOpenSettingsAndQuit() throws {
        let view = Self.content()
        let openButton = try view.inspect().find(button: "Open Watchtower")
        let settingsButton = try view.inspect().find(button: "Settings…")
        let quitButton = try view.inspect().find(button: "Quit Watchtower")
        XCTAssertNotNil(openButton)
        XCTAssertNotNil(settingsButton)
        XCTAssertNotNil(quitButton)
    }

    /// New Voice Idea is the tray's entry point into quick capture — it must
    /// stay reachable and must fire the closure the environment-wired
    /// `TrayMenuView` wires to `AppState.openQuickCapture`.
    func testNewVoiceIdeaFiresQuickCaptureAction() throws {
        var fired = false
        // `quickCaptureAction` isn't `content`'s last parameter, so trailing-closure form would bind wrong.
        // swiftlint:disable:next trailing_closure
        let view = Self.content(quickCaptureAction: { fired = true })
        let button = try view.inspect().find(button: "New Voice Idea")
        try button.tap()
        XCTAssertTrue(fired)
    }

    func testStatusLineReflectsDaemonState() throws {
        XCTAssertEqual(
            TrayMenuContent.statusText(isRunning: false, syncProgress: nil),
            "Sync daemon not running")
        XCTAssertEqual(
            TrayMenuContent.statusText(isRunning: true, syncProgress: nil),
            "Daemon running · idle")
    }

    /// The point of the heartbeat: while a sync runs, the tray says which phase
    /// it is in — a live daemon between syncs must not claim to be syncing.
    func testStatusLineShowsLiveSyncPhase() throws {
        let now = Date()
        let syncing = Self.progress(active: true, phase: "Messages", detail: "34/105 channels", updated: now)
        XCTAssertEqual(
            TrayMenuContent.statusText(isRunning: true, syncProgress: syncing, now: now),
            "Syncing: Messages · 34/105 channels")

        let noDetail = Self.progress(active: true, phase: "Metadata", detail: nil, updated: now)
        XCTAssertEqual(
            TrayMenuContent.statusText(isRunning: true, syncProgress: noDetail, now: now),
            "Syncing: Metadata")
    }

    /// A daemon killed mid-sync leaves `active: true` behind forever; the tray
    /// must not keep claiming a sync is running because of a dead file.
    func testStaleHeartbeatDoesNotClaimSyncing() throws {
        let now = Date()
        let stale = Self.progress(
            active: true, phase: "Messages", detail: "34/105 channels",
            updated: now.addingTimeInterval(-SyncProgress.staleAfter - 1))
        XCTAssertEqual(
            TrayMenuContent.statusText(isRunning: true, syncProgress: stale, now: now),
            "Daemon running · idle")
    }

    func testSyncNowFiresActionAndNeedsARunningDaemon() throws {
        var fired = false
        // `syncNowAction` isn't `content`'s last parameter, so trailing-closure form would bind wrong.
        // swiftlint:disable:next trailing_closure
        let view = Self.content(syncNowAction: { fired = true })
        try view.inspect().find(button: "Sync Now").tap()
        XCTAssertTrue(fired)

        // Without a daemon there is nothing to ask: the CLI signals a process
        // that isn't there.
        let stopped = Self.content(isRunning: false)
        XCTAssertTrue(try stopped.inspect().find(button: "Sync Now").isDisabled())
    }

    /// Builds a heartbeat through the JSON decoder, so the test exercises the
    /// same field names and timestamp format the Go writer emits.
    private static func progress(active: Bool, phase: String, detail: String?, updated: Date) -> SyncProgress {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let detailJSON = detail.map { "\"detail\": \"\($0)\"," } ?? ""
        let json = """
        {
          "active": \(active),
          "phase": "\(phase)",
          \(detailJSON)
          "messages_fetched": 1200,
          "started_at": "\(formatter.string(from: updated.addingTimeInterval(-60)))",
          "updated_at": "\(formatter.string(from: updated))"
        }
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(SyncProgress.self, from: Data(json.utf8))
    }

    /// The history backfill line sits under the status text while a backfill loads.
    func testBackfillLineIsRenderedWhenSet() throws {
        let view = TrayMenuContent(
            isRunning: true, syncProgress: nil, daemonError: nil, cliStoreError: nil, voicesPendingCount: 0,
            backfillLine: "Loading history: 1 of 30 days",
            updateVersion: nil, updateAction: {}, syncNowAction: {}, quickCaptureAction: {}, voicesAction: {},
            reviewVoicesAction: {}, trainVoicesAction: {}, openAction: {}, settingsAction: {})
        XCTAssertNoThrow(try view.inspect().find(text: "Loading history: 1 of 30 days"))
    }

    func testNoBackfillLineWhenNil() {
        let view = Self.content()
        XCTAssertThrowsError(try view.inspect().find { text, _ in text.hasPrefix("Loading history") })
    }

    func testNoErrorLinesWhenNothingFailed() throws {
        let view = Self.content()
        XCTAssertThrowsError(try view.inspect().find { text, _ in text.hasPrefix("CLI store:") })
        XCTAssertThrowsError(try view.inspect().find { text, _ in text.hasPrefix("Daemon:") })
    }

    /// The CLI store falling back to the bundle is the one thing the tray can
    /// say that no other always-available surface does.
    func testCLIStoreErrorIsRendered() throws {
        let view = Self.content(isRunning: false, cliStoreError: "rename to /x failed: No such file")
        XCTAssertNoThrow(try view.inspect().find(text: "CLI store: rename to /x failed: No such file"))
    }

    /// A daemon that could not be started must not fail silently in the one
    /// surface that is always on screen.
    func testDaemonErrorIsRendered() throws {
        let view = Self.content(isRunning: false, daemonError: "Failed to start daemon (exit code 1)")
        XCTAssertNoThrow(try view.inspect().find(text: "Daemon: Failed to start daemon (exit code 1)"))
    }

    // MARK: - Voices entry points

    /// The queue button only earns its place when there's something to
    /// label — an empty queue would just be one more permanent menu row.
    func testVoicesToLabelButtonAppearsOnlyWithPendingCount() throws {
        let withPending = Self.content(voicesPendingCount: 3)
        XCTAssertNoThrow(try withPending.inspect().find(button: "Voices to label (3)"))

        let empty = Self.content(voicesPendingCount: 0)
        XCTAssertThrowsError(
            try empty.inspect().find(ViewType.Button.self) { try $0.labelView().text().string().hasPrefix("Voices to label") })
    }

    /// Review and Train are always reachable, regardless of the queue.
    func testReviewAndTrainVoicesAreAlwaysOffered() throws {
        let view = Self.content()
        XCTAssertNoThrow(try view.inspect().find(button: "Review voices"))
        XCTAssertNoThrow(try view.inspect().find(button: "Train voices"))
    }

    func testVoicesButtonsFireTheirActions() throws {
        var voices = false
        var review = false
        var train = false
        let view = Self.content(
            voicesPendingCount: 1,
            voicesAction: { voices = true },
            reviewVoicesAction: { review = true },
            trainVoicesAction: { train = true })
        try view.inspect().find(button: "Voices to label (1)").tap()
        try view.inspect().find(button: "Review voices").tap()
        try view.inspect().find(button: "Train voices").tap()
        XCTAssertTrue(voices)
        XCTAssertTrue(review)
        XCTAssertTrue(train)
    }

    // MARK: - Model download line (#744)

    private static func download(_ state: TranscriptionModelProvisioner.DownloadState, startedAt: Date)
        -> TranscriptionModelProvisioner.Download {
        TranscriptionModelProvisioner.Download(
            key: .init(providerID: "whisperkit", model: "large-v3"), purpose: .meetings, label: "Large v3",
            sizeBytes: nil, state: state, startedAt: startedAt, startFraction: 0.2)
    }

    func testModelDownloadLineShowsProgressAndTimeLeft() {
        let start = Date()
        // 0.2 → 0.6 in 40 s: the remaining 40% takes about 40 s.
        let line = TrayMenuContent.modelDownloadText(Self.download(.downloading(progress: 0.6), startedAt: start),
                                                     now: start.addingTimeInterval(40))
        XCTAssertEqual(line, "Downloading Large v3 — 60%, less than a minute left (one-time)")
    }

    func testModelDownloadLineShowsAFailureAndTheRetryItem() throws {
        var retried: TranscriptionModelProvisioner.ModelKey?
        let failed = Self.download(.failed("The connection dropped."), startedAt: Date())
        XCTAssertEqual(TrayMenuContent.modelDownloadText(failed), "Large v3 download failed: The connection dropped.")
        let view = TrayMenuContent(
            isRunning: true, syncProgress: nil, daemonError: nil, cliStoreError: nil, voicesPendingCount: 0,
            modelDownloads: [failed], retryModelDownloadAction: { retried = $0 },
            updateVersion: nil, updateAction: {}, syncNowAction: {}, quickCaptureAction: {}, voicesAction: {},
            reviewVoicesAction: {}, trainVoicesAction: {}, openAction: {}, settingsAction: {})
        try view.inspect().find(button: "Retry Large v3 Download").tap()
        XCTAssertEqual(retried, failed.key)
    }

    // MARK: - Run automation ▸ (spec §12.7)

    private static let sections = [
        TrayRunAutomationMenu.Section(id: "workbench-10", title: "acme", items: [
            .init(id: 1, title: "Release…", status: "✓ 2 d ago", isActionable: true),
            .init(id: 2, title: "Deploy to stage", status: "— disabled", isActionable: false)
        ]),
        TrayRunAutomationMenu.Section(id: "personal", title: "Personal", items: [
            .init(id: 3, title: "Release notes draft", status: "", isActionable: true)
        ])
    ]

    func testRunAutomationMenuHiddenWhenFeatureOff() throws {
        let view = Self.content(runAutomationSections: nil)
        XCTAssertThrowsError(try view.inspect().find(ViewType.Menu.self))
        XCTAssertThrowsError(try view.inspect().find(button: "Open Automations…"))
        XCTAssertNoThrow(try Self.content(runAutomationSections: []).inspect().find(ViewType.Menu.self))
    }

    func testRunAutomationMenuEndsWithOpenAutomations() throws {
        var ran: [Int64] = []
        var opened = false
        let view = Self.content(runAutomationSections: Self.sections,
                                runAutomationAction: { ran.append($0) },
                                openAutomationsAction: { opened = true })
        let menu = try view.inspect().find(ViewType.Menu.self)
        XCTAssertEqual(try menu.labelView().text().string(), "Run automation")
        let labels = try menu.findAll(ViewType.Button.self).map { try $0.labelView().text().string() }
        XCTAssertEqual(labels, ["Release…  ✓ 2 d ago", "Deploy to stage  — disabled", "Release notes draft",
                                "Open Automations…"])
        XCTAssertNoThrow(try menu.find(text: "acme"))
        XCTAssertNoThrow(try menu.find(text: "Personal"))
        try menu.find(button: "Release…  ✓ 2 d ago").tap()
        try menu.find(button: "Open Automations…").tap()
        XCTAssertEqual(ran, [1])
        XCTAssertTrue(opened)
    }

    func testDisabledItemRendersDisabled() throws {
        let view = Self.content(runAutomationSections: Self.sections)
        XCTAssertTrue(try view.inspect().find(button: "Deploy to stage  — disabled").isDisabled())
        XCTAssertFalse(try view.inspect().find(button: "Release notes draft").isDisabled())
    }

    /// The environment-wired view reads its sections from `AppState`: the
    /// quick-run rows, nil (no submenu) before the database opens.
    func testTraySectionsFollowTheDatabase() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let suite = "TrayMenuViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let features = FeatureManagerService(runner: FakeCLIRunner(stdout: Data(#"{"features":[]}"#.utf8)))
        let appState = AppState(onboardingDefaults: defaults, featureManager: features)
        XCTAssertNil(appState.trayRunAutomationSections(), "no quick-run center before the database opens")
        appState.wireAppDatabaseOverride = { _ in }
        appState.databaseManager = manager
        appState.completeOnboarding()
        defer {
            appState.automationsViewModel?.stop()
            appState.stopSidebarCounts()
        }
        XCTAssertEqual(appState.trayRunAutomationSections(), [])
    }
}
