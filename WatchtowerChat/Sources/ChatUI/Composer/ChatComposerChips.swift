import ChatWire
import Foundation

/// What a new chat may be started with: the models and projects the engine offers (the list's `models` and
/// `projects`). A shell that sets `ChatComposerModel.newChatChoices` gets the model and project chips.
public struct ChatNewChatChoices: Equatable, Sendable {
    public let models: [ChatList.Model]
    public let projects: [ChatList.Project]

    public init(models: [ChatList.Model], projects: [ChatList.Project]) {
        self.models = models
        self.projects = projects
    }
}

/// One chip over the composer: editable on a new chat (a menu), locked once the first message went.
public struct ChatComposerChip: Equatable, Sendable {
    public let label: String
    public let editable: Bool

    public init(label: String, editable: Bool) {
        self.label = label
        self.editable = editable
    }
}

/// The model and project chips (iPhone chat spec §6.2, mockups 2a, 2h): on a new chat the picked routing and project,
/// editable; on a saved chat its routing (with the provider that answered) and project, locked.
extension ChatComposerModel {
    public static let autoLabel = "Auto"
    public static let noProject = "No project"

    public var modelChip: ChatComposerChip? {
        guard let choices = newChatChoices else { return nil }
        guard let saved = conversation.feed?.conversation, conversation.conversationID != nil else {
            return ChatComposerChip(label: Self.modelLabel(routing, provider: nil, models: choices.models),
                                    editable: conversation.conversationID == nil)
        }
        return ChatComposerChip(label: Self.modelLabel(saved.routing, provider: saved.actualProvider, models: choices.models),
                                editable: false)
    }

    public var projectChip: ChatComposerChip? {
        guard let choices = newChatChoices else { return nil }
        guard let saved = conversation.feed?.conversation, conversation.conversationID != nil else {
            let name = projectID.flatMap { id in choices.projects.first { $0.id == id }?.name }
            return ChatComposerChip(label: name ?? Self.noProject, editable: conversation.conversationID == nil)
        }
        return ChatComposerChip(label: saved.project?.name ?? Self.noProject, editable: false)
    }

    /// "Auto · Claude" (the provider's name), or the pinned model's name.
    public static func modelLabel(_ routing: ChatRouting?, provider: String?, models: [ChatList.Model]) -> String {
        if let routing, routing.mode == "pinned" {
            let named = models.first { $0.provider == routing.provider && $0.model == (routing.model ?? "") }
            return named?.displayName ?? routing.model ?? routing.provider ?? autoLabel
        }
        let wanted = provider.flatMap { $0.isEmpty ? nil : $0 }
        let name = models.first { wanted == nil || $0.provider == wanted }?.displayName ?? wanted?.capitalized
        return name.map { "\(autoLabel) · \($0)" } ?? autoLabel
    }

    /// The model menu: Auto, then every model offered.
    public static func modelOptions(_ models: [ChatList.Model]) -> [(label: String, routing: ChatRouting?)] {
        [(autoLabel, nil)] + models.map { model in
            (model.displayName, ChatRouting(mode: "pinned", provider: model.provider, model: model.model))
        }
    }
}
