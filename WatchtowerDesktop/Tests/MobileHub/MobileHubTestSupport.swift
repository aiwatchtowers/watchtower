import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync

/// HubTransport stub: InMemoryCloudTransport record I/O plus steerable
/// availability, a log of every saved record (with the instant it was
/// saved) and counters for the lifecycle calls. Two stubs over one `cloud`
/// are two Macs on one iCloud account. `echoesOwnSaves: false` mirrors
/// CloudKitTransport, whose buffer never holds the device's own saves.
final class StubHubTransport: HubTransport, @unchecked Sendable {
    struct Saved {
        let record: CloudRecord
        let at: ContinuousClock.Instant
    }

    private let inner: InMemoryCloudTransport
    private let lock = NSLock()
    private var currentAvailability: CloudAvailability
    private var startCount = 0
    private var stopCount = 0
    private var lifecycleLog: [String] = []
    private var appliedIDs: [String] = []
    private var savedLog: [Saved] = []
    private var sendNowCount = 0
    private var resetHandler: (@Sendable () -> Void)?
    private var rejectedHandler: (@Sendable (String, CloudZoneID) -> Void)?
    private var pullHangs = false
    private var pullFails = false
    private var dataChangesFail = false
    private let echoesOwnSaves: Bool
    private var ownPayloads: Set<Data> = []

    init(
        availability: CloudAvailability = .available,
        cloud: InMemoryCloudTransport = InMemoryCloudTransport(),
        echoesOwnSaves: Bool = true
    ) {
        currentAvailability = availability
        inner = cloud
        self.echoesOwnSaves = echoesOwnSaves
    }

    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
    /// "start" / "stop", in call order.
    var lifecycle: [String] { lock.withLock { lifecycleLog } }
    /// Ids of every `applied` action echo saved, in order — counted here, on
    /// save, so a test polls an O(1) value instead of re-decoding the log.
    var appliedEchoIDs: [String] { lock.withLock { appliedIDs } }
    var saved: [Saved] { lock.withLock { savedLog } }
    /// How many times the hub asked for an immediate send.
    var sendNowCalls: Int { lock.withLock { sendNowCount } }

    /// A pull that never returns until it is cancelled (a hung CloudKit fetch).
    func setPullHangs(_ value: Bool) {
        lock.withLock { pullHangs = value }
    }

    /// A pull that fails at once (CloudKit offline).
    func setPullFails(_ value: Bool) {
        lock.withLock { pullFails = value }
    }

    /// `changes(in: .data, …)` throws (a broken local buffer).
    func setDataChangesFail(_ value: Bool) {
        lock.withLock { dataChangesFail = value }
    }

    func setAvailability(_ value: CloudAvailability) {
        lock.withLock { currentAvailability = value }
    }

    func fireAccountReset() {
        let handler = lock.withLock { resetHandler }
        handler?()
    }

    func fireRecordRejected(_ recordName: String, zone: CloudZoneID) {
        let handler = lock.withLock { rejectedHandler }
        handler?(recordName, zone)
    }

    func start() async {
        lock.withLock {
            startCount += 1
            lifecycleLog.append("start")
        }
    }

    func stop() async {
        lock.withLock {
            stopCount += 1
            lifecycleLog.append("stop")
        }
    }
    func sendNow() async {
        lock.withLock { sendNowCount += 1 }
    }

    func pull() async throws {
        let (hangs, fails) = lock.withLock { (pullHangs, pullFails) }
        if fails { throw URLError(.notConnectedToInternet) }
        guard hangs else { return }
        try await Task.sleep(for: .seconds(3600))
    }
    func availability() async -> CloudAvailability { lock.withLock { currentAvailability } }

    func setAccountResetHandler(_ handler: (@Sendable () -> Void)?) async {
        lock.withLock { resetHandler = handler }
    }

    func setRecordRejectedHandler(_ handler: (@Sendable (String, CloudZoneID) -> Void)?) async {
        lock.withLock { rejectedHandler = handler }
    }

