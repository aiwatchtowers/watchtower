import Foundation
import os
import WatchtowerRelayProto

/// The one relay socket of the device (R2). The relay displaces an older socket of the same
/// device (`GoingAway`, close 1001), so two hubs, or a hub and a pairing slot, each with a
/// socket of its own would knock each other off in a loop. Every relay object of the process
/// attaches here instead:
/// - the socket is `client.connect(zones:)` with the union of the owners' zones, opened by the
///   first `attach` and closed by the last `detach`; an attach or detach in between is a
///   `setZones` (every reconnect subscribes the whole union);
/// - a zone event (`zoneChanged`, `zoneRefused`) goes to the owners of that zone only, each
///   once; `connected`, `disconnected` and `stopped` go to every owner; `stopped` also detaches
///   them all (an owner attaches again when it wants the socket again);
/// - account-level signals go to `events`, once per signal however many owners there are.
///
/// Each owner has its own ordered inbox, so a slow handler (a pull) never holds the others' events.
public actor HostedRelaySession {
    static let logger = Logger(subsystem: "WatchtowerKit", category: "HostedRelay")
    /// `events` keeps the newest this many while nobody reads.
    static let eventBuffer = 256
    /// The most record bytes (envelopes) of zone events one owner's inbox holds unread: an event past it is
    /// delivered without its records, so its owner reads the zone (the relay's own lane bound, `MAX_LANE_BYTES`).
    static let inboxRecordBytes = 1 << 20

    nonisolated public let client: HostedRelayClient
    /// Account-level relay signals: socket controls (`ENTITLEMENT_EXPIRED`, `SUBSCRIPTION_MOVED`,
    /// `SLOT_REMOVED`; `PAIRING_OPENED` is never sent to a phone), `.entitlementInactive`,
    /// `.unsupportedVersion`, `.attestation(…)` and the socket's `.reachable(Bool)`. For one reader.
    /// Level-like: a latched case (`.entitlementInactive`, `.unsupportedVersion`, `.attestation`)
    /// is reported once per state, not once per transport or per reconnect; its repeat is dropped
    /// until `.reachable(true)` or another latched case comes. Controls are never dropped.
    nonisolated public let events: AsyncStream<HostedRelayEvent>
    nonisolated private let sink: AsyncStream<HostedRelayEvent>.Continuation
    /// A private session's transport (`HostedRelayTransport(client:…)`): every account-level
    /// signal but `.reachable` is also its `relayEvents`, Phase 2's one-transport shape.
    nonisolated private let mirror: AsyncStream<HostedRelayEvent>.Continuation?
    /// The latched case `events` last reported (nil after `.reachable(true)`).
    nonisolated private let latched = OSAllocatedUnfairLock<HostedRelayEvent?>(initialState: nil)

    private struct Owner {
        var zones: [String]
        let inbox: AsyncStream<HostedRelayClientEvent>.Continuation
        /// The record bytes of the zone events waiting in `inbox`.
        let waiting: OSAllocatedUnfairLock<Int>
        let reader: Task<Void, Never>
    }

    private var owners: [ObjectIdentifier: Owner] = [:]
    /// Owners in attach order: the order of the union.
    private var order: [ObjectIdentifier] = []
    private(set) var connection: HostedRelayConnection?
    private var opening = false
    private var socketReader: Task<Void, Never>?
    private var accountRead: Task<Void, Never>?
    /// The zone set last handed to the connection, and whether a hand-over is in flight.
    private var sentZones: [String] = []
    private var syncingZones = false
    /// The socket's reachability last published (`reachabilityKnown` false before any).
    private var reachable = false
    private var reachabilityKnown = false
    /// The open connection's last `.connected` / `.disconnected`: nil before its first `connected`.
    private var socketState: HostedRelayClientEvent?
    /// The wake in flight, fired when it ends: every hub's return to the foreground joins it.
    private var waking: Latch?

    public init(client: HostedRelayClient) {
        self.init(client: client, mirror: nil)
    }

    init(client: HostedRelayClient, mirror: AsyncStream<HostedRelayEvent>.Continuation?) {
        self.client = client
        self.mirror = mirror
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(Self.eventBuffer))
    }

    deinit {
        sink.finish()
        socketReader?.cancel()
        accountRead?.cancel()
        for owner in owners.values {
            owner.inbox.finish()
            owner.reader.cancel()
        }
        if let connection { Task { await connection.close() } }
    }

    // MARK: - Owners

    /// Adds `zones` for `owner` to the one connection and routes their events to `handler`
    /// (attaching again replaces the owner's zones and handler). Opens the socket on first use.
    func attach(
        owner id: ObjectIdentifier, zones: [String], handler: @escaping @Sendable (HostedRelayClientEvent) async -> Void
    ) async {
        if let old = owners[id] {
            old.inbox.finish()
            old.reader.cancel()
        } else {
            order.append(id)
        }
        let (stream, inbox) = AsyncStream.makeStream(of: HostedRelayClientEvent.self)
        let waiting = OSAllocatedUnfairLock(initialState: 0)
        let reader = Task {
            for await event in stream {
                let bytes = Self.recordBytes(event)
                if bytes > 0 { waiting.withLock { $0 -= bytes } }
                await handler(event)
            }
        }
        owners[id] = Owner(zones: zones, inbox: inbox, waiting: waiting, reader: reader)
        // A late owner learns the open socket's state at once.
        if connection != nil, let socketState { inbox.yield(socketState) }
        if connection == nil {
            await open()
        } else {
            await syncZones()
        }
    }

    /// Removes `owner`; the last owner gone closes the socket. Its zones stay subscribed on the
    /// relay until the next connect, their events unreported.
    func detach(owner id: ObjectIdentifier) async {
        guard let owner = owners.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        owner.inbox.finish()
        owner.reader.cancel()
        if owners.isEmpty {
            await close()
        } else {
            await syncZones()
        }
    }

    /// Subscribes `owner`'s `zones` again: a zone the socket refused (dropped from the union at the refusal) that
    /// its owner can read again, e.g. once the hub made the phone a reader (Phase 3 R5). An owner not attached is
    /// ignored; a zone refused again is dropped again.
    func resubscribe(owner id: ObjectIdentifier, zones: [String]) async {
        guard owners[id] != nil else { return }
        owners[id]?.zones = zones
        await syncZones()
    }

    // MARK: - Account-level signals

    /// Yields `event` on `events`, dropping a latched case's repeat (and on a private session's
    /// transport, which keeps Phase 2's one notice per call).
    nonisolated func publish(_ event: HostedRelayEvent) {
        let repeated = latched.withLock { last in
            switch event {
            case .reachable(true):
                last = nil
            case .entitlementInactive, .unsupportedVersion, .attestation:
                if last == event { return true }
                last = event
            default:
                break
            }
            return false
        }
        if !repeated { sink.yield(event) }
        if case .reachable = event { return }
        mirror?.yield(event)
    }

    /// Publishes an error that stops the relay (`.unsupportedVersion`, an App Attest
    /// `.notSupported`/`.updateRequired`); false for any other.
    @discardableResult
    nonisolated func publishStop(_ error: HostedRelayError) -> Bool {
        switch error {
        case .unsupportedVersion:
            publish(.unsupportedVersion)
        case .attestation(.notSupported), .attestation(.updateRequired):
            if case .attestation(let outcome) = error { publish(.attestation(outcome)) }
        default:
            return false
        }
        return true
    }

    /// `get_account_state`: an entitlement that does not pay is `.entitlementInactive`.
    func readAccountState() async {
        do {
            let state = try await accountState()
            let inactive: [Relay_V1_EntitlementKind] = [Relay_V1_EntitlementKind.none, .expired, .revoked]
            if inactive.contains(state.entitlement.state) { publish(.entitlementInactive) }
        } catch {
            if let error = error as? HostedRelayError, publishStop(error) { return }
            Self.logger.error("relay account state failed")
        }
    }

    // MARK: - Wake (live link R6)

    /// The app became active (`HostedRelayConnection.wake`): the socket is pinged; with no pong within
    /// `HostedRelayConnection.wakePingDeadline` it is dropped at once (the reads go over HTTPS) and a second socket is
    /// dialled in the background; a connection waiting out a reconnect backoff dials at once. Returns at most the ping
    /// deadline later; a wake already in flight is joined. Nothing without a connection (nobody wants the socket).
    public func wake() async {
        // Each caller's wait is cancellable on its own (the app left): the shared wake goes on for the others.
        if let waking { return await waking.wait() }
        guard let connection else { return }
        let done = Latch()
        waking = done
        Task {
            await connection.wake()
            await self.wakeEnded(done)
        }
        await done.wait()
    }

    private func wakeEnded(_ done: Latch) {
        if waking === done { waking = nil }
        done.fire()
    }

    // MARK: - The socket

    /// Dials with the union; an attach while dialing only adds its zones, handed over after.
    private func open() async {
        guard !opening else { return }
        opening = true
        let zones = union()
        let connection = await client.connect(zones: zones)
        opening = false
        guard !owners.isEmpty, self.connection == nil else {
            await connection.close()
            return
        }
        self.connection = connection
        socketState = nil
        sentZones = zones
        let events = connection.events
        socketReader = Task { [weak self] in
            for await event in events {
                await self?.route(event, from: connection)
            }
        }
        await syncZones()
    }

    private func close() async {
        socketReader?.cancel()
        socketReader = nil
        accountRead?.cancel()
        accountRead = nil
        sentZones = []
        socketState = nil
        let connection = connection
        self.connection = nil
        await connection?.close()
    }

    /// Hands the union to the connection until it has the current one; one hand-over at a time,
    /// so an older union never lands after a newer one.
    private func syncZones() async {
        guard !syncingZones else { return }
        syncingZones = true
        while let connection, sentZones != union() {
            let zones = union()
            sentZones = zones
            await connection.setZones(zones)
        }
        syncingZones = false
    }

    private func union() -> [String] {
        var seen = Set<String>()
        return order.flatMap { owners[$0]?.zones ?? [] }.filter { seen.insert($0).inserted }
    }

    private func route(_ event: HostedRelayClientEvent, from source: HostedRelayConnection) async {
        guard source === connection else { return }
        switch event {
        case let .zoneChanged(zone, seq, _):
            let bytes = Self.recordBytes(event)
            for id in owners(of: zone) {
                guard let owner = owners[id] else { continue }
                // An owner busy with a pull holds what it has not read: bounded, the rest come record-less.
                let fits = bytes == 0 || owner.waiting.withLock { waiting in
                    guard waiting + bytes <= Self.inboxRecordBytes else { return false }
                    waiting += bytes
                    return true
                }
                owner.inbox.yield(fits ? event : .zoneChanged(zone: zone, seq: seq))
            }
        case .zoneRefused(let zone, _):
            deliver(event, to: owners(of: zone))
            // The connection dropped it from its set: so does the union.
            for id in order { owners[id]?.zones.removeAll { $0 == zone } }
            sentZones.removeAll { $0 == zone }
        case let .control(kind, detail):
            publish(.control(kind: kind, detail: detail))
        case .connected:
            socketState = event
            deliver(event, to: order)
            setReachable(true)
            accountRead?.cancel()
            accountRead = Task { await self.readAccountState() }
        case .disconnected:
            socketState = event
            deliver(event, to: order)
            setReachable(false)
        case .stopped(let error):
            socketReader = nil
            accountRead?.cancel()
            accountRead = nil
            self.connection = nil
            socketState = nil
            sentZones = []
            setReachable(false)
            publishStop(error)
            let stopped = order.compactMap { owners[$0] }
            owners = [:]
            order = []
            for owner in stopped {
                owner.inbox.yield(event)
                owner.inbox.finish()
            }
        }
    }

    private func owners(of zone: String) -> [ObjectIdentifier] {
        order.filter { owners[$0]?.zones.contains(zone) == true }
    }

    /// The record bytes waiting unread in `owner`'s inbox.
    func unreadRecordBytes(owner id: ObjectIdentifier) -> Int {
        owners[id]?.waiting.withLock { $0 } ?? 0
    }

    /// The envelope bytes of a zone event's records (0 for any other event).
    private static func recordBytes(_ event: HostedRelayClientEvent) -> Int {
        guard case .zoneChanged(_, _, let records) = event else { return 0 }
        return records.reduce(0) { $0 + $1.envelope.count }
    }

    private func deliver(_ event: HostedRelayClientEvent, to ids: [ObjectIdentifier]) {
        for id in ids { owners[id]?.inbox.yield(event) }
    }

    private func setReachable(_ value: Bool) {
        guard !reachabilityKnown || reachable != value else { return }
        reachabilityKnown = true
        reachable = value
        publish(.reachable(value))
    }
}
