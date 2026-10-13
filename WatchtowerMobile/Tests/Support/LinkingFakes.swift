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
    private var monotonic: TimeInterval = 0
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

    func uptime() -> TimeInterval { lock.withLock { monotonic } }

    func advance(by seconds: TimeInterval) {
        lock.withLock {
            current = current.addingTimeInterval(seconds)
            monotonic += seconds
        }
    }

    /// A wall-clock jump (the owner sets the time, a network sync): `now()`
    /// moves, `uptime()` does not.
    func jumpWallClock(by seconds: TimeInterval) {
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
            monotonic += seconds
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
    var leaveError: (any Error)?
    private(set) var accepted: [[URL]] = []
    private(set) var left: [String] = []
    /// The hub of each `leaveShares`, in call order.
    private(set) var leftHubIDs: [String] = []
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

    func leaveShares(ownerName: String, hubID: String) async throws {
        log.append("leave \(ownerName)")
        if let leaveError { throw leaveError }
        left.append(ownerName)
        leftHubIDs.append(hubID)
        await onLeave?()
    }
}

/// A transport that keeps every save in order (the in-memory transport
/// coalesces rewrites of one record name), so tests count device writes.
/// With a sealer (the phone's `SecureTransport` for the prepared hub) each
/// record is also sealed as the app's link transport does, and kept in
/// `sealed`: a record that cannot be sealed throws, as on a device.
actor SaveLogTransport: CloudSyncTransport {
    private(set) var saved: [CloudRecord] = []
    private(set) var sealed: [CloudRecord] = []
    private var sealer: SecureTransport?

    func setSealer(_ sealer: SecureTransport?) {
        self.sealer = sealer
    }

    func save(_ records: [CloudRecord]) async throws {
        if let sealer {
            var wire: [CloudRecord] = []
            for record in records { wire.append(try await sealer.seal(record)) }
            sealed += wire
        }
        saved += records
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {}

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        CloudChangeBatch(changed: [], deletedRecordNames: [], newToken: token ?? CloudChangeToken(value: 0))
    }

    /// Every device record saved (a hello's device record, or a plain
    /// `device` record), in write order.
    func deviceWrites() throws -> [DevicePayload] {
        try saved.compactMap { record in
            switch record.kind {
            case RelayRecordKind.device.rawValue:
                try RelayCoder.makeDecoder().decode(DevicePayload.self, from: record.payload)
            case RelayRecordKind.hello.rawValue:
                try RelayCoder.makeDecoder().decode(DeviceHello.self, from: record.payload).device
            default:
                nil
            }
        }
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
    /// The hub of each `prepare`, in call order.
    private(set) var preparedHubIDs: [String] = []
    /// Every `setLink` call: the device and whether writes were allowed.
    private(set) var links: [(device: LinkedDevice?, writesAllowed: Bool)] = []
    private(set) var wipes = 0
    private(set) var flushes = 0
    private(set) var permissionRequests = 0
    private(set) var openedNow = 0
    /// What the next wipe reports as not sent (once).
    var notSentCount = 0
    /// The Mac: answers from every device record written so far, both
    /// databases, in write order. nil = no grant in the replica.
    var mac: @MainActor (_ writes: [DevicePayload]) -> DeviceGrant? = { _ in nil }
    /// The keys a linked (unrevoked) grant's keybox carries.
    var keyboxKeys: KeyboxKeys? = TestPhone.keyboxKeys()
    /// The phone's key store: what is saved through a prepared transport is
    /// sealed with it for the prepared hub. nil: plain saves only.
    var keys: (any PhoneKeyStore)?
    /// `fresh` of each `prepare`, in call order.
    private(set) var preparedFresh: [Bool] = []

    init(log: LinkEventLog) {
        self.log = log
    }

    /// When true, `prepare` waits until its task is cancelled (the app
    /// killed while the sync stack restarts).
    var parksPrepare = false
    /// Thrown by `prepare` (the sync stack could not restart).
    var prepareError: (any Error)?

    func prepare(scope: CloudDatabaseScope, hubID: String, fresh: Bool) async throws -> any CloudSyncTransport {
        log.append("prepare \(Self.describe(scope))")
        prepared.append(scope)
        preparedHubIDs.append(hubID)
        preparedFresh.append(fresh)
        while parksPrepare {
            try await Task.sleep(for: .milliseconds(5))
        }
        if let prepareError { throw prepareError }
        let transport = transport(for: scope)
        if let keys {
            let provider = try PhoneKeyProvider(store: keys, hubID: hubID, seq: SeqAllocator(load: { 1 }, store: { _ in }))
            await transport.setSealer(SecureTransport(inner: InMemoryCloudTransport(), keys: provider, rollback: InMemoryRollbackGuard()))
        }
        return transport
    }

    /// When true, `fetchKeybox` waits until it is set false again (a link
    /// flow held mid-check).
    var parksFetchGrant = false

    func fetchKeybox(deviceID: String) async -> Keybox? {
        while parksFetchGrant {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await storedKeybox(deviceID: deviceID)
    }

    func storedKeybox(deviceID: String) async -> Keybox? {
        guard let grant = mac((try? await deviceWrites()) ?? []) else { return nil }
        return Keybox(grant: grant, keys: grant.linked && grant.revoked != true ? keyboxKeys : nil)
    }

    /// How many times the flow reported merged epoch keys.
    private(set) var keyMerges = 0

    func keysMerged() {
        keyMerges += 1
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

    private(set) var retirements = 0

    func retireEnvironment() {
        log.append("retire")
        retirements += 1
    }

    /// The hub of each wipe's restart, in call order.
    private(set) var wipedHubIDs: [String] = []

    /// The next wipe reports a capture it stopped and kept (once; as the
    /// real host, never when the recordings are not kept).
    var stopsRecording = false
    /// The next wipe reports a recording problem (once).
    var recordingProblem: String?

    /// `keepRecordings` of each wipe, in call order.
    private(set) var wipesKeptRecordings: [Bool] = []

    func wipeLocalData(restartingOn scope: CloudDatabaseScope, hubID: String, keepRecordings: Bool) async -> LocalWipe {
        wipedHubIDs.append(hubID)
        wipesKeptRecordings.append(keepRecordings)
        log.append("wipe \(Self.describe(scope))")
        wipes += 1
        // A second wipe finds nothing left: what the first lost was counted.
        defer {
            stopsRecording = false
            recordingProblem = nil
            notSentCount = 0
        }
        return LocalWipe(notSent: notSentCount, stoppedRecording: stopsRecording && keepRecordings, problem: recordingProblem)
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
