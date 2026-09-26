import Foundation

/// The tools a reaction may dispatch, in seed order (migration 00063's
/// `INSERT ... VALUES` plus the four Wave 2 tools) — the picker's options when
/// the owner adds a new emoji mapping. Not read from the DB: the registry
/// itself is Go-only static code, so this list is kept in sync by hand
/// alongside `internal/tools/*.go`. Deliberately NOT the whole registry:
/// `connect_jira_board` is `Surfaces: ["main"]` (main AI Chat only), so the
/// reaction surface could never dispatch it and it is left out on purpose.
package enum ReactionDictionaryTools {
    package static let all = [
        "create_target",
        "create_jira_issue",
        "create_track",
        "create_idea",
        "remind_me",
        "brief_context"
    ]
}

/// What an agent-actions tool means to the owner: a human title, one line on
/// what it does, and where its result lands.
package struct ReactionToolInfo: Equatable, Sendable {
    package let title: String
    package let summary: String
    package let destination: String
    /// An `External` tool (Go `internal/tools`) — `SetTrust` refuses
    /// `execute` for it, so it lands behind Approve whatever `tool_trust` says.
    package let alwaysAsks: Bool
}

/// The ONE tool id → human name mapping: the Inbox cheat sheet, the agent-
/// action card title and the Settings reaction-dictionary editor all read it,
/// so a tool never goes by two names. An unknown tool id is shown as itself.
package enum ReactionToolCatalog {
    private static let entries: [String: ReactionToolInfo] = [
        "create_target": ReactionToolInfo(
            title: "Create a target",
            summary: "Turns the message into a target",
            destination: "Targets",
            alwaysAsks: false
        ),
        "create_jira_issue": ReactionToolInfo(
            title: "Create a Jira issue",
            summary: "Drafts a Jira issue from the message",
            destination: "Jira",
            alwaysAsks: true
        ),
        "create_track": ReactionToolInfo(
            title: "Track this",
            summary: "Starts a track following the topic",
            destination: "Tracks",
            alwaysAsks: false
        ),
        "create_idea": ReactionToolInfo(
            title: "Save as idea",
            summary: "Captures the message as an idea",
            destination: "Ideas",
            alwaysAsks: false
        ),
        "remind_me": ReactionToolInfo(
            title: "Remind me",
            summary: "Resurfaces the message later (tomorrow 09:00 unless the message names a time)",
            destination: "Inbox",
            alwaysAsks: false
        ),
        "brief_context": ReactionToolInfo(
            title: "Brief me",
            summary: "Summarises the message's thread: what it's about, who's involved, what's decided, what you're asked",
            destination: "Inbox",
            alwaysAsks: false
        ),
        // Not a reaction tool (main AI Chat only), but its proposals render
        // on the same agent-action card, so it gets its human name here too.
        "connect_jira_board": ReactionToolInfo(
            title: "Connect a Jira board",
            summary: "Starts watching a Jira board",
            destination: "Jira",
            alwaysAsks: true
        )
    ]

    package static func info(for tool: String) -> ReactionToolInfo? {
        entries[tool]
    }

    package static func title(for tool: String) -> String {
        entries[tool]?.title ?? tool
    }
}

/// The Inbox Strip's reaction cheat sheet — pure derivations over the live
/// dictionary (`reaction_command_map`) and `tool_trust`, so a Settings edit
/// shows up here with no second list to keep in sync. Static help, never a
/// strip card (STRIP-01): nothing here reads or writes `agent_actions`.
package enum ReactionCheatSheet {
    package struct Row: Identifiable, Equatable, Sendable {
        package var id: String { emoji }
        package let emoji: String
        package let tool: String
        package let title: String
        package let summary: String
        package let destination: String
        package let needsApproval: Bool
    }

    /// One row per enabled mapping, in dictionary order. A disabled mapping
    /// is omitted rather than greyed — the sheet answers "what can I react
    /// with right now"; the Settings editor is where disabled ones live. A
    /// mapping with no tool (a later-wave `agent` kind) dispatches nothing
    /// and is omitted too.
    package static func rows(mappings: [ReactionCommandMapping], trustByTool: [String: String]) -> [Row] {
        mappings.compactMap { mapping in
            guard mapping.enabled, !mapping.tool.isEmpty else { return nil }
            let info = ReactionToolCatalog.info(for: mapping.tool)
            // No tool_trust row is Go's default, "ask" (`Registry.Propose`).
            let trustAsks = trustByTool[mapping.tool] != "execute"
            return Row(
                emoji: mapping.emoji,
                tool: mapping.tool,
                title: info?.title ?? mapping.tool,
                summary: info?.summary ?? "",
                destination: info?.destination ?? "",
                needsApproval: (info?.alwaysAsks ?? false) || trustAsks
            )
        }
    }

    /// The feature-on status line. `lastCheck` is the latest successful
    /// `reaction-commands` run's `finished_at`; without one the line claims
    /// no time rather than inventing one.
    package static func statusLine(lastCheck: String?) -> String {
        guard let lastCheck, TimeFormatting.parseISO(lastCheck) != nil else {
            return "Watching your Slack reactions"
        }
        return "Watching your Slack reactions — last check \(TimeFormatting.relativeTime(from: lastCheck))"
    }
}
