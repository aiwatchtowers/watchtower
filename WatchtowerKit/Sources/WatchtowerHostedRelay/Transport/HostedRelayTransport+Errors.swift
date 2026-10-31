import Foundation
import WatchtowerRelayProto
import WatchtowerSync

/// The relay's answers as Phase 1's `TransportRefusal` (R6, no new cases; pinned by
/// `testErrorMapping`), the side signals (`TransportEvent`, `relayEvents`) and the attestation
/// gate.
extension HostedRelayTransport {
    /// R6's table. A response lost after the request was sent cannot be told from one never
    /// sent (the client answers both `.unreachable`), so both are `.unreachable`.
    static func refusal(for error: any Error) -> TransportRefusal {
        if error is CancellationError { return .transient(code: "cancelled") }
        guard let error = error as? HostedRelayError else { return .unreachable }
        switch error {
        case let .server(code, retryAfter):
            return refusal(code: code, retryAfter: retryAfter)
        case .unsupportedVersion, .unreachable:
            return .unreachable
        case .undecodable(let status):
            return (500..<600).contains(status) ? .unreachable : .transient(code: "malformed_answer")
        case .attestation(.retryLater):
            return .transient(code: "attestation_backoff")
        case .attestation(.notSupported), .attestation(.updateRequired):
            return .unreachable
        }
    }

    static func refusal(code: Relay_V1_ErrorCode, retryAfter: UInt32?) -> TransportRefusal {
        switch code {
        case .mailboxQuotaExceeded:
            return .quotaExceeded
        case .rateLimited, .trafficLimitExceeded:
            return .rateLimited(retryAfter: retryAfter.map(TimeInterval.init))
        case .entitlementInactive:
            return .entitlementInactive
        case .unavailable, .unsupportedVersion:
            return .unreachable
        case .unauthenticated:
            return .transient(code: "unauthenticated")
        case .recordTooLarge, .attachmentTooLarge:
            return .permanent(code: "record_too_large")
        case .forbidden:
            return .permanent(code: "forbidden")
        case .notFound:
            return .permanent(code: "not_found")
        case .unspecified:
            return .permanent(code: "unspecified")
        default:
            return .transient(code: "relay_\(code.rawValue)")
        }
    }

    /// Runs one relay call: an answer marks the relay reachable (and ends an attestation
    /// backoff); an error is noted (`note`) and rethrown.
    func call<T>(_ zone: CloudZoneID?, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            setReachable(true)
            loginNotBefore = nil
            return value
        } catch {
            await note(error, zone: zone)
            throw error
        }
    }

    /// The side signals of a failed call: `MAILBOX_QUOTA_EXCEEDED` → `TransportEvent.quotaExceeded`,
    /// `ENTITLEMENT_INACTIVE` / `FORBIDDEN` / `UNSUPPORTED_VERSION` → `relayEvents`, no answer →
    /// `reachable(false)`, an App Attest outcome → a stop or a backoff.
    func note(_ error: any Error, zone: CloudZoneID?) async {
        guard let error = error as? HostedRelayError else { return }
        switch error {
        case .server(let code, _):
            setReachable(true)
            Self.logger.error("relay call refused: \(String(describing: code), privacy: .public)")
            switch code {
            case .mailboxQuotaExceeded: eventHandler?(.quotaExceeded)
            case .entitlementInactive: emit(.entitlementInactive)
            case .forbidden: if let zone { emit(.forbidden(zone: zone)) }
            default: break
            }
        case .unsupportedVersion:
            setReachable(false)
            emit(.unsupportedVersion)
        case .unreachable:
            setReachable(false)
        case .undecodable(let status):
            setReachable(!(500..<600).contains(status))
        case .attestation(let outcome):
            await attestation(outcome)
        }
    }

    /// `.retryLater` holds every call until its deadline; `.notSupported` / `.updateRequired`
    /// stop the transport (socket closed, reported once) until `start()`.
    func attestation(_ outcome: HostedRelayAttestError) async {
        switch outcome {
        case .retryLater(let after):
            loginNotBefore = clock.now().addingTimeInterval(Self.seconds(after))
            Self.logger.error("relay login: app attest retry later")
            emit(.attestation(outcome))
        case .notSupported, .updateRequired:
            guard stoppedBy == nil else { return }
            stoppedBy = outcome
            Self.logger.error("relay stopped: app attest \(String(describing: outcome), privacy: .public)")
            setReachable(false)
            emit(.attestation(outcome))
            await closeConnection()
        }
    }

    /// Throws what a call would get while the transport is stopped or holding for an attestation
    /// backoff, without touching the attestor or the network.
    func gate() throws {
        if let stoppedBy { throw HostedRelayError.attestation(stoppedBy) }
        if let loginNotBefore {
            let left = loginNotBefore.timeIntervalSince(clock.now())
            if left > 0 { throw HostedRelayError.attestation(.retryLater(after: .milliseconds(Int((left * 1000).rounded(.up))))) }
        }
    }

    /// The refusal of a call made now while stopped or held; nil when calls may go out.
    func held() -> TransportRefusal? {
        do {
            try gate()
            return nil
        } catch {
            return Self.refusal(for: error)
        }
    }

    func emit(_ event: HostedRelayEvent) {
        relayEventSink.yield(event)
    }

    func setReachable(_ value: Bool) {
        guard !reachabilityKnown || reachable != value else { return }
        reachabilityKnown = true
        reachable = value
        emit(.reachable(value))
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
