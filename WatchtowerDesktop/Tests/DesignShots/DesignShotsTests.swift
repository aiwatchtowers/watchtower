import AppKit
import SwiftUI
import XCTest
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// Renders every `DesignShotCatalog` entry in light and dark mode (style
/// guide #719, spec §6) under `make desktop-shots`. Each shot must draw
/// something — more than one distinct colour — and lands as
/// `<dir>/<name>-light.png` and `<dir>/<name>-dark.png` in `DESKTOP_SHOTS_DIR`
/// for a by-eye before/after comparison. Nothing asserts pixels.
@MainActor
final class DesignShotsTests: XCTestCase {
    override static func tearDown() {
        MainActor.assumeIsolated { DesignShotFixtures.cleanUp() }
        super.tearDown()
    }

    /// A fixture that never finishes fails its shot within its turns, by
    /// name, instead of hanging the shots run.
    func testAFixtureThatNeverFinishesFailsInsteadOfHanging() throws {
        let gate = ShotGate()
        let shot = DesignShot(name: "never-finishes", prepare: {
            await gate.wait()
            return AnyView(EmptyView())
        }, size: NSSize(width: 10, height: 10))
        XCTAssertThrowsError(try Self.prepared(shot, turns: 1_000)) { error in
            XCTAssertEqual(String(describing: error),
                           "the fixture of shot never-finishes did not finish within 1000 run-loop turns")
        }
        Task { await gate.open() } // the waiting fixture ends with the test
    }

    func testShotNamesAreUnique() {
        let shots = DesignShotCatalog.all
        XCTAssertFalse(shots.isEmpty, "the catalog registers no shots")
        XCTAssertEqual(Set(shots.map(\.name)).count, shots.count, "shot names are file stems and must be unique")
    }

    /// Rendering every shot costs ~100 s, so it runs only under
    /// `make desktop-shots` (which sets `DESKTOP_SHOTS_DIR`), never in the
    /// unfiltered suite (style guide spec §6).
    func testEveryShotRenders() throws {
        try renderShots(DesignShotCatalog.all)
    }

    /// Inbox builder A's shots alone (mockups a-01 … a-11).
    func testInboxBuilderAShotsRender() throws {
        try renderShots(InboxBuilderAShotFixtures.shots)
    }

    /// Inbox builder B's shots alone (mockups b-01 … b-04).
    func testInboxBuilderBShotsRender() throws {
        try renderShots(InboxBuilderBShotFixtures.shots)
    }

    func testReviewerShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter { $0.name.hasPrefix("branch-review-reviewer") })
    }

    func testSpecReviewShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter { $0.name.hasPrefix("spec-review-") })
    }

    func testProviderFallbackShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter { $0.name.hasPrefix("provider-") })
    }

    func testSessionCapsShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter {
            ["workchat-hold-caption", "settings-notifications-idle-caption"].contains($0.name)
        })
    }

    func testTuningChatShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter { $0.name.hasPrefix("tuning-chat-") })
    }

    func testWorkchatActivityShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter { $0.name.hasPrefix("workchat-activity-") })
    }

    func testChatMarkdownShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter { $0.name.hasPrefix("chat-markdown-") })
    }

    func testClosedAsksShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter { $0.name.hasPrefix("closed-asks-") })
    }

    func testReportProblemShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter { $0.name.hasPrefix("report-problem-") })
    }

    func testOnboardingAgentShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter {
            $0.name.hasPrefix("onboarding-agent-") || $0.name.hasPrefix("onboarding-step-live-")
        })
    }

    /// The Slack Full / Live screens spec's mockups (#1779).
    func testSlackFullLiveShotsRender() throws {
        try renderShots(SlackFullLiveShotFixtures.shots)
    }

    /// The adaptive Slack sync plan's Statistics mockups (#1709).
    func testSlackAdaptiveSyncShotsRender() throws {
        try renderShots(SlackAdaptiveSyncShotFixtures.shots)
    }

    private func renderShots(_ shots: [DesignShot]) throws {
        guard let outputDir = ProcessInfo.processInfo.environment["DESKTOP_SHOTS_DIR"]
            .flatMap({ $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) })
        else {
            throw XCTSkip("DESKTOP_SHOTS_DIR is not set; run `make desktop-shots`")
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        for shot in shots {
            let view = try Self.prepared(shot)
            // A zero height means "as tall as the content".
            var size = shot.size
            if size.height <= 0 {
                size.height = ViewRenderProbe.fittingHeight(view, width: size.width)
            }
            let probe = ViewRenderProbe(size: size)
            for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                let data = try probe.png(view, appearance)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
                XCTAssertGreaterThan(Self.distinctColours(bitmap, limit: 2), 1, "\(shot.name)-\(suffix) is blank")
                try data.write(to: outputDir.appendingPathComponent("\(shot.name)-\(suffix).png"))
            }
        }
    }

    /// The most run-loop turns a shot's fixture may take (each a pass that
    /// never waits, `before: .distantPast`): far above the slowest Inbox
    /// fixture, and a count, never a clock.
    static let preparationTurns = 50_000_000

    /// A fixture that did not finish within its turns.
    struct UnfinishedFixture: Error, CustomStringConvertible {
        let shot: String
        let turns: Int
        var description: String { "the fixture of shot \(shot) did not finish within \(turns) run-loop turns" }
    }

    /// The shot's view: built at once, or its fixture's async work run to
    /// its end first (an Inbox shot lists Go's feed). The main run loop turns
    /// without waiting, at most `turns` times: a fixture that never finishes
    /// fails its shot, naming it, instead of hanging the run. A test method
    /// runs outside the main actor's executor, so the fixture's main-actor
    /// work drains on these turns.
    static func prepared(_ shot: DesignShot, turns: Int = preparationTurns) throws -> AnyView {
        if let make = shot.make { return make() }
        final class Box { var result: Result<AnyView, Error>? }
        let box = Box()
        Task { @MainActor in
            do { box.result = .success(try await shot.prepare()) } catch { box.result = .failure(error) }
        }
        var left = turns
        while box.result == nil, left > 0 {
            RunLoop.main.run(mode: .default, before: .distantPast)
            left -= 1
        }
        guard let result = box.result else { throw UnfinishedFixture(shot: shot.name, turns: turns) }
        return try result.get()
    }

    /// Distinct raw RGBA values in `bitmap`, counting up to `limit` only.
    private static func distinctColours(_ bitmap: NSBitmapImageRep, limit: Int) -> Int {
        guard let data = bitmap.bitmapData else { return 0 }
        let bytesPerPixel = bitmap.bitsPerPixel / 8
        var seen = Set<UInt32>()
        for y in 0..<bitmap.pixelsHigh {
            let row = data + y * bitmap.bytesPerRow
            for x in 0..<bitmap.pixelsWide {
                let pixel = row + x * bytesPerPixel
                let value = UInt32(pixel[0]) << 24 | UInt32(pixel[1]) << 16 | UInt32(pixel[2]) << 8 | UInt32(pixel[3])
                seen.insert(value)
                if seen.count >= limit { return seen.count }
            }
        }
        return seen.count
    }
}

