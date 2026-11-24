extension TerminalCenter {
    /// What the hint over a session holding an ask's answer says.
    enum AnswerHint: Equatable {
        /// Pasted, not submitted (a permission prompt appeared during the
        /// pause): press Return.
        case typed
        /// On the clipboard: paste it, then press Return.
        case copied
        /// Held while the agent waits on a permission prompt; it goes once
        /// the prompt is answered.
        case held
        /// Held so long (`OwnerAsksViewModel.stillHeldAfter`) with no change
        /// that the pane says it still waits and that Dismiss leaves it for
        /// the session's brief.
        case stillHeld
        /// Held while another answer is going to the same session; it goes
        /// right after that one.
        case queued

        /// Waiting for its delivery: the owner's input keeps it, and its
        /// Dismiss cancels the delivery.
        var isHeld: Bool {
            switch self {
            case .held, .stillHeld, .queued: true
            case .typed, .copied: false
            }
        }
    }
}
