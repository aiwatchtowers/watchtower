import Foundation
import GRDB
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// Everything the Workbench and Now tabs draw, decoded from the replica in
/// one database snapshot: the hub's resolved Workbench slices plus the
/// heartbeat. An undecodable record is skipped and counted in
/// `skippedRecords`, so a newer Mac's reshaped record never breaks a screen.
struct WorkbenchReplicaSnapshot: Equatable {
    var workbenches: [Workbench] = []
    var targets: [WorkbenchTarget] = []
    var sessions: [TerminalSessionState] = []
    var asks: [OwnerAsk] = []
    var comments: [WorkbenchComment] = []
    /// The Claude Code permission prompts live board sessions wait on
    /// (#517); the hub publishes only pending ones.
    var permissionRequests: [PermissionRequest] = []
    var heartbeat: HeartbeatPayload?
    /// The hub's `device_grant` records (spec §4.13); `grant(for:)` picks
    /// this phone's. An undecodable one is left out.
    var grants: [DeviceGrant] = []
    /// The outbox overlay: the phone's actions the Mac has not yet applied
    /// (pending) or refused (failed), oldest first.
    var pending: [PendingAction] = []
    /// Undecodable records per kind in this read; kinds without any are
    /// absent.
    var skippedRecords: [SliceKind: Int] = [:]

    /// The slice kinds this snapshot decodes.
    static let kinds: [SliceKind] = [
        Workbench.sliceKind, WorkbenchTarget.sliceKind, TerminalSessionState.sliceKind,
        OwnerAsk.sliceKind, WorkbenchComment.sliceKind, PermissionRequest.sliceKind, .heartbeat, .deviceGrant
    ]

    /// Reads from an ALREADY-OPEN database, so it runs inside a
    /// ValueObservation fetch. A kind whose change stamp is unchanged comes
    /// from `cache` undecoded; the default fresh cache decodes everything.
    static func read(from db: Database, store: ReplicaStore, cache: ReplicaDecodeCache = ReplicaDecodeCache()) throws -> Self {
        let versions = try store.kindVersions(kinds, from: db)
        var snapshot = Self()
        snapshot.workbenches = try snapshot.decodeAll(Workbench.self, store: store, from: db, cache: cache, versions: versions)
        snapshot.targets = try snapshot.decodeAll(WorkbenchTarget.self, store: store, from: db, cache: cache, versions: versions)
        snapshot.sessions = try snapshot.decodeAll(TerminalSessionState.self, store: store, from: db, cache: cache, versions: versions)
        snapshot.asks = try snapshot.decodeAll(OwnerAsk.self, store: store, from: db, cache: cache, versions: versions)
        snapshot.comments = try snapshot.decodeAll(WorkbenchComment.self, store: store, from: db, cache: cache, versions: versions)
        snapshot.permissionRequests = try snapshot.decodeAll(
            PermissionRequest.self, store: store, from: db, cache: cache, versions: versions
        )
        snapshot.heartbeat = try cache.value(HeartbeatPayload.recordName, version: versions[.heartbeat] ?? 0) {
            try SettingsSnapshot.decode(HeartbeatPayload.self, recordName: HeartbeatPayload.recordName, store: store, from: db)
        }
        snapshot.grants = try cache.value(SliceKind.deviceGrant.rawValue, version: versions[.deviceGrant] ?? 0) {
            let decoder = RelayCoder.makeDecoder()
            return try store.payloads(of: .deviceGrant, from: db).compactMap { try? decoder.decode(DeviceGrant.self, from: $0) }
        }
        snapshot.pending = try store.pendingActions(from: db)
        return snapshot
    }

    /// One kind's decoded records and how many did not decode.
    private struct Decoded<T> {
        let records: [T]
        let skipped: Int
    }

    private mutating func decodeAll<T: SliceMirror>(
        _ type: T.Type,
        store: ReplicaStore,
        from db: Database,
        cache: ReplicaDecodeCache,
        versions: [SliceKind: Int64]
    ) throws -> [T] {
        let decoded = try cache.value(T.sliceKind.rawValue, version: versions[T.sliceKind] ?? 0) {
            var skipped = 0
            let records = try store.payloads(of: T.sliceKind, from: db).compactMap { payload -> T? in
                do {
                    return try T.decode(payload: payload)
                } catch {
                    skipped += 1
                    return nil
                }
            }
            return Decoded(records: records, skipped: skipped)
        }
        if decoded.skipped > 0 {
            skippedRecords[T.sliceKind] = decoded.skipped
        }
        return decoded.records
    }

