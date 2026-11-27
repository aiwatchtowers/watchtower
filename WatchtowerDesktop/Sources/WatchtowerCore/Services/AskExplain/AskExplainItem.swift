import Foundation

/// One item of an ask the owner can open a "Not clear?" chat from (spec
/// 2026-11-27 D3): a question or a check step, by its 1-based position in
/// the payload — never the agent's free-text id.
package enum AskExplainItem: Hashable, Sendable {
    case question(Int)
    case step(Int)

    package var number: Int {
        switch self {
        case .question(let number), .step(let number): number
        }
    }

    /// The item's part of the chat's context id: "q2", "s3".
    package var token: String {
        "\(isStep ? "s" : "q")\(number)"
    }

    package var isStep: Bool {
        if case .step = self { return true }
        return false
    }

    /// The ask's items in order: its questions, then its steps; none for a
    /// kind that shows no entry.
    package static func items(of ask: OwnerAsk) -> [Self] {
        guard AskExplainPresentation.showsEntry(kind: ask.kind, hasCLI: true) else { return [] }
        return ask.payload.questions.indices.map { .question($0 + 1) }
            + ask.payload.checklist.indices.map { .step($0 + 1) }
    }

    /// The position of the question with this id (ids are unique within a card).
    package static func forQuestion(id: String, in ask: OwnerAsk) -> Self? {
        ask.payload.questions.firstIndex { $0.id == id }.map { .question($0 + 1) }
    }

    /// Whether this is the ask's only item (spec D4: the legacy whole-ask
    /// chat becomes that item's chat).
    package static func isOnlyItem(_ item: Self, of ask: OwnerAsk) -> Bool {
        items(of: ask) == [item]
    }
}

/// What one explain chat is about: an item of an ask.
package struct AskExplainSubject: Hashable, Sendable {
    package let askID: Int64
    package let item: AskExplainItem

    package init(askID: Int64, item: AskExplainItem) {
        self.askID = askID
        self.item = item
    }
}

/// The compact card of the item pinned over the chat (spec D5): a question
/// with its option labels (no descriptions), or a step with its hint.
package enum AskExplainCard: Equatable {
    package struct Option: Equatable {
        package let label: String
        package let recommended: Bool

        package init(label: String, recommended: Bool) {
            self.label = label
            self.recommended = recommended
        }
    }

    case question(text: String, options: [Option])
    case step(number: Int, text: String, hint: String)

    /// The item's card, or nil when the ask has no such item.
    package static func make(ask: OwnerAsk, item: AskExplainItem) -> Self? {
        let index = item.number - 1
        switch item {
        case .question:
            guard ask.payload.questions.indices.contains(index) else { return nil }
            let question = ask.payload.questions[index]
            return .question(
                text: question.question,
                options: question.options.map { Option(label: $0.label, recommended: $0.recommended) })
        case .step(let number):
            guard ask.payload.checklist.indices.contains(index) else { return nil }
            let step = ask.payload.checklist[index]
            return .step(number: number, text: step.text, hint: step.hint)
        }
    }
}

/// How tall the item card is (spec D6): whole up to `clampHeight`, clamped
/// past it until expanded; expanded, it scrolls inside itself past
/// `expandedMaxHeight`.
package enum AskExplainCardLayout {
    package static let clampHeight: CGFloat = 76
    package static let expandedMaxHeight: CGFloat = 180

    package enum Mode: Equatable {
        case whole, clamped, expanded, expandedScrolling
    }

    package static func mode(contentHeight: CGFloat, expanded: Bool) -> Mode {
        if contentHeight <= clampHeight { return .whole }
        if !expanded { return .clamped }
        return contentHeight <= expandedMaxHeight ? .expanded : .expandedScrolling
    }

    /// Show more / Show less: only for a card taller than the clamp.
    package static func showsToggle(_ mode: Mode) -> Bool {
        mode != .whole
    }
}
