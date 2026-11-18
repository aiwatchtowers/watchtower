import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// `AppState.backgroundAI` (#1886, spec §3.3): the answer in the shared
/// config resolved with the forced policy, re-read by `reloadBackgroundAI()`.
@MainActor
final class AppStateBackgroundAITests: XCTestCase {
    private func appState(config: String?, policy: [String: Any] = [:]) throws -> (AppState, String) {
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
            try ConfigFileWriter.write(text, configPath: path, token: token)
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
}