    /// The Workbench list's order: latest session activity first (none
    /// last), then by name.
    var orderedWorkbenches: [Workbench] {
        workbenches.sorted { lhs, rhs in
            switch (lhs.lastSessionActivity, rhs.lastSessionActivity) {
            case let (left?, right?) where left != right: left > right
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    func workbench(_ id: Int64) -> Workbench? {
        workbenches.first { $0.id == id }
    }

    /// This phone's grant; nil while unlinked or before the hub wrote one.
    func grant(for deviceID: String?) -> DeviceGrant? {
        deviceID.flatMap { id in grants.first { $0.deviceID == id } }
    }

    func session(_ id: Int64) -> TerminalSessionState? {
        sessions.first { $0.id == id }
    }

    /// Open asks, newest first; all workbenches when `workbenchID` is nil.
    func openAsks(in workbenchID: Int64? = nil) -> [OwnerAsk] {
        asks
            .filter { $0.status == .open && (workbenchID == nil || $0.workbenchID == workbenchID) }
            .sorted(by: Self.newestFirst)
    }

    /// The pending permission requests, newest first (the hub closes a
    /// session's older one when the next opens: one per session).
    var pendingPermissions: [PermissionRequest] {
        permissionRequests.sorted { Self.olderRequest($1, $0) }
    }

    /// The prompt `sessionID` waits on; nil without one.
    func pendingPermission(for sessionID: Int64) -> PermissionRequest? {
        permissionRequests.filter { $0.sessionID == sessionID }.max(by: Self.olderRequest)
    }

    /// Open asks plus pending permission requests (the hub switcher's
    /// questions waiting on another Mac).
    var openAskCount: Int {
        openAsks().count + pendingPermissions.count
    }

    /// Failed sessions the owner can continue from this phone
    /// (`SessionInputModel.waitsToContinue`), unless an open ask of theirs
    /// already waits: one row per thing (ask #622).
    func sessionsToContinue(typing: PhoneTyping) -> [TerminalSessionState] {
        guard typing.allowed else { return [] }
        let asked = Set(openAsks().compactMap(\.sessionID))
        return sessions.filter { !asked.contains($0.id) && SessionInputModel.waitsToContinue($0, in: self, typing: typing) }
    }

    /// Everything Now's Waiting for you lists (#1788, #1785 follow-up): open
    /// asks, pending permission requests and failed sessions to continue.
    /// The Now tab's badge; summed over the hubs, the app icon's.
    func waitingCount(typing: PhoneTyping) -> Int {
        openAskCount + sessionsToContinue(typing: typing).count
    }

    private static func olderRequest(_ lhs: PermissionRequest, _ rhs: PermissionRequest) -> Bool {
        lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.id < rhs.id
    }

    static func newestFirst(_ lhs: OwnerAsk, _ rhs: OwnerAsk) -> Bool {
        lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.id > rhs.id
    }
}

/// Live replica state for one tab root: one observation over the change
/// stamps of its kinds and the outbox overlay.
@MainActor
@Observable
final class WorkbenchReplicaModel {
    private(set) var snapshot = WorkbenchReplicaSnapshot()
    /// `snapshot.waitingCount(typing:)` across all workbenches: the Now
    /// tab's badge. Its own property, so the tab bar re-renders only when
    /// it changes.
    private(set) var waitingCount = 0
    /// The phone's typing to this hub, from the hub session (the owner's
    /// toggle and the link's device id); `waitingCount` follows it.
    var typing = PhoneTypingSource() {
        didSet { if typing != oldValue { recount() } }
    }
    /// The decoded kinds between reads (and the tests' decode counter).
    @ObservationIgnored let decodeCache = ReplicaDecodeCache()
    @ObservationIgnored private var cancellable: ResilientObservation?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "WorkbenchReplicaModel")

    /// Re-read when a stamp changes (any kind's write) or the overlay does;
    /// only this snapshot's changed kinds decode again, and a read that
    /// leaves it equal publishes nothing.
    nonisolated static func observation(
        store: ReplicaStore,
        cache: ReplicaDecodeCache = ReplicaDecodeCache()
    ) -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<WorkbenchReplicaSnapshot>>> {
        ValueObservation.tracking(regions: [ReplicaStore.kindVersionsRegion, ReplicaStore.pendingActionsRegion]) { db in
            try WorkbenchReplicaSnapshot.read(from: db, store: store, cache: cache)
        }
        .removeDuplicates()
    }

    /// `settings`: the hub's device settings, whose typing toggle (and linked device) the badge follows; the hub
    /// session moves the device on a link change (`typing.deviceID`).
    func start(store: ReplicaStore, gate: ReplicaObservationGate? = nil, following settings: DeviceSettings? = nil) {
        guard cancellable == nil else { return }
        if let settings {
            typing = PhoneTypingSource(deviceID: settings.linkedDevice?.deviceID, requested: settings.typingRequested)
            settings.onTypingRequested = { [weak self] in self?.typing.requested = $0 }
        }
        let cache = decodeCache
        cancellable = ResilientObservation(
            name: "workbench",
            reader: store.reader,
            gate: gate,
            observation: { Self.observation(store: store, cache: cache) },
            onChange: { [weak self] value in self?.receive(value) }
        )
    }

    /// Logs the skipped records only when their count changes, not on
    /// every replica write.
    private func receive(_ value: WorkbenchReplicaSnapshot) {
        if value.skippedRecords != snapshot.skippedRecords {
            for (kind, count) in value.skippedRecords.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                Self.logger.warning("\(count) undecodable \(kind.rawValue, privacy: .public) records skipped")
            }
        }
        snapshot = value
        recount()
    }

    private func recount() {
        let waiting = snapshot.waitingCount(typing: typing.typing(in: snapshot))
        if waiting != waitingCount {
            waitingCount = waiting
        }
    }
}

/// What the replica needs to know of the phone's typing: the linked device (its grant is in the snapshot) and the
/// owner's own toggle.
struct PhoneTypingSource: Equatable {
    var deviceID: String?
    var requested = false

    func typing(in snapshot: WorkbenchReplicaSnapshot) -> PhoneTyping {
        PhoneTyping(grant: snapshot.grant(for: deviceID), requested: requested)
    }
}
