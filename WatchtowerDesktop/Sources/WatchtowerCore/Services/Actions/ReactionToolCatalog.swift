import ChatWire
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
        "create_linear_issue",
        "create_track",
        "create_idea",
        "remind_me",
        "brief_context"
    ]
}

/// The tool id → human name mapping, read from `ChatWire.ActionToolCatalog`
/// (the one table the approval card shares with the iPhone), plus the
/// reaction wording the Inbox cheat sheet and the Settings dictionary use.
package enum ReactionToolCatalog {
    package static func info(for tool: String) -> ReactionToolInfo? {
        ActionToolCatalog.info(for: tool)
    }

    package static func title(for tool: String) -> String {
        ActionToolCatalog.title(for: tool)
    }

    /// What a reaction mapping does, for the dictionary editor and the
    /// cheat sheet. `create_jira_issue` as a reaction drafts the issue on
    /// the tracker the channel's keys belong to, Jira or Linear, so it
    /// reads tracker-neutral there; approval cards keep the proposed
    /// tool's own title (`title(for:)`).
    package static func reactionInfo(for tool: String) -> ReactionToolInfo? {
        let shared = ActionToolCatalog.info(for: tool)
        guard tool == "create_jira_issue", let shared else { return shared }
        return ReactionToolInfo(
            title: "Create an issue",
            summary: "Drafts an issue from the message in Jira or Linear, by the channel's issue keys",
            destination: "Jira or Linear",
            alwaysAsks: shared.alwaysAsks
        )
    }

    package static func reactionTitle(for tool: String) -> String {
        reactionInfo(for: tool)?.title ?? tool
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
            let info = ReactionToolCatalog.reactionInfo(for: mapping.tool)
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
