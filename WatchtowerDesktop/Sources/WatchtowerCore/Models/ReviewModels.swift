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
    /// Deep mode state (`''` reads as the Meaning phase); absent in older output.
    package let phase: String
    package let chapterKey: String
    package let activeSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case id, status, mode, folderRoot, baseSha, baseLabel, treeSha, prevRoundId, prevTreeSha, prevTreeLost
        case phase, chapterKey, activeSeconds
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        status = try c.decode(String.self, forKey: .status)
        mode = try c.decode(String.self, forKey: .mode)
        folderRoot = try c.decode(String.self, forKey: .folderRoot)
        baseSha = try c.decode(String.self, forKey: .baseSha)
        baseLabel = try c.decode(String.self, forKey: .baseLabel)
        treeSha = try c.decode(String.self, forKey: .treeSha)
        prevRoundId = try c.decode(Int64.self, forKey: .prevRoundId)
        prevTreeSha = try c.decode(String.self, forKey: .prevTreeSha)
        prevTreeLost = try c.decode(Bool.self, forKey: .prevTreeLost)
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? ""
        chapterKey = try c.decodeIfPresent(String.self, forKey: .chapterKey) ?? ""
        activeSeconds = try c.decodeIfPresent(Int.self, forKey: .activeSeconds) ?? 0
    }
}

/// The Deep-mode phases stored in `review_rounds.phase` (`''` and unknown read as Meaning).
package enum ReviewPhase: String, Sendable, CaseIterable {
    case meaning, chapters, wrapup

    package init(stored: String) {
        self = Self(rawValue: stored) ?? .meaning
    }
}

/// One review lens with its checklist (built-ins plus the workbench's `review.md`).
package struct ReviewLens: Decodable, Equatable, Sendable, Identifiable {
    package struct Item: Decodable, Equatable, Sendable {
        package let key: String
        package let text: String
    }

    package let id: String
    package let name: String
    package let builtin: Bool
    package let items: [Item]
}

/// One `review_checks` row: a ticked checklist item or a Wrap-up mark.
package struct ReviewCheck: FetchableRecord, Decodable, Equatable, Sendable {
    package enum State: String, Decodable, Sendable { case checked, commented, done, partial, notDone = "not_done" }

    package let chapterKey: String
    package let lens: String
    package let itemKey: String
    package let state: State

    private enum CodingKeys: String, CodingKey {
        case lens, state
        case chapterKey = "chapter_key"
        case itemKey = "item_key"
    }
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
    package let lenses: [ReviewLens]?
    package let lensNotes: [String]?
    package let revert: RevertInfo?
    package let overview: ReviewOverview?
    // swiftlint:disable:next discouraged_optional_boolean
    package let overviewCached: Bool?
    /// Present as `[]` for `lessons propose`, absent for every other command.
    package let lessons: [ReviewLesson]?
    package let written: String?

    /// The hunk an undo reverted.
    package struct RevertInfo: Decodable, Equatable, Sendable {
        package let hunkId: String
        package let path: String
    }
}

/// One `review_notes` row: an agent note on lines or one of the agent's chapters.
package struct ReviewNote: FetchableRecord, Decodable, Equatable, Sendable, Identifiable {
    package enum Kind: String, Decodable, Sendable { case note, chapter }

    package let id: Int64
    package let kind: Kind
    package let ord: Int
    package let path: String
    package let startLine: Int
    package let endLine: Int
    package let quote: String
    package let text: String
    /// A chapter's files (`paths_json`).
    package let paths: [String]
    package let core: Bool
    package let why: String
    package let treeSHA: String

    private enum CodingKeys: String, CodingKey {
        case id, kind, ord, path, quote, text, core, why
        case startLine = "start_line"
        case endLine = "end_line"
        case paths = "paths_json"
        case treeSHA = "tree_sha"
    }
}

