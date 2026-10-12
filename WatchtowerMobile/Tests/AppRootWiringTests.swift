import Foundation
import GRDB
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

    /// Every environment the root built, and the database and hub each runs.
    private var built: [(env: AppEnvironment, scope: CloudDatabaseScope, hubID: String)] = []
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
            let env = try AppEnvironment(
                transport: transport,
                replicaPath: path,
                transportKind: .cloudKit,
                linkedDevice: device,
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
        let identity = DeviceIdentity(deviceID: device.deviceID, name: device.name, model: device.model, appVersion: device.appVersion)
        return AppRoot(
            env: try make(.private, AppEnvironment.unlinkedHubID, linked),
            scope: .private,
            hubID: AppEnvironment.unlinkedHubID,
            linking: LinkingViewModel(container: container, store: store, identity: identity, clock: linkClock),
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
        try await transports[0].save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        try await poll { (try? self.sliceCountSync(first)) == 1 }
        for id in 1...3 {
            try await first.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-\(id)")
        }
        XCTAssertEqual(try first.store.pendingActions().count, 3)

        let notSent = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)

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

        let notSent = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)

        XCTAssertEqual(notSent, LocalWipe(notSent: 3))
        let after = try await transportCounts(raw)
        XCTAssertEqual(after.pending, 0, "the unlinked phone's queue is not sent")
        XCTAssertEqual(after.events, 0, "the next replica re-reads the zone from scratch")
        XCTAssertEqual(after.engineState, 0, "the engine fetches everything again")
        XCTAssertEqual(built.last?.scope, .private)
        XCTAssertNil(root.failure)
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

        async let first = root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)
        async let second = root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)
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
        try await transports[2].save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        let fetched = await last.refresh()
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
        try await root.env.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-1")
    }

    // MARK: - Recordings across a wipe (board #63)

    /// An unlink, a removal or an account change during a meeting capture:
    /// the capture is stopped and saved, the wipe keeps it, and it goes to
    /// the Mac once a link is back.
    func testAWipeDuringACaptureStopsItKeepsItAndSendsItAfterTheNextLink() async throws {
        let root = try makeRoot(linked: device)
        let first = root.env
        try await poll { first.isBootstrapped }
        let event = MeetingEvent(id: "event-1", title: "Design sync", start: clock.now, end: clock.now.addingTimeInterval(1_800))
        await first.recorder.recordMeeting(event)
        XCTAssertTrue(first.recorder.isCapturing)
        clock.advance(30)
        first.recorder.markMoment()
        await root.setLink(nil, writesAllowed: true)

        let wipe = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)

        XCTAssertEqual(wipe, LocalWipe(notSent: 0, stoppedRecording: true), "kept, so not reported Not sent")
        XCTAssertEqual(engine.finishCount, 1, "the file was finalised, not cut off")
        XCTAssertFalse(root.env === first)
        try await poll { root.env.isBootstrapped }
        let rows = try root.env.store.phoneRecordings()
        XCTAssertEqual(rows.count, 1, "the new replica holds the recording")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.state, .waiting)
        XCTAssertEqual(row.durationSec, 30)
        XCTAssertEqual(row.eventID, "event-1")
        XCTAssertEqual(try root.env.store.phoneRecordingMarks(id: row.id), [30])
        let file = row.fileURL(in: recordingsDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the launch sweep left the audio alone")

        await root.setLink(device, writesAllowed: true)

        let uploads = try await relayUploads(in: try XCTUnwrap(transports.last))
        XCTAssertEqual(uploads.map(\.id), [row.id], "sent after the next link")
    }

    /// An unlink restarts twice in a row (the queue wipe, then the
    /// unlinked hub): a recording still waiting survives both, even when
    /// the second starts before the first environment adopted it.
    func testAWaitingRecordingSurvivesBackToBackWipes() async throws {
        let root = try makeRoot(linked: device)
        let first = root.env
        try await poll { first.isBootstrapped }
        await first.recorder.recordVoiceNote()
        clock.advance(12)
        await first.recorder.stop()
        let id = try XCTUnwrap(first.recorder.savedRecording?.id)
        await root.setLink(nil, writesAllowed: true)

        async let one = root.wipeLocalData(restartingOn: .private, hubID: "hub-acme")
        async let two = root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)
        let wipes = await [one, two]

        XCTAssertEqual(wipes, [LocalWipe(), LocalWipe()], "nothing lost, no capture running")
        try await poll { root.env.isBootstrapped }
        let rows = try root.env.store.phoneRecordings()
        XCTAssertEqual(rows.map(\.id), [id])
        XCTAssertEqual(rows.first?.state, .waiting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(rows.first).fileURL(in: recordingsDirectory).path))
    }

    /// A recording whose audio is already gone cannot be kept: it is
    /// reported Not sent, as before.
    func testARecordingWithoutItsFileIsReportedNotSent() async throws {
        let root = try makeRoot(linked: device)
        let first = root.env
        try await poll { first.isBootstrapped }
        await first.recorder.recordVoiceNote()
        clock.advance(12)
        await first.recorder.stop()
        let row = try XCTUnwrap(try first.store.phoneRecordings().first)
        try FileManager.default.removeItem(at: row.fileURL(in: recordingsDirectory))

        let wipe = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)

        XCTAssertEqual(wipe, LocalWipe(notSent: 1))
        try await poll { root.env.isBootstrapped }
        XCTAssertTrue(try root.env.store.phoneRecordings().isEmpty)
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

        _ = await root.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)

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
        _ = try await root.prepare(scope: .private, hubID: AppEnvironment.unlinkedHubID)

        XCTAssertFalse(root.env === first)
        _ = try await root.prepare(scope: .private, hubID: AppEnvironment.unlinkedHubID)
        XCTAssertEqual(built.count, 2, "a fresh environment is not retired")
    }

    func testPreparingAnotherScopeRestartsOnAnEmptyReplica() async throws {
        let root = try makeRoot(linked: nil)
        let first = root.env
        let now = Date()
        try await transports[0].save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        try await poll { (try? self.sliceCountSync(first)) == 1 }

        let samePrivate = try await root.prepare(scope: .private, hubID: AppEnvironment.unlinkedHubID)
        XCTAssertTrue(root.env === first, "the running scope needs no restart")
        XCTAssertTrue((samePrivate as? InMemoryCloudTransport) === transports[0])

        let shared = try await root.prepare(scope: .shared(ownerName: "_owner-acme"), hubID: AppEnvironment.unlinkedHubID)

        XCTAssertFalse(root.env === first)
        XCTAssertEqual(built.last?.scope, .shared(ownerName: "_owner-acme"))
        XCTAssertTrue((shared as? InMemoryCloudTransport) === transports.last)
        let rows = try await sliceCount(root.env)
        XCTAssertEqual(rows, 0, "another database's data is not kept")
    }

    func testPreparingAnotherHubOnTheSameScopeRestartsOnAnEmptyReplica() async throws {
        let root = try makeRoot(linked: nil)
        let first = root.env
        let now = Date()
        try await transports[0].save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        try await poll { (try? self.sliceCountSync(first)) == 1 }

        _ = try await root.prepare(scope: .private, hubID: "hub-acme")

        XCTAssertFalse(root.env === first, "another hub is another pair of zones")
        XCTAssertEqual(built.last?.hubID, "hub-acme")
        let rows = try await sliceCount(root.env)
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
        let first = root.env
        XCTAssertFalse(root.showsOnboarding)

        first.onLinkSignal?(.unlinked)

        try await poll { root.linking.notice == .removed }
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
        let now = Date()
        let moved = heartbeat(updatedAt: now, hubID: "hub-studio", macName: "Acme Studio")
        try await transports[0].save([try CloudRecordFactory.record(for: moved, modifiedAt: now)])

        let fetched = await root.env.refresh()

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
        XCTAssertEqual(Array(built.map(\.hubID).suffix(2)), ["hub-acme", AppEnvironment.unlinkedHubID])
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
