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

    /// What is on disk: no file, a list, or a file that cannot be read or
    /// decoded — never taken for "no list" and never overwritten.
    package enum Stored: Equatable {
        case absent
        case list(HostRestartList)
        case unreadable
    }

    package static func stored(at url: URL) -> Stored {
        do {
            return try load(from: url).map(Stored.list) ?? .absent
        } catch {
            return .unreadable
        }
    }

    /// The name an unreadable list is set aside under, on the owner's word.
    package static func setAsideURL(for url: URL) -> URL {
        url.appendingPathExtension("corrupt")
    }

    /// Moves an unreadable list aside (`<name>.corrupt`, replacing an older
    /// one), so the next look starts without a list.
    package static func setAside(_ url: URL) throws {
        let aside = setAsideURL(for: url)
        let manager = FileManager.default
        if manager.fileExists(atPath: aside.path) { try manager.removeItem(at: aside) }
        try manager.moveItem(at: url, to: aside)
    }

    /// Writes the list into a 0600 temp file beside `url`, then renames it
    /// over `url` (one atomic step; the file is never readable by others,
    /// not even for a moment). An empty list removes the file.
    package func save(to url: URL) throws {
        let manager = FileManager.default
        guard !rows.isEmpty else {
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            return
        }
        let dir = url.deletingLastPathComponent()
        try manager.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        // Created 0600 from the start (O_EXCL: never someone else's file).
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? manager.removeItem(at: temp)
            throw error
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? manager.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
