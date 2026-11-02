import Foundation
import WatchtowerCore

/// The `watchtower hub …` verbs Settings → Mobile reads and drives (go hub
/// plan 3 Task 23). Every read is `--json` with the CLI's pinned keys; the
/// Desktop never opens the hub's own database (Task 24 guard).
struct MobileHubCLI {
    /// `hub status --json` (Plan 1a keys, Phase 2 `recordings`, Task 13
    /// `kept_recordings`, Task 21 `bridge`/`switched_at`/`switched_by`, Task 23
    /// `name`). Unknown or absent keys decode as nil.
    struct Status: Decodable, Equatable {
        struct Kept: Decodable, Equatable {
            let count: Int
            let removeAt: Date
            let dir: String

            enum CodingKeys: String, CodingKey {
                case count, dir
                case removeAt = "remove_at"
            }
        }

        let state: String
        let reason: String?
        let transport: String?
        let recordings: String?
        let name: String?
        let bridge: String?
        let switchedAt: Date?
        let switchedBy: String?
        let keptRecordings: Kept?

        enum CodingKeys: String, CodingKey {
            case state, reason, transport, recordings, name, bridge
            case switchedAt = "switched_at"
            case switchedBy = "switched_by"
            case keptRecordings = "kept_recordings"
        }

        init(
            state: String,
            reason: String? = nil,
            transport: String? = nil,
            recordings: String? = nil,
            name: String? = nil,
            bridge: String? = nil,
            switchedAt: Date? = nil,
            switchedBy: String? = nil,
            keptRecordings: Kept? = nil
        ) {
            self.state = state
            self.reason = reason
            self.transport = transport
            self.recordings = recordings
            self.name = name
            self.bridge = bridge
            self.switchedAt = switchedAt
            self.switchedBy = switchedBy
            self.keptRecordings = keptRecordings
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) throws -> String? {
                let value = try c.decodeIfPresent(String.self, forKey: key)
                return value?.isEmpty == false ? value : nil
            }
            state = try c.decode(String.self, forKey: .state)
            reason = try text(.reason)
            transport = try text(.transport)
            recordings = try text(.recordings)
            name = try text(.name)
            bridge = try text(.bridge)
            switchedAt = try text(.switchedAt).flatMap(MobileHubCLI.date)
            switchedBy = try text(.switchedBy)
            keptRecordings = try c.decodeIfPresent(Kept.self, forKey: .keptRecordings)
        }
    }

    /// One `hub phones --json` element.
    struct Phone: Decodable, Equatable {
        let deviceID: String
        let name: String
        let scope: String
        let linkedAt: Date
        let typingAllowed: Bool
        let typingRequested: Bool
        let permissionsAllowed: Bool
        let permissionsRequested: Bool
        let startSessionsAllowed: Bool
        let startSessionsGranted: Bool
        let transport: String

        enum CodingKeys: String, CodingKey {
            case name, scope, transport
            case deviceID = "device_id"
            case linkedAt = "linked_at"
            case typingAllowed = "typing_allowed"
            case typingRequested = "typing_requested"
            case permissionsAllowed = "permissions_allowed"
            case permissionsRequested = "permissions_requested"
            case startSessionsAllowed = "start_sessions_allowed"
            case startSessionsGranted = "start_sessions_granted"
        }
    }

    /// `hub recording list --json` (Task 17): `ready` false = no queue yet.
    struct RecordingJobs: Decodable, Equatable {
        struct Job: Decodable, Equatable {
            let uploadID: String
            let status: String
            let errorClass: String?

            enum CodingKeys: String, CodingKey {
                case status
                case uploadID = "upload_id"
                case errorClass = "error_class"
            }
        }

        let ready: Bool
        let jobs: [Job]
    }

    /// nil: the watchtower binary was not found; every call throws.
    let runner: (any CLIRunnerProtocol)?

    nonisolated static let statusArgs = ["hub", "status", "--json"]
    nonisolated static let phonesArgs = ["hub", "phones", "--json"]
    nonisolated static let recordingJobsArgs = ["hub", "recording", "list", "--json"]

    nonisolated static func enabledArgs(_ on: Bool) -> [String] { ["hub", on ? "enable" : "disable", "--json"] }
    nonisolated static func recordingsArgs(_ on: Bool) -> [String] { ["hub", "recordings", on ? "on" : "off", "--json"] }
    nonisolated static func allowArgs(_ id: String, _ grant: String, _ on: Bool) -> [String] {
        ["hub", "allow", id, grant, "--json"] + (on ? [] : ["--revoke"])
    }
    nonisolated static func unlinkArgs(_ id: String) -> [String] { ["hub", "unlink", id, "--json"] }
    nonisolated static func nameArgs(_ name: String) -> [String] { ["hub", "name", name, "--json"] }
    nonisolated static func claimArgs(_ id: String) -> [String] { ["hub", "recording", "claim", "--upload", id, "--json"] }
    nonisolated static func discardArgs(_ id: String) -> [String] { ["hub", "recording", "discard", "--upload", id, "--json"] }

    func status() async throws -> Status { try Self.decoder.decode(Status.self, from: await output(Self.statusArgs)) }
    func phones() async throws -> [Phone] { try Self.decoder.decode([Phone].self, from: await output(Self.phonesArgs)) }
    func recordingJobs() async throws -> RecordingJobs {
        try Self.decoder.decode(RecordingJobs.self, from: await output(Self.recordingJobsArgs))
    }

    func run(_ args: [String]) async throws { _ = try await output(args) }

    private func output(_ args: [String]) async throws -> Data {
        guard let runner else { throw CLIRunnerError.binaryNotFound }
        return try await runner.run(args: args)
    }

    /// The CLI's own sentence for a refusal (`Error: <text>` on stderr), else
    /// the error's description.
    nonisolated static func reason(_ error: any Error) -> String {
        guard case let CLIRunnerError.nonZeroExit(_, stderr) = error else { return error.localizedDescription }
        let line = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("Error: ") { text.removeFirst("Error: ".count) }
        guard let first = text.first else { return error.localizedDescription }
        text = first.uppercased() + text.dropFirst()
        return text.hasSuffix(".") ? text : text + "."
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.date(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an RFC 3339 time"))
            }
            return date
        }
        return d
    }()

    /// An RFC 3339 time as Go writes it, with or without fractional seconds.
    nonisolated static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
