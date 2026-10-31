import Foundation
import os
import WatchtowerHostedRelay
@testable import WatchtowerSync

/// The CloudKit leg (R12, amended): the Kit's own `InMemoryCloudTransport` as a
/// `ConditionalTransport`, one instance per mailbox (its `.relay` zone) and one for the data
/// zone (its `.data` zone), shared by the hub and every phone like Go's `FakeCloudKit`. It adds
/// only the sim's availability switch (Go `SetAvailable`): while down, every write is
/// `.refused(.unreachable)` and every read throws `SimUnavailable`.
final class SimCloudKitLeg: SimTransport {
    private struct Zone {
        let store: InMemoryCloudTransport
        let id: CloudZoneID
    }

    private struct State {
        var down = false
        var zones: [String: Zone] = [:]
    }

    let kind = SimKind.cloudkit
    private let clock: any RelayClock
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(clock: any RelayClock) {
        self.clock = clock
    }

    /// Adds a phone's mailbox (an instance of its own).
    func addMailbox(_ zone: String) {
        add(zone, .relay)
    }

    /// Adds the hub's data zone (an instance of its own).
    func addDataZone(_ zone: String) {
        add(zone, .data)
    }

    /// Turns the outage off (true) or on (false).
    func setAvailable(_ isAvailable: Bool) {
        state.withLock { $0.down = !isAvailable }
    }

    /// The instance behind `zone`, for a test's own hooks (`refuseNext`, `suspendNextSave`).
    func store(for zone: String) -> InMemoryCloudTransport? {
        state.withLock { $0.zones[zone]?.store }
    }

    /// The names of the live records in `zone`, ignoring the outage.
    func live(_ zone: String) async -> [String] {
        guard let target = state.withLock({ $0.zones[zone] }),
              let batch = try? await target.store.changes(in: target.id, since: nil)
        else { return [] }
        return batch.changed.map(\.recordName).sorted()
    }

    // MARK: - SimTransport

    func available() -> Bool {
        state.withLock { !$0.down }
    }

    func save(_ zone: String, _ items: [SimSaveItem]) async -> [SaveOutcome] {
        guard let target = reachable(zone) else { return items.map { _ in .refused(refusal(zone)) } }
        let saves = items.map { item in
            ConditionalSave(
                record: CloudRecord(
                    recordName: item.name, zone: target.id, kind: WireKind.envelope, modifiedAt: clock.now(), payload: item.envelope),
                expect: item.expect)
        }
        do {
            return try await target.store.save(saves)
        } catch {
            return items.map { _ in .refused(.unreachable) } // a local failure: retried next pass
        }
    }

    func delete(_ zone: String, _ items: [SimDeleteItem]) async -> [DeleteOutcome] {
        guard let target = reachable(zone) else { return items.map { _ in .refused(refusal(zone)) } }
        do {
            return try await target.store.delete(items.map { ConditionalDelete(recordName: $0.name, zone: target.id, expect: $0.expect) })
        } catch {
            return items.map { _ in .refused(.unreachable) } // a local failure: retried next pass
        }
    }

    func changes(_ zone: String, since: UInt64) async throws -> SimChanges {
        guard let target = reachable(zone) else {
            if refusal(zone) == .unreachable { throw SimUnavailable() }
            throw SimRefused(refusal: refusal(zone))
        }
        let batch = try await target.store.changes(in: target.id, since: since == 0 ? nil : CloudChangeToken(value: Int(since)))
        return SimChanges(changed: batch.changed, deleted: batch.deletedRecordNames, newSeq: UInt64(batch.newToken.value))
    }

    func takeControls() async -> [SimControl] {
        []
    }

    func pendingControls() -> [SimControl] {
        []
    }

    // MARK: - Private

    private func add(_ zone: String, _ id: CloudZoneID) {
        state.withLock { state in
            if state.zones[zone] == nil { state.zones[zone] = Zone(store: InMemoryCloudTransport(), id: id) }
        }
    }

    /// The zone when CloudKit is up and the zone exists.
    private func reachable(_ zone: String) -> Zone? {
        state.withLock { $0.down ? nil : $0.zones[zone] }
    }

    /// Why `reachable` found nothing.
    private func refusal(_ zone: String) -> TransportRefusal {
        state.withLock { $0.down ? .unreachable : .permanent(code: "no_zone") }
    }
}
