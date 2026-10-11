import Foundation

/// The JSON `watchtower workbench escalate-question` prints (Go
/// `escalateResult`, spec 2026-10-10-owner-asks-v2 Part 5.3): `{ok: true,
/// outcome: "filed", ask_id, level}`, `{ok: true, outcome: "gone"}` or
/// `{ok: false, error_code, error}`, exit 0 either way. Keys this build does
/// not know are ignored.
package struct ChatQuestionEscalationResult: Decodable, Equatable, Sendable {
    package enum Outcome: Equatable, Sendable {
        /// The question became ask `askID`; Go cleared it from the session.
        case filed
        /// The question was no longer there to raise: answered, replaced,
        /// or the session moved off `waiting`. Nothing written.
        case gone
        /// An outcome this build does not know.
        case other(String)

        init(raw: String) {
            switch raw {
            case "filed": self = .filed
            case "gone": self = .gone
            default: self = .other(raw)
            }
        }
    }

    /// Why Go wrote nothing. `busy` and `openCap` leave the question in
    /// place and are worth another try; every other code is not.
    /// `launchFailed` is the Desktop's own: the binary could not be started
    /// (the CLI store mid-replace), so nothing ran — worth another try too.
    package enum ErrorCode: Equatable, Sendable {
        case busy, openCap, notFound, badArgs, schema, `internal`, launchFailed
        /// A code this build does not know: not retried.
        case other(String)

        init(raw: String) {
            switch raw {
            case "busy": self = .busy
            case "open_cap": self = .openCap
            case "not_found": self = .notFound
            case "bad_args": self = .badArgs
            case "schema": self = .schema
            case "internal": self = .internal
            default: self = .other(raw)
            }
        }

        package var isTransient: Bool { self == .busy || self == .openCap || self == .launchFailed }
    }

    /// What the runner does with a result.
    package enum Verdict: Equatable, Sendable {
        case filed(askID: Int64?)
        case gone
        /// Retried later (at most once a minute).
        case transient(String)
        /// Not retried for this question.
        case failed(String)
    }

    package let ok: Bool
    /// nil when `ok` is false.
    package let outcome: Outcome?
    package let askID: Int64?
    package let level: OwnerAskLevel?
    package let errorCode: ErrorCode?
    package let error: String?

    package init(
        ok: Bool,
        outcome: Outcome? = nil,
        askID: Int64? = nil,
        level: OwnerAskLevel? = nil,
        errorCode: ErrorCode? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.outcome = outcome
        self.askID = askID
        self.level = level
        self.errorCode = errorCode
        self.error = error
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome).map(Outcome.init(raw:))
        askID = try container.decodeIfPresent(Int64.self, forKey: .askID)
        // An unknown level is not this runner's concern: the asks reload reads the row.
        level = try container.decodeIfPresent(String.self, forKey: .level).flatMap(OwnerAskLevel.init(rawValue:))
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode).map(ErrorCode.init(raw:))
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    /// The Desktop's own envelope for a run that printed no readable result
    /// — a non-zero exit, a launch failure, unparsable stdout: not retried.
    package static func failure(_ message: String) -> Self {
        Self(ok: false, errorCode: .internal, error: message)
    }

    /// The Desktop's own envelope for a run whose binary could not be
    /// started: retried.
    package static func launchFailure(_ message: String) -> Self {
        Self(ok: false, errorCode: .launchFailed, error: message)
    }

    package var verdict: Verdict {
        guard ok else {
            let code = errorCode ?? .other("")
            let message = "\(code.label): \(error ?? "no error text")"
            return code.isTransient ? .transient(message) : .failed(message)
        }
        switch outcome {
        case .filed: return .filed(askID: askID)
        case .gone: return .gone
        case let .other(raw): return .failed("unknown outcome \(raw)")
        case nil: return .failed("no outcome")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case ok, outcome, level, error
        case askID = "ask_id"
        case errorCode = "error_code"
    }
}

private extension ChatQuestionEscalationResult.ErrorCode {
    /// The wire name, for the log.
    var label: String {
        switch self {
        case .busy: "busy"
        case .openCap: "open_cap"
        case .notFound: "not_found"
        case .badArgs: "bad_args"
        case .schema: "schema"
        case .internal: "internal"
        case .launchFailed: "launch failed"
        case let .other(raw): raw.isEmpty ? "no error_code" : raw
        }
    }
}
