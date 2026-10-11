import Foundation
import WatchtowerSync

/// The `session_report` slice (mobile POC spec §4.8), record name
/// `session_report-<terminal_sessions.id>`: the output of
/// `watchtower workbench session-report --session S --json` (Go
/// `internal/sessionreport.Report`, Core `SessionReport`), capped by the hub.
/// Every key may be absent (an older or newer CLI) and decodes with a
/// default. Datetimes stay Go's UTC strings, "" for none.
///
/// A capped list carries `<list>_more` (items not shown). Past the 128 KiB
/// payload cap the hub drops the oldest phase items and sets
/// `phases_clipped`.
public struct SessionReport: SliceMirror {
    public static let sliceKind = SliceKind.sessionReport

    public let session: Session
    public let progress: Progress
    /// The session's open asks. Cap 30.
    public let onYou: [Ask]
    public let onYouMore: Int?
    /// Cap 20.
    public let now: [NowItem]
    public let nowMore: Int?
    /// Cap 20.
    public let next: [Item]
    public let nextMore: Int?
    /// Cap 30, each with at most 50 items.
    public let phases: [Phase]
    public let phasesMore: Int?
    public let phasesClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// Cap 10.
    public let prs: [PullRequest]
    public let prsMore: Int?
    /// Why the PR states may be incomplete; "" when they are not.
    public let prNote: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decode(.session, or: Session.empty)
        progress = try c.decode(.progress, or: Progress(done: 0, total: 0))
        onYou = try c.decode(.onYou, or: [])
        onYouMore = try c.decodeIfPresent(Int.self, forKey: .onYouMore)
        now = try c.decode(.now, or: [])
        nowMore = try c.decodeIfPresent(Int.self, forKey: .nowMore)
        next = try c.decode(.next, or: [])
        nextMore = try c.decodeIfPresent(Int.self, forKey: .nextMore)
        phases = try c.decode(.phases, or: [])
        phasesMore = try c.decodeIfPresent(Int.self, forKey: .phasesMore)
        phasesClipped = try c.decodeIfPresent(Bool.self, forKey: .phasesClipped)
        prs = try c.decode(.prs, or: [])
        prsMore = try c.decodeIfPresent(Int.self, forKey: .prsMore)
        prNote = try c.decode(.prNote, or: "")
    }

    // RelayCoder's convertFromSnakeCase turns "on_you" into "onYou" before
    // matching, so the keys are in that form.
    enum CodingKeys: String, CodingKey {
        case session, progress, onYou, onYouMore, now, nowMore, next, nextMore
        case phases, phasesMore, phasesClipped, prs, prsMore, prNote
    }

    /// The terminal_sessions row the report is about.
    public struct Session: Decodable, Hashable, Sendable {
        public let id: Int64
        public let title: String
        public let targetID: Int64?
        public let kind: String
        public let createdAt: String
        public let lastActiveAt: String
        public let agentState: String
        public let agentStateAt: String
        /// Set by `finish_session`; "" when the session is not finished.
        public let finishedAt: String
        public let finishSummary: String

        /// A report with no `session` key.
        static let empty = Self()

        private init() {
            id = 0
            title = ""
            targetID = nil
            kind = ""
            createdAt = ""
            lastActiveAt = ""
            agentState = ""
            agentStateAt = ""
            finishedAt = ""
            finishSummary = ""
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(.id, or: 0)
            title = try c.decode(.title, or: "")
            targetID = try c.decodeIfPresent(Int64.self, forKey: .targetID)
            kind = try c.decode(.kind, or: "")
            createdAt = try c.decode(.createdAt, or: "")
            lastActiveAt = try c.decode(.lastActiveAt, or: "")
            agentState = try c.decode(.agentState, or: "")
            agentStateAt = try c.decode(.agentStateAt, or: "")
            finishedAt = try c.decode(.finishedAt, or: "")
            finishSummary = try c.decode(.finishSummary, or: "")
        }

        enum CodingKeys: String, CodingKey {
            case id, title, kind, createdAt, lastActiveAt, agentState, agentStateAt, finishedAt, finishSummary
            case targetID = "targetId"
        }
    }

    /// Leaves in scope: `done` counts done ones, `total` leaves out dismissed.
    public struct Progress: Decodable, Hashable, Sendable {
        public let done: Int
        public let total: Int

        public init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            done = try c.decode(.done, or: 0)
            total = try c.decode(.total, or: 0)
        }

        enum CodingKeys: String, CodingKey { case done, total }
    }

    /// One of the session's open asks.
    public struct Ask: Decodable, Hashable, Sendable, Identifiable {
        public let id: Int64
        public let kind: String
        public let title: String
        public let targetID: Int64?
        public let createdAt: String

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(.id, or: 0)
            kind = try c.decode(.kind, or: "")
            title = try c.decode(.title, or: "")
            targetID = try c.decodeIfPresent(Int64.self, forKey: .targetID)
            createdAt = try c.decode(.createdAt, or: "")
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, title, createdAt
            case targetID = "targetId"
        }
    }

    /// A board leaf: a `next` entry or one of a phase's items.
    public struct Item: Decodable, Hashable, Sendable, Identifiable {
        public let id: Int64
        public let text: String
        public let status: String

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(.id, or: 0)
            text = try c.decode(.text, or: "")
            status = try c.decode(.status, or: "")
        }

        enum CodingKeys: String, CodingKey { case id, text, status }
    }

    /// A leaf in progress, in review or blocked; `since` is its latest
    /// status move.
    public struct NowItem: Decodable, Hashable, Sendable, Identifiable {
        public let id: Int64
        public let text: String
        public let status: String
        public let branch: String
        public let since: String

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(.id, or: 0)
            text = try c.decode(.text, or: "")
            status = try c.decode(.status, or: "")
            branch = try c.decode(.branch, or: "")
            since = try c.decode(.since, or: "")
        }

        enum CodingKeys: String, CodingKey { case id, text, status, branch, since }
    }

    /// A parent of in-scope leaves. `done`/`total` count all its
    /// non-dismissed leaf descendants; `finishedAt` is set only when all are
    /// done.
    public struct Phase: Decodable, Hashable, Sendable, Identifiable {
        public let targetID: Int64
        public let text: String
        public let done: Int
        public let total: Int
        public let startedAt: String
        public let finishedAt: String
        /// Cap 50.
        public let items: [Item]
        public let itemsMore: Int?

        public var id: Int64 { targetID }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            targetID = try c.decode(.targetID, or: 0)
            text = try c.decode(.text, or: "")
            done = try c.decode(.done, or: 0)
            total = try c.decode(.total, or: 0)
            startedAt = try c.decode(.startedAt, or: "")
            finishedAt = try c.decode(.finishedAt, or: "")
            items = try c.decode(.items, or: [])
            itemsMore = try c.decodeIfPresent(Int.self, forKey: .itemsMore)
        }

        enum CodingKeys: String, CodingKey {
            case text, done, total, startedAt, finishedAt, items, itemsMore
            case targetID = "targetId"
        }
    }

    /// A pull request (`ref` "pr:147") or a branch with no known PR (`ref`
    /// "branch:<name>"). `state` is open, merged, closed or unknown.
    public struct PullRequest: Decodable, Hashable, Sendable, Identifiable {
        public let ref: String
        public let prNumber: Int64?
        public let title: String
        public let state: String
        public let additions: Int64?
        public let deletions: Int64?
        public let mergedAt: String
        public let checkedAt: String
        public let targets: [Int64]

        public var id: String { ref }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ref = try c.decode(.ref, or: "")
            prNumber = try c.decodeIfPresent(Int64.self, forKey: .prNumber)
            title = try c.decode(.title, or: "")
            state = try c.decode(.state, or: "unknown")
            additions = try c.decodeIfPresent(Int64.self, forKey: .additions)
            deletions = try c.decodeIfPresent(Int64.self, forKey: .deletions)
            mergedAt = try c.decode(.mergedAt, or: "")
            checkedAt = try c.decode(.checkedAt, or: "")
            targets = try c.decode(.targets, or: [])
        }

        enum CodingKeys: String, CodingKey {
            case ref, prNumber, title, state, additions, deletions, mergedAt, checkedAt, targets
        }
    }
}

private extension KeyedDecodingContainer {
    /// The value at `key`, or `fallback` when the key is absent or null; a
    /// present value of the wrong type still throws.
    func decode<T: Decodable>(_ key: Key, or fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}
