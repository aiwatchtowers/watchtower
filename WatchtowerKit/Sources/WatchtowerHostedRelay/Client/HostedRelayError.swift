import WatchtowerRelayProto

/// What a relay call failed with. No case carries a token, a key, an envelope
/// or the server's `Error.message` (logs only, never kept), so an error's
/// description is safe to log.
public enum HostedRelayError: Error, Equatable, Sendable {
    /// A protocol error the relay answered (`Response.error`).
    case server(code: Relay_V1_ErrorCode, retryAfter: UInt32?)
    /// `UNSUPPORTED_VERSION` / WebSocket close 4000: "update the app".
    case unsupportedVersion
    /// The body is not a `Response`, a non-2xx status came without a
    /// `Response.error`, or the op answered with a result of the wrong kind.
    case undecodable(status: Int)
    /// No answer: the request failed in transport or the connection dropped.
    case unreachable
    /// App Attest could not be completed, or the relay refused the attestation.
    case attestation(HostedRelayAttestError)
}
