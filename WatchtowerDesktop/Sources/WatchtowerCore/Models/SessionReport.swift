import Foundation

/// `watchtower workbench session-report --session S --json` (spec
/// 2026-10-03-workbench-session-report Part 6): what one claude session did.
/// Go owns the report (`internal/sessionreport.Report`); the Desktop only
/// decodes and shows it. Every key may be absent or extra — an older or newer
/// CLI decodes with defaults. Datetimes stay Go's UTC strings, "" for none.
package struct SessionReport: Decodable, Equatable, Sendable {
    package var session: Session
    package var progress: Progress
    package var onYou: [Ask]
    package var now: [NowItem]
    package var next: [Item]
    package var phases: [Phase]
    package var prs: [PullRequest]
    /// Why the PR states may be incomplete (gh missing, no network, budget
    /// hit); "" when they are not.
    package var prNote: String

    package init(
        session: Session,
        progress: Progress = Progress(),
        onYou: [Ask] = [],
        now: [NowItem] = [],
        next: [Item] = [],
        phases: [Phase] = [],
        prs: [PullRequest] = [],
        prNote: String = ""
    ) {
        self.session = session
        self.progress = progress
        self.onYou = onYou
        self.now = now
        self.next = next
        self.phases = phases
        self.prs = prs
        self.prNote = prNote
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decode(.session, or: Session())
        progress = try c.decode(.progress, or: Progress())
        onYou = try c.decode(.onYou, or: [])
        now = try c.decode(.now, or: [])
        next = try c.decode(.next, or: [])
        phases = try c.decode(.phases, or: [])
        prs = try c.decode(.prs, or: [])
        prNote = try c.decode(.prNote, or: "")
    }

    enum CodingKeys: String, CodingKey {
        case session, progress, now, next, phases, prs
        case onYou = "on_you"
        case prNote = "pr_note"
    }

    package struct Session: Decodable, Equatable, Sendable {
        package var id: Int64
        package var title: String
        package var targetID: Int64?
        package var kind: String
        package var createdAt: String
        package var lastActiveAt: String
        package var agentState: String
        package var agentStateAt: String
        /// Set by `finish_session`; "" when the session is not finished.
        package var finishedAt: String
        /// The last `finish_session` summary, kept after `finishedAt` clears.
        package var finishSummary: String

        package init(
            id: Int64 = 0,
            title: String = "",
            targetID: Int64? = nil,
            kind: String = "",
            createdAt: String = "",
            lastActiveAt: String = "",
            agentState: String = "",
            agentStateAt: String = "",
            finishedAt: String = "",
            finishSummary: String = ""
        ) {
            self.id = id
            self.title = title
            self.targetID = targetID
            self.kind = kind
            self.createdAt = createdAt
            self.lastActiveAt = lastActiveAt
            self.agentState = agentState
            self.agentStateAt = agentStateAt
            self.finishedAt = finishedAt
            self.finishSummary = finishSummary
        }

        package init(from decoder: Decoder) throws {
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
            case id, title, kind
            case targetID = "target_id"
            case createdAt = "created_at"
            case lastActiveAt = "last_active_at"
            case agentState = "agent_state"
            case agentStateAt = "agent_state_at"
            case finishedAt = "finished_at"
            case finishSummary = "finish_summary"
        }
    }

    /// Leaves in scope: `done` counts done ones, `total` leaves out dismissed.
    package struct Progress: Decodable, Equatable, Sendable {
        package var done: Int
        package var total: Int

        package init(done: Int = 0, total: Int = 0) {
            self.done = done
            self.total = total
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            done = try c.decode(.done, or: 0)
            total = try c.decode(.total, or: 0)
        }

        enum CodingKeys: String, CodingKey {
            case done, total
        }
    }

    /// One of this session's open asks.
    package struct Ask: Decodable, Equatable, Sendable, Identifiable {
        package var id: Int64
        package var kind: String
        package var title: String
        package var targetID: Int64?
        package var createdAt: String

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(.id, or: 0)
            kind = try c.decode(.kind, or: "")
            title = try c.decode(.title, or: "")
            targetID = try c.decodeIfPresent(Int64.self, forKey: .targetID)
            createdAt = try c.decode(.createdAt, or: "")
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, title
            case targetID = "target_id"
            case createdAt = "created_at"
        }
    }

    /// A board leaf: a `next` entry or one of a phase's items.
    package struct Item: Decodable, Equatable, Sendable, Identifiable {
        package var id: Int64
        package var text: String
        package var status: String

        package init(id: Int64, text: String, status: String) {
            self.id = id
            self.text = text
            self.status = status
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(.id, or: 0)
            text = try c.decode(.text, or: "")
            status = try c.decode(.status, or: "")
        }

        enum CodingKeys: String, CodingKey {
            case id, text, status
        }
    }

    /// A leaf in progress, in review or blocked; `since` is its latest status
    /// move.
    package struct NowItem: Decodable, Equatable, Sendable, Identifiable {
        package var id: Int64
        package var text: String
        package var status: String
        package var branch: String
        package var since: String

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(.id, or: 0)
            text = try c.decode(.text, or: "")
            status = try c.decode(.status, or: "")
            branch = try c.decode(.branch, or: "")
            since = try c.decode(.since, or: "")
        }

        enum CodingKeys: String, CodingKey {
            case id, text, status, branch, since
        }
    }

    /// A parent of in-scope leaves. `done`/`total` count all its non-dismissed
    /// leaf descendants; `finishedAt` is set only when all are done.
    package struct Phase: Decodable, Equatable, Sendable, Identifiable {
        package var targetID: Int64
        package var text: String
        package var done: Int
        package var total: Int
        package var startedAt: String
        package var finishedAt: String
        package var items: [Item]

        package var id: Int64 { targetID }

        package init(
            targetID: Int64,
            text: String,
            done: Int,
            total: Int,
            startedAt: String = "",
            finishedAt: String = "",
            items: [Item] = []
        ) {
            self.targetID = targetID
            self.text = text
            self.done = done
            self.total = total
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.items = items
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            targetID = try c.decode(.targetID, or: 0)
            text = try c.decode(.text, or: "")
            done = try c.decode(.done, or: 0)
            total = try c.decode(.total, or: 0)
            startedAt = try c.decode(.startedAt, or: "")
            finishedAt = try c.decode(.finishedAt, or: "")
            items = try c.decode(.items, or: [])
        }

        enum CodingKeys: String, CodingKey {
            case text, done, total, items
            case targetID = "target_id"
            case startedAt = "started_at"
            case finishedAt = "finished_at"
        }
    }

    /// A pull request (`ref` "pr:147") or a branch with no known PR
    /// (`ref` "branch:<name>"). `state` is open, merged, closed or unknown.
    package struct PullRequest: Decodable, Equatable, Sendable, Identifiable {
        package var ref: String
        package var prNumber: Int64?
        package var title: String
        package var state: String
        package var additions: Int64?
        package var deletions: Int64?
        package var mergedAt: String
        package var checkedAt: String
        package var targets: [Int64]

        package var id: String { ref }

        package init(
            ref: String,
            prNumber: Int64? = nil,
            title: String = "",
            state: String = "unknown",
            additions: Int64? = nil,
            deletions: Int64? = nil,
            mergedAt: String = "",
            checkedAt: String = "",
            targets: [Int64] = []
        ) {
            self.ref = ref
            self.prNumber = prNumber
            self.title = title
            self.state = state
            self.additions = additions
            self.deletions = deletions
            self.mergedAt = mergedAt
            self.checkedAt = checkedAt
            self.targets = targets
        }

        package init(from decoder: Decoder) throws {
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
            case ref, title, state, additions, deletions, targets
            case prNumber = "pr_number"
            case mergedAt = "merged_at"
            case checkedAt = "checked_at"
        }

        /// The branch name of a branch entry; nil for a PR entry.
        package var branch: String? {
            ref.hasPrefix("branch:") ? String(ref.dropFirst("branch:".count)) : nil
        }
    }
}

