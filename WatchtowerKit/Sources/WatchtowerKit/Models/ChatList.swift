import Foundation
import WatchtowerSync

/// The `chat_list` slice, one record `chat_list-main` (iPhone chat spec
/// §4.6): the Mac's main-chat conversations (up to 200, not archived,
/// pinned first then newest), its chat projects and the models the
/// composer offers. Published only while this phone holds the `chat`
/// grant; it stays in the replica, so it is also the offline list.
public struct ChatList: SliceMirror, Equatable {
    public static let sliceKind = SliceKind.chatList
    /// The one record's id.
    public static let recordID = "main"

    /// A row's state dot, by precedence: waiting for an approval >
    /// answering > unread > read. rawValues are wire format.
    public struct State: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let waiting = Self(rawValue: "waiting")
        public static let answering = Self(rawValue: "answering")
        public static let unread = Self(rawValue: "unread")
        public static let read = Self(rawValue: "read")
        public static let knownValues: [Self] = [.waiting, .answering, .unread, .read]
    }

    public struct Project: Hashable, Sendable, Decodable, Identifiable {
        public let id: Int64
        public let name: String

        public init(id: Int64, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Conversation: Hashable, Sendable, Decodable, Identifiable {
        public let id: Int64
        public let title: String
        public let pinned: Bool
        public let updatedAt: Date
        public let project: Project?
        public let state: State
        /// The last answer's first line, cap 120; "" before any answer.
        public let lastLine: String
        /// "hub" or "desktop" while a turn runs.
        public let leaseOwner: String?

        public init(
            id: Int64,
            title: String,
            pinned: Bool = false,
            updatedAt: Date,
            project: Project? = nil,
            state: State,
            lastLine: String = "",
            leaseOwner: String? = nil
        ) {
            self.id = id
            self.title = title
            self.pinned = pinned
            self.updatedAt = updatedAt
            self.project = project
            self.state = state
            self.lastLine = lastLine
            self.leaseOwner = leaseOwner
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int64.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            updatedAt = try c.decode(Date.self, forKey: .updatedAt)
            project = try c.decodeIfPresent(Project.self, forKey: .project)
            state = try c.decodeIfPresent(State.self, forKey: .state) ?? .read
            lastLine = try c.decodeIfPresent(String.self, forKey: .lastLine) ?? ""
            leaseOwner = try c.decodeIfPresent(String.self, forKey: .leaseOwner)
        }

        enum CodingKeys: String, CodingKey {
            case id, title, pinned, updatedAt, project, state, lastLine, leaseOwner
        }
    }

    /// One model the composer offers, with the attachments it takes.
    public struct Model: Hashable, Sendable, Decodable {
        public let provider: String
        public let model: String
        public let displayName: String
        public let images: Bool
        public let pdf: Bool

        public init(provider: String, model: String, displayName: String, images: Bool, pdf: Bool) {
            self.provider = provider
            self.model = model
            self.displayName = displayName
            self.images = images
            self.pdf = pdf
        }
    }

    public let conversations: [Conversation]
    public let projects: [Project]
    public let models: [Model]
    /// Set when the Mac could not read its chats ("Couldn't load chats");
    /// the lists are then empty.
    public let error: String?

    public init(conversations: [Conversation], projects: [Project] = [], models: [Model] = [], error: String? = nil) {
        self.conversations = conversations
        self.projects = projects
        self.models = models
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try c.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        models = try c.decodeIfPresent([Model].self, forKey: .models) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    enum CodingKeys: String, CodingKey {
        case conversations, projects, models, error
    }

    /// `chat_list-main`.
    public static var recordName: String { SliceKind.chatList.recordName(id: recordID) }
}
