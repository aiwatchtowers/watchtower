import Foundation

/// `watchtower workbench session-feed --json`: the dialog of one Claude Code
/// session, built by Go (`internal/sessionfeed`) without AI. The Desktop only
/// decodes and shows it. An unknown `kind` decodes as-is so a newer CLI never
/// breaks an older app; the store hides kinds it does not know.
package struct SessionFeedSubagent: Decodable, Equatable, Sendable {
    package var toolUseID: String
    package var agentID: String
    package var type: String
    package var description: String
    /// "running", "finished" or "unknown".
    package var status: String
    /// When the Agent call started; only the feed's `subagents` list carries
    /// it (`started_at`). nil when absent or Go's zero time.
    package var startedAt: Date?

    package init(
        toolUseID: String,
        agentID: String = "",
        type: String = "",
        description: String = "",
        status: String = "unknown",
        startedAt: Date? = nil
    ) {
        self.toolUseID = toolUseID
        self.agentID = agentID
        self.type = type
        self.description = description
        self.status = status
        self.startedAt = startedAt
    }

    /// The status of `subagent` in `entries`, the store's subagent list
    /// (`SessionFeedStore.subagents`, which a read updates in place); the copy
    /// itself when the list has no marker for it — a copy kept since it was
    /// opened would never see it finish.
    package static func currentStatus(of subagent: Self, in entries: [SessionFeedEntry]) -> String {
        entries.last { $0.subagent?.toolUseID == subagent.toolUseID }?.subagent?.status ?? subagent.status
    }

    private enum CodingKeys: String, CodingKey {
        case toolUseID = "tool_use_id"
        case agentID = "agent_id"
        case startedAt = "started_at"
        case type, description, status
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolUseID = try c.decodeIfPresent(String.self, forKey: .toolUseID) ?? ""
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        startedAt = SessionFeedEntry.parseDate(try c.decodeIfPresent(String.self, forKey: .startedAt))
    }
}

/// The `peer` payload (Go `sessionfeed.PeerRef`): another agent of the workbench
/// speaking to this session or this session speaking to one.
package struct SessionFeedPeer: Decodable, Equatable, Sendable {
    /// "in" or "out".
    package var direction: String
    /// "message", "finished" or "started".
    package var kind: String
    package var sessionID: Int64
    package var title: String
    package var folder: String
    package var worktree: String
    /// Why the call was refused; "" when it was not.
    package var error: String

    package init(
        direction: String,
        kind: String,
        sessionID: Int64 = 0,
        title: String = "",
        folder: String = "",
        worktree: String = "",
        error: String = ""
    ) {
        self.direction = direction
        self.kind = kind
        self.sessionID = sessionID
        self.title = title
        self.folder = folder
        self.worktree = worktree
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case direction, kind, title, folder, worktree, error
        case sessionID = "session_id"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        sessionID = try c.decodeIfPresent(Int64.self, forKey: .sessionID) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        worktree = try c.decodeIfPresent(String.self, forKey: .worktree) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
}

/// The `task` payload (Go `sessionfeed.TaskRef`) of a task-notification `event`: an agent or a background command
/// Claude Code ran finished. `result` is "" when the notice held only Claude Code's delivery boilerplate and the
/// feed found no handback for it.
package struct SessionFeedTask: Decodable, Equatable, Sendable {
    package var taskID: String
    package var toolUseID: String
    /// "completed", "failed", "killed", …
    package var status: String
    package var summary: String
    package var result: String
    package var outputFile: String
    package var tokens: Int
    package var toolUses: Int
    package var durationMS: Int
    /// "agent" or "command".
    package var kind: String
    /// A background command's exit code; nil when the notice gave none.
    package var exitCode: Int?

    package init(
        taskID: String = "",
        toolUseID: String = "",
        status: String = "",
        summary: String = "",
        result: String = "",
        outputFile: String = "",
        tokens: Int = 0,
        toolUses: Int = 0,
        durationMS: Int = 0,
        kind: String = "",
        exitCode: Int? = nil
    ) {
        self.taskID = taskID
        self.toolUseID = toolUseID
        self.status = status
        self.summary = summary
        self.result = result
        self.outputFile = outputFile
        self.tokens = tokens
        self.toolUses = toolUses
        self.durationMS = durationMS
        self.kind = kind
        self.exitCode = exitCode
    }

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case toolUseID = "tool_use_id"
        case outputFile = "output_file"
        case toolUses = "tool_uses"
        case durationMS = "duration_ms"
        case exitCode = "exit_code"
        case status, summary, result, tokens, kind
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID) ?? ""
        toolUseID = try c.decodeIfPresent(String.self, forKey: .toolUseID) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        result = try c.decodeIfPresent(String.self, forKey: .result) ?? ""
        outputFile = try c.decodeIfPresent(String.self, forKey: .outputFile) ?? ""
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        toolUses = try c.decodeIfPresent(Int.self, forKey: .toolUses) ?? 0
        durationMS = try c.decodeIfPresent(Int.self, forKey: .durationMS) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
    }
}

