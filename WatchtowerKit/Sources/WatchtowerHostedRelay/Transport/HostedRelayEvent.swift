import WatchtowerRelayProto
import WatchtowerSync

/// What the hosted relay transport reports besides `TransportEvent` (R11): relay-only signals
/// Phases 3–4 wire to the phone's screens. No case carries a token, a key or an envelope.
public enum HostedRelayEvent: Equatable, Sendable {
    /// A control event from the socket (`SESSION_EXPIRED` is the connection's own).
    case control(kind: Relay_V1_ControlKind, detail: String)
    /// `ENTITLEMENT_INACTIVE`, or an account state whose entitlement does not pay.
    case entitlementInactive
    /// The relay refused the zone (`FORBIDDEN`).
    case forbidden(zone: CloudZoneID)
    /// `UNSUPPORTED_VERSION` / close 4000: "update the app".
    case unsupportedVersion
    /// An App Attest outcome that stops the transport (`.notSupported`, `.updateRequired`)
    /// or holds it until a deadline (`.retryLater`).
    case attestation(HostedRelayAttestError)
    /// Whether the last op reached the relay (reported on change).
    case reachable(Bool)
}
