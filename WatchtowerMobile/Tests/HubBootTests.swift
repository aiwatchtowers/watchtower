import Foundation
import GRDB
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The registry boot (multi-hub F2): an F1 phone's one link and its files
/// move into the registry layout once, without losing the link, the replica
/// or unsent recordings; a hub directory left by a link that never
/// completed is handed to the hold and removed; the live boot builds one
/// session per registry row.
@MainActor
final class HubBootTests: XCTestCase {
    private let device = LinkedDevice(
        deviceID: "device-acme-1",
        name: "Acme iPhone",
        model: "iPhone",
        appVersion: "1.0",
        scope: .private,
        userRecordName: "_owner-acme"
    )
    /// Hubs the test factory built, in order.
    private var built: [String] = []

    // MARK: - Fixtures

    private func makePaths() throws -> HubPaths {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hub-boot-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let paths = HubPaths(
            groupDirectory: base.appendingPathComponent("group", isDirectory: true),
            localDirectory: base.appendingPathComponent("local", isDirectory: true),
            recordingsBase: base.appendingPathComponent("phone-recordings", isDirectory: true)
        )
        for directory in [paths.groupDirectory, paths.localDirectory, paths.recordingsBase] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return paths
    }

    private func link(_ hubID: String, mac: String = "Acme Mac") -> LinkRecord {
        LinkRecord(
            hubID: hubID, macName: mac, scope: .private, ownerName: "_owner-acme", userRecordName: "_owner-acme",
            nonce: "nonce-\(hubID)", dataShareURL: nil, relayShareURL: nil, deviceID: "device-acme-1", linkedAt: nil
        )
    }

    private func legacyReplica(_ paths: HubPaths) -> URL {
        paths.groupDirectory.appendingPathComponent("replica.sqlite")
    }

    private func legacyLocalTransport(_ paths: HubPaths) -> URL {
        paths.localDirectory.appendingPathComponent(AppEnvironment.transportStoreFileName)
    }

