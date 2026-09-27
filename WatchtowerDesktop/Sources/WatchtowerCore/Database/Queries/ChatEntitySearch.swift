import Foundation
import GRDB

/// What the chat composer and the project source picker can point at.
package enum ChatEntityKind: String, CaseIterable, Sendable {
    case person
    case channel
    case jiraIssue = "jira"
    case jiraProject = "jira_project"
    case target
    case track
}

/// One local-DB entity found by a prefix search. `ref` is the id the model's
/// `get_*` tools take: a namespaced Slack user/channel id, an issue key, a
/// project key, or a target/track row id.
package struct ChatEntityHit: Equatable, Hashable, Sendable {
    package let kind: ChatEntityKind
    package let ref: String
    package let label: String
    package let detail: String

    package init(kind: ChatEntityKind, ref: String, label: String, detail: String) {
        self.kind = kind
        self.ref = ref
        self.label = label
        self.detail = detail
    }
}

extension ChatProjectSource.Kind {
    /// The project-source kind for a search hit; nil for a Jira issue, which
    /// can be mentioned but not pinned (a project pins the whole Jira project).
    package init?(entity: ChatEntityKind) {
        switch entity {
        case .person: self = .person
        case .channel: self = .slackChannel
        case .jiraProject: self = .jiraProject
        case .target: self = .target
        case .track: self = .track
        case .jiraIssue: return nil
        }
    }
}

