import Foundation

/// The words of the "Not clear?" chat on an ask (spec 2026-11-24 "Texts").
package enum AskExplainCopy {
    package static let entry = "Not clear?"
    package static let entryHelp = "Ask the assistant to explain this question"
    package static let back = "Back to question"
    package static let placeholder = "Ask about this question…"
    package static let explaining = "Explaining…"
    package static let queued = "Waiting — other chats are answering."
    package static let errorPrefix = "Couldn't explain:"
    package static let retry = "Retry"
    package static let emptyHint = "The assistant explains; it never changes anything."
}

/// The chat's identity: one conversation per ask, found or created by this key.
package enum AskExplainKey {
    package static let contextType = "owner_ask_explain"
    /// The `ai query --purpose` tag; the usage ledger names it "Ask explanations".
    package static let purpose = "ask.explain"

    package static func contextID(workbenchID: Int64, askID: Int64) -> String {
        "\(workbenchID):\(askID)"
    }

    package static func title(askID: Int64) -> String {
        "Ask #\(askID)"
    }
}

package enum AskExplainPresentation {
    /// "Not clear?" shows under a question or a check, and only where a CLI
    /// can run the assistant.
    package static func showsEntry(kind: OwnerAskKind, hasCLI: Bool) -> Bool {
        hasCLI && (kind == .question || kind == .check)
    }
}