    func save(_ records: [CloudRecord]) async throws {
        try await inner.save(records)
        let now = ContinuousClock.now
        let applied = records.compactMap { record -> String? in
            guard record.kind == RelayRecordKind.action.rawValue,
                  let action = try? decodeAction(record), action.status == .applied else { return nil }
            return action.id
        }
        lock.withLock {
            ownPayloads.formUnion(records.map(\.payload))
            savedLog.append(contentsOf: records.map { Saved(record: $0, at: now) })
            appliedIDs.append(contentsOf: applied)
        }
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try await inner.delete(recordNames: recordNames, in: zone)
    }

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        let (fails, own) = lock.withLock { (dataChangesFail && zone == .data, echoesOwnSaves ? [] : ownPayloads) }
        if fails { throw CocoaError(.fileReadCorruptFile) }
        let batch = try await inner.changes(in: zone, since: token)
        guard !own.isEmpty else { return batch }
        return CloudChangeBatch(
            changed: batch.changed.filter { !own.contains($0.payload) },
            deletedRecordNames: batch.deletedRecordNames,
            newToken: batch.newToken
        )
    }
}

/// Host facts for a test hub: no host lookup, no main DB, no CloudKit.
func testHostInfo(
    macName: String = "Mac acme",
    flavor: HubFlavor = .default,
    accounts: @escaping @Sendable () -> [HeartbeatAccount] = { [] },
    ownerUser: String? = "_owner-acme"
) -> HubHostInfo {
    HubHostInfo(macName: macName, appVersion: "0.0.0-test", flavor: flavor, accounts: accounts) { ownerUser }
}

/// A slice source whose records the test sets; counts its reads.
final class StubSliceSource: SliceSource, @unchecked Sendable {
    let kind: SliceKind
    private let lock = NSLock()
    private var current: [SliceRecord] = []
    private var readCount = 0

    init(kind: SliceKind) {
        self.kind = kind
    }

    var reads: Int { lock.withLock { readCount } }

    func setRecords(_ records: [SliceRecord]) {
        lock.withLock { current = records }
    }

    /// One record `<kind>-<id>` whose payload is `payload`.
    func setPayload(_ payload: Data, id: String = "1") {
        setRecords([SliceRecord(kind: kind, id: id, modifiedAt: Date(), payload: payload)])
    }

    func records(_ db: Database) throws -> [SliceRecord] {
        lock.withLock {
            readCount += 1
            return current
        }
    }
}

/// Polls `condition` until it holds or `timeout` passes, then fails.
func awaitHubCondition(
    _ message: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async throws -> Bool
) async rethrows {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail(message, file: file, line: line)
}

/// A pending phone action record, `createdAt` = `age` seconds before `now`.
func pendingActionRecord(
    id: String = UUID().uuidString,
    kind: ActionKind,
    entityID: String? = nil,
    params: [String: JSONValue] = [:],
    age: TimeInterval = 0,
    now: Date = Date()
) throws -> CloudRecord {
    let created = now.addingTimeInterval(-age)
    let action = ActionRequestPayload(
        id: id, kind: kind, entityID: entityID, params: params, createdAt: created, deviceID: "device-a"
    )
    return try CloudRecordFactory.record(for: action, modifiedAt: created)
}

func decodeAction(_ record: CloudRecord) throws -> ActionRequestPayload {
    try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
}

/// Parks a handler until the test releases it; counts entries per action.
@MainActor
final class HandlerLatch {
    private(set) var calls: [String: Int] = [:]
    private var isOpen = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    var entries: Int { calls.values.reduce(0, +) }

    /// Called by the handler: records the action, then waits while closed.
    func enter(_ action: ActionRequestPayload) async {
        calls[action.id, default: 0] += 1
        guard !isOpen else { return }
        await withCheckedContinuation { parked.append($0) }
    }

    func release() {
        isOpen = true
        let waiting = parked
        parked = []
        waiting.forEach { $0.resume() }
    }
}