/// Prefix search over the local DB (spec §6.2: people, Slack channels, Jira
/// issues, targets, tracks — prefix match, 8 results), plus Jira project keys
/// for the project source picker. Pure reads; every function is bounded by
/// `limit`.
package enum ChatEntitySearch {
    package static let defaultLimit = 8

    package static func search(
        _ db: Database, kind: ChatEntityKind, query: String, limit: Int = defaultLimit
    ) throws -> [ChatEntityHit] {
        switch kind {
        case .person: return try people(db, query: query, limit: limit)
        case .channel: return try channels(db, query: query, limit: limit)
        case .jiraIssue: return try jiraIssues(db, query: query, limit: limit)
        case .jiraProject: return try jiraProjects(db, query: query, limit: limit)
        case .target: return try targets(db, query: query, limit: limit)
        case .track: return try tracks(db, query: query, limit: limit)
        }
    }

    package static func people(_ db: Database, query: String, limit: Int = defaultLimit) throws -> [ChatEntityHit] {
        let match = PrefixMatch(query).clause(columns: ["name", "display_name", "real_name"])
        var args = StatementArguments(match.args)
        args += [limit]
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name,
                       COALESCE(NULLIF(display_name, ''), NULLIF(real_name, ''), name) AS label
                FROM users
                WHERE is_bot = 0 AND is_deleted = 0 AND is_stub = 0 AND \(match.sql)
                ORDER BY label COLLATE NOCASE, id
                LIMIT ?
                """,
            arguments: args
        )
        return rows.map { row in
            ChatEntityHit(kind: .person, ref: row["id"], label: row["label"], detail: "@" + (row["name"] as String))
        }
    }

    package static func channels(_ db: Database, query: String, limit: Int = defaultLimit) throws -> [ChatEntityHit] {
        let match = PrefixMatch(query).clause(columns: ["name"])
        var args = StatementArguments(match.args)
        args += [limit]
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name FROM channels
                WHERE type IN ('public', 'private') AND is_archived = 0 AND \(match.sql)
                ORDER BY is_member DESC, name COLLATE NOCASE, id
                LIMIT ?
                """,
            arguments: args
        )
        return rows.map { row in
            ChatEntityHit(kind: .channel, ref: row["id"], label: "#" + (row["name"] as String), detail: "Slack channel")
        }
    }

    /// Key prefix (`pay-1` → `PAY-12`) or summary word prefix. A key shared by
    /// two Jira sites is one hit (the multi-account bare-key convention).
    package static func jiraIssues(_ db: Database, query: String, limit: Int = defaultLimit) throws -> [ChatEntityHit] {
        let prefix = PrefixMatch(query)
        let summary = prefix.clause(columns: ["summary"])
        let keyPattern = PrefixMatch.escape(query.trimmingCharacters(in: .whitespaces).uppercased()) + "%"
        var args: StatementArguments = [keyPattern]
        args += StatementArguments(summary.args)
        args += [limit]
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT key, summary, MAX(updated_at) AS newest FROM jira_issues
                WHERE is_deleted = 0 AND (key LIKE ? ESCAPE '\\' OR \(summary.sql))
                GROUP BY key
                ORDER BY newest DESC, key
                LIMIT ?
                """,
            arguments: args
        )
        return rows.map { row in
            ChatEntityHit(kind: .jiraIssue, ref: row["key"], label: row["key"], detail: row["summary"])
        }
    }

    package static func jiraProjects(_ db: Database, query: String, limit: Int = defaultLimit) throws -> [ChatEntityHit] {
        let pattern = PrefixMatch.escape(query.trimmingCharacters(in: .whitespaces).uppercased()) + "%"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT project_key, COUNT(DISTINCT key) AS n FROM jira_issues
                WHERE is_deleted = 0 AND project_key LIKE ? ESCAPE '\\'
                GROUP BY project_key
                ORDER BY project_key
                LIMIT ?
                """,
            arguments: [pattern, limit]
        )
        return rows.map { row in
            let count: Int = row["n"]
            return ChatEntityHit(
                kind: .jiraProject, ref: row["project_key"], label: row["project_key"],
                detail: count == 1 ? "1 issue" : "\(count) issues"
            )
        }
    }

    package static func targets(_ db: Database, query: String, limit: Int = defaultLimit) throws -> [ChatEntityHit] {
        let match = PrefixMatch(query).clause(columns: ["text"])
        var args = StatementArguments(match.args)
        args += [limit]
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, text, status FROM targets
                WHERE status NOT IN ('done', 'dismissed') AND \(match.sql)
                ORDER BY updated_at DESC, id DESC
                LIMIT ?
                """,
            arguments: args
        )
        return rows.map { row in
            let id: Int64 = row["id"]
            return ChatEntityHit(kind: .target, ref: String(id), label: firstLine(row["text"]), detail: row["status"])
        }
    }

    package static func tracks(_ db: Database, query: String, limit: Int = defaultLimit) throws -> [ChatEntityHit] {
        let match = PrefixMatch(query).clause(columns: ["text"])
        var args = StatementArguments(match.args)
        args += [limit]
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, text, priority FROM tracks
                WHERE dismissed_at = '' AND \(match.sql)
                ORDER BY updated_at DESC, id DESC
                LIMIT ?
                """,
            arguments: args
        )
        return rows.map { row in
            let id: Int64 = row["id"]
            return ChatEntityHit(
                kind: .track, ref: String(id), label: firstLine(row["text"]),
                detail: "track · " + (row["priority"] as String)
            )
        }
    }

    /// First non-empty line, capped at 60 characters — a label, not the text.
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(59)) + "…"
    }
}

/// A prefix / word-prefix LIKE matcher. SQLite `LIKE` folds ASCII case only,
/// so the query's first letter is also tried upper- and lower-cased (`ива`
/// finds `Иван`); `%`, `_` and `\` are escaped so they match literally. An
/// empty query matches everything (`1`).
struct PrefixMatch {
    let patterns: [String]

    init(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            patterns = []
            return
        }
        var variants: [String] = [query]
        for variant in [query.prefix(1).uppercased() + query.dropFirst(),
                        query.prefix(1).lowercased() + query.dropFirst()]
        where !variants.contains(variant) {
            variants.append(variant)
        }
        patterns = variants.flatMap { variant -> [String] in
            let escaped = Self.escape(variant)
            return [escaped + "%", "% " + escaped + "%"]
        }
    }

    func clause(columns: [String]) -> (sql: String, args: [String]) {
        guard !patterns.isEmpty else { return ("1", []) }
        var parts: [String] = []
        var args: [String] = []
        for column in columns {
            for pattern in patterns {
                parts.append("\(column) LIKE ? ESCAPE '\\'")
                args.append(pattern)
            }
        }
        return ("(" + parts.joined(separator: " OR ") + ")", args)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
