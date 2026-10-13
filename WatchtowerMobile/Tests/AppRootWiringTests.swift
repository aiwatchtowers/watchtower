import CryptoKit
import Foundation
import GRDB
import os
import WatchtowerE2ETesting
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// `AppRoot` as the link flow's host (spec §2.3, §9): the wipe really
/// empties the replica and the outbox, a moved hub sends nothing, a scope
/// change restarts on an empty replica, and the demo never onboards.
@MainActor
final class AppRootWiringTests: XCTestCase {
    /// The test pairing's phone (`TestE2E`): the hub seals its grant to
    /// this device id.
    private let device = LinkedDevice(
        deviceID: TestPhone.deviceID(),
        name: "Colleague A's iPhone",
        model: "iPhone",
        appVersion: "1.0",
        scope: .private,
        userRecordName: "_owner-acme"
    )

    /// Every environment the root built, and the database and hub each runs.
    private var built: [(env: AppEnvironment, scope: CloudDatabaseScope, hubID: String)] = []
    /// Every environment's recorder runs on this engine and clock: no audio.
    private let engine = FakeAudioEngine()
    private let clock = FakeClock()
    private var recordingsDirectory: URL?
    private var transports: [InMemoryCloudTransport] = []
    private var replicaPath = ""
    private var container: FakeLinkContainer!
    /// The phone's Keychain stand-in, shared by every environment and the link flow (as the Keychain is).
    private var keyStore: InMemoryPhoneKeyStore!
    /// The root's `UserDefaults` (its `LinkStore`).
    private var defaultsInUse: UserDefaults?

    /// A live-kind root on one replica path. Without `transportStorePath`
    /// each environment gets a fresh in-memory transport; with it, a
    /// `CloudKitTransport` over the persistent store at that path (the app's
    /// shape: one transport file across restarts; no engine starts in the
    /// unsigned test host).
    /// `link` is the saved link the flow starts from; `linkClock` runs the
    /// flow's grant wait.
    private func makeRoot(
        linked: LinkedDevice?,
        hubID initialHub: String = AppEnvironment.unlinkedHubID,
        link: LinkRecord? = nil,
        linkClock: any LinkClock = SystemLinkClock(),
        transportStorePath: String? = nil,
        keyStore given: InMemoryPhoneKeyStore? = nil
    ) throws -> AppRoot {
        let keyStore = try given ?? TestE2E.phoneStore()
        self.keyStore = keyStore
        let path = try makeReplicaPath()
        replicaPath = path
        let defaults = try makeDefaults()
        defaultsInUse = defaults
        let store = LinkStore(defaults: defaults)
        store.link = link
        container = FakeLinkContainer(log: LinkEventLog())
        let recordings = try makeRecordingsDirectory()
        recordingsDirectory = recordings
        let engine = engine
        let clock = clock
        typealias Make = @MainActor (CloudDatabaseScope, String, LinkedDevice?, UInt64) throws -> AppEnvironment
        let make: Make = { [weak self] scope, hubID, device, seqFloor in
            let transport: any CloudSyncTransport
            if let transportStorePath {
                transport = CloudKitTransport(
                    store: try TransportStore(path: transportStorePath), scope: scope, hubID: hubID, role: .phone
                )
            } else {
                let memory = InMemoryCloudTransport()
                self?.transports.append(memory)
                transport = memory
            }
            let env = try AppEnvironment(
                transport: transport,
                replicaPath: path,
                transportKind: .cloudKit,
                hubID: hubID,
                linkedDevice: device,
                // The test hub's keys whatever zones the environment syncs: tests seal through the test hub.
                keys: PhoneKeys(store: keyStore, hubID: TestE2E.hubID.uuidString),
                seqFloor: seqFloor,
                defaults: defaults,
                recordingsDirectory: recordings
            ) { uploader in
                PhoneRecorderController(
                    uploader: uploader, engine: engine, notificationCenter: NotificationCenter(), now: { clock.now }, tickInterval: nil
                )
            }
            self?.addTeardownBlock { @MainActor in env.stop() }
            self?.built.append((env, scope, hubID))
            return env
        }
        let identity = DeviceIdentity(
            deviceID: try keyStore.deviceID()?.uuidString, name: device.name, model: device.model, appVersion: device.appVersion
        )
        return AppRoot(
            env: try make(.private, initialHub, linked, 0),
            scope: .private,
            hubID: initialHub,
            linking: LinkingViewModel(container: container, store: store, identity: identity, keys: keyStore, clock: linkClock),
            restarter: AppRoot.Restarter(replicaPath: path, transportStorePath: transportStorePath, make: make)
        )
    }

