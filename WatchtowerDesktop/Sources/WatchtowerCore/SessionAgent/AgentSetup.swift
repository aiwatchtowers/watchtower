import Foundation

/// How an agent's CLI gets onto the Mac and signed in, for onboarding's AI
/// agent section (#1521): a plain value each session adapter fills, so the
/// onboarding code never names a transport (LLMTRANSPORT-01, ask #1211).
package struct AgentSetup: Equatable, Sendable {
    /// The tile title ("Claude Code", "Codex CLI"); `AgentKind.displayName`
    /// stays the Workbench's name.
    package var productName: String
    /// The vendor's install script, run in the owner's Terminal.
    package var installCommand: String
    /// The sign-in after the executable (`<exe> auth login`).
    package var signInArguments: [String]
    /// The help probe after the executable; its text says whether the CLI
    /// has the sign-in at all (never the exit code, ask #1163).
    package var loginHelpArguments: [String]
    /// What in that help text marks the sign-in command.
    package var loginHelp: LoginHelpMarker
    /// The vendor's install page (Homebrew, npm and the rest).
    package var installDocsURL: String
    /// The config key a manually picked executable is saved under.
    package var pathKey: String
    /// Folders, relative to the home folder, that the vendor's installer
    /// owns: a resolved executable under one is a `.native` install.
    package var nativeRoots: [String]
    /// The update per install kind; a kind without one gets no command.
    package var updates: [OnboardingAgentChoice.InstallKind: AgentUpdate]

    /// Whether the CLI has the sign-in command, read from the help text.
    package func loginSupported(help: String) -> Bool {
        switch loginHelp {
        case .indentedRow(let command):
            // A command list row: "  login [options]  Sign in…".
            help.split(separator: "\n").contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return line.first == " " && (trimmed == command || trimmed.hasPrefix(command + " "))
            }
        case .text(let marker):
            help.contains(marker)
        }
    }
}

/// How the login help text shows that the sign-in command exists.
package enum LoginHelpMarker: Equatable, Sendable {
    /// An indented row of the command list that starts with this word.
    case indentedRow(String)
    /// This text anywhere in the help.
    case text(String)
}

/// One install kind's update.
package enum AgentUpdate: Equatable, Sendable {
    /// `<exe> <arguments>`, through the located executable.
    case runExecutable([String])
    /// A command run as written.
    case literal(String)
}
