import AppKit
import ChatWire
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

    /// Every background AI consent frame (#1886) has its shot.
    func testEveryBackgroundAIConsentFrameHasAShot() {
        let names = Set(BackgroundAIConsentShotFixtures.shots.map(\.name))
        for step in BackgroundAIConsentShotFixtures.Step.allCases {
            XCTAssertTrue(names.contains("ai-consent-step-\(step.rawValue)"))
        }
        for state in BackgroundAIConsentShotFixtures.Settings.allCases {
            XCTAssertTrue(names.contains("ai-consent-settings-\(state.rawValue)"))
        }
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

    /// The approval card's shots alone (#1822 T15): every card state, the chat's, and the older approval shots.
    func testApprovalCardShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter {
            $0.name.hasPrefix("approval-") || $0.name.hasPrefix("inbox-b-approvals-")
                || ApprovalCardShotFixtures.comparedNames.contains($0.name)
        })
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

    /// The plan limits without a token spec's mockups (#1885).
    func testPlanLimitsNoTokenShotsRender() throws {
        try renderShots(PlanLimitsNoTokenShotFixtures.shots)
    }

    /// The Slack Full / Live screens spec's mockups (#1779).
    func testBackgroundAIConsentShotsRender() throws {
        try renderShots(BackgroundAIConsentShotFixtures.shots)
    }

    func testSlackFullLiveShotsRender() throws {
        try renderShots(SlackFullLiveShotFixtures.shots)
    }

    /// The Watchman spec's mockups (#1824).
    func testWatchmanShotsRender() throws {
        try renderShots(WatchmanShotFixtures.shots)
    }

    /// Connections → Slack: the `slack-fl-pane-*` shots draw the real Slack
    /// mode section (`SlackModeSection`, screens spec §1), and its chip and
    /// summary say what the approved mockup said for the same frame.
    func testSlackModePaneShotsRender() throws {
        typealias Copy = SlackFullLiveMockCopy
        let expected: [SlackFullLiveShotFixtures.Pane: (String, String)] = [
            .full: (Copy.chipFull, Copy.summaryFull),
            .fullLive: (Copy.chipFullLive, Copy.summaryFullLive),
            .checking: (Copy.chipFullLive, Copy.summaryFullLive),
            .probeFailed: (Copy.chipFullLive, Copy.summaryFullLive),
            .live: (Copy.chipLive, Copy.summaryLive),
            .liveProblems: (Copy.chipLive, Copy.summaryLive),
            .off: (Copy.chipOff, Copy.summaryOff),
            .sharedApp: (Copy.chipShared, Copy.summaryShared)
        ]
        for (pane, copy) in expected {
            let presentation = SlackPaneModeFixture.presentation(pane)
            XCTAssertEqual(presentation.chip, copy.0, pane.rawValue)
            XCTAssertEqual(presentation.summary, copy.1, pane.rawValue)
        }
        XCTAssertEqual(SlackPaneModeFixture.presentation(.probeFailed).problem, Copy.probeFailed)
        XCTAssertEqual(SlackPaneModeFixture.presentation(.readFailed).problem, Copy.readFailed)
        XCTAssertEqual(SlackPaneModeFixture.presentation(.live).liveRows.map(\.status),
                       [Copy.liveNotConnected, Copy.liveOnTeamID])
        XCTAssertEqual(SlackPaneModeFixture.presentation(.fullLive).liveRows.map(\.age),
                       [Copy.checked5H, Copy.checked5H])
        try renderShots(SlackFullLiveShotFixtures.shots.filter { $0.name.hasPrefix("slack-fl-pane-") })
    }

    /// `needsFullSlack` (screens spec §2): the Digests, Catch-Up and
    /// Statistics shots draw the real `FeatureEmptyState`, the Home shot the
    /// real Getting ready row; their strings are the approved mockups'.
    func testSlackNeedsFullShotsRender() throws {
        typealias Copy = SlackFullLiveMockCopy
        XCTAssertEqual(FeatureReadiness.line(.needsFullSlack), Copy.needsFullLine)
        XCTAssertEqual(ReadinessSource.fullSlack.actionTitle, Copy.needsFullAction)
        XCTAssertEqual(SlackPaneModeFixture.presentation(.live).knowledgeNote, Copy.knowledgeNote)
        try renderShots(SlackFullLiveShotFixtures.shots.filter { $0.name.hasPrefix("slack-fl-needs-full-") })
    }

    /// The unified chat's new states and baselines (#1822 T0).
    /// The composer's shots and the existing shots that hold a composer (#1822 T13).
    func testComposerShotsRender() throws {
        let parts = [
            "composer-", "chat-daemon-", "other-provider", "chat-composer-ollama-capabilities", "workchat-hold-caption",
            "spec-review-thread-replying", "chat-project-page-", "embedded-chat-", "chat-remote-turn-live"
        ]
        try renderShots(DesignShotCatalog.all.filter { shot in parts.contains { shot.name.contains($0) } })
    }

    /// The routing pill, the fallback card and every shot that holds them, for the before/after comparison of the
    /// pill's move into ChatUI (#1822 T17).
    func testRoutingShotsRender() throws {
        let parts = ["routing-", "provider-chat-", "provider-fallback-", "chat-composer-ollama-capabilities", "composer-main-"]
        try renderShots(DesignShotCatalog.all.filter { shot in parts.contains { shot.name.hasPrefix($0) } }
            + ProviderFallbackShotFixtures.historicalActualShots)
    }

    func testUnifiedChatShotsRender() throws {
        try renderShots(UnifiedChatShotFixtures.shots)
    }

    /// The Chats panel's rows (final review I5), for the before/after comparison with the pre-umbrella row.
    func testChatSidebarShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter { $0.name.hasPrefix("chat-sidebar-") })
    }

    /// Every main-chat shot (`chat-*`), for the before/after comparison of the
    /// chat's move onto the engine (#1822 T8).
    func testChatShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter { $0.name.hasPrefix("chat-") })
    }

    /// The adaptive Slack sync plan's Statistics mockups (#1709).
    func testSlackAdaptiveSyncShotsRender() throws {
        try renderShots(SlackAdaptiveSyncShotFixtures.shots)
    }

    /// The session's Spec review state mockups (board #1945).
    func testSpecReviewStateShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter { $0.name.hasPrefix("session-state-spec-review") })
    }

    /// The workbench FILES tree's states (#2017).
    func testFilesSectionShotsRender() throws {
        try renderShots(FilesSectionShotFixtures.shots)
    }

    /// The Slack Developer Policy hygiene spec's mockups (#1769).
    func testSlackPolicyShotsRender() throws {
        try renderShots(SlackPolicyShotFixtures.shots)
    }

    private func renderShots(_ shots: [DesignShot]) throws {
        guard let outputDir = ProcessInfo.processInfo.environment["DESKTOP_SHOTS_DIR"]
            .flatMap({ $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) })
        else {
            throw XCTSkip("DESKTOP_SHOTS_DIR is not set; run `make desktop-shots`")
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        for shot in shots {
            // A zero height means "as tall as the content".
            var size = shot.size
            if size.height <= 0 {
                size.height = ViewRenderProbe.fittingHeight(shot.make(), width: size.width)
            }
            let probe = ViewRenderProbe(size: size)
            for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                let data = try probe.png(shot.make(), appearance)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
                XCTAssertGreaterThan(Self.distinctColours(bitmap, limit: 2), 1, "\(shot.name)-\(suffix) is blank")
                try data.write(to: outputDir.appendingPathComponent("\(shot.name)-\(suffix).png"))
            }
        }
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

extension DesignShotsTests {
    /// The auto-cleanup states only (board #1716), for iterating on them.
    func testAutoCleanupShotsRender() throws {
        try renderShots(DesignShotCatalog.all.filter { $0.name.hasPrefix("auto-cleanup-") })
    }
}
