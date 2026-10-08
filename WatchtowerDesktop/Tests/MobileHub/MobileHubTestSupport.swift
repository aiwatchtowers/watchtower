import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync

/// HubTransport stub: InMemoryCloudTransport record I/O plus steerable
/// availability, a log of every saved record (with the instant it was
/// saved) and counters for the lifecycle calls.
final class StubHubTransport: HubTransport, @unchecked Sendable {
    struct Saved {
        let record: CloudRecord
        let at: ContinuousClock.Instant
    }

    private let inner = InMemoryCloudTransport()
    private let lock = NSLock()
    private var currentAvailability: CloudAvailability
    private var startCount = 0
    private var savedLog: [Saved] = []
    private var resetHandler: (@Sendable () -> Void)?
    private var rejectedHandler: (@Sendable (String, CloudZoneID) -> Void)?

    init(availability: CloudAvailability = .available) {
        currentAvailability = availability
    }

    var starts: Int { lock.withLock { startCount } }
    var saved: [Saved] { lock.withLock { savedLog } }

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

    func start() async { lock.withLock { startCount += 1 } }
    func pull() async throws {}
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
        lock.withLock { savedLog.append(contentsOf: records.map { Saved(record: $0, at: now) }) }
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try await inner.delete(recordNames: recordNames, in: zone)
    }

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try await inner.changes(in: zone, since: token)
    }
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
