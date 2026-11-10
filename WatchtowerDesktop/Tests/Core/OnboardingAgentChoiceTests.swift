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
            .init(label: "Sign in:", command: "claude auth login")
        ])
        XCTAssertTrue(claude.showsManualPath)
        XCTAssertEqual(claude.docsURL, "https://code.claude.com/docs/en/setup")
        XCTAssertFalse(claude.runsSignIn)
        none.pick(.codex)
        let codex = try XCTUnwrap(none.setup)
        XCTAssertEqual(codex.title, "Install Codex CLI")
        XCTAssertEqual(codex.steps.map(\.command), ["curl -fsSL https://chatgpt.com/codex/install.sh | sh", "codex login"])
    }

    func testSetupWhenSignedOutOrFailed() throws {
        let signedOut = try XCTUnwrap(choice(.signedOut, .notInstalled).setup)
        XCTAssertEqual(signedOut.title, "Sign in to Claude Code")
        XCTAssertEqual(signedOut.steps, [.init(label: "Or run it in your own Terminal:", command: "claude auth login")])
        XCTAssertFalse(signedOut.showsManualPath)
        XCTAssertTrue(signedOut.runsSignIn)
        XCTAssertNil(signedOut.docsURL)

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

    // MARK: Sign-in terminal (ask #1157)

    func testSignInOpensOnceForTheSignedOutPick() {
        var signedOut = choice(.signedOut, .notInstalled)
        XCTAssertEqual(signedOut.signInToOpen, .claude)
        signedOut.signInStarted()
        XCTAssertEqual(signedOut.signIn, .running)
        XCTAssertNil(signedOut.signInToOpen)
        signedOut.signInStopped()
        XCTAssertEqual(signedOut.signIn, .ended(nil))
        // Never reopens by itself after a Stop.
        XCTAssertNil(signedOut.signInToOpen)
        XCTAssertNil(choice(.ready, .signedOut).signInToOpen)
    }

    func testSignInEndCopy() throws {
        var signedOut = choice(.signedOut, .notInstalled)
        signedOut.signInStarted()
        let running = try XCTUnwrap(signedOut.setup)
        XCTAssertEqual(
            running.signInNote,
            "Your browser opens to sign in. When it’s done, this closes and Watchtower checks again."
        )
        XCTAssertFalse(running.signInNoteWarns)
        signedOut.signInEnded(exitCode: 1)
        let failed = try XCTUnwrap(signedOut.setup)
        XCTAssertEqual(failed.signInNote, "Sign-in stopped before it finished (exit code 1).")
        XCTAssertTrue(failed.signInNoteWarns)
        signedOut.signInStopped()
        XCTAssertEqual(signedOut.setup?.signInNote, "Sign-in stopped before it finished.")
        signedOut.signInEnded(exitCode: 0)
        XCTAssertEqual(signedOut.signIn, .idle)
        XCTAssertEqual(Choice.signInAgain, "Sign in again")
        XCTAssertEqual(Choice.stopSignIn, "Stop")
    }

    func testPickingAnotherAgentResetsSignIn() {
        var signedOut = choice(.signedOut, .ready)
        signedOut.pick(.claude)
        signedOut.signInStarted()
        signedOut.pick(.codex)
        XCTAssertEqual(signedOut.signIn, .idle)
    }

    func testFailureMessages() {
        XCTAssertEqual(
            Choice.failureMessage(.claude, code: "timeout", error: "x"),
            "Couldn’t reach Claude Code’s service. Check the network or VPN, then check again."
        )
        XCTAssertEqual(
            Choice.failureMessage(.codex, code: "transport", error: nil),
            "Couldn’t reach Codex CLI’s service. Check the network or VPN, then check again."
        )
        // Go's message names Codex even for Claude: never shown.
        XCTAssertEqual(
            Choice.failureMessage(.claude, code: "invalid_output", error: "Codex answered but ignored Watchtower's instructions."),
            "Claude Code answered but ignored Watchtower’s instructions. Update it and check again."
        )
        XCTAssertEqual(
            Choice.failureMessage(.codex, code: "invalid_output", error: nil),
            "Codex CLI answered but ignored Watchtower’s instructions. Update it and check again."
        )
        XCTAssertEqual(
            Choice.failureMessage(.claude, code: nil, error: "Provider request failed (unknown)."),
            "Claude Code didn’t answer (Provider request failed (unknown).). Run it once in Terminal to see what it says, then check again."
        )
        XCTAssertEqual(
            Choice.failureMessage(.claude, code: "x", error: ""),
            "Claude Code didn’t answer. Run it once in Terminal to see what it says, then check again."
        )
    }

    func testOtherProviderFailureBringsTilesBack() {
        var failed = Choice(
            statuses: [.claude: .ready, .codex: .notInstalled],
            otherProvider: "Ollama",
            otherProviderFailure: "Couldn’t reach the server."
        )
        failed.applyDefault(configured: "ollama")
        XCTAssertTrue(failed.showsTiles)
        XCTAssertEqual(failed.selected, .claude)
        XCTAssertTrue(failed.canContinue)
        XCTAssertEqual(failed.providerToSave(configured: "ollama"), "claude")
        XCTAssertEqual(
            failed.caption,
            "Ollama, set in Settings → AI, didn’t answer: Couldn’t reach the server. "
                + "Pick Claude Code or Codex CLI instead, or fix it in Settings and check again."
        )
        XCTAssertEqual(Choice.Setup.docsLink, "Other ways to install")
    }

    func testPolicyForbidsBoth() {
        let both = choice(.forbidden, .forbidden)
        XCTAssertNil(both.selected)
        XCTAssertFalse(both.canContinue)
        XCTAssertFalse(both.noneInstalled)
        XCTAssertEqual(both.continueHint, "Continue unlocks once an AI agent is ready")
    }

    func testOutdatedCLIUpdatesThenSignsIn() throws {
        var old = choice(.signedOut, .notInstalled)
        old.outdated = [.claude]
        XCTAssertEqual(old.terminalCommand, "claude update")
        let setup = try XCTUnwrap(old.setup)
        XCTAssertEqual(setup.title, "Update Claude Code to sign in")
        XCTAssertEqual(setup.steps.map(\.command), ["claude update"])
        XCTAssertEqual(
            setup.signInNote,
            "This Claude Code is too old to sign in from here. It updates first; sign-in starts right after."
        )
        XCTAssertEqual(old.signInToOpen, .claude)
        old.signInStarted()
        old.signInEnded(exitCode: 1)
        XCTAssertEqual(old.retryLabel, "Update again")
        XCTAssertEqual(old.setup?.signInNote, "Sign-in stopped before it finished (exit code 1).")
        old.signInStarted()
        old.signInEnded(exitCode: 0)
        // Updated: the sign-in command opens by itself next.
        XCTAssertTrue(old.outdated.isEmpty)
        XCTAssertEqual(old.terminalCommand, "claude auth login")
        XCTAssertEqual(old.signInToOpen, .claude)
        XCTAssertEqual(old.retryLabel, "Sign in again")
        XCTAssertEqual(Choice.Agent.codex.updateCommand, "curl -fsSL https://chatgpt.com/codex/install.sh | sh")
    }
}
