import Foundation

/// Test fake: an append-only event log per zone with CloudKit-like change
/// semantics (latest state per recordName since a token; deletes win).
///
/// Every stored version, plain `save` included, takes the next value of one
/// counter per zone as its `recordSeq`, which `changes` returns and the
/// conditional writes (`ConditionalTransport`) compare against.
public actor InMemoryCloudTransport: ConditionalTransport {
    private struct Event {
        let seq: Int
        let zone: CloudZoneID
        let recordName: String
        /// nil means tombstone (deleted)
        let record: CloudRecord?
    }

    private struct Key: Hashable {
        let zone: CloudZoneID
        let recordName: String
    }

    private var events: [Event] = []
    private var nextSeq = 1
    /// The last `recordSeq` handed out per zone.
    private var lastRecordSeq: [CloudZoneID: UInt64] = [:]
    /// The current record per name; a delete removes the entry.
    private var current: [Key: CloudRecord] = [:]
    /// Scripted refusals, consumed one per conditional item before any condition is checked.
    private var scriptedRefusals: [TransportRefusal] = []
    private var pendingGate: SaveGate?

    public init() {}

    public func save(_ records: [CloudRecord]) async throws {
        for record in records {
            store(record)
        }
    }

    public func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        for name in recordNames {
            tombstone(name, in: zone)
        }
    }

    public func save(_ items: [ConditionalSave]) async throws -> [SaveOutcome] {
        if let gate = pendingGate {
            pendingGate = nil
            await gate.arrive()
        }
        return items.map { item in
            if let refusal = takeScriptedRefusal() { return .refused(refusal) }
            let existing = current[Key(zone: item.record.zone, recordName: item.record.recordName)]
            switch (item.expect, existing) {
            case let (.absent, present?):
                return .conflict(current: present)
            case (.seq, nil):
                // There is no current record to hand back.
                return .refused(.permanent(code: "gone"))
            case let (.seq(expected), present?) where present.recordSeq != expected:
                return .conflict(current: present)
            default:
                return .saved(recordSeq: store(item.record))
            }
        }
    }

    public func delete(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome] {
        items.map { item in
            if let refusal = takeScriptedRefusal() { return .refused(refusal) }
            guard let present = current[Key(zone: item.zone, recordName: item.recordName)] else {
                // The seam's idempotent delete: an absent record is already deleted.
                return .deleted
            }
            switch item.expect {
            case .absent:
                return .conflict(current: present)
            case let .seq(expected) where present.recordSeq != expected:
                return .conflict(current: present)
            default:
                tombstone(item.recordName, in: item.zone)
                return .deleted
            }
        }
    }

    public func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        let floor = token?.value ?? 0
        let relevant = events.filter { $0.zone == zone && $0.seq > floor }

        // Latest event per recordName wins, in first-seen order.
        var latest: [String: Event] = [:]
        var order: [String] = []
        for event in relevant {
            if latest[event.recordName] == nil { order.append(event.recordName) }
            latest[event.recordName] = event
        }

        var changed: [CloudRecord] = []
        var deleted: [String] = []
        for name in order {
            if let record = latest[name]?.record {
                changed.append(record)
            } else {
                deleted.append(name)
            }
        }

        let zoneMax = relevant.map(\.seq).max() ?? floor
        return CloudChangeBatch(
            changed: changed,
            deletedRecordNames: deleted,
            newToken: CloudChangeToken(value: max(floor, zoneMax))
        )
    }

    // MARK: - Test hooks

    /// The next `count` conditional items (saves and deletes alike) come back `.refused(refusal)` and write nothing.
    func refuseNext(_ refusal: TransportRefusal, count: Int) {
        scriptedRefusals.append(contentsOf: Array(repeating: refusal, count: max(0, count)))
    }

    /// The next conditional `save(_ items:)` call waits at the returned gate until the test opens it; its conditions
    /// are checked only after that, against the state the transport has then. Only that call is gated: plain
    /// `save(_ records:)`, plain and conditional deletes, and later conditional saves go through at once.
    func suspendNextSave() -> SaveGate {
        let gate = SaveGate()
        pendingGate = gate
        return gate
    }

    // MARK: - Private

    @discardableResult
    private func store(_ record: CloudRecord) -> UInt64 {
        let recordSeq = (lastRecordSeq[record.zone] ?? 0) + 1
        lastRecordSeq[record.zone] = recordSeq
        let stored = CloudRecord(
            recordName: record.recordName,
            zone: record.zone,
            kind: record.kind,
            modifiedAt: record.modifiedAt,
            payload: record.payload,
            notifyLevel: record.notifyLevel,
            assetFileURL: record.assetFileURL,
            origin: record.origin,
            asset: record.asset,
            sealed: record.sealed,
            recordSeq: recordSeq
        )
        current[Key(zone: record.zone, recordName: record.recordName)] = stored
        append(zone: record.zone, recordName: record.recordName, record: stored)
        return recordSeq
    }

    private func tombstone(_ name: String, in zone: CloudZoneID) {
        current[Key(zone: zone, recordName: name)] = nil
        append(zone: zone, recordName: name, record: nil)
    }

    private func append(zone: CloudZoneID, recordName: String, record: CloudRecord?) {
        events.append(Event(seq: nextSeq, zone: zone, recordName: recordName, record: record))
        nextSeq += 1
    }

    private func takeScriptedRefusal() -> TransportRefusal? {
        scriptedRefusals.isEmpty ? nil : scriptedRefusals.removeFirst()
    }
}

/// A test gate for `InMemoryCloudTransport.suspendNextSave()`: the suspended save waits in `arrive()` until `open()`.
final class SaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var hasArrived = false
    private var saveWaiter: CheckedContinuation<Void, Never>?
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    /// Lets the suspended save go on (or, opened early, lets it pass straight through).
    func open() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            isOpen = true
            defer { saveWaiter = nil }
            return saveWaiter
        }
        waiter?.resume()
    }

    /// Returns once the suspended save has reached the gate.
    func waitUntilReached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let arrived = lock.withLock {
                if !hasArrived { arrivalWaiters.append(continuation) }
                return hasArrived
            }
            if arrived { continuation.resume() }
        }
    }

    /// Called by the suspended save.
    func arrive() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (open, waiters): (Bool, [CheckedContinuation<Void, Never>]) = lock.withLock {
                hasArrived = true
                let waiters = arrivalWaiters
                arrivalWaiters = []
                if !isOpen { saveWaiter = continuation }
                return (isOpen, waiters)
            }
            waiters.forEach { $0.resume() }
            if open { continuation.resume() }
        }
    }
}
