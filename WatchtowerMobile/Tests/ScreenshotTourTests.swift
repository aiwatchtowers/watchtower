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
        let session = try HubSession(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            transportKind: .inMemoryDemo,
            defaults: defaults,
            recordingsDirectory: try makeRecordingsDirectory()
        )
        addTeardownBlock { @MainActor in session.stop() }
        let root = AppRoot.demo(AppEnvironment.single(session, defaults: defaults), defaults: defaults)
        return root
    }

    private static func isHydrated(_ env: AppEnvironment) -> Bool {
        env.activeSession.isBootstrapped && !env.workbenchReplica.snapshot.workbenches.isEmpty
            && !env.calendarReplica.snapshot.events.isEmpty && !env.phoneRecordings.snapshot.recordings.isEmpty
    }

    /// 26b–26d: the recorder over a fake engine and clock, recording,
    /// paused and saved. The demo environment's recorder never starts (no
    /// microphone on the simulator), so it shows 26 (idle) only.
    private func captureRecorder(into dir: URL, linking: LinkingViewModel) async throws -> [ScreenshotHost.IndexRow] {
        let engine = FakeAudioEngine()
        let clock = FakeClock()
        let defaults = try makeDefaults()
        let session = try HubSession(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            transportKind: .inMemoryDemo,
            defaults: defaults,
            recordingsDirectory: try makeRecordingsDirectory()
        ) { uploader in
            PhoneRecorderController(
                uploader: uploader, engine: engine, notificationCenter: NotificationCenter(),
                now: { clock.now }, tickInterval: nil
            )
        }
        addTeardownBlock { @MainActor in session.stop() }
        try await poll(timeout: 20, { session.isBootstrapped }, "the recorder environment booted")
        let env = AppEnvironment.single(session, defaults: defaults)
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
            let end = ScreenshotHost.IndexRow(
                number: "\(shot.number)e", view: view, source: shot.source,
                reached: "\(shot.reached.rawValue), scrolled to the end"
            )
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
            Shot(
                number: number, slug: "session-\(id)-\(slug)", source: "Features/Workbench/SessionDetailView.swift",
                reached: .bareStack,
                make: stack {
                    SessionDetailView(replica: $0.workbenchReplica, sessionID: id, store: $0.store, requester: $0.reportRequests)
                }
            )
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
            Shot(number: "24", slug: "recap", source: "Features/Recordings/RecapView.swift", reached: .fullApp,
                 make: app(.calendar, path: [.recap(501)])),
            Shot(number: "25", slug: "transcript", source: "Features/Recordings/RecapView.swift", reached: .bareStack, make: stack { _ in
                RecapView(transcriptID: 501, initialTab: .transcript)
            }),
            Shot(number: "26", slug: "recorder-idle", source: "Features/Recording/RecordingView.swift", reached: .leaf,
                 make: leaf { _ in RecordingView() }),
            Shot(number: "27", slug: "settings", source: "Features/Settings/SettingsView.swift", reached: .bareStack,
                 make: stack { _ in SettingsView() })
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
            Shot(number: "30", slug: "checking", source: source + "LinkSteps.swift", reached: .leaf, make: leaf { _ in
                LinkStepsView(model: LinkStepsModel(waitingFor: nil, startedAt: nil, now: Date()))
            }),
            Shot(number: "31", slug: "waiting", source: source + "LinkSteps.swift", reached: .leaf, make: leaf { _ in
                LinkStepsView(model: LinkStepsModel(waitingFor: mac, startedAt: Date(), now: Date()))
            }),
            Shot(number: "31b", slug: "waiting-hint", source: source + "LinkSteps.swift", reached: .leaf, make: leaf { _ in
                LinkStepsView(model: LinkStepsModel(waitingFor: mac, startedAt: Date().addingTimeInterval(-25), now: Date()))
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
}
