import Foundation

/// A dry run's journal as one plain line per step ("Would propose …",
/// "Would post to Inbox: …", "Denied — needs …").
package enum DryRunPresentation {
    /// How much of a write tool's arguments a line shows.
    package static let argsLimit = 200

    nonisolated(unsafe) private static let tokenFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    package static func lines(steps: [AutomationRunStep]) -> [String] {
        steps.map(line)
    }

    private static func line(_ step: AutomationRunStep) -> String {
        if step.status == "denied" {
            return step.permission.isEmpty ? "Denied — \(step.name)" : "Denied — needs \(step.permission)"
        }
        switch (step.kind, step.status) {
        case ("tool", "dry_run"):
            return "Would propose \(step.name) \(clip(step.argsJSON))"
        case ("tool", "ok"):
            return "Read \(step.name)"
        case ("output", _):
            return outputLine(step)
        case ("state", "dry_run"):
            return "Would save state"
        case ("mcp", "dry_run"):
            // A draft stops at its first mcp() call (ask #326); a saved
            // recipe's dry run calls the Quick Connection for real.
            return "Stopped before calling \(step.name): Quick Connections are not called in a draft"
        case ("llm", "ok"):
            let tokens = tokenFormatter.string(from: NSNumber(value: step.inputTokens + step.outputTokens)) ?? "0"
            return "Asked the assistant · \(tokens) tokens"
        default:
            let head = step.name.isEmpty ? "\(step.kind) · \(step.status)" : "\(step.kind) \(step.name) · \(step.status)"
            return step.error.isEmpty ? head : "\(head): \(step.error)"
        }
    }

    private static func outputLine(_ step: AutomationRunStep) -> String {
        let title = outputTitle(step.argsJSON)
        switch step.name {
        case "inbox": return "Would post to Inbox: \(title)"
        case "report": return "Would add a report: \(title)"
        case "briefing": return "Would add to the briefing: \(title)"
        default: return "Would write \(step.name): \(title)"
        }
    }

    private static func outputTitle(_ argsJSON: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any],
              let title = object["title"] as? String else { return "" }
        return title
    }

    private static func clip(_ text: String) -> String {
        text.count > argsLimit ? String(text.prefix(argsLimit)) + "…" : text
    }
}
