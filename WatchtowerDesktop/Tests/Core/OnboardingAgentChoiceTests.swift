import XCTest
@testable import WatchtowerCore

final class OnboardingAgentChoiceTests: XCTestCase {
    private typealias Choice = OnboardingAgentChoice

    private func choice(_ claude: Choice.Status, _ codex: Choice.Status, configured: String? = nil) -> Choice {
        var choice = Choice(statuses: [.claude: claude, .codex: codex])
        choice.applyDefault(configured: configured)
        return choice
    }

    // MARK: Default selection

    func testBothReadyDefaultsToClaude() {
        XCTAssertEqual(choice(.ready, .ready).selected, .claude)
    }

    func testConfiguredAgentWinsOverOrder() {
        XCTAssertEqual(choice(.ready, .ready, configured: "codex").selected, .codex)
        // Even when it is not ready: the owner sees its setup, not a silent switch.
        XCTAssertEqual(choice(.ready, .signedOut, configured: "codex").selected, .codex)
    }

    func testOnlyReadyAgentIsPicked() {
        XCTAssertEqual(choice(.notInstalled, .ready).selected, .codex)
        XCTAssertEqual(choice(.signedOut, .ready).selected, .codex)
    }

    func testInstalledBeatsMissingWhenNoneReady() {
        XCTAssertEqual(choice(.notInstalled, .signedOut).selected, .codex)
        XCTAssertEqual(choice(.failed("x"), .notInstalled).selected, .claude)
    }

    func testNoneInstalledDefaultsToClaude() {
        let none = choice(.notInstalled, .notInstalled)
        XCTAssertEqual(none.selected, .claude)
        XCTAssertTrue(none.noneInstalled)
    }

    func testPolicyForbiddenAgentIsNeverSelected() {
        XCTAssertEqual(choice(.forbidden, .notInstalled, configured: "claude").selected, .codex)
        var forbidden = choice(.forbidden, .ready)
        forbidden.pick(.claude)
        XCTAssertEqual(forbidden.selected, .codex)
        XCTAssertFalse(forbidden.tile(.claude).enabled)
    }

    func testOwnerPickSurvivesLaterChecks() {
        var picked = choice(.ready, .ready)
        picked.pick(.codex)
        picked.statuses = [.claude: .ready, .codex: .signedOut]
        picked.applyDefault(configured: nil)
        XCTAssertEqual(picked.selected, .codex)
        XCTAssertFalse(picked.canContinue)
    }

    func testSelectionWaitsWhileChecking() {
        XCTAssertNil(Choice().selected)
        XCTAssertTrue(Choice().isChecking)
        XCTAssertNil(Choice().continueHint)
    }

    // MARK: Continue and saving

    func testContinueOnlyWithReadySelection() {
        XCTAssertTrue(choice(.ready, .notInstalled).canContinue)
        XCTAssertFalse(choice(.notInstalled, .notInstalled).canContinue)
        XCTAssertFalse(Choice().canContinue)
    }

    func testOtherProviderContinuesWithoutTiles() {
        let other = Choice(statuses: [.claude: .notInstalled, .codex: .notInstalled], otherProvider: "Ollama")
        XCTAssertTrue(other.canContinue)
        XCTAssertNil(other.setup)
        XCTAssertNil(other.providerToSave(configured: "ollama"))
        XCTAssertEqual(other.caption, "Watchtower runs on Ollama, set in Settings → AI.")
    }

    func testProviderToSave() {
        XCTAssertEqual(choice(.ready, .ready).providerToSave(configured: nil), "claude")
        XCTAssertEqual(choice(.ready, .ready).providerToSave(configured: " "), "claude")
        XCTAssertNil(choice(.ready, .ready).providerToSave(configured: "claude"))
        var codex = choice(.ready, .ready, configured: "claude")
        codex.pick(.codex)
        XCTAssertEqual(codex.providerToSave(configured: "claude"), "codex")
        XCTAssertNil(choice(.notInstalled, .notInstalled).providerToSave(configured: nil))
    }

    // MARK: Copy

