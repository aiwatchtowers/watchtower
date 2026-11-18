import Foundation

/// Whether a recipe's manifest grants AI (#1886, spec D4): the Swift twin of
/// Go's `automations.PermissionsUseAI`, pinned to it by the shared fixture
/// `internal/automations/testdata/uses_ai_cases.json`. A paused background
/// AI holds exactly these recipes; one that only runs `shell()`, `mcp()` or
/// registry reads keeps running.
package enum AutomationAIUse {
    /// The built-in primitives that call a model. Twin of Go's
    /// `automations.PrimitiveUsesAI`; an unknown primitive is not AI there
    /// either.
    private static let aiPrimitives: Set<String> = [
        "brief.compose", "plan.compose", "tracks.extract", "ideas.consolidate", "reaction.compose", "track.scan"
    ]

    package static func usesAI(permissions: [String]) -> Bool {
        permissions.contains { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let capability = parts[0].lowercased()
            let rest = parts.count > 1 ? parts[1] : ""
            let verb = rest.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map { $0.lowercased() } ?? ""
            return entryUsesAI(capability: capability, verb: verb)
        }
    }

    private static func entryUsesAI(capability: String, verb: String) -> Bool {
        switch capability {
        case "llm": true
        case "agent": verb == "run"
        case "session": verb == "start"
        case "track": verb == "scan"
        case "builtin": aiPrimitives.contains(verb)
        default: false
        }
    }
}
