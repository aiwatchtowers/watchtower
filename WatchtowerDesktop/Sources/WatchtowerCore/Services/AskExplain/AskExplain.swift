import Foundation

/// The words of the "Not clear?" chat on an ask item (specs 2026-11-24 and
/// 2026-11-27 "Texts").
package enum AskExplainCopy {
    package static let entry = "Not clear?"
    package static let entryHelp = "Ask the assistant to explain this question"
    package static let stepEntryHelp = "Ask the assistant about this step"
    package static let back = "Back to question"
    package static let backToCheck = "Back to check"
    package static let placeholder = "Ask about this question…"
    package static let stepPlaceholder = "Ask about this step…"
    package static let showMore = "Show more"
    package static let showLess = "Show less"
    /// The same string as `QuestionPartView.recommendedLabel`.
    package static let recommended = "Recommended"
    package static let errorPrefix = "Couldn't explain:"
    package static let retry = "Retry"
    package static let emptyHint = "The assistant explains; it never changes anything."

    /// "Question 2" / "Step 3".
    package static func itemLabel(_ item: AskExplainItem) -> String {
        "\(item.isStep ? "Step" : "Question") \(item.number)"
    }

    /// Every entry's accessibility label names its item: "Not clear? Question 2".
    package static func entryAccessibilityLabel(_ item: AskExplainItem) -> String {
        "\(entry) \(itemLabel(item))"
    }

    package static func entryHelp(for item: AskExplainItem) -> String {
        item.isStep ? stepEntryHelp : entryHelp
    }

    package static func back(for item: AskExplainItem) -> String {
        item.isStep ? backToCheck : back
    }

    package static func placeholder(for item: AskExplainItem) -> String {
        item.isStep ? stepPlaceholder : placeholder
    }
}

/// The chat's identity: one conversation per ask item, found or created by
/// this key (spec 2026-11-27 D3).
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

    /// `<workbench>:<ask>:<item>`, the item by its 1-based position: "3:41:q2".
    package static func contextID(workbenchID: Int64, askID: Int64, item: AskExplainItem) -> String {
        "\(workbenchID):\(askID):\(item.token)"
    }

    /// "Ask #41 · Question 2".
    package static func title(askID: Int64, item: AskExplainItem) -> String {
        "Ask #\(askID) · \(AskExplainCopy.itemLabel(item))"
    }
}

package enum AskExplainPresentation {
    /// "Not clear?" shows under a question or a check, and only where a CLI
    /// can run the assistant.
    package static func showsEntry(kind: OwnerAskKind, hasCLI: Bool) -> Bool {
        hasCLI && (kind == .question || kind == .check)
    }

    /// Whether an Esc leaves the chat for the question: always, unless a
    /// focused composer holds text. The composer's own Esc is the focused
    /// one; any other reaches the drawer's key catcher.
    package static func escapeLeavesChat(composerFocused: Bool, draft: String) -> Bool {
        !composerFocused || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