extension DesignShotsTests {
    func testRuntimeFallbackChatShotsRender() throws {
        try renderShots(ProviderFallbackShotFixtures.runtimeShots)
    }
}

extension DesignShotsTests {
    func testHistoricalActualOnlyShotsRender() throws {
        try renderShots(ProviderFallbackShotFixtures.historicalActualShots)
    }
}

extension DesignShotsTests {
    func testRuntimeProviderApplyShotsRender() async throws {
        for provider in ["claude", "codex"] {
            for state in ["applying", "failed", "applied"] {
                let bytes = Data("""
                    {"preferred_provider":"\(provider)","enabled":true,"revision":"fixture-revision",
                     "saved_version":"fixture-file","providers":[],
                     "application":{"identity":"fixture-run","revision":"fixture-revision",
                     "saved_version":"fixture-file","preferred_provider":"\(provider)"}}
                    """.utf8)
                let model = ProviderRoutingApplication(attempts: 1, read: {
                    if state == "failed" { throw CocoaError(.fileReadNoPermission) }
                    return try ChatRoutingStatus.parse(bytes)
                }, pause: {})
                model.saved()
                if state != "applying" { await model.applyLatest() }
                let shot = DesignShot(name: "provider-apply-\(state)-\(provider)-narrow",
                                      size: CGSize(width: 360, height: 0)) {
                    AnyView(ProviderRoutingApplicationStatus(model: model) {}
                        .padding(.vertical, Spacing.large).background(Color(nsColor: .windowBackgroundColor)))
                }
                try renderShots([shot])
            }
        }
    }
}

extension DesignShotsTests {
    func testRuntimeProviderSettingsShotsRender() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The Go-written rows: the reserve and saved-limits sections read them.
        let catalog = AIModelCatalog(providers: ProviderCatalogFixture.providers())
        for provider in ["claude", "codex"] {
            let other = provider == "claude" ? "codex" : "claude"
            for (name, metadata) in [("unverified", ProviderConnection.Metadata.notVerified),
                                     ("notInstalled", .missingCLI), ("signInRequired", .missingSignIn), ("networkError", .networkError)] {
                let connection = ProviderConnection(catalog: catalog) { _ in metadata }
                let path = directory.appendingPathComponent("\(provider)-\(name).yaml").path
                let yaml = """
                ai:
                  provider: \(provider)
                  fallback: {enabled: false, provider: \(other)}
                  providers:
                    \(provider): {models: {light: sample-light, strong: sample-strong}}
                    \(other): {models: {light: reserve-light, strong: reserve-strong}}
                """
                try yaml.write(toFile: path, atomically: true, encoding: .utf8)
                let config = ConfigService(configPath: path, connection: connection, catalog: catalog)
                await connection.check(.init(provider: other, model: "reserve-strong", path: "", configPath: path), policy: .none)
                for narrow in [false, true] {
                    let shot = DesignShot(name: "provider-settings-\(name)-\(provider)\(narrow ? "-narrow" : "")",
                                          size: CGSize(width: narrow ? 360 : 640, height: 0)) {
                        AnyView(ProviderSettings(config: config, catalog: catalog, policy: .none)
                            .padding(Spacing.page).detailBackground())
                    }
                    try renderShots([shot])
                }
            }
        }
    }
}

extension DesignShotsTests {
    /// The big-branch review frames only (board #1025), for iterating on them.
    func testBigBranchReviewShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter { $0.name.hasPrefix("big-branch-") })
    }
}

/// A wait a test opens (the never-finishing fixture's).
private actor ShotGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