    /// A replica at `replicaPath` with one waiting recording whose audio,
    /// `rec-1.m4a`, is in `recordings`. Returns the recording's id.
    private func seedRecording(replicaPath: String, recordings: URL) async throws -> String {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let audio = recordings.appendingPathComponent("rec-1.m4a")
        try Data(repeating: 0x5A, count: 256).write(to: audio)
        let uploader = RecordingUploader(
            transport: try TestPhone.transport(),
            store: try TestPhone.replica(path: replicaPath),
            directory: recordings
        )
        let now = Date()
        let row = try await uploader.register(
            fileURL: audio, startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-60), titleHint: "Acme sync"
        )
        return try XCTUnwrap(row).id
    }

    private func makeTransportStore(at url: URL) throws {
        _ = try TransportStore(path: url.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    private func migrate(
        _ store: LinkStore,
        _ registry: HubRegistry,
        _ paths: HubPaths,
        transport: URL,
        defaults: UserDefaults,
        fileManager: FileManager = .default
    ) throws {
        try HubBoot.migrateF1(
            store: store,
            registry: registry,
            paths: paths,
            legacyGroupDirectory: paths.groupDirectory,
            legacyTransportStorePath: transport.path,
            legacyRecordings: paths.recordingsBase,
            defaults: defaults,
            now: Date(timeIntervalSince1970: 1_000),
            fileManager: fileManager
        )
    }

    /// Every file under `paths`' three trees, relative.
    private func fileTree(_ paths: HubPaths) -> [String] {
        let files = [paths.groupDirectory, paths.localDirectory, paths.recordingsBase].flatMap { root in
            (FileManager.default.subpaths(atPath: root.path) ?? []).map { "\(root.lastPathComponent)/\($0)" }
        }
        return files.sorted()
    }

    /// In-memory sessions on `paths`, as the live factory lays them out.
    private func testFactory(_ paths: HubPaths, defaults: UserDefaults) -> HubSessionFactory {
        HubSessionFactory { [weak self] _, hubID, scope, device in
            try paths.prepare(hubID)
            self?.built.append(hubID)
            let engine = FakeAudioEngine()
            let clock = FakeClock()
            let session = try HubSession(
                transport: InMemoryCloudTransport(),
                replicaPath: paths.replicaPath(hubID),
                transportKind: .cloudKit,
                hubID: hubID,
                linkedDevice: device,
                keys: try TestPhone.keys(),
                defaults: defaults,
                recordingsDirectory: paths.recordingsDirectory(hubID),
                hold: RecordingHold(directory: paths.holdDirectory),
                databaseScope: scope,
                makeRecorder: { uploader in
                    PhoneRecorderController(
                        uploader: uploader, engine: engine, notificationCenter: NotificationCenter(),
                        now: { clock.now }, tickInterval: nil
                    )
                },
                sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
            )
            self?.addTeardownBlock { @MainActor in session.stop() }
            return session
        }
    }

    // MARK: - The F1 migration

    func testF1LinkAndFilesMoveIntoTheRegistryLayoutOnce() async throws {
        let paths = try makePaths()
        let defaults = try makeDefaults()
        let store = LinkStore(defaults: defaults)
        let missingSince = Date(timeIntervalSince1970: 500)
        store.legacyLink = link("hub-acme")
        store.legacyGrantMissingSince = missingSince
        defaults.set(true, forKey: "device.typingRequested")
        defaults.set(false, forKey: "device.startSessions")
        let recordingID = try await seedRecording(replicaPath: legacyReplica(paths).path, recordings: paths.recordingsBase)
        try makeTransportStore(at: legacyLocalTransport(paths))
        try FileManager.default.createDirectory(at: paths.holdDirectory, withIntermediateDirectories: true)
        let manifest = paths.holdDirectory.appendingPathComponent("manifest.json")
        try Data("[]".utf8).write(to: manifest)
        let registry = try HubRegistry.inMemory()

        try migrate(store, registry, paths, transport: legacyLocalTransport(paths), defaults: defaults)

        let rows = try registry.rows()
        XCTAssertEqual(rows.map(\.hubID), ["hub-acme"])
        XCTAssertEqual(try registry.activeHubID, "hub-acme")
        XCTAssertEqual(rows.first?.grantMissingSince, missingSince, "the removal check's first look is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.replicaPath("hub-acme")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyReplica(paths).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.transportStorePath("hub-acme")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyLocalTransport(paths).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.recordingsDirectory("hub-acme").appendingPathComponent("rec-1.m4a").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.recordingsBase.appendingPathComponent("rec-1.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path), "the hold stays where it is")
        let moved = try TestPhone.replica(path: paths.replicaPath("hub-acme"))
        XCTAssertEqual(try moved.phoneRecordings().map(\.id), [recordingID], "the replica keeps its recording")
        XCTAssertNil(defaults.object(forKey: "link.record"), "the legacy link is gone")
        XCTAssertNil(defaults.object(forKey: "link.grantMissingSince"))
        XCTAssertEqual(defaults.object(forKey: "hub.hub-acme.device.typingRequested") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "hub.hub-acme.device.startSessions") as? Bool, false)
        XCTAssertNil(defaults.object(forKey: "device.typingRequested"))
        XCTAssertNil(defaults.object(forKey: "device.startSessions"))

        let filesBefore = fileTree(paths)
        let rowsBefore = try registry.rows()
        try migrate(store, registry, paths, transport: legacyLocalTransport(paths), defaults: defaults)
        XCTAssertEqual(fileTree(paths), filesBefore, "a second run moves nothing")
        XCTAssertEqual(try registry.rows(), rowsBefore, "and writes nothing")
    }

    func testNoLegacyLinkDeletesTheLegacyReplicaAndKeepsAudio() async throws {
        let paths = try makePaths()
        let defaults = try makeDefaults()
        _ = try await seedRecording(replicaPath: legacyReplica(paths).path, recordings: paths.recordingsBase)
        try makeTransportStore(at: legacyLocalTransport(paths))
        let registry = try HubRegistry.inMemory()

        try migrate(LinkStore(defaults: defaults), registry, paths, transport: legacyLocalTransport(paths), defaults: defaults)

        XCTAssertEqual(try registry.rows(), [])
        for database in [legacyReplica(paths), legacyLocalTransport(paths)] {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + suffix), "\(database.lastPathComponent)\(suffix)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.recordingsBase.appendingPathComponent("rec-1.m4a").path))
    }

    func testATransportStoreStillInTheGroupMovesToo() async throws {
        let paths = try makePaths()
        let defaults = try makeDefaults()
        let store = LinkStore(defaults: defaults)
        store.legacyLink = link("hub-acme")
        let inGroup = paths.groupDirectory.appendingPathComponent(AppEnvironment.transportStoreFileName)
        try makeTransportStore(at: inGroup)
        try Data("side".utf8).write(to: URL(fileURLWithPath: inGroup.path + "-journal"))
        let registry = try HubRegistry.inMemory()

        try migrate(store, registry, paths, transport: inGroup, defaults: defaults)

        let target = paths.transportStorePath("hub-acme")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target + "-journal"), "its side files go with it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inGroup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inGroup.path + "-journal"))
        XCTAssertEqual(try registry.rows().map(\.hubID), ["hub-acme"])
    }

    func testAFailedFileMoveLeavesTheLegacyLinkForTheNextLaunch() async throws {
        let paths = try makePaths()
        let defaults = try makeDefaults()
        let store = LinkStore(defaults: defaults)
        store.legacyLink = link("hub-acme")
        let recordingID = try await seedRecording(replicaPath: legacyReplica(paths).path, recordings: paths.recordingsBase)
        try makeTransportStore(at: legacyLocalTransport(paths))
        let registry = try HubRegistry.inMemory()

        XCTAssertThrowsError(try migrate(
            store, registry, paths, transport: legacyLocalTransport(paths), defaults: defaults, fileManager: FailingMoveFileManager()
        ))
        XCTAssertEqual(try registry.rows(), [], "nothing reaches the registry")
        XCTAssertEqual(store.legacyLink, link("hub-acme"), "the legacy link stays for the next launch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyLocalTransport(paths).path), "the store did not move")

        try migrate(store, registry, paths, transport: legacyLocalTransport(paths), defaults: defaults)
        XCTAssertEqual(try registry.rows().map(\.hubID), ["hub-acme"], "the next launch moves it")
        XCTAssertEqual(try TestPhone.replica(path: paths.replicaPath("hub-acme")).phoneRecordings().map(\.id), [recordingID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.transportStorePath("hub-acme")))
        XCTAssertNil(store.legacyLink)
    }

    func testAnUnreadableLegacyLinkTouchesNothing() async throws {
        let paths = try makePaths()
        let defaults = try makeDefaults()
        defaults.set(Data("not a link".utf8), forKey: "link.record")
        let recordingID = try await seedRecording(replicaPath: legacyReplica(paths).path, recordings: paths.recordingsBase)
        try makeTransportStore(at: legacyLocalTransport(paths))
        let registry = try HubRegistry.inMemory()

        try migrate(LinkStore(defaults: defaults), registry, paths, transport: legacyLocalTransport(paths), defaults: defaults)

        XCTAssertEqual(try registry.rows(), [], "nothing migrated")
        XCTAssertNotNil(defaults.object(forKey: "link.record"), "the saved link stays for a build that reads it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyLocalTransport(paths).path), "the transport store stays")
        XCTAssertEqual(
            try TestPhone.replica(path: legacyReplica(paths).path).phoneRecordings().map(\.id), [recordingID],
            "the replica keeps its unsent recording"
        )
    }

    // MARK: - Orphans

    func testOrphanHubDirectoryIsHandedToTheHoldAndRemoved() async throws {
        let paths = try makePaths()
        let defaults = try makeDefaults()
        try paths.prepare("hub-orphan")
        let recordingID = try await seedRecording(
            replicaPath: paths.replicaPath("hub-orphan"), recordings: paths.recordingsDirectory("hub-orphan")
        )
        let registry = try HubRegistry.inMemory()
        try registry.upsert(link("hub-acme"), now: Date())
        try paths.prepare("hub-acme")

        try await HubBoot.removeOrphans(
            registry: registry, paths: paths, keeping: nil, factory: testFactory(paths, defaults: defaults)
        )

        XCTAssertEqual(built, ["hub-orphan"], "only the orphan gets a session")
        let held = try RecordingHold(directory: paths.holdDirectory).load()
        XCTAssertEqual(held.map(\.id), [recordingID], "its unsent recording is held")
        XCTAssertEqual(held.first?.hubID, "hub-orphan")
        for directory in [paths.hubDirectory("hub-orphan"), paths.localHubDirectory("hub-orphan"), paths.recordingsDirectory("hub-orphan")] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), directory.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.hubDirectory("hub-acme").path), "a linked hub stays")
    }

    func testAnOrphanWhoseHandOverFailedKeepsItsFiles() async throws {
        let paths = try makePaths()
        let defaults = try makeDefaults()
        try paths.prepare("hub-orphan")
        _ = try await seedRecording(replicaPath: paths.replicaPath("hub-orphan"), recordings: paths.recordingsDirectory("hub-orphan"))
        // A file where the hold folder goes: the hold can take nothing.
        try Data("blocked".utf8).write(to: paths.holdDirectory)
        let registry = try HubRegistry.inMemory()

        try await HubBoot.removeOrphans(
            registry: registry, paths: paths, keeping: nil, factory: testFactory(paths, defaults: defaults)
        )

        XCTAssertEqual(built, ["hub-orphan"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.recordingsDirectory("hub-orphan").appendingPathComponent("rec-1.m4a").path
        ), "audio the hold could not take is not deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.replicaPath("hub-orphan")), "the next launch tries again")
    }

    func testThePendingLinksDirectoryIsNotAnOrphan() async throws {
        let paths = try makePaths()
        let defaults = try makeDefaults()
        try paths.prepare("hub-pending")
        let registry = try HubRegistry.inMemory()

        try await HubBoot.removeOrphans(
            registry: registry, paths: paths, keeping: "hub-pending", factory: testFactory(paths, defaults: defaults)
        )

        XCTAssertEqual(built, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.hubDirectory("hub-pending").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.localHubDirectory("hub-pending").path))
    }

    /// A registry row that does not decode is skipped by the boot, but its
    /// hub's files are not an orphan's: nothing is handed over or deleted.
    func testAnUndecodableRowsFilesAreNotAnOrphans() async throws {
        let paths = try makePaths()
        let defaults = try makeDefaults()
        try paths.prepare("hub-acme")
        let registry = try HubRegistry(path: paths.registryPath)
        try registry.upsert(link("hub-acme"), now: Date())
        try await DatabaseQueue(path: paths.registryPath).write { db in
            try db.execute(sql: "UPDATE hubs SET link_json = ? WHERE hub_id = 'hub-acme'", arguments: [Data("{not json".utf8)])
        }
        XCTAssertTrue(try registry.rows().isEmpty)

        try await HubBoot.removeOrphans(
            registry: registry, paths: paths, keeping: nil, factory: testFactory(paths, defaults: defaults)
        )

        XCTAssertEqual(built, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.hubDirectory("hub-acme").path))
    }

    // MARK: - The live boot

    func testLiveBootBuildsOneSessionPerRowAndActivatesTheSavedHub() async throws {
        let paths = try makePaths()
        let defaults = try makeDefaults()
        let registry = try HubRegistry.inMemory()
        try registry.upsert(link("hub-acme"), now: Date())
        try registry.upsert(link("hub-home", mac: "Home Mac"), now: Date())
        try registry.setActive("hub-home")
        let identity = DeviceIdentity(deviceID: device.deviceID, name: device.name, model: device.model, appVersion: device.appVersion)

        let env = try AppEnvironment.live(
            registry: registry, paths: paths, factory: testFactory(paths, defaults: defaults), identity: identity, defaults: defaults
        )

        XCTAssertEqual(env.order, ["hub-acme", "hub-home"])
        XCTAssertEqual(env.activeHubID, "hub-home")
        XCTAssertEqual(env.session("hub-acme")?.linkedDevice, device)
        XCTAssertEqual(env.session("hub-home")?.databaseScope, .private)
        XCTAssertEqual(try registry.activeHubID, "hub-home")
    }

    func testARowTheMacRemovedBootsFrozen() async throws {
        let paths = try makePaths()
        let defaults = try makeDefaults()
        let registry = try HubRegistry.inMemory()
        try registry.upsert(link("hub-acme"), now: Date())
        try registry.upsert(link("hub-home", mac: "Home Mac"), now: Date())
        try registry.setState(.unlinkedByMac, for: "hub-home")
        let identity = DeviceIdentity(deviceID: device.deviceID, name: device.name, model: device.model, appVersion: device.appVersion)

        let env = try AppEnvironment.live(
            registry: registry, paths: paths, factory: testFactory(paths, defaults: defaults), identity: identity, defaults: defaults
        )
        let frozen = try XCTUnwrap(env.session("hub-home"))
        await env.waitForBoot()
        try await poll({ !frozen.writesAllowed }, "the removed hub's session froze")

        XCTAssertEqual(env.activeHubID, "hub-acme", "with no saved active hub, the first row")
        XCTAssertFalse(frozen.isLooping)
        XCTAssertEqual(frozen.linkedDevice, device, "ruling 4: the link stands, as a live freeze keeps it")
        XCTAssertNil(frozen.deviceSettings.linkedDevice, "a toggle writes no device record")
        do {
            try await frozen.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
            XCTFail("a removed hub sends nothing")
        } catch {
            XCTAssertEqual(error as? ActionOutboxError, .notLinked)
        }
        try await poll({ env.session("hub-acme")?.isLooping == true }, "the linked hub runs")
    }
}