/// The AI overview (`workbench review overview`): the same JSON the Go cache stores.
package struct ReviewOverview: Decodable, Equatable, Sendable {
    package struct Coverage: Decodable, Equatable, Sendable {
        package enum Status: String, Decodable, Sendable { case done, partial, notFound = "not_found" }

        package let item: String
        package let status: Status
        package let `where`: [String]
    }

    package struct Risk: Decodable, Equatable, Sendable {
        package enum Level: String, Decodable, Sendable { case low, medium, high }

        package let path: String
        package let level: Level
        package let why: String
    }

    package struct Chapter: Decodable, Equatable, Sendable {
        package let title: String
        package let paths: [String]
        package let core: Bool
        package let lenses: [String]
    }

    package let summary: String
    package let coverage: [Coverage]
    package let outOfScope: [String]
    package let risk: [Risk]
    package let chapters: [Chapter]

    private enum CodingKeys: String, CodingKey { case summary, coverage, outOfScope, risk, chapters }

    /// Go omits empty lists (`null` or absent): they read as `[]`.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary)
        coverage = try c.decodeIfPresent([Coverage].self, forKey: .coverage) ?? []
        outOfScope = try c.decodeIfPresent([String].self, forKey: .outOfScope) ?? []
        risk = try c.decodeIfPresent([Risk].self, forKey: .risk) ?? []
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
    }
}

// The decoding inits live in extensions so the memberwise inits stay.
extension ReviewOverview.Coverage {
    private enum CodingKeys: String, CodingKey { case item, status, `where` }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            item: try c.decode(String.self, forKey: .item),
            status: try c.decode(Status.self, forKey: .status),
            where: try c.decodeIfPresent([String].self, forKey: .where) ?? []
        )
    }
}

extension ReviewOverview.Chapter {
    private enum CodingKeys: String, CodingKey { case title, paths, core, lenses }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decode(String.self, forKey: .title),
            paths: try c.decodeIfPresent([String].self, forKey: .paths) ?? [],
            core: try c.decodeIfPresent(Bool.self, forKey: .core) ?? false,
            lenses: try c.decodeIfPresent([String].self, forKey: .lenses) ?? []
        )
    }
}

/// One `review_reverts` row: a hunk the owner undid in the round.
package struct ReviewRevert: FetchableRecord, Decodable, Equatable, Sendable {
    package let hunkID: String
    package let path: String
    package let header: String
    package let at: String

    private enum CodingKeys: String, CodingKey {
        case path, header, at
        case hunkID = "hunk_id"
    }
}

/// One `review_lessons` row: a proposed house rule. The same type decodes the
/// `lessons` envelope (wire key `source_comment_ids`, an array) and the row
/// (column of the same name, JSON text — GRDB decodes it as JSON).
package struct ReviewLesson: FetchableRecord, Decodable, Equatable, Sendable, Identifiable {
    package let id: Int64
    package let lens: String
    package let text: String
    package let sourceCommentIDs: [Int64]
    package let status: String

    private enum CodingKeys: String, CodingKey {
        case id, lens, text, status
        case sourceCommentIDsRow = "source_comment_ids"
        case sourceCommentIDsWire = "sourceCommentIds"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        lens = try c.decode(String.self, forKey: .lens)
        text = try c.decode(String.self, forKey: .text)
        status = try c.decode(String.self, forKey: .status)
        sourceCommentIDs = try c.decodeIfPresent([Int64].self, forKey: .sourceCommentIDsWire)
            ?? c.decodeIfPresent([Int64].self, forKey: .sourceCommentIDsRow) ?? []
    }

    package init(id: Int64, lens: String, text: String, sourceCommentIDs: [Int64], status: String) {
        self.id = id
        self.lens = lens
        self.text = text
        self.sourceCommentIDs = sourceCommentIDs
        self.status = status
    }
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
    /// Set when the agent replied (and maybe resolved) through `reply_review_comment`.
    package let agentReplyAt: String?

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
        case agentReplyAt = "agent_reply_at"
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
        agentReply: String,
        agentReplyAt: String? = nil
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
        self.agentReplyAt = agentReplyAt
    }
}
