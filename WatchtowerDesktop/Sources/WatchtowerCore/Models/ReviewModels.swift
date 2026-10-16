import GRDB

// The diff reviewer's wire envelopes (`workbench review … --json`, decoded
// with `.convertFromSnakeCase`) and its comment row (spec §10).

package struct ReviewRoundInfo: Decodable, Equatable, Sendable {
    package let id: Int64
    /// open | sent | delivered; the model marks its copy sent after a Send.
    package var status: String
    package let mode: String
    package let folderRoot: String
    package let baseSha: String
    package let baseLabel: String
    package let treeSha: String
    package let prevRoundId: Int64
    package let prevTreeSha: String
    package let prevTreeLost: Bool
}

package struct ReviewHunk: Decodable, Equatable, Sendable {
    package let hunkId: String
    package let header: String
    package let oldStart: Int
    package let oldLines: Int
    package let newStart: Int
    package let newLines: Int
    package let lines: [String]

    private enum CodingKeys: String, CodingKey {
        case hunkId, header, oldStart, oldLines, newStart, newLines, lines
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hunkId = try c.decode(String.self, forKey: .hunkId)
        header = try c.decode(String.self, forKey: .header)
        oldStart = try c.decode(Int.self, forKey: .oldStart)
        oldLines = try c.decode(Int.self, forKey: .oldLines)
        newStart = try c.decode(Int.self, forKey: .newStart)
        newLines = try c.decode(Int.self, forKey: .newLines)
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
    }
}

package struct ReviewDiffFile: Decodable, Equatable, Sendable, Identifiable {
    package var id: String { path }
    package let path: String
    package let oldPath: String?
    package let status: String
    package let additions: Int
    package let deletions: Int
    package let binary: Bool
    package let collapsedReason: String?
    /// The new side's blob id and mode ("" for a deleted file): the Viewed key.
    package let newBlob: String
    package let newMode: String
    package let hunks: [ReviewHunk]

    private enum CodingKeys: String, CodingKey {
        case path, oldPath, status, additions, deletions, binary, collapsedReason, newBlob, newMode, hunks
    }

    /// Direct construction for the pure review logic and its tests.
    package init(
        path: String,
        additions: Int,
        deletions: Int,
        collapsedReason: String? = nil,
        status: String = "modified",
        binary: Bool = false,
        newBlob: String = "",
        newMode: String = "100644"
    ) {
        self.path = path
        self.oldPath = nil
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.binary = binary
        self.collapsedReason = collapsedReason
        self.newBlob = newBlob
        self.newMode = newMode
        self.hunks = []
    }

    /// Go emits `"hunks": null` for collapsed, binary and unchanged files.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        oldPath = try c.decodeIfPresent(String.self, forKey: .oldPath)
        status = try c.decode(String.self, forKey: .status)
        additions = try c.decode(Int.self, forKey: .additions)
        deletions = try c.decode(Int.self, forKey: .deletions)
        binary = try c.decode(Bool.self, forKey: .binary)
        collapsedReason = try c.decodeIfPresent(String.self, forKey: .collapsedReason)
        newBlob = try c.decode(String.self, forKey: .newBlob)
        newMode = try c.decode(String.self, forKey: .newMode)
        hunks = try c.decodeIfPresent([ReviewHunk].self, forKey: .hunks) ?? []
    }
}

package struct ReviewDiff: Decodable, Equatable, Sendable {
    package let files: [ReviewDiffFile]
    package let truncated: Bool

    private enum CodingKeys: String, CodingKey { case files, truncated }

    /// `files` is `null` when nothing changed.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = try c.decodeIfPresent([ReviewDiffFile].self, forKey: .files) ?? []
        truncated = try c.decode(Bool.self, forKey: .truncated)
    }
}

package struct ReviewFileSide: Decodable, Equatable, Sendable {
    package let exists: Bool
    package let text: String
    package let binary: Bool
    package let tooLarge: Bool
}

package struct ReviewContextItem: Decodable, Equatable, Sendable {
    package let targetId: Int64
    package let text: String
    package let intent: String
    package let planPath: String?
    package let planTask: Int?
    package let planText: String?
    package let specPath: String?
    package let missing: String?

    /// Direct construction for the pure review logic and its tests.
    package init(targetId: Int64, text: String, intent: String = "", missing: String? = nil) {
        self.targetId = targetId
        self.text = text
        self.intent = intent
        self.planPath = nil
        self.planTask = nil
        self.planText = nil
        self.specPath = nil
        self.missing = missing
    }
}

package struct ReviewEnvelope: Decodable, Sendable {
    package let ok: Bool
    package let error: String?
    package let round: ReviewRoundInfo?
    package let diff: ReviewDiff?
    package let from: String?
    package let to: String?
    // swiftlint:disable:next discouraged_optional_boolean
    package let previousTreeLost: Bool?
    package let old: ReviewFileSide?
    package let new: ReviewFileSide?
    // swiftlint:disable:next discouraged_optional_boolean
    package let sent: Bool?
    package let comments: Int?
    package let line: String?
    package let items: [ReviewContextItem]?
}

/// One `review_comments` row. A nil `path` is a design comment on the round.
package struct ReviewComment: FetchableRecord, Decodable, Equatable, Identifiable, Sendable {
    package enum Status: String, Decodable, Sendable { case draft, sent, carried, resolved, outdated }

    package let id: Int64
    package let roundID: Int64
    package let path: String?
    package let side: String
    package let startLine: Int
    package let endLine: Int
    package let quote: String
    package let quotePrefix: String
    package let quoteSuffix: String
    package let treeSHA: String
    package let lens: String
    package let body: String
    package let status: Status
    package let carriedFrom: Int64?
    package let agentReply: String

    private enum CodingKeys: String, CodingKey {
        case id, path, side, quote, lens, body, status
        case roundID = "round_id"
        case startLine = "start_line"
        case endLine = "end_line"
        case quotePrefix = "quote_prefix"
        case quoteSuffix = "quote_suffix"
        case treeSHA = "tree_sha"
        case carriedFrom = "carried_from"
        case agentReply = "agent_reply"
    }

    package init(
        id: Int64,
        roundID: Int64,
        path: String?,
        side: String,
        startLine: Int,
        endLine: Int,
        quote: String,
        quotePrefix: String,
        quoteSuffix: String,
        treeSHA: String,
        lens: String,
        body: String,
        status: Status,
        carriedFrom: Int64?,
        agentReply: String
    ) {
        self.id = id
        self.roundID = roundID
        self.path = path
        self.side = side
        self.startLine = startLine
        self.endLine = endLine
        self.quote = quote
        self.quotePrefix = quotePrefix
        self.quoteSuffix = quoteSuffix
        self.treeSHA = treeSHA
        self.lens = lens
        self.body = body
        self.status = status
        self.carriedFrom = carriedFrom
        self.agentReply = agentReply
    }
}
