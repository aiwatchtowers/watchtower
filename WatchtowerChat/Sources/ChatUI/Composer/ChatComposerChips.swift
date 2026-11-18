import ChatWire
import Foundation

/// The projects a new chat may be started in (the list's `projects`). A shell that sets
/// `ChatComposerModel.newChatChoices` gets the project menu beside the routing pill (the phone).
public struct ChatNewChatChoices: Equatable, Sendable {
    public let projects: [ChatList.Project]

    public init(projects: [ChatList.Project]) {
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

/// The project chip (iPhone chat spec §6.2, mockups 2a, 2h): on a new chat the picked project, editable; on a saved
/// chat its project, locked. The model is the routing pill's (`ChatRoutingModel`).
extension ChatComposerModel {
    public static let noProject = "No project"

    public var projectChip: ChatComposerChip? {
        guard let choices = newChatChoices else { return nil }
        guard let saved = conversation.feed?.conversation, conversation.conversationID != nil else {
            let name = projectID.flatMap { id in choices.projects.first { $0.id == id }?.name }
            return ChatComposerChip(label: name ?? Self.noProject, editable: conversation.conversationID == nil)
        }
        return ChatComposerChip(label: saved.project?.name ?? Self.noProject, editable: false)
    }
}
