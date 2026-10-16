import Foundation
import WatchtowerCore

/// The ⌘/ panel's help chat (spec 2026-10-16 "Asking (the help chat)").
///
/// - No tools (AGENT-04 `.draftOnly`): the guide sections a turn needs are
///   retrieved in Swift from the loaded index and put into its prompt, so it
///   works on every provider and never reads the owner's data.
/// - `.memory`: no conversation row; closing the panel releases the engine.
/// - The light tier of the configured provider.
@MainActor
enum HelpChatSurface {
    static let contextType = "help"

    static func spec(
        center: AskCenter,
        currentPage: @escaping @MainActor () -> String,
        screens: @escaping @MainActor () -> [HelpScreen]
    ) -> ChatSurfaceSpec {
        // The configured provider's light tier: answers are retrieval plus rewording.
        let runOptions = { @MainActor () -> ChatRunOptions in
            let config = ConfigService()
            let provider = AIProvider.fromConfig(config.aiProvider).rawValue
            let light = config.aiModelLight.flatMap { $0.isEmpty ? nil : $0 } ?? center.resolvedLightModel(provider)
            return ChatRunOptions(provider: provider, model: light)
        }
        return ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: contextType, contextID: center.conversationID.uuidString,
                                 conversationID: nil),
            persistence: .memory,
            toolAccess: .draftOnly,
            systemPrompt: { HelpPrompt.system(catalog: center.index?.catalog ?? "") },
            turnPrompt: { input in
                let previous = center.previousQuestion
                let query = [input.text, previous].compactMap { $0 }.joined(separator: " ")
                let sections = center.index.map {
                    GuideSearch.rank(query, in: $0.sections, limit: AskCenter.turnSectionLimit)
                } ?? []
                center.previousQuestion = input.text
                center.pendingSource = sections.first
                return HelpPrompt.turn(question: input.text, previousQuestion: previous, currentPage: currentPage(),
                                       screens: screens(), sections: sections)
            },
            postTurn: { input in
                center.recordSource(messageID: input.messageID)
                let allowed = Set(screens().map(\.rawValue))
                return ChatPostTurnResult(displayText: unlinkingNavLinks(input.reply, allowed: allowed))
            },
            emptyHint: "Ask how to do something in Watchtower.",
            runOptions: runOptions
        )
    }

    private static let navLinkPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\[([^\]]*)\]\(\#(NavLink.scheme)://([^)\s]*)\)"#)

    /// A markdown link to a screen not in `allowed` (unknown, or hidden from
    /// the sidebar) becomes its plain label, never a dead link.
    static func unlinkingNavLinks(_ text: String, allowed: Set<String>) -> String {
        guard let pattern = navLinkPattern else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let destination = source.substring(with: match.range(at: 2))
            guard !allowed.contains(destination) else { continue }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += source.substring(with: match.range(at: 1))
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }
}