package struct SessionFeedEntry: Decodable, Identifiable, Equatable, Sendable {
    /// Kinds this app renders; anything else is forward-compatible noise.
    package static let knownKinds: Set<String> = [
        "owner", "agent", "ask_answer", "watchtower", "brief", "subagent", "separator", "event", "peer"
    ]
    /// Kinds the phone slice carries (FEED-02); `event` and `peer` are Desktop only (the phone shows no peer bubbles in v1).
    package static let phoneKinds: Set<String> = [
        "owner", "agent", "ask_answer", "watchtower", "brief", "subagent", "separator"
    ]

    package var id: String
    package var kind: String
    /// nil for Go's zero time (a separator or a meta-only subagent marker).
    package var at: Date?
    package var text: String
    package var conversation: String
    package var askID: Int64?
    package var title: String?
    package var via: String?
    /// "task" or "teammate" on an `event` entry.
    package var eventType: String?
    package var subagent: SessionFeedSubagent?
    /// Who a `peer` entry is from or to.
    package var peer: SessionFeedPeer?
    /// A task notification's fields (an `event` of type "task" from a newer CLI); nil otherwise.
    package var task: SessionFeedTask?

    package init(
        id: String,
        kind: String,
        at: Date? = nil,
        text: String = "",
        conversation: String = "",
        askID: Int64? = nil,
        title: String? = nil,
        via: String? = nil,
        eventType: String? = nil,
        subagent: SessionFeedSubagent? = nil,
        peer: SessionFeedPeer? = nil,
        task: SessionFeedTask? = nil
    ) {
        self.id = id
        self.kind = kind
        self.at = at
        self.text = text
        self.conversation = conversation
        self.askID = askID
        self.title = title
        self.via = via
        self.eventType = eventType
        self.subagent = subagent
        self.peer = peer
        self.task = task
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, at, text, conversation, title, via, subagent, peer, task
        case askID = "ask_id"
        case eventType = "event_type"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        at = Self.parseDate(try c.decodeIfPresent(String.self, forKey: .at))
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        conversation = try c.decodeIfPresent(String.self, forKey: .conversation) ?? ""
        askID = try c.decodeIfPresent(Int64.self, forKey: .askID)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        via = try c.decodeIfPresent(String.self, forKey: .via)
        eventType = try c.decodeIfPresent(String.self, forKey: .eventType)
        subagent = try c.decodeIfPresent(SessionFeedSubagent.self, forKey: .subagent)
        peer = try c.decodeIfPresent(SessionFeedPeer.self, forKey: .peer)
        task = try c.decodeIfPresent(SessionFeedTask.self, forKey: .task)
    }

    /// RFC 3339 with or without fractional seconds; Go's zero time and
    /// anything unparsable mean "no time". The formatters are made once: a
    /// formatter per date cost most of a large feed's decode (#2065).
    package static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty, !s.hasPrefix("0001-01-01") else { return nil }
        return fractionalDate.date(from: s) ?? plainDate.date(from: s)
    }

    private static let plainDate = ISO8601DateFormatter()
    private static let fractionalDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

package struct SessionFeedPayload: Decodable, Sendable {
    package var sessionID: Int64
    /// "" when nothing was read yet: the next refresh is a full read.
    package var cursor: String
    package var entries: [SessionFeedEntry]
    /// Current state of the subagent markers (status changes after the marker
    /// was first emitted).
    package var subagents: [SessionFeedEntry]
    /// The agent's open tool call; nil = none (or an older CLI).
    package var activity: SessionFeedActivity?
    package var live: SessionFeedLive?
    package var liveOK: Bool
    package var liveError: String?
    /// A `--tail` read's page start: the id to pass as `--before` for the
    /// page before it; "" when absent (nothing earlier, or not a tail read).
    package var before: String
    /// Each Claude Code conversation's transcript directory (the folder's or a worktree's project); empty from a
    /// `--subagent` read, a Codex session or an older CLI.
    package var transcriptDirs: [String: String]

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cursor, entries, subagents, activity, live, before
        case liveOK = "live_ok", liveError = "live_error", transcriptDirs = "transcript_dirs"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decodeIfPresent(Int64.self, forKey: .sessionID) ?? 0
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor) ?? ""
        entries = try c.decodeIfPresent([SessionFeedEntry].self, forKey: .entries) ?? []
        subagents = try c.decodeIfPresent([SessionFeedEntry].self, forKey: .subagents) ?? []
        activity = try c.decodeIfPresent(SessionFeedActivity.self, forKey: .activity)
        live = try c.decodeIfPresent(SessionFeedLive.self, forKey: .live)
        liveOK = try c.decodeIfPresent(Bool.self, forKey: .liveOK) ?? false
        liveError = try c.decodeIfPresent(String.self, forKey: .liveError)
        before = try c.decodeIfPresent(String.self, forKey: .before) ?? ""
        transcriptDirs = try c.decodeIfPresent([String: String].self, forKey: .transcriptDirs) ?? [:]
    }
}
