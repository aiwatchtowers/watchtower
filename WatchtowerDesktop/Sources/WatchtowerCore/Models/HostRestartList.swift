import Foundation

/// The one-time restart of sessions from a v1 session host (go hub spec
/// §8 p. 4b, asks #813, #814): every live run the old host held, written to
/// `<app support>/session-host-restart.json` before any of them is stopped.
/// A row leaves the list once its relaunch ran; rows of another workspace
/// stay until that workspace opens. The file outlives a crash or quit, so
/// the next launch resumes from it.
package struct HostRestartList: Codable, Equatable, Sendable {
    package struct Row: Codable, Equatable, Sendable {
        /// The run's scope (`SessionHostPaths.scope`); "" from a host older
        /// than the field counts as the workspace that opens.
        package let scope: String
        /// `terminal_sessions.id` in that scope's database.
        package let rowID: Int64
        /// `claude`, `codex`, or "" (a shell, or a row of another workspace,
        /// which is read from its own database at its relaunch).
        package let agent: String
        /// The agent's session id at the time of the list ("" when unknown);
        /// the relaunch resumes the row's current id.
        package let resumeID: String

        package init(scope: String, rowID: Int64, agent: String, resumeID: String) {
            self.scope = scope
            self.rowID = rowID
            self.agent = agent
            self.resumeID = resumeID
        }

        enum CodingKeys: String, CodingKey {
            case scope
            case rowID = "row_id"
            case agent
            case resumeID = "resume_id"
        }
    }

    package var rows: [Row]

    package init(rows: [Row] = []) {
        self.rows = rows
    }

    /// The file's name in Watchtower's Application Support folder.
    package static let fileName = "session-host-restart.json"

    /// `~/Library/Application Support/Watchtower/session-host-restart.json`.
    package static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Watchtower", isDirectory: true).appendingPathComponent(fileName)
    }

    /// Whether `row` belongs to the workspace of `scope` ("" from an older
    /// host counts as it, as at reattach).
    package static func row(_ row: Row, isIn scope: String) -> Bool {
        row.scope.isEmpty || row.scope == scope
    }

    /// The rows the workspace of `scope` relaunches, in list order.
    package func rows(in scope: String) -> [Row] {
        rows.filter { Self.row($0, isIn: scope) }
    }

    /// Adds `new` rows not listed yet (one per scope and row id): a second
    /// pass over a host still up keeps what the first one wrote.
    package mutating func merge(_ new: [Row]) {
        for row in new where !rows.contains(where: { $0.scope == row.scope && $0.rowID == row.rowID }) {
            rows.append(row)
        }
    }

    package mutating func remove(scope: String, rowID: Int64) {
        rows.removeAll { $0.scope == scope && $0.rowID == rowID }
    }

    /// How many rows wait in each scope other than `scope`, by scope.
    package func waiting(besides scope: String) -> [String: Int] {
        rows.reduce(into: [:]) { counts, row in
            guard !Self.row(row, isIn: scope) else { return }
            counts[row.scope, default: 0] += 1
        }
    }

    // MARK: The file

    /// The list at `url`; nil when there is no file. Throws when it exists
    /// but cannot be read or decoded.
    package static func load(from url: URL) throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    /// Writes the list atomically (0600); an empty list removes the file.
    package func save(to url: URL) throws {
        let manager = FileManager.default
        guard !rows.isEmpty else {
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            return
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
