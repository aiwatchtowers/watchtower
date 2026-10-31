import Foundation
import os
import WatchtowerRelayProto
import WatchtowerSync

/// The phone's transport over the hosted relay (spec §7; R4–R11): `.data` is the paired Mac's
/// data zone (`data/<mac>`, read only), `.relay` the phone's mailbox with that Mac
/// (`relay/<mac>/<phone>`). Server pages are buffered into `TransportStore` (R5), so consumers
/// keep local change tokens, compaction and the asset stash. Plain `save`/`delete` queue durably
/// and go out on a flush; `ConditionalTransport` calls go straight to the relay after the queue
/// (R8). Mirrors the Go hub's `internal/hub/transport/relay` (same relay commit).
///
/// After an App Attest `.notSupported`/`.updateRequired` the transport is stopped until
/// `start()`: no login, register or request; queued writes stay queued. After `.retryLater`
/// every call answers without the attestor or the network until the deadline.
public actor HostedRelayTransport: LiveTransport, ConditionalTransport, CompactingTransport {
    static let logger = Logger(subsystem: "WatchtowerKit", category: "HostedRelay")
    /// How long a resync the relay refused partway waits before it starts again (`start()` ends
    /// the wait at once).
    static let resyncStallHold: TimeInterval = 3_600
    /// Records asked for per `changes` page: the relay's own cap.
    static let pageLimit: UInt32 = 500
    /// `relayEvents` keeps the newest this many while nobody reads (the client's event buffer).
    static let eventBuffer = 256

    let client: HostedRelayClient
    let store: TransportStore
    let energy: EnergyCounter?
    let maxAttachmentBytes: Int64
    let clock: any RelayClock
    nonisolated let dataZone: String
    nonisolated let mailboxZone: String

    /// Relay-only signals (R11), for one reader.
    nonisolated public let relayEvents: AsyncStream<HostedRelayEvent>
    let relayEventSink: AsyncStream<HostedRelayEvent>.Continuation

    var connection: HostedRelayConnection?
    var socketReader: Task<Void, Never>?
    /// Set by an App Attest `.notSupported`/`.updateRequired`; cleared by `start()`.
    var stoppedBy: HostedRelayAttestError?
    /// Set by an App Attest `.retryLater`; cleared by `start()` and by an op that reached the relay.
    var loginNotBefore: Date?
    /// Whether the last op reached the relay (`reachabilityKnown` false before any).
    var reachable = false
    var reachabilityKnown = false

    /// The pull in flight and the zones it still owes (`HostedRelayTransport+Pull.swift`).
    var pullTask: Task<Void, any Error>?
    var zonesToPull: Set<CloudZoneID> = []
    /// Until when a stalled resync of a zone waits (`HostedRelayTransport+Pull.swift`).
    var resyncHolds: [CloudZoneID: Date] = [:]
    /// The flush in flight and how many flushes have started (`HostedRelayTransport+Save.swift`).
    var flushTask: Task<FlushStop?, any Error>?
    var flushStarts = 0
    /// `start()` asked for the socket and `stop()` has not: a socket that could not be dialed
    /// then (an attestation backoff) is dialed after the next successful pull or flush.
    var wantsSocket = false

    var eventHandler: (@Sendable (TransportEvent) -> Void)?
    var accountResetHandler: (@Sendable () -> Void)?
    var engineFetchedHandler: (@Sendable () -> Void)?

    /// Binds `store` to the relay Mac `macDeviceID` first: a store bound to CloudKit or to
    /// another Mac throws `TransportStoreError.boundToAnotherRoute` before any request.
    /// `maxAttachmentBytes`: the largest attachment a pull downloads (the relay's default cap,
    /// Go `MaxAttachmentBytes`).
    public init(
        client: HostedRelayClient,
        store: TransportStore,
        macDeviceID: String,
        energy: EnergyCounter? = nil,
        maxAttachmentBytes: Int64 = 100 << 20
    ) throws {
        _ = try store.adoptRelayBinding(macDeviceID: macDeviceID, hubID: nil)
        self.client = client
        self.store = store
        self.energy = energy
        self.maxAttachmentBytes = maxAttachmentBytes
        self.clock = client.clock
        self.dataZone = HostedRelayZones.data(mac: macDeviceID)
        self.mailboxZone = HostedRelayZones.mailbox(mac: macDeviceID, phone: client.deviceID)
        (relayEvents, relayEventSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(Self.eventBuffer))
    }

    deinit {
        relayEventSink.finish()
        socketReader?.cancel()
        if let connection { Task { await connection.close() } }
    }

    // MARK: - CloudSyncTransport

    /// Queues `records` for the next flush (R8). Only the mailbox is writable: a `.data` record
    /// throws `HostedRelayError.server(code: .forbidden, …)` and nothing is queued.
    public func save(_ records: [CloudRecord]) async throws {
        guard records.allSatisfy({ $0.zone == .relay }) else { throw Self.forbidden }
        try store.enqueueSave(records)
    }

    public func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        guard zone == .relay else { throw Self.forbidden }
        try store.enqueueDelete(recordNames: recordNames, zone: zone)
    }

    /// Served from the local buffer (R5).
    public func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try store.changes(in: zone, since: token)
    }

    public func compact(in zone: CloudZoneID, keepSince token: CloudChangeToken) async throws {
        try store.compactEvents(in: zone, keepSince: token)
    }

    // MARK: - LiveTransport

    /// Registers when this client has not yet, connects with both zones, flushes and pulls.
    /// Clears an attestation stop and backoff (the app came to the foreground).
    public func start() async {
        stoppedBy = nil
        loginNotBefore = nil
        wantsSocket = true
        for zone in CloudZoneID.allCases { resyncHolds[zone] = .distantPast }
        if connection == nil, await client.accountID == nil {
            do {
                _ = try await call(nil) { try await self.client.register() }
            } catch {
                Self.logger.error("relay start: register failed")
            }
        }
        guard held() == nil else { return }
        await connectIfWanted()
        await sendNow()
        do {
            try await pull()
        } catch {
            Self.logger.error("relay start: pull failed")
        }
    }

    /// Closes the socket. Queued writes stay queued.
    public func stop() async {
        wantsSocket = false
        await closeConnection()
    }

    /// Flushes the plain queue; a stopped flush re-reads its zone.
    public func sendNow() async {
        guard held() == nil else { return }
        do {
            if let stop = try await flush() {
                await reread(stop.zone)
            } else {
                await connectIfWanted()
            }
        } catch {
            Self.logger.error("relay flush: the send queue could not be read")
        }
    }

    /// Flushes the plain queue, then pulls both zones over HTTPS. Throws `HostedRelayError` as
    /// the client does (a held or stopped transport throws `.attestation`).
    public func pull() async throws {
        try gate()
        _ = try await flush()
        try await pullZones(Set(CloudZoneID.allCases))
        await connectIfWanted()
    }

    /// One HTTPS `pull()`, joining one in flight. A held transport does nothing (as CloudKit's
    /// throttle does).
    public func fetchForPush(since: Date, grace: TimeInterval, pollOnFallback: Bool) async throws {
        if let pullTask { return try await pullTask.value }
        guard held() == nil else { return }
        try await pull()
    }

    /// `.available` once the last op reached the relay, else `.unavailable("relay")`.
    public func availability() async -> CloudAvailability {
        reachable && stoppedBy == nil ? .available : .unavailable("relay")
    }

    /// `MAILBOX_QUOTA_EXCEEDED` → `.quotaExceeded` (R11).
    public func setEventHandler(_ handler: (@Sendable (TransportEvent) -> Void)?) async {
        eventHandler = handler
    }

    /// Kept, never fired: the relay has no account reset the phone must wipe for.
    public func setAccountResetHandler(_ handler: (@Sendable () -> Void)?) async {
        accountResetHandler = handler
    }

    /// Fired after a pull that buffered anything.
    public func setEngineFetchedHandler(_ handler: (@Sendable () -> Void)?) async {
        engineFetchedHandler = handler
    }

    // MARK: - The socket

    /// A socket event: a zone change is a pull of that zone (R9; the connection sends a
    /// record-less one per zone after every connect, so a reconnect pulls both), a connect
    /// reads the account state, controls and refusals go to `relayEvents`.
    func handle(_ event: HostedRelayClientEvent) async {
        switch event {
        case .zoneChanged(let zone, _):
            guard let id = cloudZone(zone) else { return }
            do {
                try await pullZones([id])
            } catch {
                Self.logger.error("relay pull after a zone event failed, \(Self.kind(id), privacy: .public)")
            }
        case let .zoneRefused(zone, error):
            await note(error, zone: cloudZone(zone))
        case let .control(kind, detail):
            emit(.control(kind: kind, detail: detail))
        case .connected:
            setReachable(true)
            await readAccountState()
        case .disconnected:
            setReachable(false)
        case .stopped(let error):
            connection = nil
            socketReader = nil
            if error == .unsupportedVersion { wantsSocket = false }
            await note(error, zone: nil)
        }
    }

    /// `get_account_state` after a connect: an entitlement that does not pay is reported.
    func readAccountState() async {
        guard held() == nil else { return }
        do {
            let state = try await call(nil) { try await self.client.accountState() }
            let inactive: [Relay_V1_EntitlementKind] = [Relay_V1_EntitlementKind.none, .expired, .revoked]
            if inactive.contains(state.entitlement.state) { emit(.entitlementInactive) }
        } catch {
            Self.logger.error("relay account state failed")
        }
    }

    /// Dials the socket when `start()` wants one and none is open, unless stopped or held.
    func connectIfWanted() async {
        guard wantsSocket, connection == nil, held() == nil else { return }
        let connection = await client.connect(zones: [dataZone, mailboxZone])
        guard wantsSocket, self.connection == nil else {
            await connection.close()
            return
        }
        self.connection = connection
        let events = connection.events
        socketReader = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    func closeConnection() async {
        socketReader?.cancel()
        socketReader = nil
        let connection = connection
        self.connection = nil
        await connection?.close()
    }

    // MARK: - Zones

    nonisolated func zoneName(_ zone: CloudZoneID) -> String {
        zone == .data ? dataZone : mailboxZone
    }

    nonisolated func cloudZone(_ name: String) -> CloudZoneID? {
        switch name {
        case dataZone: return .data
        case mailboxZone: return .relay
        default: return nil
        }
    }

    /// A zone's kind for logs (never the device ids in its name).
    static func kind(_ zone: CloudZoneID) -> String {
        zone == .data ? "data" : "mailbox"
    }

    static let forbidden = HostedRelayError.server(code: .forbidden, retryAfter: nil)
}
