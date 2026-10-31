import CryptoKit
import Foundation
import WatchtowerHostedRelay
import WatchtowerRelayProto

/// In-memory relay following relay@3a99bd7 `proto/README.md` (R20; where the
/// README is silent, the Worker's code at that commit). Thread-safe (one lock);
/// time from a `ManualRelayClock`, so TTLs run when the test advances it.
///
/// Not modelled: rate limits, phone traffic, App Store transactions
/// (`submit_transaction` answers "not implemented", as a stand without App
/// Store keys does), push, blob uploads (Task 7), sockets and `ZoneChanged` (Task 7).
public final class FakeHostedRelay: @unchecked Sendable {
    public enum AttestMode: Sendable, Equatable {
        /// README "Who must attest": every device attests, except the listed ones
        /// (the relay's probe devices; here the test-only Macs, R18).
        case enforce(exemptDeviceIDs: Set<String>)
        /// `RELAY_ATTEST_MODE=off` (dev): `attestation` is ignored.
        case off
    }

    /// Quotas and sizes (README "Operations notes", Worker `config.ts` defaults); tests may lower them.
    public struct Limits: Sendable, Equatable {
        public var maxRecordBytes = 1 << 20
        public var maxAttachmentBytes = 100 << 20
        public var hubQuotaBytes = 5 << 30
        /// Summed over all of a phone's mailboxes.
        public var mailboxQuotaBytes = 2 << 30
        /// README: `pair/<slot_id>` zones hold at most 1 MiB of records.
        public var pairZoneBytes = 1 << 20
        /// README: a `changes` page holds at most 4 MiB of envelopes (but at least one record).
        public var changesPageBytes = 4 << 20
        public var maxMacSlots = 3
        public var slotReplacementsPer30Days = 5

        public init() {}
    }

    /// The server origin as configured (README: signed into the register and login hashes).
    public let origin: String
    let relayOrigin: RelayOrigin
    let clock: ManualRelayClock
    private let lock = NSLock()
    /// Guarded by `lock`; only touched inside `locked`.
    var state: State

    public init(
        origin: String = "https://relay.example.com",
        attest: AttestMode = .enforce(exemptDeviceIDs: []),
        clock: ManualRelayClock
    ) {
        // A test bug, not a runtime condition: the fake's origin is a literal in the test.
        guard let parsed = try? RelayOrigin(origin) else { preconditionFailure("FakeHostedRelay: invalid origin") }
        self.origin = parsed.string
        relayOrigin = parsed
        self.clock = clock
        state = State(attestMode: attest)
    }

    /// The server side of one op, as `POST /v1/op` would answer it (HTTP status + Response).
    /// README "HTTP status": 401 for `UNAUTHENTICATED`, 413 for a body over the record
    /// limit plus 64 KiB, 200 for everything else (protocol errors included).
    public func handle(_ request: Relay_V1_Request, bearer: String?) -> (status: Int, response: Relay_V1_Response) {
        locked {
            if let op = request.op { state.log.append(op) }
            var response: Relay_V1_Response
            var status = 200
            let bodyBytes = (try? request.serializedData().count) ?? 0
            if bodyBytes > state.limits.maxRecordBytes + Self.extraBodyBytes {
                response = Self.failure(.recordTooLarge, "request too large")
                status = 413
            } else {
                do {
                    response = try run(request, bearer: bearer)
                } catch let failure as RelayFailure {
                    response = Self.failure(failure.code, failure.message)
                } catch {
                    response = Self.failure(.unspecified, "internal error")
                }
            }
            response.id = request.id
            if case .error(let error) = response.result, error.code == .unauthenticated { status = 401 }
            return (status, response)
        }
    }

    /// Every op handled so far, in order (for assertions; never holds tokens).
    public var log: [Relay_V1_Request.OneOf_Op] {
        locked { state.log }
    }

    public var attestMode: AttestMode {
        get { locked { state.attestMode } }
        set { locked { state.attestMode = newValue } }
    }

    /// Off (the default): a revocation counts as delivered at once, so a repeated `remove_slot`
    /// answers `Ok`, as on the stand. On: revocations stay pending, and a repeat answers
    /// `UNAVAILABLE` until `markRevocationsDelivered()`.
    public var holdRevocations: Bool {
        get { locked { state.holdRevocations } }
        set { locked { state.holdRevocations = newValue } }
    }

    public var limits: Limits {
        get { locked { state.limits } }
        set { locked { state.limits = newValue } }
    }

