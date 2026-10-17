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

    package init(
        row: Int64,
        run: String,
        executable: String,
        args: [String],
        env: [String],
        cwd: String,
        cols: Int,
        rows: Int
    ) {
        self.row = row
        self.run = run
        self.executable = executable
        self.args = args
        self.env = env
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
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

    package init(row: Int64, run: String, pid: Int, startedAtMs: Int64, exited: Bool, code: Int?) {
        self.row = row
        self.run = run
        self.pid = pid
        self.startedAtMs = startedAtMs
        self.exited = exited
        self.code = code
    }

    enum CodingKeys: String, CodingKey {
        case row, run, pid, exited, code
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
