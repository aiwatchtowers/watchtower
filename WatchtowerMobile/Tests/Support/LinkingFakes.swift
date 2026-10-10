import Foundation
import WatchtowerSync
@testable import WatchtowerMobile

/// A clock the link flow's waits run against: `sleep` advances `now` at
/// once, so a 60 s grant wait takes no wall time. `parked` makes every
/// sleep wait until its task is cancelled (the app killed mid-wait).
final class FakeLinkClock: LinkClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleptTotal: TimeInterval = 0
    private var isParked = false

    init(now: Date) {
        current = now
    }

    var slept: TimeInterval { lock.withLock { sleptTotal } }

    var parked: Bool {
        get { lock.withLock { isParked } }
        set { lock.withLock { isParked = newValue } }
    }

    func now() -> Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        if parked {
            // Bounded by the test: it cancels the task, and Task.sleep throws.
            while true {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        lock.withLock {
            current = current.addingTimeInterval(seconds)
            sleptTotal += seconds
        }
        await Task.yield()
    }
}

/// The order the fakes saw the flow's steps in.
@MainActor
final class LinkEventLog {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

/// The phone's iCloud identity and share accept, scripted.
@MainActor
final class FakeLinkContainer: LinkContainer {
    var status: CloudAvailability = .available
    var userRecordNameValue = "_owner-acme"
    var acceptError: (any Error)?
    private(set) var accepted: [[URL]] = []
    private(set) var left: [String] = []
    /// Runs inside `leaveShares`, before it returns: what arrives while the
    /// Mac's zones go away.
    var onLeave: (@MainActor () async -> Void)?
    let log: LinkEventLog

    init(log: LinkEventLog) {
        self.log = log
    }

    func accountStatus() async -> CloudAvailability { status }

    func userRecordName() async throws -> String { userRecordNameValue }

    func acceptShares(_ urls: [URL]) async throws {
        log.append("accept \(urls.count)")
        if let acceptError { throw acceptError }
        accepted.append(urls)
    }

    func leaveShares(ownerName: String) async throws {
        log.append("leave \(ownerName)")
        left.append(ownerName)
        await onLeave?()
    }
}

/// A transport that keeps every save in order (the in-memory transport
/// coalesces rewrites of one record name), so tests count device writes.
actor SaveLogTransport: CloudSyncTransport {
    private(set) var saved: [CloudRecord] = []

    func save(_ records: [CloudRecord]) async throws {
        saved += records
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {}

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        CloudChangeBatch(changed: [], deletedRecordNames: [], newToken: token ?? CloudChangeToken(value: 0))
    }

    /// Every `device` record saved, in write order.
    func deviceWrites() throws -> [DevicePayload] {
        try saved
            .filter { $0.kind == RelayRecordKind.device.rawValue }
            .map { try RelayCoder.makeDecoder().decode(DevicePayload.self, from: $0.payload) }
    }
}

/// The app side of the link flow: one save-log transport per database
/// scope, a scripted Mac answering the device records written so far, and
/// counters for the link, the wipe and the permission prompt.
@MainActor
final class FakeLinkHost: LinkHost {
    let log: LinkEventLog
    /// Keyed by `describe(scope)`: the scope type is not Hashable.
    private(set) var transports: [String: SaveLogTransport] = [:]
    private(set) var prepared: [CloudDatabaseScope] = []
    /// Every `setLink` call: the device and whether writes were allowed.
    private(set) var links: [(device: LinkedDevice?, writesAllowed: Bool)] = []
    private(set) var wipes = 0
    private(set) var flushes = 0
    private(set) var permissionRequests = 0
    private(set) var openedNow = 0
    /// What the wipe reports as not sent.
    var notSentCount = 0
    /// The Mac: answers from every device record written so far, both
    /// databases, in write order. nil = no grant in the replica.
    var mac: @MainActor (_ writes: [DevicePayload]) -> DeviceGrant? = { _ in nil }

    init(log: LinkEventLog) {
        self.log = log
    }

    /// When true, `prepare` waits until its task is cancelled (the app
    /// killed while the sync stack restarts).
    var parksPrepare = false

    func prepare(scope: CloudDatabaseScope) async throws -> any CloudSyncTransport {
        log.append("prepare \(Self.describe(scope))")
        prepared.append(scope)
        while parksPrepare {
            try await Task.sleep(for: .milliseconds(5))
        }
        return transport(for: scope)
    }

    func fetchGrant(deviceID: String) async -> DeviceGrant? {
        mac((try? await deviceWrites()) ?? [])
    }

    func setLink(_ device: LinkedDevice?, writesAllowed: Bool) async {
        links.append((device, writesAllowed))
    }

    func devicePayload(for device: LinkedDevice, linkNonce: String?, unlinked: Bool, now: Date) -> DevicePayload {
        DevicePayload(
            deviceID: device.deviceID,
            name: device.name,
            model: device.model,
            appVersion: device.appVersion,
            scope: device.scope,
            userRecordName: device.userRecordName,
            linkNonce: linkNonce,
            unlinked: unlinked ? true : nil,
            typingRequested: false,
            startSessions: true,
            updatedAt: now
        )
    }

    func flushSends() async {
        flushes += 1
    }

    func wipeLocalData(restartingOn scope: CloudDatabaseScope) async -> Int {
        log.append("wipe \(Self.describe(scope))")
        wipes += 1
        return notSentCount
    }

    func requestNotificationPermission() async {
        permissionRequests += 1
    }

    func openNow() {
        openedNow += 1
    }

    func transport(for scope: CloudDatabaseScope) -> SaveLogTransport {
        if let existing = transports[Self.describe(scope)] { return existing }
        let created = SaveLogTransport()
        transports[Self.describe(scope)] = created
        return created
    }

    /// Every `device` record written to one database, in write order.
    func deviceWrites(in scope: CloudDatabaseScope) async throws -> [DevicePayload] {
        guard let transport = transports[Self.describe(scope)] else { return [] }
        return try await transport.deviceWrites()
    }

    /// Every `device` record written, both databases (private first).
    func deviceWrites() async throws -> [DevicePayload] {
        var all: [DevicePayload] = []
        for key in transports.keys.sorted() {
            all += try await transports[key]?.deviceWrites() ?? []
        }
        return all
    }

    static func describe(_ scope: CloudDatabaseScope) -> String {
        switch scope {
        case .private: "private"
        case let .shared(ownerName): "shared(\(ownerName))"
        }
    }
}
