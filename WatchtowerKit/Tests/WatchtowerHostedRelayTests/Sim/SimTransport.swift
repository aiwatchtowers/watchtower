import Foundation
import os
@testable import WatchtowerHostedRelay
import WatchtowerRelayProto
@testable import WatchtowerSync

// Port of relay@3a99bd7 `sim/transport.go`'s `Transport` and `sim/relaytransport.go`. The sim's
// transport is the record store under SecureTransport — last-version records, conditional
// writes, a per-zone change feed — here over the Kit's `ConditionalTransport` outcomes: a Go
// call-level error is a `.refused` outcome, a Go conflict a `.conflict` (or, with no live
// record, `.refused(.permanent("gone"))`, R6).

/// Go `ErrUnavailable`: the transport cannot be reached.
struct SimUnavailable: Error {}

/// A read the server answered with a refusal (Go: a protocol error).
struct SimRefused: Error {
    let refusal: TransportRefusal
}

/// A server control event (Go `relayv1.Control`).
struct SimControl: Equatable, Sendable {
    let kind: Relay_V1_ControlKind
    let detail: String
}

/// One conditional write of an envelope under `name` (Go `SaveItem`).
struct SimSaveItem: Equatable, Sendable {
    let name: String
    let envelope: Data
    let expect: WriteExpectation
}

struct SimDeleteItem: Equatable, Sendable {
    let name: String
    let expect: WriteExpectation
}

/// Everything changed in a zone after a cursor (Go `ChangesResult`, all pages).
struct SimChanges: Sendable {
    let changed: [CloudRecord]
    let deleted: [String]
    let newSeq: UInt64
}

/// Go `Transport` + `ControlSource`. Zones are the sim's zone names; each leg maps them onto
/// its store. `save`/`delete` never throw: a local failure is a `.refused` outcome.
protocol SimTransport: AnyObject, Sendable {
    var kind: SimKind { get }
    func save(_ zone: String, _ items: [SimSaveItem]) async -> [SaveOutcome]
    func delete(_ zone: String, _ items: [SimDeleteItem]) async -> [DeleteOutcome]
    /// Throws `SimUnavailable` when unreachable, `SimRefused` when the server refused.
    func changes(_ zone: String, since: UInt64) async throws -> SimChanges
    /// Whether the last attempt to reach the transport succeeded.
    func available() async -> Bool
    /// The server control events not taken yet (the relay's; CloudKit has none), taken.
    func takeControls() async -> [SimControl]
    /// The same, left in place (Go `PendingControls`).
    func pendingControls() -> [SimControl]
}

extension SimTransport {
    func saveOne(_ zone: String, _ item: SimSaveItem) async -> SaveOutcome {
        await save(zone, [item]).first ?? .refused(.transient(code: "no_outcome"))
    }
}

extension Sim {
    /// A write that must find no record under `name` (Go `saveItem`).
    static func saveItem(_ name: String, _ env: SimEnvelope) -> SimSaveItem {
        SimSaveItem(name: name, envelope: env.marshal(), expect: .absent)
    }

    /// A write over the version `seq` (Go `overwriteItem`).
    static func overwriteItem(_ name: String, _ bytes: Data, _ seq: UInt64) -> SimSaveItem {
        SimSaveItem(name: name, envelope: bytes, expect: .seq(seq))
    }

    /// The Go call-level error of a save outcome: nil when the server answered (saved or a
    /// conflict, a conflict with a deleted record included).
    static func failure(_ outcome: SaveOutcome) -> TransportRefusal? {
        guard case .refused(let refusal) = outcome, refusal != .permanent(code: "gone") else { return nil }
        return refusal
    }

    /// Go `retryable`: the write did not happen and may succeed later (unreachable, rate
    /// limited). Every other refusal is for good, as a Go protocol error is.
    static func retryable(_ refusal: TransportRefusal?) -> Bool {
        switch refusal {
        case .unreachable, .rateLimited: return true
        default: return false
        }
    }

    /// Deletes `rec` if it is still that version; failures are left to the next pass or the TTL
    /// (Go `deleteRecord`: a conflict is not a failure).
    @discardableResult
    static func deleteRecord(_ transport: any SimTransport, _ zone: String, _ rec: CloudRecord) async -> Bool {
        let outcome = await transport.delete(zone, [SimDeleteItem(name: rec.recordName, expect: .seq(rec.recordSeq ?? 0))])
        if case .refused = outcome.first { return false }
        return true
    }
}

