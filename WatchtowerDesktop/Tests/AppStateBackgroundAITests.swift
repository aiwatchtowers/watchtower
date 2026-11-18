import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// `AppState.backgroundAI` (#1886, spec §3.3): the answer in the shared
/// config resolved with the forced policy, re-read by `reloadBackgroundAI()`.
@MainActor
final class AppStateBackgroundAITests: XCTestCase {
    private func appState(config: String?, policy: [String: Any] = [:]) throws -> (AppState, String) {
        ProviderCatalogFixture.seedShared() // the agents' plans come from the catalog, as after the launch read
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-bgai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.yaml").path
        if let config { try config.write(toFile: path, atomically: true, encoding: .utf8) }
        let state = AppState.isolated(managedPolicy: policy)
        state.managedPolicy.refresh()
        state.sharedConfig = ConfigService(configPath: path)
        return (state, path)
    }

    private func write(_ text: String, to path: String) throws {
        try ConfigFileLock.withLock(configPath: path) { token in
            try ConfigFileWriter.writeConfigFile(text, configPath: path, token: token)
        }
    }

    func testNoConfigIsUnansweredAndPrompts() throws {
        let (state, _) = try appState(config: nil)
        XCTAssertEqual(state.backgroundAI, BackgroundAIConsent.resolve(answer: nil, policy: nil))
        XCTAssertTrue(state.backgroundAI.prompt)
        XCTAssertFalse(state.backgroundAIConfigUnreadable)
    }

    func testAnswerAndPolicyResolveTogether() throws {
        let (state, _) = try appState(config: "ai: {background_runs: allowed}\n", policy: ["AllowBackgroundAI": false])
        XCTAssertEqual(state.backgroundAI.reason, .organization)
        XCTAssertTrue(state.backgroundAI.locked)
        let (owner, _) = try appState(config: "ai: {background_runs: allowed}\n")
        XCTAssertEqual(owner.backgroundAI, .allowedByOwner)
    }

    /// An answer written outside the Desktop shows after the re-read.
    func testReloadPicksUpAnAnswerFromTheTerminal() throws {
        let (state, path) = try appState(config: "ai: {model: m}\n")
        XCTAssertTrue(state.backgroundAI.prompt)
        try write("ai: {model: m, background_runs: paused}\n", to: path)
        state.reloadBackgroundAI()
        XCTAssertEqual(state.backgroundAI.reason, .owner)
        XCTAssertFalse(state.backgroundAI.isAllowed)
    }

    /// A broken config.yaml reads paused even when the profile allows (Go `Current`).
    func testUnreadableConfigIsPausedWithAPermissiveProfile() throws {
        let (state, _) = try appState(config: "ai: [unclosed\n", policy: ["AllowBackgroundAI": true])
        XCTAssertFalse(state.backgroundAI.isAllowed)
        XCTAssertEqual(state.backgroundAI.reason, .unanswered)
        XCTAssertTrue(state.backgroundAIConfigUnreadable)
    }

    /// The consent screen names the provider saved in config.yaml, read when
    /// it opens: an unsaved Settings edit does not change it, a save does.
    func testConsentModelDisclosesThePersistedProvider() throws {
        let (state, path) = try appState(config: "ai: {provider: codex}\n")
        state.sharedConfig.aiProvider = "claude" // an unsaved edit
        let runner = FakeCLIRunner(stdout: Data())
        XCTAssertEqual(state.makeBackgroundAIConsentModel(runner: runner)?.agent, .codex)

        try write("ai: {provider: claude, fallback: {enabled: true, provider: codex}}\n", to: path)
        let model = try XCTUnwrap(state.makeBackgroundAIConsentModel(runner: runner))
        XCTAssertEqual(model.agent, .claude)
        XCTAssertEqual(model.reserve, .codex)
    }

    /// The upgrade sheet waits for the What's New pass, and a re-entry while
    /// the sheet is marked open re-asserts it with its kind.
    func testUpgradeSheetWaitsForWhatsNewAndReentryReasserts() async throws {
        let (state, _) = try appState(config: nil)
        state.onboarding.goTo(.complete)
        state.updateService.buildFlavor = ""
        let suite = "AppStateBackgroundAITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        state.updateService.defaults = defaults
        XCTAssertFalse(state.updateService.isWhatsNewSettled)
        state.syncBackgroundAIConsentSheet()
        XCTAssertFalse(state.isBackgroundAIConsentPresented, "What's New may still open")

        state.updateService.fetchInstalledNotes = { _ in nil }
        await state.updateService.showWhatsNewIfUpdated(currentVersion: "1.0.0")
        state.syncBackgroundAIConsentSheet()
        XCTAssertEqual(state.backgroundAIConsentSheet.opened, .upgrade)

        state.presentBackgroundAIConsent()
        XCTAssertNil(state.backgroundAIConsentSheet.opened, "closed for a moment")
        for _ in 0..<10 where state.backgroundAIConsentSheet.opened == nil { await Task.yield() }
        XCTAssertEqual(state.backgroundAIConsentSheet.opened, .upgrade)
    }

    /// A config.yaml that is there but unreadable gives no model (never
    /// Claude and the default cadence): the re-entry shows the config error.
    func testUnreadableConfigShowsTheErrorNotDefaults() throws {
        let (state, _) = try appState(config: "ai: [unclosed\n")
        XCTAssertNil(state.makeBackgroundAIConsentModel(runner: FakeCLIRunner(stdout: Data())))
        state.presentBackgroundAIConsent()
        XCTAssertNil(state.backgroundAIConsentSheet.opened)
        XCTAssertTrue(state.backgroundAIConsentSheet.showsConfigError)

        let (missing, _) = try appState(config: nil)
        XCTAssertEqual(missing.makeBackgroundAIConsentModel(runner: FakeCLIRunner(stdout: Data()))?.agent, .claude,
                       "a missing file reads as the defaults")
    }
}