    /// The events queued for a device (README "Control events"), oldest first, and
    /// forgets them. Controls are best effort: a device that never takes them
    /// learns the same facts from `get_account_state`.
    public func takeEvents(for deviceID: String) -> [Relay_V1_Event] {
        locked { state.events.removeValue(forKey: deviceID) ?? [] }
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Dispatch (called with the lock held)

    private func run(_ request: Relay_V1_Request, bearer: String?) throws -> Relay_V1_Response {
        guard let op = request.op else { throw RelayFailure(.unspecified, "invalid request") }
        switch op {
        case .register(let register):
            return try self.register(register)
        case .challenge(let challenge):
            return try self.challenge(challenge)
        case .login(let login):
            return try self.login(login)
        default:
            return try runSessionOp(op, try session(bearer: bearer))
        }
    }

    private func runSessionOp(_ op: Relay_V1_Request.OneOf_Op, _ session: Session) throws -> Relay_V1_Response {
        switch op {
        case .save(let save):
            return try self.save(save.items, session)
        case .delete(let delete):
            return try self.delete(delete, session)
        case .changes(let changes):
            return try self.changes(changes, session)
        case .createUpload(let upload):
            return try createUpload(upload, session)
        case .getDownload(let download):
            return try getDownload(download, session)
        case .setHubReaders(let readers):
            return try setHubReaders(readers, session)
        case .subscribe:
            // WebSocket-only (Worker ops.ts).
            throw RelayFailure(.unspecified, "not implemented")
        default:
            return try runAccountOp(op, session)
        }
    }

    // MARK: - Helpers

    /// README: a body may exceed the record limit by this much.
    static let extraBodyBytes = 64 << 10

    static func failure(_ code: Relay_V1_ErrorCode, _ message: String) -> Relay_V1_Response {
        var response = Relay_V1_Response()
        response.error.code = code
        response.error.message = message
        return response
    }

    static func okResponse() -> Relay_V1_Response {
        var response = Relay_V1_Response()
        response.ok = Relay_V1_Ok()
        return response
    }

    var now: Date {
        clock.now()
    }

    static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds) + TimeInterval(duration.components.attoseconds) / 1e18
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// Queues a control for a device (README "Control events").
    func sendControl(_ kind: Relay_V1_ControlKind, _ detail: String, to deviceID: String) {
        var event = Relay_V1_Event()
        event.control.kind = kind
        event.control.detail = detail
        state.events[deviceID, default: []].append(event)
    }
}

/// An expected failure inside an op, answered as `Response.error`.
struct RelayFailure: Error {
    let code: Relay_V1_ErrorCode
    let message: String

    init(_ code: Relay_V1_ErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    static let forbidden = Self(.forbidden, "forbidden")
    static let notFound = Self(.notFound, "not found")
    static let invalid = Self(.unspecified, "invalid request")
    static let unauthenticated = Self(.unauthenticated, "unauthenticated")
    static let entitlementInactive = Self(.entitlementInactive, "entitlement inactive")
}

/// Durations of the Worker's `config.ts` and auth code, in seconds.
enum RelayTTL {
    static let registerNonce: TimeInterval = 5 * 60
    static let loginNonce: TimeInterval = 60
    static let session: TimeInterval = 15 * 60
    static let pairingSlot: TimeInterval = 600
    static let presignedURL: TimeInterval = 15 * 60
    static let mailbox: TimeInterval = 14 * 86_400
    static let tombstone: TimeInterval = 30 * 86_400
    static let postExpiryRead: TimeInterval = 7 * 86_400
    static let revocationMemory: TimeInterval = 86_400
    static let replacementWindow: TimeInterval = 30 * 86_400
}

extension FakeHostedRelay {
    struct State {
        var attestMode: AttestMode
        var limits = Limits()
        var holdRevocations = false
        /// Phones that registered a push token (`send_alert` needs one).
        var pushPhones: Set<String> = []
        var log: [Relay_V1_Request.OneOf_Op] = []
        /// The register nonces' HMAC key (stateless nonces, Worker `register-nonce.ts`).
        let nonceKey = SymmetricKey(size: .bits256)
        var devices: [String: Device] = [:]
        /// Single-use login nonces by device: nonce → expiry.
        var loginNonces: [String: [Data: Date]] = [:]
        var sessions: [String: Session] = [:]
        /// By account id.
        var accounts: [String: Account] = [:]
        var zones: [String: Zone] = [:]
        var events: [String: [Relay_V1_Event]] = [:]

        init(attestMode: AttestMode) {
            self.attestMode = attestMode
        }
    }

    struct Device {
        let id: String
        let kind: Relay_V1_DeviceKind
        let authPub: Data
        /// A phone's account (README: `DeviceRegistered.account_id`); nil for a Mac.
        let accountID: String?
        /// The App Attest key id bytes and the last assertion counter.
        var attestKeyID: Data?
        var attestCounter = 0
    }

    struct Session {
        let deviceID: String
        let kind: Relay_V1_DeviceKind
        let expiresAt: Date
    }
}
