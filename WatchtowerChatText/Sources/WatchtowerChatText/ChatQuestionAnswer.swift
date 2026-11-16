import Foundation

/// The owner's answer to a card, as their next message — and back: an
/// answered card reads its selections from that message (nothing else is
/// stored, so it survives restart and replay).
public enum ChatQuestionAnswer {
    public static let header = "Answers:"
    private static let arrow = " → "
    private static let otherPrefix = "Other: "

    public struct Entry: Equatable, Sendable {
        public var labels: [String]
        public var other: String?

        public init(labels: [String] = [], other: String? = nil) {
            self.labels = labels
            self.other = other
        }

        public var isEmpty: Bool {
            labels.isEmpty && (other?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    /// "Answers:" then one line per question: `- <question> → <labels>` with
    /// `Other: <text>` last (its line breaks as spaces).
    public static func format(_ card: ChatQuestionCard, answers: [String: Entry]) -> String {
        let lines = card.questions.map { question -> String in
            let entry = answers[question.id] ?? Entry()
            var parts = entry.labels
            if let other = entry.other?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty {
                // A multi-line answer stays on its question's line: the
                // read-back finds each answer by its line.
                parts.append(otherPrefix + other.split(whereSeparator: \.isNewline).joined(separator: " "))
            }
            return "- \(question.question)\(arrow)\(parts.joined(separator: ", "))"
        }
        return ([header] + lines).joined(separator: "\n")
    }

    /// The selections an owner message carries for `card`; empty when the
    /// message is not an answer in this format.
    public static func selections(in owner: String, for card: ChatQuestionCard) -> [String: Entry] {
        let lines = owner.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == header else { return [:] }
        var result: [String: Entry] = [:]
        for question in card.questions {
            let prefix = "- \(question.question)\(arrow)"
            guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { continue }
            let value = String(line.dropFirst(prefix.count))
            var choices = value
            var other: String?
            if let range = value.range(of: otherPrefix) {
                other = String(value[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                choices = String(value[..<range.lowerBound])
            }
            // Matched against the known labels, not split: a label may hold ", ".
            let padded = ", " + choices.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",")) + ", "
            let labels = question.options.map(\.label).filter { padded.contains(", \($0), ") }
            result[question.id] = Entry(labels: labels, other: other)
        }
        return result
    }
}
