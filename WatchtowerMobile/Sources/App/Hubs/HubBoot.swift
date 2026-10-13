import Foundation
import os
import UIKit
import WatchtowerSync

/// Builds one hub's session on its own files (`HubPaths`). `row` is nil for
/// a hub that has no registry row yet (a link being made, an orphan being
/// cleared).
struct HubSessionFactory {
    let make: @MainActor (_ row: HubRow?, _ hubID: String, _ scope: CloudDatabaseScope, _ device: LinkedDevice?) throws -> HubSession

    /// The live app: a `CloudKitTransport` on the hub's own transport store
    /// and a session on the hub's replica and recordings folder, sharing
    /// the hold, with the battery counter and the boot's background work.
    static func live(paths: HubPaths) -> Self {
        Self { _, hubID, scope, device in
            try paths.prepare(hubID)
            let energy = BatteryDiagnostics.shared.counter
            let active = UIApplication.shared.applicationState == .active
            let transport = CloudKitTransport(
                store: try TransportStore(path: paths.transportStorePath(hubID)),
                scope: scope,
                hubID: hubID,
                role: .phone,
                energy: energy
            )
            return try HubSession(
                transport: transport,
                replicaPath: paths.replicaPath(hubID),
                transportKind: .cloudKit,
                hubID: hubID,
                linkedDevice: device,
                recordingsDirectory: paths.recordingsDirectory(hubID),
                hold: RecordingHold(directory: paths.holdDirectory),
                databaseScope: scope,
                startsActive: active,
                uploadRetriesAllowed: active,
                replicaObservesSuspension: true,
                energy: energy,
                startWork: BackgroundWork.starter()
            )
        }
    }
}

/// The launch steps before any session opens (multi-hub F2): an F1 phone's
/// single link moves into the registry layout once, and hub directories
/// left by a link that never completed are cleared.
enum HubBoot {
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "HubBoot")

    /// The SQLite side files that travel with a database, moved before it.
    private static let sideSuffixes = ["-wal", "-shm", "-journal"]

    /// The F1 Workbench choices, global before F2 (`DeviceSettings` keys
    /// them per hub now).
    private static let legacyDeviceKeys = ["typingRequested", "startSessions"]

    /// Moves an F1 phone into the registry layout, once: with an empty
    /// registry and a saved link, the link's replica, transport store and
    /// audio move into the hub's directories, its Workbench choices into
    /// the hub's keys, and the link into the registry (active); then the
    /// legacy link keys go. A failed move throws before the registry is
    /// written, so the next launch tries again from the same state. With
    /// an empty registry and no link, the legacy replica and transport
    /// store (an unlinked phone's) are deleted; the audio stays.
    /// `legacyTransportStorePath` is `AppEnvironment.liveTransportStorePath()`
    /// (#232's move out of the group has run, or failed and points there).
    static func migrateF1(
        store: LinkStore,
        registry: HubRegistry,
        paths: HubPaths,
        legacyGroupDirectory: URL,
        legacyTransportStorePath: String,
        legacyRecordings: URL,
        defaults: UserDefaults,
        now: Date,
        fileManager: FileManager = .default
    ) throws {
        guard try registry.rows().isEmpty else { return }
        let legacyReplica = legacyGroupDirectory.appendingPathComponent("replica.sqlite")
        let legacyTransport = URL(fileURLWithPath: legacyTransportStorePath)
        guard let link = store.link else {
            for database in [legacyReplica, legacyTransport] {
                try removeDatabase(database, fileManager: fileManager)
            }
            return
        }
        let hubID = link.hubID
        try paths.prepare(hubID)
        try moveDatabase(legacyReplica, to: URL(fileURLWithPath: paths.replicaPath(hubID)), fileManager: fileManager)
        try moveDatabase(legacyTransport, to: URL(fileURLWithPath: paths.transportStorePath(hubID)), fileManager: fileManager)
        try moveAudio(from: legacyRecordings, to: paths.recordingsDirectory(hubID), fileManager: fileManager)
        for key in legacyDeviceKeys {
            let legacy = "device.\(key)"
            let own = "hub.\(hubID).device.\(key)"
            if defaults.object(forKey: own) == nil, let value = defaults.object(forKey: legacy) as? Bool {
                defaults.set(value, forKey: own)
            }
            defaults.removeObject(forKey: legacy)
        }
        try registry.upsert(link, now: now)
        try registry.setActive(hubID)
        try registry.setGrantMissingSince(store.grantMissingSince, for: hubID)
        store.link = nil
        store.grantMissingSince = nil
        logger.notice("F1 link moved into the hub registry")
    }

    /// Hub directories with no registry row, other than `pendingHubID`'s
    /// (a link waiting for its grant), belong to a link that never
    /// completed: a session built on each (never started) hands its
    /// recordings to the hold, then its files are deleted.
    @MainActor
    static func removeOrphans(
        registry: HubRegistry,
        paths: HubPaths,
        keeping pendingHubID: String?,
        factory: HubSessionFactory
    ) async throws {
        let linked = Set(try registry.rows().map(\.hubID))
        for hubID in try paths.hubIDsOnDisk() where !linked.contains(hubID) && hubID != pendingHubID {
            let session = try factory.make(nil, hubID, .private, nil)
            // Stopped before its boot runs: no engine starts, no fetch.
            session.stop()
            await session.shutDown()
            let handover = await session.handOverRecordings(stoppedCapture: nil, keep: true)
            if let problem = handover.problem {
                logger.error("orphan hub recordings: \(problem, privacy: .public)")
            }
            try paths.removeHubFiles(hubID)
            logger.notice("removed the files of a link that never completed")
        }
    }

    // MARK: - Files

    /// Moves a SQLite database and its side files: the side files first and
    /// the database last, so a database at `target` means the move is done.
    /// A missing file is skipped; a side file already at `target` (an
    /// earlier attempt's) is replaced by the live one.
    private static func moveDatabase(_ source: URL, to target: URL, fileManager: FileManager) throws {
        for suffix in sideSuffixes {
            let from = URL(fileURLWithPath: source.path + suffix)
            guard fileManager.fileExists(atPath: from.path) else { continue }
            let to = URL(fileURLWithPath: target.path + suffix)
            if fileManager.fileExists(atPath: to.path) {
                try fileManager.removeItem(at: to)
            }
            try fileManager.moveItem(at: from, to: to)
        }
        guard fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.moveItem(at: source, to: target)
    }

    private static func removeDatabase(_ database: URL, fileManager: FileManager) throws {
        for path in [database.path] + sideSuffixes.map({ database.path + $0 }) where fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
    }

    /// Every non-hidden regular file of `source` (the hold and `hubs` are
    /// folders and stay). A name already taken in `target` keeps its source.
    private static func moveAudio(from source: URL, to target: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        let files = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for file in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let destination = target.appendingPathComponent(file.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else {
                logger.warning("recording \(file.lastPathComponent, privacy: .public) already in the hub's folder: kept in place")
                continue
            }
            try fileManager.moveItem(at: file, to: destination)
        }
    }
}
