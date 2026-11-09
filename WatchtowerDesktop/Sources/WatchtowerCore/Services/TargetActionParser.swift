import Foundation

/// Extracts ```watchtower-action``` fenced JSON blocks from AI output.
/// The AI emits one ProposedAction JSON object per block; everything else
/// is the human-visible answer. Blocks are removed from the visible text.
package enum TargetActionParser {
    private static let pattern = "```watchtower-action\\s*\\n(.*?)\\n?```"

    /// A reply that may have called tools: the visible text is the whole
    /// reply without its blocks, the actions and errors come from
    /// `finalText` only (the text after the last tool call started,
    /// `ChatPostTurnInput.finalText`). A block written before a tool call is
    /// a draft the model may revise after the result; only the final version
    /// is applied, so an execute-mode change never lands twice
    /// (TGT-BRIEF-03). `ignored` counts earlier blocks that are not in the
    /// final text, so the owner learns they were dropped.
    package static func parse(
        reply: String, finalText: String
    ) -> (text: String, actions: [ProposedAction], errors: [String], ignored: Int) {
        let whole = parse(reply)
        guard finalText != reply else { return (whole.text, whole.actions, whole.errors, 0) }
        let last = parse(finalText)
        let kept = Set(last.actions.map(\.changeKey))
        let ignored = whole.actions.filter { !kept.contains($0.changeKey) }.count
        return (whole.text, last.actions, last.errors, ignored)
    }

    package static func parse(_ raw: String) -> (text: String, actions: [ProposedAction], errors: [String]) {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators]
        ) else {
            return (raw, [], [])
        }

        let full = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: full.length))

        var actions: [ProposedAction] = []
        var seen: [String: Int] = [:]  // changeKey → index in actions
        var errors: [String] = []
        for match in matches where match.numberOfRanges >= 2 {
            let json = full.substring(with: match.range(at: 1))
            do {
                let action = try JSONDecoder().decode(ProposedAction.self, from: Data(json.utf8))
                try action.validate()
                // A reply keeps the text before and after its tool calls, so
                // a block repeated after a call is one action, applied once;
                // an execute copy wins over a proposed one (the owner's directive).
                if let index = seen[action.changeKey] {
                    if action.isExecute, !actions[index].isExecute { actions[index] = action }
                } else {
                    seen[action.changeKey] = actions.count
                    actions.append(action)
                }
            } catch let ProposedActionError.invalid(msg) {
                errors.append(msg)
            } catch let decodingError as DecodingError {
                errors.append(describe(decodingError))
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

    /// Turns an opaque `DecodingError` into a human-readable reason that names
    /// the offending field, so a malformed proposal is actionable instead of a
    /// generic "malformed action JSON".
    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case let .dataCorrupted(ctx):
            if let field = ctx.codingPath.last?.stringValue {
                // Includes the unknown-enum case, e.g. an unsupported "type".
                return "invalid value for \"\(field)\": \(ctx.debugDescription)"
            }
            return "invalid JSON: \(ctx.debugDescription)"
        case let .keyNotFound(key, _):
            return "missing field \"\(key.stringValue)\""
        case let .typeMismatch(_, ctx):
            return "wrong type for \"\(ctx.codingPath.last?.stringValue ?? "a field")\""
        case let .valueNotFound(_, ctx):
            return "missing value for \"\(ctx.codingPath.last?.stringValue ?? "a field")\""
        @unknown default:
            return "malformed action JSON"
        }
    }
}