    func testTileCopy() {
        let all: [(Choice.Status, String, Choice.Tone, Bool)] = [
            (.checking, "Checking…", .neutral, true),
            (.ready, "Ready · signed in", .success, false),
            (.notInstalled, "Not installed", .neutral, false),
            (.signedOut, "Installed · not signed in", .warning, false),
            (.failed("boom"), "Check failed", .error, false),
            (.forbidden, "Turned off by your organization", .neutral, false)
        ]
        for (status, text, tone, busy) in all {
            let tile = Choice(statuses: [.claude: status, .codex: .ready]).tile(.claude)
            XCTAssertEqual(tile.title, "Claude Code")
            XCTAssertEqual(tile.status, text)
            XCTAssertEqual(tile.tone, tone)
            XCTAssertEqual(tile.busy, busy)
        }
        XCTAssertEqual(Choice().tile(.codex).title, "Codex CLI")
    }

    func testCaptions() {
        XCTAssertEqual(
            choice(.ready, .ready).caption,
            "Chat, briefings and Workbench run on it. You can change it later in Settings → AI."
        )
        XCTAssertEqual(
            choice(.notInstalled, .notInstalled).caption,
            "Watchtower needs Claude Code or Codex CLI on this Mac. Pick one, install it and sign in — it takes a couple of minutes."
        )
        // One forbidden, the other missing: still the "needs" caption.
        XCTAssertTrue(choice(.forbidden, .notInstalled).noneInstalled)
        XCTAssertEqual(Choice.title, "AI agent")
    }

    func testSetupWhenNotInstalled() throws {
        var none = choice(.notInstalled, .notInstalled)
        let claude = try XCTUnwrap(none.setup)
        XCTAssertEqual(claude.title, "Install Claude Code")
        XCTAssertEqual(claude.steps, [
            .init(label: "Install it in Terminal:", command: "curl -fsSL https://claude.ai/install.sh | bash"),
            .init(label: "Sign in:", command: "claude")
        ])
        XCTAssertTrue(claude.showsManualPath)
        none.pick(.codex)
        let codex = try XCTUnwrap(none.setup)
        XCTAssertEqual(codex.title, "Install Codex CLI")
        XCTAssertEqual(codex.steps.map(\.command), ["curl -fsSL https://chatgpt.com/codex/install.sh | sh", "codex login"])
    }

    func testSetupWhenSignedOutOrFailed() throws {
        let signedOut = try XCTUnwrap(choice(.signedOut, .notInstalled).setup)
        XCTAssertEqual(signedOut.title, "Sign in to Claude Code")
        XCTAssertEqual(signedOut.steps, [.init(label: "Run in Terminal and follow the prompts:", command: "claude")])
        XCTAssertFalse(signedOut.showsManualPath)

        let failed = try XCTUnwrap(choice(.failed("timed out"), .notInstalled).setup)
        XCTAssertEqual(failed.title, "Claude Code didn’t answer")
        XCTAssertEqual(failed.detail, "timed out")
        XCTAssertTrue(failed.steps.isEmpty)
    }

    func testNoSetupWhenReadyCheckingOrForbidden() {
        XCTAssertNil(choice(.ready, .ready).setup)
        XCTAssertNil(Choice().setup)
    }

    func testSetupButtonsAndHints() {
        XCTAssertEqual(Choice.Setup.checkAgain, "Check again")
        XCTAssertEqual(Choice.Setup.manualPath, "Choose the executable…")
        XCTAssertEqual(Choice.Setup.autoCheck, "Watchtower checks again when you come back to this window.")
        XCTAssertEqual(Choice.saveFailure, "Couldn’t save the AI agent.")
    }

    func testContinueHint() {
        XCTAssertNil(choice(.ready, .ready).continueHint)
        XCTAssertEqual(choice(.notInstalled, .notInstalled).continueHint, "Continue unlocks once Claude Code is ready")
        var codex = choice(.notInstalled, .notInstalled)
        codex.pick(.codex)
        XCTAssertEqual(codex.continueHint, "Continue unlocks once Codex CLI is ready")
    }

    func testDevelopmentPitchNamesTheAgent() {
        var both = choice(.ready, .ready)
        XCTAssertEqual(both.developmentPitch, "Claude Code works your folder’s board. No connections needed")
        both.pick(.codex)
        XCTAssertEqual(both.developmentPitch, "Codex CLI works your folder’s board. No connections needed")
        XCTAssertEqual(Choice().developmentPitch, "Your AI agent works your folder’s board. No connections needed")
    }
}
