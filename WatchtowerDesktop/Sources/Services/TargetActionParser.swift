import Foundation

/// Extracts ```watchtower-action``` fenced JSON blocks from AI output.
/// The AI emits one ProposedAction JSON object per block; everything else
/// is the human-visible answer. Blocks are removed from the visible text.
enum TargetActionParser {
    private static let pattern = "```watchtower-action\\s*\\n(.*?)\\n?```"

    static func parse(_ raw: String) -> (text: String, actions: [ProposedAction], errors: [String]) {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators]
        ) else {
            return (raw, [], [])
        }

        let full = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: full.length))

        var actions: [ProposedAction] = []
        var errors: [String] = []
        for match in matches where match.numberOfRanges >= 2 {
            let json = full.substring(with: match.range(at: 1))
            do {
                let action = try JSONDecoder().decode(ProposedAction.self, from: Data(json.utf8))
                try action.validate()
                actions.append(action)
            } catch let ProposedActionError.invalid(msg) {
                errors.append(msg)
            } catch {
                errors.append("malformed action JSON")
            }
        }

        let stripped = regex.stringByReplacingMatches(
            in: raw, range: NSRange(location: 0, length: full.length), withTemplate: ""
        )
        let text = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, actions, errors)
    }
}