/// Thread-safe control-event buffer of a relay leg.
final class SimControlBuffer: Sendable {
    private let controls = OSAllocatedUnfairLock<[SimControl]>(initialState: [])

    func append(_ control: SimControl) {
        controls.withLock { $0.append(control) }
    }

    func take() -> [SimControl] {
        controls.withLock { taken in
            defer { taken = [] }
            return taken
        }
    }

    var pending: [SimControl] {
        controls.withLock { $0 }
    }
}

/// The phone's relay leg: the real `HostedRelayTransport` (R12). The mailbox is written
/// through its `ConditionalTransport` calls; reads `pull()` both zones and serve the local
/// buffer, so the cursor is the buffer's change token. `start()` opens the transport's socket
/// (as every Go device is connected): its server controls arrive through `relayEvents`. The
/// socket's own zone events also `pull()` in the background; that only prefetches into the
/// buffer, and the sim's cursors stay the sim's (`SimPhone.cursors`), so a read sees each
/// change once whichever pull buffered it.
final class SimRelayPhoneLeg: SimTransport {
    let kind = SimKind.relay
    let transport: HostedRelayTransport
    private let clock: any RelayClock
    private let controls = SimControlBuffer()
    private let reader: Task<Void, Never>

    init(transport: HostedRelayTransport, clock: any RelayClock) {
        self.transport = transport
        self.clock = clock
        let events = transport.relayEvents
        reader = Task { [controls] in
            for await event in events {
                if case let .control(kind, detail) = event { controls.append(SimControl(kind: kind, detail: detail)) }
            }
        }
    }

    deinit {
        reader.cancel()
    }

    /// Opens the socket (and registers, flushes, pulls: `HostedRelayTransport.start()`).
    func start() async {
        await transport.start()
    }

    func close() async {
        await transport.stop()
    }

    func save(_ zone: String, _ items: [SimSaveItem]) async -> [SaveOutcome] {
        guard zone == transport.mailboxZone else { return items.map { _ in .refused(.permanent(code: "forbidden")) } }
        let saves = items.map { item in
            ConditionalSave(
                record: CloudRecord(
                    recordName: item.name, zone: .relay, kind: WireKind.envelope, modifiedAt: clock.now(), payload: item.envelope),
                expect: item.expect)
        }
        do {
            return try await transport.save(saves)
        } catch {
            return items.map { _ in .refused(.unreachable) } // a local failure: retried next pass
        }
    }

    func delete(_ zone: String, _ items: [SimDeleteItem]) async -> [DeleteOutcome] {
        guard zone == transport.mailboxZone else { return items.map { _ in .refused(.permanent(code: "forbidden")) } }
        do {
            return try await transport.delete(items.map { ConditionalDelete(recordName: $0.name, zone: .relay, expect: $0.expect) })
        } catch {
            return items.map { _ in .refused(.unreachable) } // a local failure: retried next pass
        }
    }

    /// Pulls both zones (the transport has no single-zone pull), then reads `zone`'s buffer
    /// after `since`. A pull that fails at the data zone (a phone that does not read the Mac's
    /// data zone) reads nothing, the mailbox included.
    func changes(_ zone: String, since: UInt64) async throws -> SimChanges {
        guard let id = transport.cloudZone(zone) else { throw SimRefused(refusal: .permanent(code: "forbidden")) }
        do {
            try await transport.pull()
        } catch {
            let refusal = HostedRelayTransport.refusal(for: error)
            if refusal == .unreachable { throw SimUnavailable() }
            throw SimRefused(refusal: refusal)
        }
        let batch = try await transport.changes(in: id, since: since == 0 ? nil : CloudChangeToken(value: Int(since)))
        return SimChanges(changed: batch.changed, deleted: batch.deletedRecordNames, newSeq: UInt64(batch.newToken.value))
    }

    func available() async -> Bool {
        await transport.availability() == .available
    }

    func takeControls() async -> [SimControl] {
        controls.take()
    }

    func pendingControls() -> [SimControl] {
        controls.pending
    }
}

/// The hub's relay leg: a `HostedRelayClient` with `DEVICE_KIND_MAC` (Go `RelayTransport`).
/// Ops go over HTTPS; `connect()` opens the client's socket (no zones: the sim polls), whose
/// `.control` events are the hub's server controls. The Mac reads every phone's mailbox and
/// writes its data zone.
final class SimRelayHubLeg: SimTransport {
    let kind = SimKind.relay
    let client: HostedRelayClient
    private let clock: any RelayClock
    private let failed = OSAllocatedUnfairLock(initialState: false)
    private let controls = SimControlBuffer()
    private let socket = OSAllocatedUnfairLock<(HostedRelayConnection, Task<Void, Never>)?>(initialState: nil)