/// One row of `watchtower workbench session-report --summary --json`: a claude
/// session's panel line, from the DB and the PR cache only (Go
/// `sessionreport.Summary`).
package struct SessionReportSummary: Decodable, Equatable, Sendable, Identifiable {
    package var sessionID: Int64
    package var targetID: Int64?
    package var done: Int
    package var total: Int
    /// "PR #147 open", "2 PRs merged", "no PR yet", "not checked", or "".
    package var prLine: String
    /// "" when the session is not finished.
    package var finishedAt: String

    package var id: Int64 { sessionID }

    package init(
        sessionID: Int64,
        targetID: Int64? = nil,
        done: Int = 0,
        total: Int = 0,
        prLine: String = "",
        finishedAt: String = ""
    ) {
        self.sessionID = sessionID
        self.targetID = targetID
        self.done = done
        self.total = total
        self.prLine = prLine
        self.finishedAt = finishedAt
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(.sessionID, or: 0)
        targetID = try c.decodeIfPresent(Int64.self, forKey: .targetID)
        done = try c.decode(.done, or: 0)
        total = try c.decode(.total, or: 0)
        prLine = try c.decode(.prLine, or: "")
        finishedAt = try c.decode(.finishedAt, or: "")
    }

    enum CodingKeys: String, CodingKey {
        case done, total
        case sessionID = "session_id"
        case targetID = "target_id"
        case prLine = "pr_line"
        case finishedAt = "finished_at"
    }
}

private extension KeyedDecodingContainer {
    /// The value at `key`, or `fallback` when the key is absent or null; a
    /// present value of the wrong type still throws.
    func decode<T: Decodable>(_ key: Key, or fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}
