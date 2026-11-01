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
    /// `claude`, `codex` or "" (a shell): the host types lines into the run
    /// with that agent's input profile (Go `ProfileFor`).
    package let agent: String

    package init(
        row: Int64,
        run: String,
        executable: String,
        args: [String],
        env: [String],
        cwd: String,
        cols: Int,
        rows: Int,
        scope: String = "",
        agent: String = ""
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
        self.agent = agent
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
        agent = try container.decodeIfPresent(String.self, forKey: .agent) ?? ""
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
    /// The host's per-row launch counter (v2); 0 from a v1 host. A delivery
    /// and a stop name it, so neither reaches a newer run.
    package let launch: UInt64

    package init(
        row: Int64, run: String, pid: Int, startedAtMs: Int64, exited: Bool, code: Int?, scope: String = "", launch: UInt64 = 0
    ) {
        self.row = row
        self.run = run
        self.pid = pid
        self.startedAtMs = startedAtMs
        self.exited = exited
        self.code = code
        self.scope = scope
        self.launch = launch
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
        launch = try container.decodeIfPresent(UInt64.self, forKey: .launch) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case row, run, pid, exited, code, scope, launch
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
    /// The exit followed a Stop (the owner stopped the session); a natural
    /// exit never carries it.
    package let requested: Bool

    package init(code: Int?, requested: Bool = false) {
        self.code = code
        self.requested = requested
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(Int.self, forKey: .code)
        requested = try container.decodeIfPresent(Bool.self, forKey: .requested) ?? false
    }
}

// MARK: - Protocol v2: delivery, dialog hint, stop (Go `deliver.go`, `frame.go`)

/// Go `DeliverReq`: one line the host types into a session — one bracketed
/// paste, then after the pause one Return of its own only into a prompt
/// that held nothing before and after it (PROJ-12).
package struct DeliverRequest: Codable, Equatable, Sendable {
    package var id: String
    package let row: Int64
    package let run: String
    package let launch: UInt64
    package let text: String
    package let keepLineBreaks: Bool
    package let keepFormat: Bool
    /// The pause between paste and Return; 0 uses the agent profile's.
    package let settleMs: Int
    /// The caller's pre-check: false only pastes.
    package let submitIf: Bool
    /// Write nothing while the prompt holds text (PROJ-16's phone lines).
    package let holdIfPromptText: Bool

    package init(
        id: String = "",
        row: Int64,
        run: String,
        launch: UInt64,
        text: String,
        keepLineBreaks: Bool = false,
        keepFormat: Bool = false,
        settleMs: Int = 0,
        submitIf: Bool,
        holdIfPromptText: Bool = false
    ) {
        self.id = id
        self.row = row
        self.run = run
        self.launch = launch
        self.text = text
        self.keepLineBreaks = keepLineBreaks
        self.keepFormat = keepFormat
        self.settleMs = settleMs
        self.submitIf = submitIf
        self.holdIfPromptText = holdIfPromptText
    }

    enum CodingKeys: String, CodingKey {
        case id, row, run, launch, text
        case keepLineBreaks = "keep_line_breaks"
        case keepFormat = "keep_format"
        case settleMs = "settle_ms"
        case submitIf = "submit_if"
        case holdIfPromptText = "hold_if_prompt_text"
    }
}

/// Go `DeliverCheckMsg`: after the pause the host asks for a re-check.
package struct DeliverCheck: Codable, Equatable, Sendable {
    package let id: String

    package init(id: String) {
        self.id = id
    }
}

/// Go `DeliverCheckReplyMsg`. `fresh`: the re-read succeeded; `canSubmit`:
/// the caller's conditions for a Return still hold; `answersDialog`: a
/// permission dialog is up, so an owner's Return in the pause may have
/// answered it.
package struct DeliverCheckReply: Codable, Equatable, Sendable {
    package var id: String
    package let fresh: Bool
    package let canSubmit: Bool
    package let answersDialog: Bool

    package init(id: String = "", fresh: Bool, canSubmit: Bool, answersDialog: Bool = false) {
        self.id = id
        self.fresh = fresh
        self.canSubmit = canSubmit
        self.answersDialog = answersDialog
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fresh = try container.decode(Bool.self, forKey: .fresh)
        canSubmit = try container.decode(Bool.self, forKey: .canSubmit)
        answersDialog = try container.decodeIfPresent(Bool.self, forKey: .answersDialog) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case id, fresh
        case canSubmit = "can_submit"
        case answersDialog = "answers_dialog"
    }
}

/// Go `DeliveredMsg`.
package struct DeliveredMessage: Codable, Equatable, Sendable {
    package let id: String
    package let outcome: String
    package let reason: String?

    package init(id: String, outcome: String, reason: String? = nil) {
        self.id = id
        self.outcome = outcome
        self.reason = reason
    }
}

/// Where a delivery went (Go's `Outcome*` values).
package enum DeliverOutcome: Equatable, Sendable {
    /// Pasted, then Return — the host's, or the owner's own in the pause.
    case submitted
    /// Pasted and left in the prompt without its Return.
    case typed
    /// Nothing written, for the host's reason (`prompt_has_text`).
    case held(String)
    /// No running session of that row, run and launch.
    case noSession
    /// Bracketed paste is off: nothing written.
    case noPasteMode
    /// Not a host answer: the delivery's connection ended (dropped, or no
    /// answer in time) after the host took the request, so the line may
    /// have been typed, submitted or not.
    case interrupted

    /// The host's outcome; an unknown one reads as no session (nothing is
    /// known to be typed).
    package init(_ message: DeliveredMessage) {
        switch message.outcome {
        case "submitted": self = .submitted
        case "typed": self = .typed
        case "held": self = .held(message.reason ?? "")
        case "no_paste_mode": self = .noPasteMode
        default: self = .noSession
        }
    }
}

/// Go `DeliveryEventMsg`: what a delivery did, sent to the session's
/// attached client so its pane keeps showing its hints.
package struct SessionHostDeliveryEvent: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable {
        case pasted
        case leftTyped = "left_typed"
        case submitted
    }

    package let row: Int64
    package let run: String
    package let kind: Kind
    /// With `leftTyped`: the line shares the prompt with other text not
    /// submitted, so the owner's Return sends them together.
    package let besideText: Bool

    package init(row: Int64, run: String, kind: Kind, besideText: Bool = false) {
        self.row = row
        self.run = run
        self.kind = kind
        self.besideText = besideText
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        row = try container.decode(Int64.self, forKey: .row)
        run = try container.decode(String.self, forKey: .run)
        kind = try container.decode(Kind.self, forKey: .kind)
        besideText = try container.decodeIfPresent(Bool.self, forKey: .besideText) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case row, run, kind
        case besideText = "beside_text"
    }
}

/// Go `PromptHintMsg`: whether a permission dialog is up in the session (the
/// app reads the hook states; the host cannot).
package struct SessionHostPromptHint: Codable, Equatable, Sendable {
    package let row: Int64
    package let run: String
    package let dialog: Bool

    package init(row: Int64, run: String, dialog: Bool) {
        self.row = row
        self.run = run
        self.dialog = dialog
    }
}

/// Go `StopReq`: SIGHUP to the run's process group, SIGKILL after the
/// host's grace; the run's Exit then carries `requested`.
package struct SessionHostStopRequest: Codable, Equatable, Sendable {
    package let row: Int64
    package let run: String
    package let launch: UInt64

    package init(row: Int64, run: String, launch: UInt64) {
        self.row = row
        self.run = run
        self.launch = launch
    }
}
