import Foundation

/// The JSON `watchtower workbench session-probe` prints (Go
/// `sessionProbeResult` / `sessionProbeFailure`, spec
/// 2026-10-10-session-background-agents §10): `{ok: true, outcome, ended,
/// agent_background_at}` or `{ok: false, error}`, exit 0 either way.
package struct SessionProbeResult: Decodable, Equatable, Sendable {
    /// What the probe read. `busy` and `waiting` leave the count alone;
    /// `idle`, `shell`, `unknown` and `gone` end it (Go writes, the Desktop
    /// only reads the row again).
    package enum Outcome: String, Decodable, Sendable {
        case notStale = "not_stale"
        case busy, waiting, idle, shell, unknown, gone

        /// An outcome this build does not know reads as `unknown`: the probe
        /// ran, the Desktop has nothing to do with its answer.
        package init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: raw) ?? .unknown
        }
    }

    package let ok: Bool
    /// nil when `ok` is false.
    package let outcome: Outcome?
    /// This probe cleared the count; false on an ending outcome means a
    /// report or a Stop landed first.
    package let ended: Bool
    /// The report stamp the probe read; nil or "" when the row has none.
    package let agentBackgroundAt: String?
    /// Why the probe could not run; nil when `ok`.
    package let error: String?

    package init(
        ok: Bool, outcome: Outcome?, ended: Bool = false, agentBackgroundAt: String? = nil, error: String? = nil
    ) {
        self.ok = ok
        self.outcome = outcome
        self.ended = ended
        self.agentBackgroundAt = agentBackgroundAt
        self.error = error
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        outcome = try container.decodeIfPresent(Outcome.self, forKey: .outcome)
        ended = try container.decodeIfPresent(Bool.self, forKey: .ended) ?? false
        agentBackgroundAt = try container.decodeIfPresent(String.self, forKey: .agentBackgroundAt)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    /// The probe ran: `ok` with an outcome. Anything else is a failed probe.
    package var ran: Bool { ok && outcome != nil }

    private enum CodingKeys: String, CodingKey {
        case ok, outcome, ended, error
        case agentBackgroundAt = "agent_background_at"
    }
}