    init(client: HostedRelayClient, clock: any RelayClock) {
        self.client = client
        self.clock = clock
    }

    deinit {
        socket.withLock { $0?.1.cancel() }
    }

    /// Opens the socket; its controls go to `takeControls`.
    func connect() async {
        let connection = await client.connect(zones: [])
        let events = connection.events
        let reader = Task { [controls] in
            for await event in events {
                if case let .control(kind, detail) = event { controls.append(SimControl(kind: kind, detail: detail)) }
            }
        }
        socket.withLock { $0 = (connection, reader) }
    }

    func close() async {
        guard let (connection, reader) = socket.withLock({ current in
            defer { current = nil }
            return current
        }) else { return }
        reader.cancel()
        await connection.close()
    }

    func save(_ zone: String, _ items: [SimSaveItem]) async -> [SaveOutcome] {
        let id = Self.cloudZone(zone)
        var save = Relay_V1_Save()
        save.items = items.map { item in
            var wire = Relay_V1_SaveItem()
            wire.record.zone = zone
            wire.record.name = item.name
            wire.record.envelope = item.envelope
            wire.record.clientModifiedAtMs = Int64((clock.now().timeIntervalSince1970 * 1000).rounded())
            switch item.expect {
            case .none: break
            case .absent: wire.mustNotExist = true
            case .seq(let seq): wire.expectedSeq = seq
            }
            return wire
        }
        let records = items.map {
            CloudRecord(recordName: $0.name, zone: id, kind: WireKind.envelope, modifiedAt: clock.now(), payload: $0.envelope)
        }
        do {
            let result = try await reach { try await self.client.save(save) }
            return HostedRelayTransport.saveOutcomes(result, items: records)
                ?? items.map { _ in .refused(.transient(code: "malformed_answer")) }
        } catch {
            return items.map { _ in .refused(HostedRelayTransport.refusal(for: error)) }
        }
    }

    func delete(_ zone: String, _ items: [SimDeleteItem]) async -> [DeleteOutcome] {
        guard !items.contains(where: { $0.expect == .absent }) else {
            return items.map { _ in .refused(.permanent(code: "unsupported_precondition")) }
        }
        var delete = Relay_V1_Delete()
        delete.zone = zone
        delete.items = items.map { item in
            var wire = Relay_V1_DeleteItem()
            wire.name = item.name
            if case .seq(let seq) = item.expect { wire.expectedSeq = seq }
            return wire
        }
        do {
            let result = try await reach { try await self.client.delete(delete) }
            return HostedRelayTransport.deleteOutcomes(result, zones: items.map { _ in Self.cloudZone(zone) })
                ?? items.map { _ in .refused(.transient(code: "malformed_answer")) }
        } catch {
            return items.map { _ in .refused(HostedRelayTransport.refusal(for: error)) }
        }
    }

    func changes(_ zone: String, since: UInt64) async throws -> SimChanges {
        let id = Self.cloudZone(zone)
        var changed: [CloudRecord] = []
        var deleted: [String] = []
        var seq = since
        while true {
            var request = Relay_V1_Changes()
            request.zone = zone
            request.sinceSeq = seq
            let page: Relay_V1_ChangesResult
            do {
                page = try await reach { try await self.client.changes(request) }
            } catch {
                let refusal = HostedRelayTransport.refusal(for: error)
                if refusal == .unreachable { throw SimUnavailable() }
                throw SimRefused(refusal: refusal)
            }
            for record in page.changed {
                if record.deleted {
                    deleted.append(record.name)
                } else {
                    changed.append(HostedRelayTransport.cloudRecord(record, zone: id))
                }
            }
            deleted += page.deleted
            seq = page.newSeq
            if !page.more { return SimChanges(changed: changed, deleted: deleted, newSeq: seq) }
        }
    }

    func available() async -> Bool {
        !failed.withLock { $0 }
    }

    func takeControls() async -> [SimControl] {
        controls.take()
    }

    func pendingControls() -> [SimControl] {
        controls.pending
    }

    /// Runs one call and records whether the server was reachable (Go `do`).
    private func reach<T>(_ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            failed.withLock { $0 = false }
            return value
        } catch {
            failed.withLock { $0 = HostedRelayTransport.refusal(for: error) == .unreachable }
            throw error
        }
    }

    private static func cloudZone(_ zone: String) -> CloudZoneID {
        zone.hasPrefix("data/") ? .data : .relay
    }
}
