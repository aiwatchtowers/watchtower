import Foundation

/// The `chat_list` slice, one record `chat_list-main` (iPhone chat spec
/// §4.6): the Mac's main-chat conversations (up to 200, not archived,
/// pinned first then newest), its chat projects and the models the
/// composer offers. Published only while this phone holds the `chat`
/// grant; it stays in the replica, so it is also the offline list.
public struct ChatList: Decodable, Hashable, Sendable {
    /// A row's state dot, by precedence: waiting for an approval >
    /// answering > unread > read. rawValues are wire format.
    /// Open like the Kit's `OpenWireValue`: a state a newer Mac adds decodes, reads as `isKnown == false` and
    /// re-encodes unchanged.
    public struct State: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }

        /// False for a state written by a newer build.
        public var isKnown: Bool { Self.knownValues.contains(self) }

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
        /// The running turn's id while one runs (absent from an older engine): a connector call of that turn is
        /// still held by its session.
        public let turnID: String?
        /// When the last answer was written; nil before any, or from an older engine (the Mac's panel then counts
        /// the row's age from `updatedAt`).
        public let lastAnswerAt: Date?
        /// The tool of the oldest pending approval while the chat waits (absent from an older engine).
        public let pendingTool: String?
        /// A complete answer the owner has not seen, whatever `state` shows first (an `unread` state always is; an
        /// older engine sends nothing else).
        public let unread: Bool

        public init(
            id: Int64,
            title: String,
            pinned: Bool = false,
            updatedAt: Date,
            project: Project? = nil,
            state: State,
            lastLine: String = "",
            leaseOwner: String? = nil,
            turnID: String? = nil,
            lastAnswerAt: Date? = nil,
            pendingTool: String? = nil,
            unread: Bool = false
        ) {
            self.id = id
            self.title = title
            self.pinned = pinned
            self.updatedAt = updatedAt
            self.project = project
            self.state = state
            self.lastLine = lastLine
            self.leaseOwner = leaseOwner
            self.turnID = turnID
            self.lastAnswerAt = lastAnswerAt
            self.pendingTool = pendingTool
            self.unread = unread || state == .unread
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
            turnID = try c.decodeIfPresent(String.self, forKey: .turnID).flatMap { $0.isEmpty ? nil : $0 }
            lastAnswerAt = try c.decodeIfPresent(Date.self, forKey: .lastAnswerAt)
            pendingTool = try c.decodeIfPresent(String.self, forKey: .pendingTool).flatMap { $0.isEmpty ? nil : $0 }
            unread = (try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false) || state == .unread
        }

        enum CodingKeys: String, CodingKey {
            case id, title, pinned, updatedAt, project, state, lastLine, leaseOwner, lastAnswerAt, pendingTool, unread
            case turnID = "turnId"
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
}
