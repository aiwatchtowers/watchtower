import Foundation
import WatchtowerCore

/// The ⌘/ panel's help chat (spec 2026-10-16 "Asking (the help chat)").
///
/// - No tools at all: `.draftOnly` (AGENT-04, no write tools) plus
///   `ChatRunOptions.noTools` (`ai query --no-tools`: no MCP server, no
///   built-ins), so it can reach none of the owner's data. The guide sections
///   a turn needs are retrieved in Swift from the loaded index and put into
///   its prompt, so it works on every provider.
/// - `.memory`: no conversation row; closing the panel releases the engine.
/// - Screen links (`watchtower-nav://`) to a hidden or unknown screen render
///   as plain text (`MarkdownView`'s `markdownNavScreens`).
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
            return ChatRunOptions(provider: provider, model: light, noTools: true)
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
                let turn = HelpPrompt.turn(question: input.text, previousQuestion: previous,
                                           currentPage: currentPage(), screens: screens(), sections: sections)
                // A run that resumes no provider session (Codex, Ollama,
                // Claude without one) gets the earlier turns replayed.
                guard !input.isResumed else { return turn }
                let replay = EmbeddedChatReplay.block(messages: center.history(), before: input.turnID,
                                                      prompt: input.text)
                return (replay ?? "") + turn
            },
            postTurn: { input in
                center.recordSource(messageID: input.messageID)
                return .identity(input)
            },
            emptyHint: "Ask how to do something in Watchtower.",
            runOptions: runOptions
        )
    }
}
