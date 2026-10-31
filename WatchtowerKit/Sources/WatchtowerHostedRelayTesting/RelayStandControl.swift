import Foundation
import WatchtowerRelayProto

/// What a test may do to the server besides the protocol: the stand's `/dev`
/// endpoints (relay@3a99bd7 `worker/src/http/dev.ts`), on `FakeHostedRelay`
/// or on the local stand (`HTTPRelayStandControl` in the interop tests).
public protocol RelayStandControl: Sendable {
    /// `POST /dev/entitlement`: `state` is active|grace|expired|revoked; a paying
    /// state needs `duration > 0` (until = now + duration), the others keep the current until.
    func setEntitlement(accountID: String, state: String, for duration: Duration) async throws
    /// `POST /dev/account`: the account of a registered phone.
    func accountID(ofPhone phoneID: String) async throws -> String
    /// `POST /dev/pair`: the Mac into every phone's slots (each must pay), then the
    /// phones become the readers of the Mac's data zone.
    func pair(mac: String, phones: [String]) async throws
    /// `POST /dev/expire-mailboxes`: runs the mailbox TTL as if `elapsed` had passed.
    func expireMailboxes(_ zones: [String], elapsed: Duration) async throws
}

/// Why a stand control call was refused.
public enum RelayStandError: Error, Equatable, Sendable {
    /// A malformed call (the stand's 400).
    case invalid
    /// No such phone or account (the stand's 404).
    case notFound
    /// A protocol step refused (the stand's 409), with the code the op would answer.
    case refused(Relay_V1_ErrorCode)
}