    private func sliceCount(_ env: AppEnvironment) async throws -> Int {
        try await env.store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0
        }
    }

    func testWipeEmptiesTheReplicaAndOutboxAndCountsWhatWasNotSent() async throws {
        let root = try makeRoot(linked: device)
        let first = root.env
        let now = Date()
        try await TestPhone.hub(over: transports[0]).save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        // The safety poll waits a minute after the boot (board #724): fetch once the boot is done.
        try await poll { first.isBootstrapped }
        _ = await first.refresh(.pull)
        try await poll { (try? self.sliceCountSync(first)) == 1 }
        for id in 1...3 {
            try await first.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-\(id)")
        }
        XCTAssertEqual(try first.store.pendingActions().count, 3)

        let notSent = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true)

        XCTAssertEqual(notSent, LocalWipe(notSent: 3), "the three pending items are reported Not sent")
        XCTAssertFalse(root.env === first, "a new environment on the same files")
        XCTAssertFalse(first.isLooping, "the old environment is stopped")
        let rows = try await sliceCount(root.env)
        XCTAssertEqual(rows, 0, "the replica is wiped")
        XCTAssertTrue(try root.env.store.pendingActions().isEmpty, "the outbox is wiped")
        XCTAssertNil(root.env.linkedDevice)
        XCTAssertEqual(built.last?.scope, .private)
        XCTAssertNil(root.failure)
    }

    /// Finding 1 of the task review: a private → private wipe must also
    /// empty the persistent transport store (buffered events, the send queue,
    /// the engine state), or the new replica never re-hydrates the compacted
    /// prefix and the unlinked phone's queue still goes out.
    func testWipeAlsoEmptiesThePersistentTransportStore() async throws {
        let transportPath = (try makeReplicaPath() as NSString).deletingLastPathComponent + "/cloudkit-transport.sqlite"
        let root = try makeRoot(linked: device, transportStorePath: transportPath)
        let first = root.env
        try await poll { first.isBootstrapped }
        for id in 1...3 {
            try await first.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-\(id)")
        }
        // The Kit's own tables, read and seeded directly: the engine and the
        // fetch buffer have no public writer outside CloudKit.
        let raw = try DatabaseQueue(path: transportPath)
        try await raw.write { db in
            try db.execute(sql: "INSERT INTO engine_state (id, data) VALUES (1, x'00')")
            try db.execute(sql: """
                INSERT INTO events (zone, record_name, kind, modified_at, payload)
                VALUES ('DataZone', 'heartbeat', 'heartbeat', 0, x'7b7d')
                """)
        }
        let before = try await transportCounts(raw)
        XCTAssertEqual(before.pending, 3, "the outbox's sends wait in the transport queue")

        let notSent = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true)

        XCTAssertEqual(notSent, LocalWipe(notSent: 3))
        let after = try await transportCounts(raw)
        XCTAssertEqual(after.pending, 0, "the unlinked phone's queue is not sent")
        XCTAssertEqual(after.events, 0, "the next replica re-reads the zone from scratch")
        XCTAssertEqual(after.engineState, 0, "the engine fetches everything again")
        XCTAssertEqual(built.last?.scope, .private)
        XCTAssertNil(root.failure)
    }

    // MARK: - Transport store location (0xdead10cc)

    /// Two throwaway directories: the app group's and the app's own.
    private func makeStoreDirectories() throws -> (group: URL, own: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transport-move-\(UUID().uuidString)")
        let group = root.appendingPathComponent("group", isDirectory: true)
        let own = root.appendingPathComponent("own", isDirectory: true)
        for dir in [group, own] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (group, own)
    }

    /// An earlier build's store in the app group moves into the app's own
    /// directory once, with its SQLite side files, and opens there with its
    /// rows; a second launch finds it in place.
    func testTheTransportStoreMovesOutOfTheAppGroupOnce() async throws {
        let (group, own) = try makeStoreDirectories()
        let name = AppEnvironment.transportStoreFileName
        let oldPath = group.appendingPathComponent(name).path
        _ = try TransportStore(path: oldPath)
        try await DatabaseQueue(path: oldPath).write { db in
            try db.execute(sql: "INSERT INTO engine_state (id, data) VALUES (1, x'2a')")
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            try Data(suffix.utf8).write(to: group.appendingPathComponent(name + suffix))
        }

        let path = AppEnvironment.moveTransportStore(from: group, to: own)

        XCTAssertEqual(path, own.appendingPathComponent(name).path)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath + suffix), "\(suffix) left in the app group")
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path + suffix)), Data(suffix.utf8))
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            // The stand-in side files are not SQLite's: drop them before opening.
            try FileManager.default.removeItem(atPath: path + suffix)
        }
        let engineState = try await DatabaseQueue(path: path).read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM engine_state") ?? 0
        }
        XCTAssertEqual(engineState, 1, "the rows came along")

        XCTAssertEqual(AppEnvironment.moveTransportStore(from: group, to: own), path, "the next launch finds it in place")
    }

    /// A fresh install has nothing to move; a store already in the app's own
    /// directory wins over a stray one in the app group, which is left alone.
    func testTheTransportStoreMoveLeavesAnInstalledStoreAlone() throws {
        let (group, own) = try makeStoreDirectories()
        let name = AppEnvironment.transportStoreFileName
        let ownPath = own.appendingPathComponent(name).path
        XCTAssertEqual(AppEnvironment.moveTransportStore(from: group, to: own), ownPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownPath), "nothing is created")

        try Data("own".utf8).write(to: URL(fileURLWithPath: ownPath))
        let stray = group.appendingPathComponent(name)
        try Data("stray".utf8).write(to: stray)
        XCTAssertEqual(AppEnvironment.moveTransportStore(from: group, to: own), ownPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ownPath)), Data("own".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    /// The live path resolves once per process: a move that failed keeps
    /// the app-group store open there, and a later resolution (a restart's
    /// environment, the wipe) returns that same path instead of moving the
    /// store from under the open database.
    func testTheTransportStorePathResolvesOncePerProcess() throws {
        let (group, own) = try makeStoreDirectories()
        let name = AppEnvironment.transportStoreFileName
        let oldMain = group.appendingPathComponent(name)
        try Data("main".utf8).write(to: oldMain)
        let target = OSAllocatedUnfairLock(initialState: own.appendingPathComponent("gone", isDirectory: true))
        let resolver = TransportStorePathResolver { AppEnvironment.moveTransportStore(from: group, to: target.withLock { $0 }) }

        XCTAssertEqual(try resolver.path(), oldMain.path, "the failed move keeps the old store")
        target.withLock { $0 = own }
        XCTAssertEqual(try resolver.path(), oldMain.path, "the same path, no second move")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldMain.path), "the open store stays where it is")
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.appendingPathComponent(name).path))
    }

    /// A move that fails keeps the app-group store, side files included,
    /// and opens it there for this launch.
    func testAFailedTransportStoreMoveKeepsTheOldStore() throws {
        let (group, own) = try makeStoreDirectories()
        let name = AppEnvironment.transportStoreFileName
        let oldMain = group.appendingPathComponent(name)
        try Data("main".utf8).write(to: oldMain)
        try Data("wal".utf8).write(to: group.appendingPathComponent(name + "-wal"))
        let missing = own.appendingPathComponent("gone", isDirectory: true)

        XCTAssertEqual(AppEnvironment.moveTransportStore(from: group, to: missing), oldMain.path)
        XCTAssertEqual(try Data(contentsOf: oldMain), Data("main".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldMain.path + "-wal"))
    }

    private func transportCounts(_ raw: DatabaseQueue) async throws -> (pending: Int, events: Int, engineState: Int) {
        try await raw.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM engine_state") ?? 0
            )
        }
    }

    /// Finding 2 of the task review: two teardowns at once run one after
    /// the other. Each environment but the last is shut down, and the last
    /// one's replica is not deleted under it.
    func testConcurrentWipesRestartOneAfterTheOther() async throws {
        let root = try makeRoot(linked: device)

        async let first = root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true)
        async let second = root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true)
        _ = await (first, second)

        XCTAssertEqual(built.count, 3, "the initial environment and one per wipe")
        let last = try XCTUnwrap(built.last?.env)
        XCTAssertTrue(root.env === last)
        try await poll { self.built.allSatisfy { $0.env.isBootstrapped } }
        try await poll { last.isLooping }
        for (index, entry) in built.dropLast().enumerated() {
            XCTAssertFalse(entry.env.isLooping, "environment \(index) was replaced without a shutdown")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: replicaPath), "the live replica's file is in place")
        let now = Date()
        try await TestPhone.hub(over: transports[2]).save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        let fetched = await last.refresh(.pull)
        XCTAssertTrue(fetched)
        XCTAssertEqual(try sliceCountSync(last), 1, "the live replica takes writes")
    }

    private func sliceCountSync(_ env: AppEnvironment) throws -> Int {
        try env.store.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0 }
    }

    /// A moved hub (spec §9): the link stands, but nothing is sent.
    func testWritesNotAllowedKeepTheLinkAndSendNothing() async throws {
        let root = try makeRoot(linked: device)

        await root.setLink(device, writesAllowed: false)

        XCTAssertEqual(root.env.linkedDevice, device, "Settings still shows the Mac")
        XCTAssertNil(root.env.deviceSettings.linkedDevice, "board #70: a toggle writes no device record either")
        await root.env.deviceSettings.setStartSessions(false)
        XCTAssertFalse(root.env.deviceSettings.startSessions, "the choice is kept")
        XCTAssertNil(root.env.deviceSettings.lastError)
        let kept = try await deviceWrites(in: transports[0])
        XCTAssertTrue(kept.isEmpty, "a moved hub's phone writes no device record")
        do {
            try await root.env.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
            XCTFail("a moved hub's phone must not send")
        } catch {
            XCTAssertEqual(error as? ActionOutboxError, .notLinked)
        }
        let actions = try await transports[0].changes(in: .relay, since: nil).changed
            .filter { $0.kind == RelayRecordKind.action.rawValue }
        XCTAssertTrue(actions.isEmpty)

        await root.setLink(device, writesAllowed: true)
        XCTAssertEqual(root.env.deviceSettings.linkedDevice, device)
        // Sealed by the phone (mobile E2E Task 17): the hub opens it.
        let resent = try await deviceWrites(in: transports[0])
        XCTAssertEqual(resent.map(\.startSessions), [false], "review F10: the kept toggle reaches the Mac when writes return")
        try await root.env.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
    }

    // MARK: - Recordings across a wipe (board #63)

    private var hold: RecordingHold {
        RecordingHold(recordingsDirectory: recordingsDirectory ?? URL(fileURLWithPath: "/nonexistent"))
    }

    /// A voice note of `seconds`, saved (`waiting`) in the running
    /// environment; returns its ledger id.
    private func saveVoiceNote(_ root: AppRoot, seconds: TimeInterval = 12) async throws -> String {
        await root.env.recorder.recordVoiceNote()
        clock.advance(seconds)
        await root.env.recorder.stop()
        return try XCTUnwrap(root.env.recorder.savedRecording?.id)
    }

    /// Ask #89 A: a saved recording is sealed at once, and its plain audio stays on the phone (what a wipe
    /// holds) until the Mac confirms it.
    private func assertSealedKeepingThePlainAudio(
        _ root: AppRoot, _ id: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let row = try XCTUnwrap(try root.env.store.phoneRecording(id: id), file: file, line: line)
        let sealed = try XCTUnwrap(row.sealedFileURL(in: recordingsDirectory), "sealed at once", file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealed.path), file: file, line: line)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: row.fileURL(in: recordingsDirectory).path),
            "the plain audio waits for the Mac", file: file, line: line
        )
    }

    /// An unlink or a removal during a meeting capture: the capture is
    /// stopped and saved, held for its hub, listed as waiting for that Mac,
    /// and sent only once this phone is on that hub again.
    func testAWipeDuringACaptureHoldsItForItsHubAndSendsItAfterRelinkingThatHub() async throws {
        let root = try makeRoot(linked: device, hubID: "hub-acme")
        let first = root.env
        try await poll { first.isBootstrapped }
        let event = MeetingEvent(id: "event-1", title: "Design sync", start: clock.now, end: clock.now.addingTimeInterval(1_800))
        await first.recorder.recordMeeting(event)
        XCTAssertTrue(first.recorder.isCapturing)
        clock.advance(30)
        first.recorder.markMoment()
        await root.setLink(nil, writesAllowed: true)

        let wipe = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true)

        XCTAssertEqual(wipe, LocalWipe(notSent: 0, stoppedRecording: true), "held, so not reported Not sent")
        XCTAssertEqual(engine.finishCount, 1, "the file was finalised, not cut off")
        try await poll { root.env.isBootstrapped }
        XCTAssertTrue(try root.env.store.phoneRecordings().isEmpty, "the unlinked hub does not adopt it")
        let held = try XCTUnwrap(root.env.heldRecordings.first, "listed as waiting for its Mac")
        XCTAssertEqual(held.hubID, "hub-acme")
        XCTAssertEqual(held.marks, [30])
        XCTAssertNotNil(hold.audioURL(of: held), "the launch sweep left the audio alone")
        let list = RecordingsListModel(
            recordings: PhoneRecordingsSnapshot(), replica: CalendarReplicaSnapshot(),
            seen: RecordingsSeen(baseline: .distantPast, opened: []), now: clock.now, calendar: .current,
            held: root.env.heldRecordings
        )
        XCTAssertEqual(list.inProgress.map(\.state), [.heldForMac(nil)])

        _ = try await root.prepare(scope: .private, hubID: "hub-acme", fresh: false)
        await root.setLink(device, writesAllowed: true)

        let row = try XCTUnwrap(try root.env.store.phoneRecordings().first)
        XCTAssertEqual(row.id, held.id)
        XCTAssertEqual(row.durationSec, 30)
        XCTAssertEqual(row.eventID, "event-1")
        XCTAssertEqual(try root.env.store.phoneRecordingMarks(id: row.id), [30])
        XCTAssertTrue(root.env.heldRecordings.isEmpty)
        XCTAssertTrue(try hold.load().isEmpty, "adopted, out of the hold")
        let uploads = try await relayUploads(in: try XCTUnwrap(transports.last))
        XCTAssertEqual(uploads.map(\.id), [row.id], "sent after relinking its Mac")
        try assertSealedKeepingThePlainAudio(root, row.id)
    }

    /// Review F6: a recording held for one Mac never goes to another.
    func testAnotherHubNeverReceivesAHeldRecording() async throws {
        let root = try makeRoot(linked: device, hubID: "hub-acme")
        try await poll { root.env.isBootstrapped }
        let id = try await saveVoiceNote(root)
        try assertSealedKeepingThePlainAudio(root, id)
        await root.setLink(nil, writesAllowed: true)
        _ = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true)

        _ = try await root.prepare(scope: .private, hubID: "hub-studio", fresh: false)
        await root.setLink(device, writesAllowed: true)

        let uploads = try await relayUploads(in: try XCTUnwrap(transports.last))
        XCTAssertTrue(uploads.isEmpty, "the other Mac gets nothing")
        XCTAssertTrue(try root.env.store.phoneRecordings().isEmpty)
        XCTAssertEqual(root.env.heldRecordings.map(\.id), [id], "still waiting for its own Mac")
    }

    /// Review F6: an iCloud account change carries nothing: the recordings
    /// were made for the old account's Mac, and are reported Not sent.
    func testAnAccountChangeWipeCarriesNoRecording() async throws {
        let root = try makeRoot(linked: device, hubID: "hub-acme")
        try await poll { root.env.isBootstrapped }
        let id = try await saveVoiceNote(root)
        let file = try XCTUnwrap(try root.env.store.phoneRecording(id: id)).fileURL(in: recordingsDirectory)
        await root.setLink(nil, writesAllowed: true)

        let wipe = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: false)

        XCTAssertEqual(wipe, LocalWipe(notSent: 1))
        try await poll { root.env.isBootstrapped }
        XCTAssertTrue(root.env.heldRecordings.isEmpty)
        XCTAssertTrue(try hold.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "swept, as before")
    }

    /// An unlink restarts twice in a row (the queue wipe on the linked hub,
    /// then the unlinked hub): a recording survives both, still held for
    /// its hub.
    func testAWaitingRecordingSurvivesBackToBackWipes() async throws {
        let root = try makeRoot(linked: device, hubID: "hub-acme")
        try await poll { root.env.isBootstrapped }
        let id = try await saveVoiceNote(root)
        try assertSealedKeepingThePlainAudio(root, id)
        await root.setLink(nil, writesAllowed: true)

        async let one = root.wipeLocalData(restartingOn: .private, hubID: "hub-acme", keepRecordings: true)
        async let two = root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true)
        let wipes = await [one, two]

        XCTAssertEqual(wipes, [LocalWipe(), LocalWipe()], "nothing lost, no capture running")
        try await poll { root.env.isBootstrapped }
        let held = try XCTUnwrap(root.env.heldRecordings.first)
        XCTAssertEqual(held.id, id)
        XCTAssertEqual(held.hubID, "hub-acme")
        XCTAssertNotNil(hold.audioURL(of: held))
    }

    /// Verify round: killed after the hold and before the replica went (or
    /// a replica that could not be removed): the next boot finds the row
    /// still in the replica, brings the audio back next to it, and sends it
    /// — its `uploading` row as the relaunch retry (board #724): in the
    /// foreground, with the Mac online and the backoff due.
    func testKilledAfterHoldingBeforeTheReplicaWentRestoresTheAudio() async throws {
        let root = try makeRoot(linked: device, hubID: "hub-acme")
        try await poll { root.env.isBootstrapped }
        let id = try await saveVoiceNote(root)
        try assertSealedKeepingThePlainAudio(root, id)
        let row = try XCTUnwrap(try root.env.store.phoneRecording(id: id))
        let file = row.fileURL(in: recordingsDirectory)
        try hold.hold([HeldRecording(row, marks: [], hubID: "hub-acme", macName: nil)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the audio is in the hold")
        root.env.stop()

        // The relaunch: the same replica, the same hub, past the first
        // backoff step, with the Mac's heartbeat fresh.
        let relaunchAt = Date().addingTimeInterval(RecordingUploader.retryDelays[0] + 1)
        let transport = InMemoryCloudTransport()
        try await TestPhone.hub(over: transport).save(
            [try CloudRecordFactory.record(for: heartbeat(updatedAt: relaunchAt), modifiedAt: relaunchAt)])
        let relaunched = try AppEnvironment(
            transport: transport,
            replicaPath: replicaPath,
            transportKind: .cloudKit,
            hubID: "hub-acme",
            linkedDevice: device,
            keys: try TestPhone.keys(),
            defaults: try makeDefaults(),
            recordingsDirectory: recordingsDirectory,
            uploadRetriesAllowed: true,
            makeRecorder: { [engine, clock] uploader in
                PhoneRecorderController(
                    uploader: uploader, engine: engine, notificationCenter: NotificationCenter(), now: { clock.now }, tickInterval: nil
                )
            },
            now: { relaunchAt }
        )
        addTeardownBlock { @MainActor in relaunched.stop() }
        try await poll { relaunched.isBootstrapped }

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "back next to its row, past the sweep")
        XCTAssertTrue(try hold.load().isEmpty)
        XCTAssertEqual(try relaunched.store.phoneRecordings().map(\.id), [id])
        let uploads = try await relayUploads(in: transport)
        XCTAssertEqual(uploads.map(\.id), [id])
    }

    /// Review F1: a capture cut short by an earlier kill, still `recording`
    /// because no launch recovery reached it, keeps its audio: the
    /// hand-over finalizes it from its file and holds it.
    func testACaptureLeftForLaunchRecoveryIsFinalizedAndHeld() async throws {
        let root = try makeRoot(linked: device, hubID: "hub-acme")
        try await poll { root.env.isBootstrapped }
        let directory = try XCTUnwrap(recordingsDirectory)
        // Another process's uploader: the capture is not live in this one.
        let earlier = RecordingUploader(transport: try TestPhone.transport(), store: root.env.store, directory: directory)
        let file = directory.appendingPathComponent("cut-short.m4a")
        try Data(repeating: 0x5A, count: 256).write(to: file)
        let stranded = try await earlier.beginCapture(fileURL: file, startedAt: clock.now, titleHint: "Cut short", eventID: nil)
        engine.fileDuration = 20
        await root.setLink(nil, writesAllowed: true)

        let wipe = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true)

        XCTAssertEqual(wipe, LocalWipe(), "not lost")
        let held = try XCTUnwrap(root.env.heldRecordings.first)
        XCTAssertEqual(held.id, stranded.id)
        XCTAssertEqual(held.durationSec, 20, "finalized from its file")
        XCTAssertNotNil(hold.audioURL(of: held))
    }

    /// Review F2: a stop already saving (the owner's tap, the 3-hour cap)
    /// is waited for, then its recording is held; the wipe did not stop it.
    func testAWipeDuringASaveWaitsForItAndHoldsTheRecording() async throws {
        let root = try makeRoot(linked: device, hubID: "hub-acme")
        let first = root.env
        try await poll { first.isBootstrapped }
        await first.recorder.recordVoiceNote()
        clock.advance(15)
        engine.holdFinish = true
        let ownerStop = Task { await first.recorder.stop() }
        try await poll { first.recorder.phase == .saving && self.engine.finishCount == 1 }
        await root.setLink(nil, writesAllowed: true)

        let wipeTask = Task { await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(root.env === first, "the wipe waits for the save")
        engine.releaseFinish()
        let wipe = await wipeTask.value
        await ownerStop.value

        XCTAssertEqual(wipe, LocalWipe(), "the owner stopped it: kept, not the wipe's news")
        XCTAssertEqual(root.env.heldRecordings.map(\.durationSec), [15])
    }

    /// Review F3: a ledger the hand-over cannot read never sends the audio
    /// into the sweep: it moves to the hold's `unreadable` folder, and the
    /// wipe says so.
    func testAnUnreadableHandOverKeepsTheAudioAndSaysSo() async throws {
        let root = try makeRoot(linked: device, hubID: "hub-acme")
        try await poll { root.env.isBootstrapped }
        let id = try await saveVoiceNote(root)
        try assertSealedKeepingThePlainAudio(root, id)
        let file = try XCTUnwrap(try root.env.store.phoneRecording(id: id)).fileURL(in: recordingsDirectory)
        // A manifest that cannot be read: holding fails.
        try FileManager.default.createDirectory(
            at: hold.directory.appendingPathComponent("manifest.json"), withIntermediateDirectories: true
        )
        await root.setLink(nil, writesAllowed: true)

        let wipe = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true)

        let problem = try XCTUnwrap(wipe.problem)
        XCTAssertTrue(problem.hasPrefix("Some recordings couldn't be read"), problem)
        try await poll { root.env.isBootstrapped }
        let kept = hold.directory.appendingPathComponent("unreadable").appendingPathComponent(file.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "the audio is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        if case .recordingsProblem = LinkNotice.after(wipe, otherwise: .removed()) {} else {
            XCTFail("the notice reports the problem")
        }
    }

    /// A recording whose audio is already gone cannot be held: it is
    /// reported Not sent, as before.
    func testARecordingWithoutItsFileIsReportedNotSent() async throws {
        let root = try makeRoot(linked: device, hubID: "hub-acme")
        try await poll { root.env.isBootstrapped }
        let id = try await saveVoiceNote(root)
        try FileManager.default.removeItem(at: try XCTUnwrap(try root.env.store.phoneRecording(id: id)).fileURL(in: recordingsDirectory))

        let wipe = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true)

        XCTAssertEqual(wipe, LocalWipe(notSent: 1))
        try await poll { root.env.isBootstrapped }
        XCTAssertTrue(root.env.heldRecordings.isEmpty)
    }

    /// Board #70: a replica file the wipe cannot remove fails the restart
    /// (BootFailureView) instead of opening the old link's data again.
    func testAReplicaTheWipeCannotRemoveFailsTheRestart() async throws {
        let root = try makeRoot(linked: device)
        let directory = (replicaPath as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
        }

        _ = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true)

        XCTAssertNotNil(root.failure, "the restart fails visibly")
        XCTAssertEqual(built.count, 1, "no environment opens on the old replica")
    }

    /// Board #70: an unlink's flush waits for the engine start only, never
    /// for the first fetch, which a slow network can hold.
    func testSendNowDoesNotWaitForTheFirstFetch() async throws {
        let gate = GatedTransport()
        let env = try AppEnvironment(
            transport: gate,
            replicaPath: try makeReplicaPath(),
            transportKind: .cloudKit,
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory()
        )
        addTeardownBlock { @MainActor in
            env.stop()
            await gate.open()
        }
        var sent = false
        let flush = Task { @MainActor in
            await env.sendNow()
            sent = true
        }
        try await poll { sent }
        XCTAssertFalse(env.isBootstrapped, "the first fetch is still held")
        await flush.value
    }

    /// A retired environment (a shared unlink's) is replaced by the next
    /// prepare even on its own database and hub.
    func testARetiredEnvironmentRestartsOnTheNextPrepare() async throws {
        let root = try makeRoot(linked: nil)
        let first = root.env

        root.retireEnvironment()
        _ = try await root.prepare(scope: .private, hubID: AppEnvironment.unlinkedHubID, fresh: false)

        XCTAssertFalse(root.env === first)
        _ = try await root.prepare(scope: .private, hubID: AppEnvironment.unlinkedHubID, fresh: false)
        XCTAssertEqual(built.count, 2, "a fresh environment is not retired")
    }

    func testPreparingAnotherScopeRestartsOnAnEmptyReplica() async throws {
        let root = try makeRoot(linked: nil)
        let first = root.env
        let now = Date()
        try await TestPhone.hub(over: transports[0]).save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        // The safety poll waits a minute after the boot (board #724): fetch once the boot is done.
        try await poll { first.isBootstrapped }
        _ = await first.refresh(.pull)
        try await poll { (try? self.sliceCountSync(first)) == 1 }

        let samePrivate = try await root.prepare(scope: .private, hubID: AppEnvironment.unlinkedHubID, fresh: false)
        XCTAssertTrue(root.env === first, "the running scope needs no restart")
        XCTAssertTrue((samePrivate as? SecureTransport) === (first.linkTransport as? SecureTransport), "the running sealed transport")

        let shared = try await root.prepare(scope: .shared(ownerName: "_owner-acme"), hubID: AppEnvironment.unlinkedHubID, fresh: false)

        XCTAssertFalse(root.env === first)
        XCTAssertEqual(built.last?.scope, .shared(ownerName: "_owner-acme"))
        XCTAssertTrue((shared as? SecureTransport) === (root.env.linkTransport as? SecureTransport), "the new one's")
        let rows = try await sliceCount(root.env)
        XCTAssertEqual(rows, 0, "another database's data is not kept")
    }

    func testPreparingAnotherHubOnTheSameScopeRestartsOnAnEmptyReplica() async throws {
        let root = try makeRoot(linked: nil)
        let first = root.env
        let now = Date()
        try await TestPhone.hub(over: transports[0]).save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        // The safety poll waits a minute after the boot (board #724): fetch once the boot is done.
        try await poll { first.isBootstrapped }
        _ = await first.refresh(.pull)
        try await poll { (try? self.sliceCountSync(first)) == 1 }

        _ = try await root.prepare(scope: .private, hubID: "hub-acme", fresh: false)

        XCTAssertFalse(root.env === first, "another hub is another pair of zones")
        XCTAssertEqual(built.last?.hubID, "hub-acme")
        let rows = try await sliceCount(root.env)
        XCTAssertEqual(rows, 0, "another hub's data is not kept")
        _ = try await root.prepare(scope: .private, hubID: "hub-acme", fresh: false)
        XCTAssertEqual(built.count, 2, "the running hub needs no restart")
    }

    /// A new pairing (`fresh`) restarts on an empty replica even on the
    /// running database and hub: the old link's rollback marks, outbox and
    /// sealed recordings must not outlive it.
    func testAFreshPrepareRestartsOnAnEmptyReplicaOnTheSameHub() async throws {
        let root = try makeRoot(linked: nil)
        let first = root.env
        let now = Date()
        try await TestPhone.hub(over: transports[0]).save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        // The safety poll waits a minute after the boot (board #724): fetch once the boot is done.
        try await poll { first.isBootstrapped }
        _ = await first.refresh(.pull)
        try await poll { (try? self.sliceCountSync(first)) == 1 }

        _ = try await root.prepare(scope: .private, hubID: AppEnvironment.unlinkedHubID, fresh: true)

        XCTAssertFalse(root.env === first)
        let rows = try await sliceCount(root.env)
        XCTAssertEqual(rows, 0, "data_seen and the rows go with the replica")
    }

    func testFetchKeyboxReadsThisPhonesHydratedKeybox() async throws {
        let root = try makeRoot(linked: nil)
        // The boot's own first fetch done: a fetch coalesced into it would not see the save below.
        try await poll { root.env.isBootstrapped }
        let grant = DeviceGrant(
            deviceID: device.deviceID, hubID: "hub-acme", name: device.name, scope: .private,
            linked: true, typingAllowed: false, startSessionsAllowed: true
        )
        let keys = TestPhone.keyboxKeys(epoch: 1)
        try await TestPhone.hub(over: transports[0]).save([try TestPhone.grantRecord(grant, keys: keys, modifiedAt: Date())])

        let fetched = await root.fetchKeybox(deviceID: device.deviceID)

        XCTAssertEqual(fetched, Keybox(grant: grant, keys: keys), "the grant and the epoch keys")
        let other = await root.fetchKeybox(deviceID: UUID().uuidString)
        XCTAssertNil(other)
    }

    /// #64: a same-Apple-ID phone gets no `unlinked` event. After each
    /// fetch the root judges the grant of the device id the link was made
    /// with: one this build cannot read is never judged, and a grant gone
    /// on two fetches 30 s apart is the Mac's Remove. E2E: the grant is this
    /// phone's sealed keybox (the replica keeps only this phone's own, F13),
    /// published by the test hub; the heartbeat is the hub's signed one.
    func testTheLinkedDevicesGrantGoneOnTwoFetchesIsTheMacsRemoveAndAnUndecodableOneIsNot() async throws {
        let linkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = FakeLinkClock(now: linkedAt)
        var link = LinkRecord(
            hubID: "hub-acme", macName: "Acme Mac", scope: .private, ownerName: "_owner-acme",
            userRecordName: "_owner-acme", nonce: LinkPayload.makeNonce(), dataShareURL: nil, relayShareURL: nil
        )
        link.deviceID = device.deviceID
        link.linkedAt = linkedAt
        let root = try makeRoot(linked: device, link: link, linkClock: clock)
        // A refresh joins a hydration in flight: let the boot's launch fetch end first.
        try await poll { root.env.isBootstrapped }
        let hub = TestPhone.hub(over: transports[0])
        let later = linkedAt.addingTimeInterval(60)
        let grant = DeviceGrant(
            deviceID: device.deviceID, hubID: "hub-acme", name: device.name, scope: .private,
            linked: true, linkedAt: linkedAt, typingAllowed: false, startSessionsAllowed: true
        )
        try await hub.save([
            try CloudRecordFactory.record(for: heartbeat(updatedAt: later), modifiedAt: later),
            try TestPhone.grantRecord(grant, keys: TestPhone.keyboxKeys(epoch: 1), modifiedAt: later)
        ])
        // Each fetch's link check, awaited.
        let fetch = {
            await root.env.refresh(.pull)
            await root.linkCheck?.value
        }
        await fetch()
        XCTAssertNotNil(root.linking.link, "granted under the id it linked with")

        let reshaped = CloudRecord(
            recordName: grant.recordName, zone: .data, kind: SliceKind.deviceGrant.rawValue,
            modifiedAt: later.addingTimeInterval(1), payload: Data(#"{"linked":"maybe"}"#.utf8)
        )
        try await hub.save([reshaped])
        await fetch()
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        await fetch()
        XCTAssertNotNil(root.linking.link, "an unreadable keybox is not a removed one")

        try await hub.delete(recordNames: [grant.recordName], in: .data)
        await fetch()
        XCTAssertNotNil(root.linking.link, "one look is not enough")
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        await fetch()
        XCTAssertNil(root.linking.link, "the Mac's Remove ends the link")
        XCTAssertEqual(root.linking.notice, .removed())
    }

    func testALiveRootWithoutALinkOnboardsAndTheDemoNever() throws {
        XCTAssertTrue(try makeRoot(linked: nil).showsOnboarding)

        let demo = AppRoot.demo(
            try AppEnvironment(
                transport: InMemoryCloudTransport(),
                replicaPath: try makeReplicaPath(),
                transportKind: .inMemoryDemo,
                defaults: try makeDefaults(),
                recordingsDirectory: try makeRecordingsDirectory()
            ),
            defaults: try makeDefaults()
        )
        addTeardownBlock { @MainActor in demo.env.stop() }
        XCTAssertFalse(demo.showsOnboarding)
        XCTAssertEqual(demo.env.linkedDevice, DemoSeed.device)
    }

    func testTheDemoIgnoresALinkURL() async throws {
        let demo = AppRoot.demo(
            try AppEnvironment(
                transport: InMemoryCloudTransport(),
                replicaPath: try makeReplicaPath(),
                transportKind: .inMemoryDemo,
                defaults: try makeDefaults(),
                recordingsDirectory: try makeRecordingsDirectory()
            ),
            defaults: try makeDefaults()
        )
        addTeardownBlock { @MainActor in demo.env.stop() }
        let iat = Int64(Date().timeIntervalSince1970)
        let code = LinkPayload(
            hubID: "hub-acme", macName: "Acme Mac", ownerUser: "_owner-acme", nonce: LinkPayload.makeNonce(), iat: iat, exp: iat + 600,
            hubSigningKey: LinkPayload.makeNonce(), hubAgreementKey: LinkPayload.makeNonce()
        )

        await demo.open(code.url())

        XCTAssertEqual(demo.linking.phase, .idle)
        XCTAssertEqual(demo.env.linkedDevice, DemoSeed.device)
    }

    // MARK: - Glue: the root's signals, heartbeat, link URL and Unlink (board #71)

    private func linkRecord() -> LinkRecord {
        LinkRecord(
            hubID: "hub-acme", macName: "Acme Mac", scope: .private, ownerName: "_owner-acme",
            userRecordName: "_owner-acme", nonce: LinkPayload.makeNonce(), dataShareURL: nil, relayShareURL: nil
        )
    }

    /// The `device` records the phone sealed into `transport`, as the test hub opens them.
    private func deviceWrites(in transport: InMemoryCloudTransport) async throws -> [DevicePayload] {
        let opened = try await TestPhone.hub(over: transport).changes(in: .relay, since: nil).changed
        return try opened
            .filter { $0.kind == RelayRecordKind.device.rawValue }
            .map { try RelayCoder.makeDecoder().decode(DevicePayload.self, from: $0.payload) }
    }

    /// The transport's `unlinked` event reaches the link flow through the
    /// root (`AppRoot.handle`): the link ends, the replica is wiped.
    func testTheTransportsUnlinkedSignalEndsTheLink() async throws {
        let root = try makeRoot(linked: device, link: linkRecord())
        let first = root.env
        XCTAssertFalse(root.showsOnboarding)

        first.onLinkSignal?(.unlinked)

        try await poll { root.linking.notice == .removed() }
        XCTAssertNil(root.linking.link)
        XCTAssertFalse(root.env === first, "wiped onto a new environment")
        XCTAssertTrue(root.showsOnboarding)
    }

    func testAnAccountChangeSignalForAnotherAccountEndsTheLink() async throws {
        let root = try makeRoot(linked: device, link: linkRecord())
        let first = root.env
        container.userRecordNameValue = "_colleague-b"

        first.onLinkSignal?(.accountChanged)

        try await poll { root.linking.link == nil }
        try await poll { !(root.env === first) }
        XCTAssertNil(root.linking.notice)
        XCTAssertTrue(root.showsOnboarding)
    }

    /// Every successful fetch checks the heartbeat (`AppRoot.checkHeartbeat`):
    /// another hub's stops the writes.
    func testAFetchedHeartbeatOfAnotherHubShowsMovedAndStopsWrites() async throws {
        let root = try makeRoot(linked: device, link: linkRecord())
        // A refresh joins a hydration in flight: let the boot's launch fetch end first.
        try await poll { root.env.isBootstrapped }
        let now = Date()
        let moved = heartbeat(updatedAt: now, hubID: "hub-studio", macName: "Acme Studio")
        try await TestPhone.hub(over: transports[0]).save([try CloudRecordFactory.record(for: moved, modifiedAt: now)])

        let fetched = await root.env.refresh(.pull)

        XCTAssertTrue(fetched)
        try await poll { root.linking.notice == .moved(macName: "Acme Studio") }
        try await poll { !root.env.writesAllowed }
        XCTAssertEqual(root.env.linkedDevice, device, "the link stands")
    }

    /// A `watchtower://link` URL on a live root runs the whole flow over the
    /// real host: the restart onto the code's hub, the device record, the
    /// Mac's grant, the link.
    func testALinkURLOnALiveRootLinksThroughTheRealHost() async throws {
        let linkClock = GateLinkClock()
        addTeardownBlock { linkClock.release() }
        let root = try makeRoot(linked: nil, linkClock: linkClock, keyStore: try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity))
        let code = TestPhone.linkCode(iat: Int64(linkClock.start.timeIntervalSince1970))
        let hubID = TestE2E.hubID.uuidString

        let flow = Task { await root.open(code.url()) }
        try await poll { linkClock.waiting == 1 }

        XCTAssertEqual(root.linking.phase, .waiting(macName: "Acme Mac"))
        XCTAssertEqual(built.last?.hubID, hubID, "restarted onto the code's hub")
        XCTAssertEqual(built.last?.scope, .private, "same Apple ID: the private database")
        let macSide = try XCTUnwrap(transports.last)
        let hellos = try await macSide.changes(in: .relay, since: nil).changed
        XCTAssertEqual(hellos.map(\.recordName), ["hello-\(device.deviceID)"])
        let opened = try TestPhone.openHello(try XCTUnwrap(hellos.first), code: code)
        XCTAssertEqual(opened.hello.device.linkNonce, code.nonce)
        XCTAssertEqual(root.linking.linkCode, opened.sas, "the real host's hello gives the Mac the phone's code")
        let grant = DeviceGrant(
            deviceID: device.deviceID, hubID: hubID, name: device.name, scope: .private,
            linked: true, linkedAt: linkClock.start, typingAllowed: false, startSessionsAllowed: true
        )
        try await TestPhone.hub(over: macSide).save([
            try TestPhone.grantRecord(grant, keys: TestPhone.keyboxKeys(), modifiedAt: Date())
        ])
        linkClock.release()
        // Bounded: a grant that never lands parks the flow on the clock
        // again, which must fail this test, not hang the suite.
        let finished = expectation(description: "the link flow finished")
        Task {
            await flow.value
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 10)
        flow.cancel()

        XCTAssertEqual(root.linking.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(root.env.linkedDevice?.deviceID, device.deviceID)
        XCTAssertEqual(try keyStore.hubLink(hubID)?.epochs.map(\.epoch), [1], "the keybox's keys are stored")
        XCTAssertFalse(root.showsOnboarding)
    }

    /// Settings → Unlink this Mac on a live root: offered while linked, it
    /// writes `unlinked` to the link's hub and ends on the unlinked hub.
    func testSettingsUnlinkOnALiveRootWritesUnlinkedAndEndsUnlinked() async throws {
        let root = try makeRoot(linked: device, link: linkRecord())
        XCTAssertTrue(SettingsView.offersUnlink(transportKind: root.env.transportKind, link: root.linking.link))
        XCTAssertFalse(SettingsView.offersUnlink(transportKind: .inMemoryDemo, link: linkRecord()), "the demo has no link to end")

        await root.linking.unlink()

        XCTAssertNil(root.linking.link)
        XCTAssertFalse(SettingsView.offersUnlink(transportKind: root.env.transportKind, link: root.linking.link))
        XCTAssertEqual(Array(built.map(\.hubID).suffix(2)), ["hub-acme", AppEnvironment.unlinkedHubID])
        let linkSide = transports[transports.count - 2]
        let writes = try await deviceWrites(in: linkSide)
        XCTAssertEqual(writes.last?.unlinked, true, "the link's hub hears the unlink")
        XCTAssertEqual(root.linking.phase, .idle)
        XCTAssertTrue(root.showsOnboarding)
    }

    // MARK: - E2E keys (mobile E2E Task 16)

    /// The test hub's link, as the phone saves it.
    private func e2eLinkRecord() -> LinkRecord {
        LinkRecord(
            hubID: TestE2E.hubID.uuidString, macName: "Acme Mac", scope: .private, ownerName: "_owner-acme",
            userRecordName: "_owner-acme", nonce: WireBytes.base64URL(TestE2E.linkNonce), dataShareURL: nil, relayShareURL: nil
        )
    }

    /// D9: Remove on the Mac publishes this phone's keybox as revoked; the
    /// phone reads it after the next fetch and runs the removal wipe.
    func testARevokedKeyboxRemovesThePhoneInPrivateScope() async throws {
        let root = try makeRoot(linked: device, link: e2eLinkRecord())
        let first = root.env
        // A refresh joins a hydration in flight: let the boot's launch fetch end first.
        try await poll { first.isBootstrapped }
        let revoked = DeviceGrant(
            deviceID: device.deviceID, hubID: TestE2E.hubID.uuidString, name: device.name, scope: .private,
            linked: false, typingAllowed: false, startSessionsAllowed: true, decidedAt: Date(), revoked: true
        )
        try await TestPhone.hub(over: transports[0]).save([try TestPhone.grantRecord(revoked, modifiedAt: Date())])

        let fetched = await first.refresh(.pull)

        XCTAssertTrue(fetched)
        try await poll { root.linking.notice == .removed() }
        XCTAssertNil(root.linking.link)
        XCTAssertNil(LinkStore(defaults: try XCTUnwrap(defaultsInUse)).link)
        XCTAssertFalse(root.env === first, "wiped onto a new environment")
        XCTAssertEqual(built.last?.hubID, AppEnvironment.unlinkedHubID)
        XCTAssertNil(try keyStore.hubLink(TestE2E.hubID.uuidString), "the hub's keys are deleted")
        XCTAssertTrue(root.showsOnboarding)
    }

    /// A link saved by a pre-E2E build has no hub keys: the launch drops it
    /// and asks for a new scan.
    func testAV2LinkIsDroppedAtLaunchWithTheReScanNotice() async throws {
        let root = try makeRoot(
            linked: device, hubID: "hub-acme", link: linkRecord(),
            keyStore: try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity)
        )
        let first = root.env

        await root.resumeLink()

        XCTAssertNil(root.linking.link)
        XCTAssertEqual(root.linking.notice, .encryptionReScan)
        XCTAssertFalse(root.env === first, "the old link's replica is wiped")
        XCTAssertEqual(built.last?.hubID, AppEnvironment.unlinkedHubID)
        XCTAssertTrue(root.showsOnboarding)
    }

    /// F14: a background launch while the phone is locked (after the first
    /// unlock) reads the device id from its `afterFirstUnlock` item, builds
    /// the environment and never creates an identity; before the first
    /// unlock the boot waits (#62's guarantee: locked is never "no id").
    func testABackgroundLaunchReadsTheDeviceIDWhileLocked() throws {
        let linked = try TestE2E.phoneStore()
        linked.isLocked = true
        XCTAssertEqual(try DeviceIdentity.current(keys: linked).deviceID, TestE2E.deviceID.uuidString)
        let env = try AppEnvironment(
            transport: InMemoryCloudTransport(), replicaPath: try makeReplicaPath(), transportKind: .cloudKit,
            hubID: TestE2E.hubID.uuidString, linkedDevice: device,
            keys: PhoneKeys(store: linked, hubID: TestE2E.hubID.uuidString),
            defaults: try makeDefaults(), recordingsDirectory: try makeRecordingsDirectory()
        )
        addTeardownBlock { @MainActor in env.stop() }
        XCTAssertTrue(env.hasDeviceKeys)

        let fresh = InMemoryPhoneKeyStore()
        XCTAssertNil(try DeviceIdentity.current(keys: fresh).deviceID)
        let unlinked = try AppEnvironment(
            transport: InMemoryCloudTransport(), replicaPath: try makeReplicaPath(), transportKind: .cloudKit,
            keys: PhoneKeys(store: fresh, hubID: TestE2E.hubID.uuidString),
            defaults: try makeDefaults(), recordingsDirectory: try makeRecordingsDirectory()
        )
        addTeardownBlock { @MainActor in unlinked.stop() }
        XCTAssertFalse(unlinked.hasDeviceKeys)
        XCTAssertNil(try fresh.deviceID(), "no identity is created outside the link flow")

        linked.isBeforeFirstUnlock = true
        XCTAssertThrowsError(try DeviceIdentity.current(keys: linked)) { error in
            XCTAssertEqual(error as? KeyStoreError, .locked)
        }
    }

    func testALockedKeychainAtBootWaitsForTheUnlockAndAnotherFailureShowsIt() {
        let locked = WatchtowerMobileApp.Boot.make(processEnvironment: [:]) { throw KeyStoreError.locked }
        guard case .waitingForUnlock = locked else {
            return XCTFail("a locked Keychain waits for the unlock, got \(locked)")
        }

        let broken = WatchtowerMobileApp.Boot.make(processEnvironment: [:]) { throw KeyStoreError.unexpected(-25_300) }
        guard case let .failed(message) = broken else {
            return XCTFail("another Keychain failure is shown, got \(broken)")
        }
        XCTAssertTrue(message.contains("Keychain"))
    }

    /// The CloudKit kind without device keys seals nothing: no action, no
    /// recording upload, no link record leaves in any form.
    func testTheCloudKitKindWithNoKeysNeverSealsAnything() async throws {
        let transport = InMemoryCloudTransport()
        let env = try AppEnvironment(
            transport: transport, replicaPath: try makeReplicaPath(), transportKind: .cloudKit,
            hubID: TestE2E.hubID.uuidString, linkedDevice: device,
            defaults: try makeDefaults(), recordingsDirectory: try makeRecordingsDirectory()
        )
        addTeardownBlock { @MainActor in env.stop() }
        XCTAssertFalse(env.hasDeviceKeys)

        do {
            try await env.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
            XCTFail("nothing can be sealed without keys")
        } catch {
            XCTAssertEqual(error as? SecureTransportError, .keysUnavailable)
        }
        do {
            try await env.linkTransport.save([try CloudRecordFactory.record(
                for: env.deviceSettings.devicePayload(for: device, linkNonce: nil, unlinked: true, now: Date()), modifiedAt: Date()
            )])
            XCTFail("the link transport seals too")
        } catch {
            XCTAssertEqual(error as? SecureTransportError, .keysUnavailable)
        }
        let relay = try await transport.changes(in: .relay, since: nil).changed
        XCTAssertTrue(relay.isEmpty, "nothing reached the transport")
    }

    /// F29: a wipe carries the phone's seq ceiling over to the new replica.
    func testAWipeCarriesTheSeqCeilingOver() async throws {
        let root = try makeRoot(linked: device)
        let first = root.env
        try await first.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
        let ceiling = try first.envelopeSeqCeiling()
        XCTAssertGreaterThan(ceiling, 0)

        _ = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true)

        XCTAssertFalse(root.env === first)
        await root.setLink(device, writesAllowed: true)
        try await root.env.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-2")
        XCTAssertGreaterThan(try root.env.envelopeSeqCeiling(), ceiling, "seqs continue above the wiped replica's")
    }

    /// Final review (Phone I-2, Desktop I-1): two wipes with no seal between them (Unlink, then a scan) keep the
    /// floor. The environment between them never allocates a seq, so the floor must be stored when its replica
    /// is created, or the next wipe reads 0 and the phone restarts at seq 1 under the hub's old marks.
    func testTwoWipesWithoutASealBetweenThemKeepTheSeqFloor() async throws {
        let root = try makeRoot(linked: device)
        try await root.env.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
        let ceiling = try root.env.envelopeSeqCeiling()
        XCTAssertGreaterThan(ceiling, 0)

        _ = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true)
        XCTAssertGreaterThanOrEqual(try root.env.envelopeSeqCeiling(), ceiling, "the new replica stores the floor at once")
        _ = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: true)

        await root.setLink(device, writesAllowed: true)
        try await root.env.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-2")
        XCTAssertGreaterThan(try root.env.envelopeSeqCeiling(), ceiling, "seqs continue above the first replica's")
    }

    /// Final review Phone I-1: a rotation's keybox reached the replica but its one-shot signal was lost (the app
    /// suspended between the index and the signal, the scanner open, a restart). The next fetch reconciles: the
    /// missing epoch's keys join the Keychain and the rows sealed under it open, without a re-scan.
    func testAKeyboxWhoseSignalWasLostIsMergedAfterTheNextFetch() async throws {
        var link = e2eLinkRecord()
        link.deviceID = device.deviceID
        let root = try makeRoot(linked: device, link: link)
        try await poll { root.env.isBootstrapped }
        let env = root.env
        env.onKeyboxChanged = nil
        XCTAssertEqual(try keyStore.hubLink(TestE2E.hubID.uuidString)?.epochs.map(\.epoch), [1])
        let grant = DeviceGrant(
            deviceID: device.deviceID, hubID: TestE2E.hubID.uuidString, name: device.name, scope: .private,
            linked: true, typingAllowed: false, startSessionsAllowed: true
        )
        let now = Date()
        let rotated = TestE2E.hubTransport(TestE2E.hub(epoch: 2, firstSeq: 900_000_000_000), inner: transports[0])
        try await rotated.save([
            try TestPhone.grantRecord(grant, keys: TestPhone.keyboxKeys(epoch: 2), modifiedAt: now),
            CloudRecordFactory.record(for: SliceRecord(kind: .workbench, id: "7", modifiedAt: now, payload: Data("{}".utf8)))
        ])

        _ = await env.refresh(.pull)
        await root.linkCheck?.value

        XCTAssertEqual(try keyStore.hubLink(TestE2E.hubID.uuidString)?.epochs.map(\.epoch), [1, 2], "merged on the fetch")
        let opened = try await env.store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records WHERE kind = ?", arguments: [SliceKind.workbench.rawValue])
        }
        XCTAssertEqual(opened, 1, "the epoch-2 row opens without waiting for the next hydrate")
    }

    /// M-5: a keybox signed by another hub key than the QR's (an attacker
    /// writing into the zone) is refused at apply through the real host: a
    /// forged "revoked" removes nothing, and the link flow reads no keybox.
    func testAKeyboxSignedByAStrangerHubKeyIsRefused() async throws {
        let root = try makeRoot(linked: device, link: e2eLinkRecord())
        try await poll { root.env.isBootstrapped }
        let first = root.env
        let forged = DeviceGrant(
            deviceID: device.deviceID, hubID: TestE2E.hubID.uuidString, name: device.name, scope: .private,
            linked: false, typingAllowed: false, startSessionsAllowed: true, decidedAt: Date(), revoked: true
        )
        let stranger = SecureTransport(
            inner: transports[0], keys: StrangerSignedHub(), rollback: InMemoryRollbackGuard()
        )
        try await stranger.save([try TestPhone.grantRecord(forged, modifiedAt: Date())])

        let keybox = await root.fetchKeybox(deviceID: device.deviceID)

        XCTAssertNil(keybox, "never stored, so never read")
        XCTAssertGreaterThanOrEqual(first.store.rejectedCount(), 1, "refused at apply: bad signature")
        XCTAssertTrue(root.env === first, "no removal wipe")
        XCTAssertNotNil(root.linking.link)
        XCTAssertEqual(try keyStore.hubLink(TestE2E.hubID.uuidString)?.epochs.map(\.epoch), [1])
    }

    private func heartbeat(updatedAt: Date, hubID: String = "hub-acme", macName: String = "Acme Mac") -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: updatedAt,
            appVersion: "1.0",
            hubID: hubID,
            macName: macName,
            flavor: .default,
            lastPublishAt: updatedAt,
            lastRelayAt: updatedAt,
            relayBacklog: 0,
            accounts: [],
            enabledAt: updatedAt,
            ownerUser: "_owner-acme",
            sharing: .none
        )
    }
}

