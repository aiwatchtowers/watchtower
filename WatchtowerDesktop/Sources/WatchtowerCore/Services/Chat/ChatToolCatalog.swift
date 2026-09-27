import Foundation

/// The ONE tool name → human step label/icon mapping for chat steps (spec
/// §3.2, the `ReactionToolCatalog` precedent). Write tools reuse
/// `ReactionToolCatalog` titles so a tool never goes by two names.
package enum ChatToolCatalog {
    private struct Entry {
        let template: String?
        let fallback: String
        let keys: [String]
    }

    private static let maxSubject = 80

    private static let reads: [String: Entry] = [
        "search_knowledge": Entry(template: "Searched knowledge: {}", fallback: "Searched knowledge", keys: ["queries"]),
        "get_knowledge_document": Entry(template: nil, fallback: "Opened a document", keys: []),
        "list_messages": Entry(template: "Searched Slack: {}", fallback: "Searched Slack messages", keys: ["query", "person", "channel"]),
        "list_digests": Entry(template: nil, fallback: "Listed digests", keys: []),
        "get_digest": Entry(template: nil, fallback: "Opened a digest", keys: []),
        "get_today_briefing": Entry(template: nil, fallback: "Read today's briefing", keys: []),
        "list_jira_issues": Entry(template: "Listed Jira issues: {}", fallback: "Listed Jira issues", keys: ["project", "assignee", "status"]),
        "list_jira_projects": Entry(template: nil, fallback: "Listed Jira projects", keys: []),
        "get_jira_issue": Entry(template: "Opened {}", fallback: "Opened a Jira issue", keys: ["key"]),
        "get_task_context": Entry(template: "Gathered context for {}", fallback: "Gathered task context", keys: ["key", "issue_key"]),
        "list_people": Entry(template: nil, fallback: "Listed people", keys: []),
        "get_person": Entry(template: "Looked up {}", fallback: "Looked up a person", keys: ["name", "query", "id"]),
        "list_tracks": Entry(template: nil, fallback: "Listed tracks", keys: []),
        "get_track": Entry(template: nil, fallback: "Opened a track", keys: []),
        "list_targets": Entry(template: nil, fallback: "Listed targets", keys: []),
        "get_target": Entry(template: nil, fallback: "Opened a target", keys: []),
        "list_upcoming_events": Entry(template: nil, fallback: "Checked the calendar", keys: []),
        "list_transcripts": Entry(template: "Searched meetings: {}", fallback: "Listed meeting transcripts", keys: ["query"]),
        "get_transcript": Entry(template: nil, fallback: "Opened a meeting transcript", keys: []),
        "memory_recall": Entry(template: "Recalled from memory: {}", fallback: "Recalled from memory", keys: ["query"]),
        "memory_open": Entry(template: "Opened memory {}", fallback: "Opened a memory page", keys: ["ref"]),
        "memory_map": Entry(template: nil, fallback: "Read the memory map", keys: []),
        "find_experts": Entry(template: "Found experts: {}", fallback: "Found experts", keys: ["topic", "issue_key"]),
        "list_ideas": Entry(template: nil, fallback: "Listed ideas", keys: []),
        "get_idea": Entry(template: nil, fallback: "Opened an idea", keys: []),
        "load_skill": Entry(template: "Loaded skill {}", fallback: "Loaded a skill", keys: ["name"]),
        "get_action": Entry(template: nil, fallback: "Checked a proposal", keys: [])
    ]

    /// `args` is the step's raw `args` JSON; unparseable args just lose the subject.
    package static func label(name: String, args: String) -> String {
        if let label = actionLabel(name: name, args: args) { return label }
        if let (server, tool) = external(name) {
            return "Used \(server): \(tool.replacingOccurrences(of: "_", with: " "))"
        }
        if let write = ReactionToolCatalog.info(for: name) {
            return "Proposed: \(write.title)"
        }
        guard let entry = reads[name] else {
            return "Used \(name.replacingOccurrences(of: "_", with: " "))"
        }
        guard let template = entry.template, let subject = subject(args: args, keys: entry.keys) else {
            return entry.fallback
        }
        return template.replacingOccurrences(of: "{}", with: subject)
    }

    package static func icon(name: String) -> String {
        if let icon = actionIcon(name: name) { return icon }
        if external(name) != nil { return "puzzlepiece.extension" }
        if ReactionToolCatalog.info(for: name) != nil { return "hand.raised" }
        let rules: [(String, String)] = [
            ("knowledge", "magnifyingglass"), ("messages", "bubble.left.and.bubble.right"), ("jira", "ticket"),
            ("task_context", "ticket"), ("transcript", "waveform"), ("person", "person"), ("people", "person.2"),
            ("experts", "person.2"), ("memory", "brain"), ("digest", "doc.text"), ("briefing", "sun.max"),
            ("target", "target"), ("track", "arrow.triangle.branch"), ("events", "calendar"),
            ("skill", "book"), ("idea", "lightbulb"), ("action", "checklist")
        ]
        return rules.first { name.contains($0.0) }?.1 ?? "wrench.and.screwdriver"
    }

    private static func external(_ name: String) -> (String, String)? {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    private static func subject(args: String, keys: [String]) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any] else { return nil }
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty { return capped(value) }
            if let values = json[key] as? [String], !values.isEmpty { return capped(values.joined(separator: ", ")) }
        }
        return nil
    }

    private static func capped(_ value: String) -> String {
        value.count <= maxSubject ? value : String(value.prefix(maxSubject - 1)) + "…"
    }
}
