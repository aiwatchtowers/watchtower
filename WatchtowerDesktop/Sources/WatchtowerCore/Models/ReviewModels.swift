import GRDB

// The diff reviewer's wire envelopes (`workbench review … --json`, decoded
// with `.convertFromSnakeCase`) and its comment row (spec §10).

package struct ReviewRoundInfo: Decodable, Equatable, Sendable {
    package let id: Int64
    package let status: String
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
    package let hunks: [ReviewHunk]
}

package struct ReviewDiff: Decodable, Equatable, Sendable {
    package let files: [ReviewDiffFile]
    package let truncated: Bool
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
    // swiftlint:disable:next discouraged_optional_boolean
    package let missing: Bool?
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
