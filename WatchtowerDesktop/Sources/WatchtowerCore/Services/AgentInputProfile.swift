import Foundation

/// How Watchtower types an ask's answer, a comment or a hand-off into a
/// coding agent's terminal prompt (spec 2026-10-12 §8, board #399), per
/// agent. The text itself always goes as one bracketed paste
/// (`WorkbenchCommentPrompt.terminalPayload`); the profile holds what
/// follows it and what the owner-draft tracker must know about the agent's
/// composer.
package struct AgentInputProfile: Sendable, Equatable {
    /// The key Watchtower presses after the pause, as a write of its own:
    /// submits the prompt.
    package let submit: [UInt8]
    /// The agent's own composer key that inserts a line break instead of
    /// submitting, which the owner-draft tracker reads as a draft; nil when
    /// the agent has none beyond the ones the tracker knows for every agent
    /// (Option+Return, Shift+Return under an extended keyboard protocol,
    /// `\` then Return, Ctrl+J).
    package let newline: [UInt8]?
    /// A hand-off's pause between its paste and its Return, so the TUI has
    /// taken the paste in before the key arrives.
    package let pasteSettle: Duration
    /// The same pause for an ask's answer (board #379): longer, since an
    /// answer is not urgent and the state read after it then also sees a
    /// permission prompt whose async hook landed a little late.
    package let submitSettle: Duration

    /// Claude Code: CR submits; the pauses of boards #379/#380.
    package static let claude = Self(
        submit: [0x0D], newline: nil, pasteSettle: .milliseconds(150), submitSettle: .milliseconds(500)
    )

    /// Codex: CR submits a bracketed paste, multi-line too, as one prompt;
    /// Ctrl+J (LF) inserts a line break (Task 0 capture, composer keys). The
    /// pauses are Claude Code's.
    package static let codex = Self(
        submit: [0x0D], newline: [0x0A], pasteSettle: .milliseconds(150), submitSettle: .milliseconds(500)
    )

    package static func `for`(_ kind: AgentKind) -> Self {
        switch kind {
        case .claude: claude
        case .codex: codex
        }
    }
}
