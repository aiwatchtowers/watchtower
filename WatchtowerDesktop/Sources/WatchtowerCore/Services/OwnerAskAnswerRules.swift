import Foundation

/// Why Go would refuse a stored answer: the Swift twin of `asks.ParseAnswer`
/// then `asks.ValidateAnswer` (internal/asks/answer.go), checked in the same
/// order. An answer with a problem must never be written: `get_ask` would
/// fail on it every time and the ask would stay `answered` for good.
/// `message` is Go's error text; `internal/asks/testdata/answers` pins both
/// sides. Change them together.
package enum OwnerAskAnswerProblem: Equatable, Sendable {
    // ParseAnswer (a verdict and the item states are typed in Swift).
    case brokenWithoutNote(index: Int)
    case noteTooLong
    // ValidateAnswer.
    case verdictRequired
    case verdictNotAllowed
    case commentsNotAllowed
    case commentBodyRequired(index: Int)
    case unknownQuestion(index: Int, id: String)
    case questionAnsweredTwice(index: Int, id: String)
    case emptyQuestionAnswer(index: Int)
    case tooManyLabels(index: Int, id: String)
    case unknownLabel(index: Int, id: String, label: String)
    case questionUnanswered(id: String)
    case unknownCheckItem(index: Int, id: String)
    case checkItemMarkedTwice(index: Int, id: String)
    case checkItemUnmarked(id: String)

    /// Go's `asks.Answer.note` bound, in runes.
    package static let maxNoteRunes = 4000

    package var message: String {
        switch self {
        case let .brokenWithoutNote(i): "checklist[\(i)].note: required when broken"
        case .noteTooLong: "note: at most \(Self.maxNoteRunes) characters"
        case .verdictRequired: "verdict: required for a review"
        case .verdictNotAllowed: "verdict: only a review has a verdict"
        case .commentsNotAllowed: "comments: only a review has comments"
        case let .commentBodyRequired(i): "comments[\(i)].body: required"
        case let .unknownQuestion(i, id): "answers[\(i)].id: no question \(Self.quoted(id))"
        case let .questionAnsweredTwice(i, id): "answers[\(i)].id: question \(Self.quoted(id)) answered twice"
        case let .emptyQuestionAnswer(i): "answers[\(i)]: no label and no other answer"
        case let .tooManyLabels(i, id): "answers[\(i)].labels: question \(Self.quoted(id)) takes one label"
        case let .unknownLabel(i, id, label):
            "answers[\(i)].labels: question \(Self.quoted(id)) has no option \(Self.quoted(label))"
        case let .questionUnanswered(id): "answers: question \(Self.quoted(id)) has no answer"
        case let .unknownCheckItem(i, id): "checklist[\(i)].id: no check item \(Self.quoted(id))"
        case let .checkItemMarkedTwice(i, id): "checklist[\(i)].id: item \(Self.quoted(id)) marked twice"
        case let .checkItemUnmarked(id): "checklist: item \(Self.quoted(id)) has no state"
        }
    }

    /// Go's `%q` for the plain ids and labels asks carry.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension OwnerAskAnswer {
    /// The first rule Go's reader would refuse this answer to an ask of
    /// `kind` with `payload` for; nil when `get_ask` will read it.
    package func problem(kind: OwnerAskKind, payload: OwnerAskPayload) -> OwnerAskAnswerProblem? {
        if let index = checklist.firstIndex(where: { $0.state == .broken && Self.isBlank($0.note) }) {
            return .brokenWithoutNote(index: index)
        }
        if note.unicodeScalars.count > OwnerAskAnswerProblem.maxNoteRunes { return .noteTooLong }
        if kind == .review && verdict == nil { return .verdictRequired }
        if kind != .review && verdict != nil { return .verdictNotAllowed }
        if kind != .review && !comments.isEmpty { return .commentsNotAllowed }
        if let index = comments.firstIndex(where: { Self.isBlank($0.body) }) { return .commentBodyRequired(index: index) }
        return questionProblem(payload.questions) ?? checkProblem(payload.checklist)
    }

    private func questionProblem(_ questions: [ChatQuestion]) -> OwnerAskAnswerProblem? {
        let byID = Dictionary(questions.map { ($0.id, $0) }) { first, _ in first }
        var seen = Set<String>()
        for (index, answer) in answers.enumerated() {
            guard let question = byID[answer.id] else { return .unknownQuestion(index: index, id: answer.id) }
            guard seen.insert(answer.id).inserted else { return .questionAnsweredTwice(index: index, id: answer.id) }
            if answer.labels.isEmpty && Self.isBlank(answer.other) { return .emptyQuestionAnswer(index: index) }
            if !question.multi && answer.labels.count > 1 { return .tooManyLabels(index: index, id: answer.id) }
            if let label = answer.labels.first(where: { label in !question.options.contains { $0.label == label } }) {
                return .unknownLabel(index: index, id: answer.id, label: label)
            }
        }
        return questions.first { !seen.contains($0.id) }.map { .questionUnanswered(id: $0.id) }
    }

    private func checkProblem(_ items: [OwnerAskCheckItem]) -> OwnerAskAnswerProblem? {
        let known = Set(items.map(\.id))
        var seen = Set<String>()
        for (index, mark) in checklist.enumerated() {
            guard known.contains(mark.id) else { return .unknownCheckItem(index: index, id: mark.id) }
            guard seen.insert(mark.id).inserted else { return .checkItemMarkedTwice(index: index, id: mark.id) }
        }
        return items.first { !seen.contains($0.id) }.map { .checkItemUnmarked(id: $0.id) }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