/// A transport whose fetches wait until `open()`: the environment's first
/// fetch is held for as long as the test needs.
private actor GatedTransport: CloudSyncTransport {
    private let inner = InMemoryCloudTransport()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func save(_ records: [CloudRecord]) async throws {
        try await inner.save(records)
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try await inner.delete(recordNames: recordNames, in: zone)
    }

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return try await inner.changes(in: zone, since: token)
    }
}

/// A link clock whose sleeps wait for `release()` and whose `now` stands
/// still: the grant wait polls once, then the test answers for the Mac.
private final class GateLinkClock: LinkClock, @unchecked Sendable {
    let start = Date()
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { lock.withLock { waiters.count } }

    func now() -> Date { start }

    func sleep(for duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
        }
        try Task.checkCancellation()
    }

    func release() {
        let all = lock.withLock {
            let parked = waiters
            waiters = []
            return parked
        }
        all.forEach { $0.resume() }
    }
}

/// The test hub with its signing key swapped for a stranger's: everything else (hub id, recipient) is right.
private final class StrangerSignedHub: SecureKeyProvider, @unchecked Sendable {
    private let hub = TestE2E.hub(firstSeq: 9_000_000_000)
    private let stranger = Curve25519.Signing.PrivateKey()

    var role: SecureRole { hub.role }
    func metaKey() throws -> SymmetricKey { try hub.metaKey() }
    func currentEpoch() throws -> UInt32 { try hub.currentEpoch() }
    func dataKey(epoch: UInt32) throws -> SymmetricKey { try hub.dataKey(epoch: epoch) }
    func alertKey(epoch: UInt32) throws -> SymmetricKey { try hub.alertKey(epoch: epoch) }
    func relayKey(_ direction: RelayDirection, deviceID: UUID, epoch: UInt32) throws -> SymmetricKey {
        try hub.relayKey(direction, deviceID: deviceID, epoch: epoch)
    }
    func acceptsRelayEpoch(_ epoch: UInt32, deviceID: UUID) throws -> Bool { try hub.acceptsRelayEpoch(epoch, deviceID: deviceID) }
    func relayDeviceIDs() throws -> [UUID] { try hub.relayDeviceIDs() }
    func nextSeq() throws -> UInt64 { try hub.nextSeq() }
    func hubSigner() throws -> Curve25519.Signing.PrivateKey { stranger }
    func hubAgreement() throws -> Curve25519.KeyAgreement.PrivateKey { try hub.hubAgreement() }
    func keyboxRecipient(deviceID: UUID) throws -> Curve25519.KeyAgreement.PublicKey? { try hub.keyboxRecipient(deviceID: deviceID) }
    func deviceSigner() throws -> Curve25519.Signing.PrivateKey { try hub.deviceSigner() }
    func hubAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey { try hub.hubAgreementPublicKey() }
    func linkNonce() throws -> Data { try hub.linkNonce() }
}
