import Foundation

/// A chapter's or a file's danger level in the review map (Go `reviewmap.Level`).
/// Never mixed with a risk's `low|medium|high` (`ReviewOverview.Risk.Level`).
package enum ReviewDangerLevel: String, Decodable, Equatable, Sendable {
    case breaking, significant, normal
}

/// The instant, AI-free map of a review round (`workbench review map --json`,
/// the `map` stream event; tech spec §2.6). Chapters come in reading order
/// (danger first, "Can skip" last); files in diff order. Decoded with
/// `.convertFromSnakeCase`, as every `workbench review` envelope.
package struct ReviewMap: Decodable, Equatable, Sendable {
    /// The noise chapter's key ("Can skip").
    package static let collapsedKey = "collapsed"

    package struct Chapter: Decodable, Equatable, Sendable, Identifiable {
        package var id: String { key }
        /// `agent:<n>`, `collapsed`, `lane:<lane>`, `lane:<lane>/<dir>[#N]` or `dir:<dir>[#N]`.
        package let key: String
        package let title: String
        package let level: ReviewDangerLevel
        package let core: Bool
        package let paths: [String]
        package let changedLines: Int
        package let lane: String?
        package let targetId: Int64?
        package let jiraKey: String?
        /// Signal id → number of the chapter's files carrying it.
        package let signalsSummary: [String: Int]

        package var isCollapsed: Bool { key == ReviewMap.collapsedKey }
    }

    package struct File: Decodable, Equatable, Sendable {
        package let path: String
        package let chapter: String
        package let level: ReviewDangerLevel
        package let signals: [String]
        package let lane: String?
        /// The file's other lanes (it was changed by more than one).
        package let also: [String]
    }

    package let chapters: [Chapter]
    package let files: [File]
    package let lanesPartial: Bool
    package let diffTruncated: Bool
    package let notes: [String]

    private enum CodingKeys: String, CodingKey { case chapters, files, lanesPartial, diffTruncated, notes }

    /// Go omits empty lists (`null` or absent): they read as `[]`.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        files = try c.decodeIfPresent([File].self, forKey: .files) ?? []
        lanesPartial = try c.decodeIfPresent(Bool.self, forKey: .lanesPartial) ?? false
        diffTruncated = try c.decodeIfPresent(Bool.self, forKey: .diffTruncated) ?? false
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    package init(chapters: [Chapter], files: [File], lanesPartial: Bool = false, diffTruncated: Bool = false, notes: [String] = []) {
        self.chapters = chapters
        self.files = files
        self.lanesPartial = lanesPartial
        self.diffTruncated = diffTruncated
        self.notes = notes
    }
}

// The decoding inits live in extensions so the memberwise inits stay.
extension ReviewMap.Chapter {
    private enum CodingKeys: String, CodingKey {
        case key, title, level, core, paths, changedLines, lane, targetId, jiraKey, signalsSummary
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try c.decode(String.self, forKey: .key),
            title: try c.decode(String.self, forKey: .title),
            level: try c.decode(ReviewDangerLevel.self, forKey: .level),
            core: try c.decodeIfPresent(Bool.self, forKey: .core) ?? false,
            paths: try c.decodeIfPresent([String].self, forKey: .paths) ?? [],
            changedLines: try c.decodeIfPresent(Int.self, forKey: .changedLines) ?? 0,
            lane: try c.decodeIfPresent(String.self, forKey: .lane),
            targetId: try c.decodeIfPresent(Int64.self, forKey: .targetId),
            jiraKey: try c.decodeIfPresent(String.self, forKey: .jiraKey),
            signalsSummary: try c.decodeIfPresent([String: Int].self, forKey: .signalsSummary) ?? [:]
        )
    }
}

extension ReviewMap.File {
    private enum CodingKeys: String, CodingKey { case path, chapter, level, signals, lane, also }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try c.decode(String.self, forKey: .path),
            chapter: try c.decode(String.self, forKey: .chapter),
            level: try c.decode(ReviewDangerLevel.self, forKey: .level),
            signals: try c.decodeIfPresent([String].self, forKey: .signals) ?? [],
            lane: try c.decodeIfPresent(String.self, forKey: .lane),
            also: try c.decodeIfPresent([String].self, forKey: .also) ?? []
        )
    }
}