extension HubBootTests {
    // MARK: - Leftover legacy keys (ruling 3)

    /// A kill between the migration's registry write and its removal of the
    /// legacy keys leaves both: the next launch, finding rows, clears the
    /// keys and touches nothing else.
    func testLegacyLinkKeysLeftNextToRowsAreCleared() throws {
        let paths = try makePaths()
        let defaults = try makeDefaults()
        let store = LinkStore(defaults: defaults)
        let registry = try HubRegistry.inMemory()
        try registry.upsert(link("hub-acme"), now: Date())
        try registry.setActive("hub-acme")
        store.legacyLink = link("hub-acme")
        store.legacyGrantMissingSince = Date(timeIntervalSince1970: 500)
        let rowsBefore = try registry.rows()

        try migrate(store, registry, paths, transport: legacyLocalTransport(paths), defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "link.record"))
        XCTAssertNil(defaults.object(forKey: "link.grantMissingSince"))
        XCTAssertEqual(try registry.rows(), rowsBefore, "the rows are left as they are")
        XCTAssertEqual(try registry.activeHubID, "hub-acme")
    }
}

/// A file manager that cannot move the transport store (a destination it
/// may not write): the replica's move before it succeeds.
private final class FailingMoveFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.lastPathComponent.hasPrefix(AppEnvironment.transportStoreFileName) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
