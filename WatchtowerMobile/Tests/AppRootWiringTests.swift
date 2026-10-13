import Foundation
import GRDB
import os
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// `AppRoot` as the link flow's host (spec §2.3, §9): the wipe really
/// empties the replica and the outbox, a moved hub sends nothing, a scope
/// change restarts on an empty replica, and the demo never onboards.
@MainActor
final class AppRootWiringTests: XCTestCase {
    private let device = LinkedDevice(
        deviceID: "device-acme-1",
        name: "Colleague A's iPhone",
        model: "iPhone",
        appVersion: "1.0",
        scope: .private,
        userRecordName: "_owner-acme"
    )

    /// Every environment's session the root built, and the database and hub
    /// each runs.
    private var built: [(env: HubSession, scope: CloudDatabaseScope, hubID: String)] = []
    /// Every environment's recorder runs on this engine and clock: no audio.
    private let engine = FakeAudioEngine()
    private let clock = FakeClock()
    private var recordingsDirectory: URL?
    private var transports: [InMemoryCloudTransport] = []
    private var replicaPath = ""
    private var container: FakeLinkContainer!

    /// A live-kind root on one replica path. Without `transportStorePath`
    /// each environment gets a fresh in-memory transport; with it, a
    /// `CloudKitTransport` over the persistent store at that path (the app's
    /// shape: one transport file across restarts; no engine starts in the
    /// unsigned test host).
    /// `link` is the saved link the flow starts from; `linkClock` runs the
    /// flow's grant wait.
    private func makeRoot(
        linked: LinkedDevice?,
        hubID initialHub: String = HubSession.unlinkedHubID,
        link: LinkRecord? = nil,
        linkClock: any LinkClock = SystemLinkClock(),
        transportStorePath: String? = nil
    ) throws -> AppRoot {
        let path = try makeReplicaPath()
        replicaPath = path
        let defaults = try makeDefaults()
        let store = LinkStore(defaults: defaults)
        store.link = link
        container = FakeLinkContainer(log: LinkEventLog())
        let recordings = try makeRecordingsDirectory()
        recordingsDirectory = recordings
        let engine = engine
        let clock = clock
        let make: @MainActor (CloudDatabaseScope, String, LinkedDevice?) throws -> AppEnvironment = { [weak self] scope, hubID, device in
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
            let env = try HubSession(
                transport: transport,
                replicaPath: path,
                transportKind: .cloudKit,
                hubID: hubID,
                linkedDevice: device,
                defaults: defaults,
                recordingsDirectory: recordings,
                hold: Self.hold(in: recordings),
                databaseScope: scope
            ) { uploader in
                PhoneRecorderController(
                    uploader: uploader, engine: engine, notificationCenter: NotificationCenter(), now: { clock.now }, tickInterval: nil
                )
            }
            self?.addTeardownBlock { @MainActor in env.stop() }
            self?.built.append((env, scope, hubID))
            return AppEnvironment.single(env, defaults: defaults)
        }
        let identity = DeviceIdentity(deviceID: device.deviceID, name: device.name, model: device.model, appVersion: device.appVersion)
        return AppRoot(
            env: try make(.private, initialHub, linked),
            scope: .private,
            hubID: initialHub,
            linking: LinkingViewModel(container: container, store: store, identity: identity, clock: linkClock),
            restarter: AppRoot.Restarter(replicaPath: path, transportStorePath: transportStorePath, make: make)
        )
    }

