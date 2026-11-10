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

    // MARK: Outdated CLI (asks #1161, #1163)

    /// `claude auth --help` of Claude Code 2.1.322.
    private let claudeAuthHelp = """
    Usage: claude auth [options] [command]

    Manage authentication

    Options:
      -h, --help        Display help for command

    Commands:
      help [command]    display help for command
      login [options]   Sign in to your Anthropic account
      logout            Log out from your Anthropic account
      status [options]  Show authentication status
    """

    /// An old Claude Code that doesn't know `auth`: its general help, exit 0.
    private let claudeGeneralHelp = """
    Usage: claude [options] [command] [prompt]

    Options:
      -p, --print       Print response and exit
      --login-hint <x>  Not a command

    Commands:
      config            Manage configuration
      mcp               Configure and manage MCP servers
      update            Check for updates and install if available
    """

    func testLoginSupportReadsTheHelpText() {
        XCTAssertTrue(Choice.Agent.claude.loginSupported(help: claudeAuthHelp))
        XCTAssertFalse(Choice.Agent.claude.loginSupported(help: claudeGeneralHelp))
        XCTAssertFalse(Choice.Agent.claude.loginSupported(help: ""))
        XCTAssertTrue(Choice.Agent.codex.loginSupported(help: "Manage login\n\nUsage: codex login [OPTIONS] [COMMAND]\n"))
        XCTAssertFalse(Choice.Agent.codex.loginSupported(help: "Usage: codex [OPTIONS] [PROMPT]\n"))
    }

    func testInstallKindFromTheResolvedPath() {
        let home = "/Users/owner"
        typealias Kind = Choice.InstallKind
        XCTAssertEqual(Kind.of(.claude, resolvedPath: "/Users/owner/.local/share/claude/versions/2.1.322", home: home), .native)
        XCTAssertEqual(Kind.of(.claude, resolvedPath: "/opt/homebrew/Caskroom/claude-code/2.1.3/claude", home: home), .homebrew)
        XCTAssertEqual(
            Kind.of(.claude, resolvedPath: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js", home: home), .npm
        )
        XCTAssertEqual(Kind.of(.codex, resolvedPath: "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", home: home), .npm)
        XCTAssertEqual(Kind.of(.codex, resolvedPath: "/opt/homebrew/Caskroom/codex/0.166.0/codex", home: home), .homebrew)
        XCTAssertEqual(Kind.of(.codex, resolvedPath: "/Users/owner/.local/bin/codex", home: home), .native)
        XCTAssertEqual(Kind.of(.claude, resolvedPath: "/usr/local/bin/claude", home: home), .unknown)
        // The old local install is not a global npm one: `claude update`, never `npm install -g`.
        XCTAssertEqual(
            Kind.of(.claude, resolvedPath: "/Users/owner/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js", home: home),
            .native
        )
    }

    func testUpdateCommandPerInstallKind() {
        XCTAssertEqual(Choice.Agent.claude.updateCommand(.native), "claude update")
        XCTAssertEqual(Choice.Agent.claude.updateCommand(.homebrew), "brew upgrade --cask claude-code")
        XCTAssertEqual(Choice.Agent.claude.updateCommand(.npm), "npm install -g @anthropic-ai/claude-code@latest")
        XCTAssertEqual(Choice.Agent.codex.updateCommand(.native), "curl -fsSL https://chatgpt.com/codex/install.sh | sh")
        XCTAssertEqual(Choice.Agent.codex.updateCommand(.homebrew), "brew upgrade --cask codex")
        XCTAssertEqual(Choice.Agent.codex.updateCommand(.npm), "npm install -g @openai/codex@latest")
        XCTAssertNil(Choice.Agent.claude.updateCommand(.unknown))
    }

    private func outdatedClaude(_ kind: Choice.InstallKind) -> Choice {
        var old = choice(.signedOut, .notInstalled)
        old.installs = [.claude: .init(path: "/opt/homebrew/Caskroom/claude-code/1.0.88/claude", kind: kind)]
        old.applyLoginProbe(outdated: [.claude])
        return old
    }

    func testOutdatedCLIUpdatesThenSignsIn() throws {
        var old = outdatedClaude(.homebrew)
        XCTAssertEqual(old.terminalCommand, "brew upgrade --cask claude-code")
        let setup = try XCTUnwrap(old.setup)
        XCTAssertEqual(setup.title, "Update Claude Code to sign in")
        XCTAssertEqual(setup.steps.map(\.command), ["brew upgrade --cask claude-code"])
        XCTAssertTrue(setup.runsSignIn)
        XCTAssertEqual(
            setup.signInNote,
            "This Claude Code is too old to sign in from here. It updates first; sign-in starts right after."
        )
        XCTAssertEqual(old.signInToOpen, .claude)
        old.signInStarted()
        old.signInEnded(exitCode: 1)
        XCTAssertEqual(old.retryLabel, "Update again")
        old.signInStarted()
        old.signInEnded(exitCode: 0)
        // The caller probes again: the login is there now, and it opens by itself.
        old.applyLoginProbe(outdated: [])
        XCTAssertEqual(old.terminalCommand, "claude auth login")
        XCTAssertEqual(old.signInToOpen, .claude)
        XCTAssertEqual(old.retryLabel, "Sign in again")
    }

    func testUpdateThatChangedNothingNeverLoops() throws {
        var old = outdatedClaude(.homebrew)
        old.signInStarted()
        old.signInEnded(exitCode: 0)
        // Another copy is first on PATH: the probe still finds no login.
        old.applyLoginProbe(outdated: [.claude])
        XCTAssertTrue(old.updateStuck(.claude))
        XCTAssertNil(old.terminalCommand)
        XCTAssertNil(old.signInToOpen)
        let setup = try XCTUnwrap(old.setup)
        XCTAssertFalse(setup.runsSignIn)
        XCTAssertTrue(setup.steps.isEmpty)
        XCTAssertTrue(setup.showsManualPath)
        XCTAssertEqual(setup.docsURL, "https://code.claude.com/docs/en/setup")
        XCTAssertTrue(setup.signInNoteWarns)
        XCTAssertEqual(
            setup.signInNote,
            "Updating didn’t change the Claude Code Watchtower uses (/opt/homebrew/Caskroom/claude-code/1.0.88/claude). "
                + "It may be installed twice. Update that copy the way you installed it, or choose another executable."
        )
    }

    func testUnknownInstallOffersNoUpdateCommand() throws {
        let old = outdatedClaude(.unknown)
        XCTAssertNil(old.terminalCommand)
        XCTAssertNil(old.signInToOpen)
        let setup = try XCTUnwrap(old.setup)
        XCTAssertFalse(setup.runsSignIn)
        XCTAssertEqual(
            setup.signInNote,
            "Watchtower can’t tell how this Claude Code was installed (/opt/homebrew/Caskroom/claude-code/1.0.88/claude). "
                + "Update it the way you installed it, then check again."
        )
    }
}
