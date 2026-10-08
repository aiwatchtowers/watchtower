import Foundation
import WatchtowerSync

/// The `session_timeline` slice (mobile POC spec §4.9), record name
/// `session_timeline-<terminal_sessions.id>`: the session's milestones,
/// newest first, at most 100. No subagent events (OD-3) and never the raw
/// Claude Code transcript (I-4).
public struct SessionTimeline: SliceMirror {
    public static let sliceKind = SliceKind.sessionTimeline

    public struct Milestone: Codable, Hashable, Sendable {
        /// rawValues are wire format; a kind added by a newer Mac decodes as
        /// an unknown value.
        public struct Kind: OpenWireValue {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }

            /// A resolved state-kind transition the hub observed.
            public static let state = Self(rawValue: "state")
            public static let askOpened = Self(rawValue: "ask_opened")
            public static let askAnswered = Self(rawValue: "ask_answered")
            public static let askWithdrawn = Self(rawValue: "ask_withdrawn")
            public static let targetLinked = Self(rawValue: "target_linked")
            /// `from → to` with the actor.
            public static let targetStatus = Self(rawValue: "target_status")
            public static let phase = Self(rawValue: "phase")
            public static let pr = Self(rawValue: "pr")
            public static let finished = Self(rawValue: "finished")
            public static let knownValues: [Self] = [
                .state, .askOpened, .askAnswered, .askWithdrawn, .targetLinked, .targetStatus, .phase, .pr, .finished
            ]
        }

        public let at: Date
        public let kind: Kind
        /// Cap 200.
        public let text: String
        public let textClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        /// The target or ask the milestone is about; nil for none.
        public let ref: Int64?

        public init(
            at: Date,
            kind: Kind,
            text: String,
            textClipped: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
            ref: Int64? = nil
        ) {
            self.at = at
            self.kind = kind
            self.text = text
            self.textClipped = textClipped
            self.ref = ref
        }
    }

    public let sessionID: Int64
    /// Newest first. Cap 100.
    public let milestones: [Milestone]
    public let milestonesMore: Int?

    // convertFromSnakeCase maps "session_id" -> "sessionId" (lowercase d).
    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case milestones, milestonesMore
    }
}
