import Foundation

// Codable mirrors of the Go session host's JSON payloads (a dual path:
// keep the keys in step with `internal/sessionhost`).

package struct SessionHostLaunchRequest: Codable, Equatable, Sendable {
    package let row: Int64
    package let run: String
    package let executable: String
    package let args: [String]
    package let env: [String]
    package let cwd: String
    package let cols: Int
    package let rows: Int
    /// The workspace the row id belongs to (`SessionHostPaths.scope`); the
    /// host stores it and lists it back.
    package let scope: String

    package init(
        row: Int64,
        run: String,
        executable: String,
        args: [String],
        env: [String],
        cwd: String,
        cols: Int,
        rows: Int,
        scope: String = ""
    ) {
        self.row = row
        self.run = run
        self.executable = executable
        self.args = args
        self.env = env
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.scope = scope
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        row = try container.decode(Int64.self, forKey: .row)
        run = try container.decode(String.self, forKey: .run)
        executable = try container.decode(String.self, forKey: .executable)
        args = try container.decode([String].self, forKey: .args)
        env = try container.decode([String].self, forKey: .env)
        cwd = try container.decode(String.self, forKey: .cwd)
        cols = try container.decode(Int.self, forKey: .cols)
        rows = try container.decode(Int.self, forKey: .rows)
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? ""
    }
}

package struct SessionHostAttachRequest: Codable, Equatable, Sendable {
    package let row: Int64
    package let run: String

    package init(row: Int64, run: String) {
        self.row = row
        self.run = run
    }
}

package struct SessionHostSessionInfo: Codable, Equatable, Sendable {
    package let row: Int64
    package let run: String
    package let pid: Int
    package let startedAtMs: Int64
    package let exited: Bool
    /// Nil while running, or when the process died by a signal.
    package let code: Int?
    /// The launch's scope; "" from a host older than the field.
    package let scope: String

    package init(row: Int64, run: String, pid: Int, startedAtMs: Int64, exited: Bool, code: Int?, scope: String = "") {
        self.row = row
        self.run = run
        self.pid = pid
        self.startedAtMs = startedAtMs
        self.exited = exited
        self.code = code
        self.scope = scope
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        row = try container.decode(Int64.self, forKey: .row)
        run = try container.decode(String.self, forKey: .run)
        pid = try container.decode(Int.self, forKey: .pid)
        startedAtMs = try container.decode(Int64.self, forKey: .startedAtMs)
        exited = try container.decode(Bool.self, forKey: .exited)
        code = try container.decodeIfPresent(Int.self, forKey: .code)
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case row, run, pid, exited, code, scope
        case startedAtMs = "started_at_ms"
    }
}

package struct SessionHostListResponse: Codable, Equatable, Sendable {
    package let sessions: [SessionHostSessionInfo]

    package init(sessions: [SessionHostSessionInfo]) {
        self.sessions = sessions
    }
}

package struct SessionHostResize: Codable, Equatable, Sendable {
    package let cols: Int
    package let rows: Int

    package init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

package struct SessionHostExit: Codable, Equatable, Sendable {
    package let code: Int?

    package init(code: Int?) {
        self.code = code
    }
}
