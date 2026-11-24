import WatchtowerCore

/// Reading the owner's keystrokes (`PromptKeys`, in the core).
extension TerminalCenter {
    /// `PromptKeys.isSubmit`.
    static func isSubmit(_ bytes: [UInt8], backslashBefore: Bool, profile: AgentInputProfile = .claude) -> Bool {
        PromptKeys.isSubmit(bytes, backslashBefore: backslashBefore, profile: profile)
    }

    /// `PromptKeys.isShiftTab`.
    static func isShiftTab(_ bytes: [UInt8]) -> Bool { PromptKeys.isShiftTab(bytes) }
}