    private func sliceCount(_ env: HubSession) async throws -> Int {
        try await env.store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0
        }
    }

    func testWipeEmptiesTheReplicaAndOutboxAndCountsWhatWasNotSent() async throws {
        let root = try makeRoot(linked: device)
        let first = root.env.activeSession
        let now = Date()
        try await transports[0].save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        try await poll { (try? self.sliceCountSync(first)) == 1 }
        for id in 1...3 {
            try await first.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-\(id)")
        }
        XCTAssertEqual(try first.store.pendingActions().count, 3)

        let notSent = await root.wipeLocalData(restartingOn: .private, hubID: HubSession.unlinkedHubID, keepRecordings: true)

        XCTAssertEqual(notSent, LocalWipe(notSent: 3), "the three pending items are reported Not sent")
        XCTAssertFalse(root.env.activeSession === first, "a new environment on the same files")
        XCTAssertFalse(first.isLooping, "the old environment is stopped")
        let rows = try await sliceCount(root.env.activeSession)
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
        let first = root.env.activeSession
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

        let notSent = await root.wipeLocalData(restartingOn: .private, hubID: HubSession.unlinkedHubID, keepRecordings: true)

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

        async let first = root.wipeLocalData(restartingOn: .private, hubID: HubSession.unlinkedHubID, keepRecordings: true)
        async let second = root.wipeLocalData(restartingOn: .private, hubID: HubSession.unlinkedHubID, keepRecordings: true)
        _ = await (first, second)

        XCTAssertEqual(built.count, 3, "the initial environment and one per wipe")
        let last = try XCTUnwrap(built.last?.env)
        XCTAssertTrue(root.env.activeSession === last)
        try await poll { self.built.allSatisfy { $0.env.isBootstrapped } }
        try await poll { last.isLooping }
        for (index, entry) in built.dropLast().enumerated() {
            XCTAssertFalse(entry.env.isLooping, "environment \(index) was replaced without a shutdown")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: replicaPath), "the live replica's file is in place")
        let now = Date()
        try await transports[2].save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        let fetched = await last.refresh(.pull)
        XCTAssertTrue(fetched)
        XCTAssertEqual(try sliceCountSync(last), 1, "the live replica takes writes")
    }

    private func sliceCountSync(_ env: HubSession) throws -> Int {
        try env.store.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0 }
    }

    /// A Workbench choice made before linking reaches the Mac with the link
    /// record, across the restart onto the link's hub; the next link starts
    /// from the defaults.
    func testAChoiceMadeBeforeLinkingTravelsWithTheLinkRecord() async throws {
        let root = try makeRoot(linked: nil)
        await root.env.deviceSettings.setTypingRequested(true)
        await root.env.deviceSettings.setStartSessions(false)

        _ = try await root.prepare(scope: .private, hubID: "hub-acme")
        XCTAssertEqual(built.last?.hubID, "hub-acme", "restarted onto the link's hub")
        let payload = root.devicePayload(for: device, linkNonce: "nonce-acme", unlinked: false, now: Date())

        XCTAssertTrue(payload.typingRequested)
        XCTAssertFalse(payload.startSessions)

        _ = try await root.prepare(scope: .private, hubID: "hub-home")
        let next = root.devicePayload(for: device, linkNonce: "nonce-home", unlinked: false, now: Date())
        XCTAssertFalse(next.typingRequested, "the unlinked choice went to the first link only")
        XCTAssertTrue(next.startSessions)
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
        let deviceWrites = try await transports[0].changes(in: .relay, since: nil).changed
            .filter { $0.kind == RelayRecordKind.device.rawValue }
        XCTAssertTrue(deviceWrites.isEmpty, "a moved hub's phone writes no device record")
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
        let resent = try await transports[0].changes(in: .relay, since: nil).changed
            .filter { $0.kind == RelayRecordKind.device.rawValue }
            .map { try RelayCoder.makeDecoder().decode(DevicePayload.self, from: $0.payload) }
        XCTAssertEqual(resent.map(\.startSessions), [false], "review F10: the kept toggle reaches the Mac when writes return")
        try await root.env.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
    }

    // MARK: - Recordings across a wipe (board #63)

    /// The running root's recordings folder.
    private var recordings: URL {
        recordingsDirectory ?? URL(fileURLWithPath: "/nonexistent")
    }

    private var hold: RecordingHold {
        Self.hold(in: recordings)
    }

    /// Today's single-hub hold: `.held` in the recordings folder.
    private static func hold(in recordings: URL) -> RecordingHold {
        RecordingHold(directory: recordings.appendingPathComponent(".held", isDirectory: true))
    }

    /// A voice note of `seconds`, saved (`waiting`) in the running
    /// environment; returns its ledger id.
    private func saveVoiceNote(_ root: AppRoot, seconds: TimeInterval = 12) async throws -> String {
        await root.env.recorder.recordVoiceNote()
        clock.advance(seconds)
        await root.env.recorder.stop()
        return try XCTUnwrap(root.env.recorder.savedRecording?.id)
    }

    /// An unlink or a removal during a meeting capture: the capture is
    /// stopped and saved, held for its hub, listed as waiting for that Mac,
    /// and sent only once this phone is on that hub again.
    func testAWipeDuringACaptureHoldsItForItsHubAndSendsItAfterRelinkingThatHub() async throws {
        let root = try makeRoot(linked: device, hubID: "hub-acme")
        let first = root.env.activeSession
        try await poll { first.isBootstrapped }
        let event = MeetingEvent(id: "event-1", title: "Design sync", start: clock.now, end: clock.now.addingTimeInterval(1_800))
        await first.recorder.recordMeeting(event)
        XCTAssertTrue(first.recorder.isCapturing)
        clock.advance(30)
        first.recorder.markMoment()
        await root.setLink(nil, writesAllowed: true)

        let wipe = await root.wipeLocalData(restartingOn: .private, hubID: HubSession.unlinkedHubID, keepRecordings: true)

        XCTAssertEqual(wipe, LocalWipe(notSent: 0, stoppedRecording: true), "held, so not reported Not sent")
        XCTAssertEqual(engine.finishCount, 1, "the file was finalised, not cut off")
        try await poll { root.env.activeSession.isBootstrapped }
        XCTAssertTrue(try root.env.store.phoneRecordings().isEmpty, "the unlinked hub does not adopt it")
        let held = try XCTUnwrap(root.env.heldRecordings.first, "listed as waiting for its Mac")
        XCTAssertEqual(held.hubID, "hub-acme")
        XCTAssertEqual(held.marks, [30])
        XCTAssertNotNil(hold.audioURL(of: held, recordingsDirectory: recordings), "the launch sweep left the audio alone")
        let list = RecordingsListModel(
            recordings: PhoneRecordingsSnapshot(), replica: CalendarReplicaSnapshot(),
            seen: RecordingsSeen(baseline: .distantPast, opened: []), now: clock.now, calendar: .current,
            held: root.env.heldRecordings
        )
        XCTAssertEqual(list.inProgress.map(\.state), [.heldForMac(nil)])

        _ = try await root.prepare(scope: .private, hubID: "hub-acme")
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
    }

    /// Review F6: a recording held for one Mac never goes to another.
    func testAnotherHubNeverReceivesAHeldRecording() async throws {
        let root = try makeRoot(linked: device, hubID: "hub-acme")
        try await poll { root.env.activeSession.isBootstrapped }
        let id = try await saveVoiceNote(root)
        await root.setLink(nil, writesAllowed: true)
        _ = await root.wipeLocalData(restartingOn: .private, hubID: HubSession.unlinkedHubID, keepRecordings: true)

        _ = try await root.prepare(scope: .private, hubID: "hub-studio")
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
        try await poll { root.env.activeSession.isBootstrapped }
        let id = try await saveVoiceNote(root)
        let file = try XCTUnwrap(try root.env.store.phoneRecording(id: id)).fileURL(in: recordingsDirectory)
        await root.setLink(nil, writesAllowed: true)

        let wipe = await root.wipeLocalData(restartingOn: .private, hubID: HubSession.unlinkedHubID, keepRecordings: false)

        XCTAssertEqual(wipe, LocalWipe(notSent: 1))
        try await poll { root.env.activeSession.isBootstrapped }
        XCTAssertTrue(root.env.heldRecordings.isEmpty)
        XCTAssertTrue(try hold.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "swept, as before")
    }

    /// An unlink restarts twice in a row (the queue wipe on the linked hub,
    /// then the unlinked hub): a recording survives both, still held for
    /// its hub.
    func testAWaitingRecordingSurvivesBackToBackWipes() async throws {
        let root = try makeRoot(linked: device, hubID: "hub-acme")
        try await poll { root.env.activeSession.isBootstrapped }
        let id = try await saveVoiceNote(root)
        await root.setLink(nil, writesAllowed: true)

        async let one = root.wipeLocalData(restartingOn: .private, hubID: "hub-acme", keepRecordings: true)
        async let two = root.wipeLocalData(restartingOn: .private, hubID: HubSession.unlinkedHubID, keepRecordings: true)
        let wipes = await [one, two]

        XCTAssertEqual(wipes, [LocalWipe(), LocalWipe()], "nothing lost, no capture running")
        try await poll { root.env.activeSession.isBootstrapped }
        let held = try XCTUnwrap(root.env.heldRecordings.first)
        XCTAssertEqual(held.id, id)
        XCTAssertEqual(held.hubID, "hub-acme")
        XCTAssertNotNil(hold.audioURL(of: held, recordingsDirectory: recordings))
    }

    /// Verify round: killed after the hold and before the replica went (or
    /// a replica that could not be removed): the next boot finds the row
    /// still in the replica, brings the audio back next to it, and sends it
    /// — its `uploading` row as the relaunch retry (board #724): in the
    /// foreground, with the Mac online and the backoff due.
    func testKilledAfterHoldingBeforeTheReplicaWentRestoresTheAudio() async throws {
        let root = try makeRoot(linked: device, hubID: "hub-acme")
        try await poll { root.env.activeSession.isBootstrapped }
        let id = try await saveVoiceNote(root)
        let row = try XCTUnwrap(try root.env.store.phoneRecording(id: id))
        let file = row.fileURL(in: recordingsDirectory)
        try hold.hold([HeldRecording(row, marks: [], hubID: "hub-acme", macName: nil)], from: recordings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the audio is in the hold")
        root.env.activeSession.stop()

        // The relaunch: the same replica, the same hub, past the first
        // backoff step, with the Mac's heartbeat fresh.
        let relaunchAt = Date().addingTimeInterval(RecordingUploader.retryDelays[0] + 1)
        let transport = InMemoryCloudTransport()
        try await transport.save([try CloudRecordFactory.record(for: heartbeat(updatedAt: relaunchAt), modifiedAt: relaunchAt)])
        let relaunched = try HubSession(
            transport: transport,
            replicaPath: replicaPath,
            transportKind: .cloudKit,
            hubID: "hub-acme",
            linkedDevice: device,
            defaults: try makeDefaults(),
            recordingsDirectory: recordingsDirectory,
            hold: hold,
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
        try await poll { root.env.activeSession.isBootstrapped }
        let directory = try XCTUnwrap(recordingsDirectory)
        // Another process's uploader: the capture is not live in this one.
        let earlier = RecordingUploader(transport: InMemoryCloudTransport(), store: root.env.store, directory: directory)
        let file = directory.appendingPathComponent("cut-short.m4a")
        try Data(repeating: 0x5A, count: 256).write(to: file)
        let stranded = try await earlier.beginCapture(fileURL: file, startedAt: clock.now, titleHint: "Cut short", eventID: nil)
        engine.fileDuration = 20
        await root.setLink(nil, writesAllowed: true)

        let wipe = await root.wipeLocalData(restartingOn: .private, hubID: HubSession.unlinkedHubID, keepRecordings: true)

        XCTAssertEqual(wipe, LocalWipe(), "not lost")
        let held = try XCTUnwrap(root.env.heldRecordings.first)
        XCTAssertEqual(held.id, stranded.id)
        XCTAssertEqual(held.durationSec, 20, "finalized from its file")
        XCTAssertNotNil(hold.audioURL(of: held, recordingsDirectory: recordings))
    }

    /// Review F2: a stop already saving (the owner's tap, the 3-hour cap)
    /// is waited for, then its recording is held; the wipe did not stop it.
    func testAWipeDuringASaveWaitsForItAndHoldsTheRecording() async throws {
        let root = try makeRoot(linked: device, hubID: "hub-acme")
        let first = root.env.activeSession
        try await poll { first.isBootstrapped }
        await first.recorder.recordVoiceNote()
        clock.advance(15)
        engine.holdFinish = true
        let ownerStop = Task { await first.recorder.stop() }
        try await poll { first.recorder.phase == .saving && self.engine.finishCount == 1 }
        await root.setLink(nil, writesAllowed: true)

        let wipeTask = Task { await root.wipeLocalData(restartingOn: .private, hubID: HubSession.unlinkedHubID, keepRecordings: true) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(root.env.activeSession === first, "the wipe waits for the save")
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
        try await poll { root.env.activeSession.isBootstrapped }
        let id = try await saveVoiceNote(root)
        let file = try XCTUnwrap(try root.env.store.phoneRecording(id: id)).fileURL(in: recordingsDirectory)
        // A manifest that cannot be read: holding fails.
        try FileManager.default.createDirectory(
            at: hold.directory.appendingPathComponent("manifest.json"), withIntermediateDirectories: true
        )
        await root.setLink(nil, writesAllowed: true)

        let wipe = await root.wipeLocalData(restartingOn: .private, hubID: HubSession.unlinkedHubID, keepRecordings: true)

        let problem = try XCTUnwrap(wipe.problem)
        XCTAssertTrue(problem.hasPrefix("Some recordings couldn't be read"), problem)
        try await poll { root.env.activeSession.isBootstrapped }
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
        try await poll { root.env.activeSession.isBootstrapped }
        let id = try await saveVoiceNote(root)
        try FileManager.default.removeItem(at: try XCTUnwrap(try root.env.store.phoneRecording(id: id)).fileURL(in: recordingsDirectory))

        let wipe = await root.wipeLocalData(restartingOn: .private, hubID: HubSession.unlinkedHubID, keepRecordings: true)

        XCTAssertEqual(wipe, LocalWipe(notSent: 1))
        try await poll { root.env.activeSession.isBootstrapped }
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

        _ = await root.wipeLocalData(restartingOn: .private, hubID: HubSession.unlinkedHubID, keepRecordings: true)

        XCTAssertNotNil(root.failure, "the restart fails visibly")
        XCTAssertEqual(built.count, 1, "no environment opens on the old replica")
    }

    /// Board #70: an unlink's flush waits for the engine start only, never
    /// for the first fetch, which a slow network can hold.
    func testSendNowDoesNotWaitForTheFirstFetch() async throws {
        let gate = GatedTransport()
        let env = try HubSession(
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
        let first = root.env.activeSession

        root.retireEnvironment()
        _ = try await root.prepare(scope: .private, hubID: HubSession.unlinkedHubID)

        XCTAssertFalse(root.env.activeSession === first)
        _ = try await root.prepare(scope: .private, hubID: HubSession.unlinkedHubID)
        XCTAssertEqual(built.count, 2, "a fresh environment is not retired")
    }

    func testPreparingAnotherScopeRestartsOnAnEmptyReplica() async throws {
        let root = try makeRoot(linked: nil)
        let first = root.env.activeSession
        let now = Date()
        try await transports[0].save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        try await poll { (try? self.sliceCountSync(first)) == 1 }

        let samePrivate = try await root.prepare(scope: .private, hubID: HubSession.unlinkedHubID)
        XCTAssertTrue(root.env.activeSession === first, "the running scope needs no restart")
        XCTAssertTrue((samePrivate as? InMemoryCloudTransport) === transports[0])

        let shared = try await root.prepare(scope: .shared(ownerName: "_owner-acme"), hubID: HubSession.unlinkedHubID)

        XCTAssertFalse(root.env.activeSession === first)
        XCTAssertEqual(built.last?.scope, .shared(ownerName: "_owner-acme"))
        XCTAssertTrue((shared as? InMemoryCloudTransport) === transports.last)
        let rows = try await sliceCount(root.env.activeSession)
        XCTAssertEqual(rows, 0, "another database's data is not kept")
    }

    func testPreparingAnotherHubOnTheSameScopeRestartsOnAnEmptyReplica() async throws {
        let root = try makeRoot(linked: nil)
        let first = root.env.activeSession
        let now = Date()
        try await transports[0].save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        try await poll { (try? self.sliceCountSync(first)) == 1 }

        _ = try await root.prepare(scope: .private, hubID: "hub-acme")

        XCTAssertFalse(root.env.activeSession === first, "another hub is another pair of zones")
        XCTAssertEqual(built.last?.hubID, "hub-acme")
        let rows = try await sliceCount(root.env.activeSession)
        XCTAssertEqual(rows, 0, "another hub's data is not kept")
        _ = try await root.prepare(scope: .private, hubID: "hub-acme")
        XCTAssertEqual(built.count, 2, "the running hub needs no restart")
    }

    func testFetchGrantReadsThisPhonesHydratedGrant() async throws {
        let root = try makeRoot(linked: nil)
        let grant = DeviceGrant(
            deviceID: device.deviceID, hubID: "hub-acme", name: device.name, scope: .private,
            linked: true, typingAllowed: false, startSessionsAllowed: true
        )
        try await transports[0].save([try CloudRecordFactory.record(for: grant, modifiedAt: Date())])

        let fetched = await root.fetchGrant(deviceID: device.deviceID)

        XCTAssertEqual(fetched, grant)
        let other = await root.fetchGrant(deviceID: "device-other")
        XCTAssertNil(other)
    }

    /// #64: a same-Apple-ID phone gets no `unlinked` event. After each
    /// fetch the root judges the grant of the device id the link was made
    /// with: one this build cannot decode is never judged, and a grant gone
    /// on two fetches 30 s apart is the Mac's Remove.
    func testTheLinkedDevicesGrantGoneOnTwoFetchesIsTheMacsRemoveAndAnUndecodableOneIsNot() async throws {
        let linkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = FakeLinkClock(now: linkedAt)
        var link = LinkRecord(
            hubID: "hub-acme", macName: "Acme Mac", scope: .private, ownerName: "_owner-acme",
            userRecordName: "_owner-acme", nonce: LinkPayload.makeNonce(), dataShareURL: nil, relayShareURL: nil
        )
        link.deviceID = "device-linked"
        link.linkedAt = linkedAt
        let root = try makeRoot(linked: device, link: link, linkClock: clock)
        let transport = transports[0]
        let later = linkedAt.addingTimeInterval(60)
        let grant = DeviceGrant(
            deviceID: "device-linked", hubID: "hub-acme", name: device.name, scope: .private,
            linked: true, linkedAt: linkedAt, typingAllowed: false, startSessionsAllowed: true
        )
        try await transport.save([
            try CloudRecordFactory.record(for: heartbeat(updatedAt: later), modifiedAt: later),
            try CloudRecordFactory.record(for: grant, modifiedAt: later)
        ])
        // Each fetch's link check, awaited.
        let fetch = {
            await root.env.refresh(.pull)
            await root.linkCheck?.value
        }
        await fetch()
        XCTAssertNotNil(root.linking.link, "granted under the id it linked with (not the Keychain's \(self.device.deviceID))")

        let reshaped = CloudRecord(
            recordName: grant.recordName, zone: .data, kind: SliceKind.deviceGrant.rawValue,
            modifiedAt: later.addingTimeInterval(1), payload: Data(#"{"linked":"maybe"}"#.utf8)
        )
        try await transport.save([reshaped])
        await fetch()
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        await fetch()
        XCTAssertNotNil(root.linking.link, "an unreadable grant is not a removed one")

        try await transport.delete(recordNames: [grant.recordName], in: .data)
        await fetch()
        XCTAssertNotNil(root.linking.link, "one look is not enough")
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        await fetch()
        XCTAssertNil(root.linking.link, "the Mac's Remove ends the link")
        XCTAssertEqual(root.linking.notice, .removed())
    }

    /// A demo root over one demo session, stopped on teardown.
    private func makeDemoRoot() throws -> AppRoot {
        let defaults = try makeDefaults()
        let session = try HubSession(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            transportKind: .inMemoryDemo,
            defaults: defaults,
            recordingsDirectory: try makeRecordingsDirectory()
        )
        addTeardownBlock { @MainActor in session.stop() }
        return AppRoot.demo(AppEnvironment.single(session, defaults: defaults), defaults: defaults)
    }

    func testALiveRootWithoutALinkOnboardsAndTheDemoNever() throws {
        XCTAssertTrue(try makeRoot(linked: nil).showsOnboarding)

        let demo = try makeDemoRoot()
        XCTAssertFalse(demo.showsOnboarding)
        XCTAssertEqual(demo.env.linkedDevice, DemoSeed.device)
    }

    func testTheDemoIgnoresALinkURL() async throws {
        let demo = try makeDemoRoot()
        let iat = Int64(Date().timeIntervalSince1970)
        let code = LinkPayload(
            hubID: "hub-acme", macName: "Acme Mac", ownerUser: "_owner-acme", nonce: LinkPayload.makeNonce(), iat: iat, exp: iat + 600
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

    private func deviceWrites(in transport: InMemoryCloudTransport) async throws -> [DevicePayload] {
        try await transport.changes(in: .relay, since: nil).changed
            .filter { $0.kind == RelayRecordKind.device.rawValue }
            .map { try RelayCoder.makeDecoder().decode(DevicePayload.self, from: $0.payload) }
    }

    /// The transport's `unlinked` event reaches the link flow through the
    /// root (`AppRoot.handle`): the link ends, the replica is wiped.
    func testTheTransportsUnlinkedSignalEndsTheLink() async throws {
        let root = try makeRoot(linked: device, link: linkRecord())
        let first = root.env.activeSession
        XCTAssertFalse(root.showsOnboarding)

        first.onLinkSignal?(.unlinked)

        try await poll { root.linking.notice == .removed() }
        XCTAssertNil(root.linking.link)
        XCTAssertFalse(root.env.activeSession === first, "wiped onto a new environment")
        XCTAssertTrue(root.showsOnboarding)
    }

    func testAnAccountChangeSignalForAnotherAccountEndsTheLink() async throws {
        let root = try makeRoot(linked: device, link: linkRecord())
        let first = root.env.activeSession
        container.userRecordNameValue = "_colleague-b"

        first.onLinkSignal?(.accountChanged)

        try await poll { root.linking.link == nil }
        try await poll { !(root.env.activeSession === first) }
        XCTAssertNil(root.linking.notice)
        XCTAssertTrue(root.showsOnboarding)
    }

    /// Every successful fetch checks the heartbeat (`AppRoot.checkHeartbeat`):
    /// another hub's stops the writes.
    func testAFetchedHeartbeatOfAnotherHubShowsMovedAndStopsWrites() async throws {
        let root = try makeRoot(linked: device, link: linkRecord())
        let now = Date()
        let moved = heartbeat(updatedAt: now, hubID: "hub-studio", macName: "Acme Studio")
        try await transports[0].save([try CloudRecordFactory.record(for: moved, modifiedAt: now)])

        let fetched = await root.env.refresh(.pull)

        XCTAssertTrue(fetched)
        try await poll { root.linking.notice == .moved(macName: "Acme Studio") }
        try await poll { !root.env.activeSession.writesAllowed }
        XCTAssertEqual(root.env.linkedDevice, device, "the link stands")
    }

    /// A `watchtower://link` URL on a live root runs the whole flow over the
    /// real host: the restart onto the code's hub, the device record, the
    /// Mac's grant, the link.
    func testALinkURLOnALiveRootLinksThroughTheRealHost() async throws {
        let linkClock = GateLinkClock()
        addTeardownBlock { linkClock.release() }
        let root = try makeRoot(linked: nil, linkClock: linkClock)
        let iat = Int64(linkClock.start.timeIntervalSince1970)
        let code = LinkPayload(
            hubID: "hub-acme", macName: "Acme Mac", ownerUser: "_owner-acme", nonce: LinkPayload.makeNonce(), iat: iat, exp: iat + 600
        )

        let flow = Task { await root.open(code.url()) }
        try await poll { linkClock.waiting == 1 }

        XCTAssertEqual(root.linking.phase, .waiting(macName: "Acme Mac"))
        XCTAssertEqual(built.last?.hubID, "hub-acme", "restarted onto the code's hub")
        XCTAssertEqual(built.last?.scope, .private, "same Apple ID: the private database")
        let macSide = try XCTUnwrap(transports.last)
        let writes = try await deviceWrites(in: macSide)
        XCTAssertEqual(writes.map(\.linkNonce), [code.nonce])
        let grant = DeviceGrant(
            deviceID: device.deviceID, hubID: "hub-acme", name: device.name, scope: .private,
            linked: true, typingAllowed: false, startSessionsAllowed: true
        )
        try await macSide.save([try CloudRecordFactory.record(for: grant, modifiedAt: Date())])
        linkClock.release()
        await flow.value

        XCTAssertEqual(root.linking.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(root.env.linkedDevice?.deviceID, device.deviceID)
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
        XCTAssertEqual(Array(built.map(\.hubID).suffix(2)), ["hub-acme", HubSession.unlinkedHubID])
        let linkSide = transports[transports.count - 2]
        let writes = try await deviceWrites(in: linkSide)
        XCTAssertEqual(writes.last?.unlinked, true, "the link's hub hears the unlink")
        XCTAssertEqual(root.linking.phase, .idle)
        XCTAssertTrue(root.showsOnboarding)
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
