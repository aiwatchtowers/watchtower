import Foundation
import GRDB
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// One phone, several Macs (multi-hub spec §5.3): `AppEnvironment` holds a
/// `HubSession` per hub. The session on screen polls every minute and the
/// others every five (every minute while they have something on its way),
/// the scene phase reaches every session, a push reaches the sessions of
/// its database only, the forwarded per-hub API follows the active hub, the
/// app badge sums the open asks of every hub, and each session sweeps only
/// its own recordings folder.
@MainActor
final class MultiHubEnvironmentTests: XCTestCase {
    /// Every safety-poll wait each session asked for, by hub.
    private var sleeps: [String: [Duration]] = [:]
    private let device = LinkedDevice(
        deviceID: "device-acme-1",
        name: "Acme iPhone",
        model: "iPhone",
        appVersion: "1.0",
        scope: .private,
        userRecordName: "_owner-acme"
    )

    /// A throwaway base folder for the hubs' files.
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("multi-hub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }

    private func paths(_ base: URL) -> HubPaths {
        HubPaths(
            groupDirectory: base.appendingPathComponent("g"),
            localDirectory: base.appendingPathComponent("l"),
            recordingsBase: base.appendingPathComponent("r")
        )
    }

    /// A cloudKit-kind session on `hubID`'s files over an in-memory
    /// transport, whose safety poll records each wait and then waits for
    /// good (each wait is the one the poll asked for).
    private func makeSession(
        _ hubID: String,
        base: URL,
        transport: InMemoryCloudTransport = InMemoryCloudTransport(),
        scope: CloudDatabaseScope? = nil,
        clock: MutableClock = MutableClock(),
        remote: RemoteFetchRecorder? = nil
    ) throws -> HubSession {
        let paths = paths(base)
        try paths.prepare(hubID)
        let engine = FakeAudioEngine()
        let recorderClock = FakeClock()
        let remoteFetch: (@Sendable (RemoteFetchDepth) async throws -> Void)? = remote.map { remote in
            { try await remote.fetch($0) }
        }
        let sleep: @Sendable (Duration) async throws -> Void = { [weak self] duration in
            await MainActor.run { self?.sleeps[hubID, default: []].append(duration) }
            try await Task.sleep(for: .seconds(3600))
        }
        let session = try HubSession(
            transport: transport,
            replicaPath: paths.replicaPath(hubID),
            transportKind: .cloudKit,
            hubID: hubID,
            linkedDevice: device,
            defaults: try makeDefaults(),
            recordingsDirectory: paths.recordingsDirectory(hubID),
            hold: RecordingHold(directory: paths.holdDirectory),
            databaseScope: scope,
            makeRecorder: { uploader in
                PhoneRecorderController(
                    uploader: uploader, engine: engine, notificationCenter: NotificationCenter(),
                    now: { recorderClock.now }, tickInterval: nil
                )
            },
            now: { clock.now },
            remoteFetch: remoteFetch,
            sleep: sleep
        )
        addTeardownBlock { @MainActor in session.stop() }
        return session
    }

    /// An environment over `sessions`, the first one active.
    private func makeEnvironment(
        _ sessions: [HubSession],
        setBadge: @escaping @MainActor (Int) -> Void = { _ in }
    ) throws -> AppEnvironment {
        let env = AppEnvironment(transportKind: .cloudKit, defaults: try makeDefaults(), setBadge: setBadge)
        for session in sessions {
            env.add(session)
        }
        if let first = sessions.first {
            env.activate(first.hubID)
        }
        return env
    }

    private func bootAll(_ env: AppEnvironment) async throws {
        await env.waitForBoot()
        try await poll({ env.sessions.values.allSatisfy(\.isLooping) }, "a session did not start its safety poll")
    }

    private func workbench(_ name: String) throws -> CloudRecord {
        try DemoSeed.record(kind: .workbench, id: 1, json: DemoSeed.JSON.workbench(1, ["name": name]), modifiedAt: Date())
    }

    private func openAsk(_ id: Int64) throws -> CloudRecord {
        try DemoSeed.record(kind: .ownerAsk, id: id, json: DemoSeed.JSON.ask(id, workbench: 1), modifiedAt: Date())
    }

    // MARK: - Cadence

    func testTheActiveSessionPollsEveryMinuteAndTheOthersEveryFiveMinutes() async throws {
        let base = try makeBase()
        let hubA = try makeSession("hub-a", base: base)
        let hubB = try makeSession("hub-b", base: base)
        let env = try makeEnvironment([hubA, hubB])
        try await bootAll(env)
        try await poll({ self.sleeps["hub-a"]?.last != nil && self.sleeps["hub-b"]?.last != nil }, "a poll never waited")
        XCTAssertEqual(sleeps["hub-a"], [.seconds(60)])
        XCTAssertEqual(sleeps["hub-b"], [.seconds(300)])
        XCTAssertEqual(hubA.role, .active)
        XCTAssertEqual(hubB.role, .inactive)

        env.activate("hub-b")

        try await poll({ self.sleeps["hub-b"]?.count == 2 && self.sleeps["hub-a"]?.count == 2 }, "the roles set no new wait")
        XCTAssertEqual(sleeps["hub-b"]?.last, .seconds(60))
        XCTAssertEqual(sleeps["hub-a"]?.last, .seconds(300))
        XCTAssertEqual(env.activeHubID, "hub-b")
    }

    func testAnInactiveSessionWithUnsentActionsPollsEveryMinute() async throws {
        let base = try makeBase()
        let hubA = try makeSession("hub-a", base: base)
        let hubB = try makeSession("hub-b", base: base)
        let env = try makeEnvironment([hubB, hubA])
        try await bootAll(env)
        let pending = await hubB.hasPendingWork
        XCTAssertFalse(pending)

        let target = try XCTUnwrap(try demoSnapshot(now: Date()).targets.first { $0.id == 415 })
        try await hubB.boardWriter.setStatus(.done, on: target)
        let queued = await hubB.hasPendingWork
        XCTAssertTrue(queued, "the status change waits for the Mac")
        env.activate("hub-a")

        try await poll({ self.sleeps["hub-b"]?.count == 2 }, "hub-b's poll did not restart")
        XCTAssertEqual(sleeps["hub-b"]?.last, .seconds(60), "unsent work keeps the minute")
        XCTAssertEqual(hubB.role, .inactive)
    }

    // MARK: - Scene phase

    func testBackgroundPausesEverySessionAndTheReturnFetchesOnlyWhatIsDue() async throws {
        let base = try makeBase()
        let clock = MutableClock()
        let hubA = try makeSession("hub-a", base: base, clock: clock)
        let hubB = try makeSession("hub-b", base: base, clock: clock)
        let env = try makeEnvironment([hubA, hubB])
        try await bootAll(env)

        env.setActive(false)
        XCTAssertFalse(hubA.isLooping)
        XCTAssertFalse(hubB.isLooping)

        clock.advance(10)
        var cyclesA = hubA.fetchCycles
        var cyclesB = hubB.fetchCycles
        env.setActive(true)
        XCTAssertTrue(hubA.isLooping)
        XCTAssertTrue(hubB.isLooping)
        XCTAssertEqual(hubA.fetchCycles, cyclesA + 1, "the hub on screen fetches on the return")
        XCTAssertEqual(hubB.fetchCycles, cyclesB, "an inactive hub fetched under five minutes ago waits")

        try await poll({ hubA.lastSyncAt == clock.now }, "the return fetch did not land")
        clock.advance(301)
        cyclesA = hubA.fetchCycles
        cyclesB = hubB.fetchCycles
        env.setActive(false)
        env.setActive(true)
        XCTAssertEqual(hubA.fetchCycles, cyclesA + 1)
        XCTAssertEqual(hubB.fetchCycles, cyclesB + 1, "five minutes on, the inactive hub fetches too")
    }

    // MARK: - Pushes

    func testAPushReachesTheSessionsOfItsScopeOnly() async throws {
        let base = try makeBase()
        let remoteA = RemoteFetchRecorder()
        let remoteB = RemoteFetchRecorder()
        let transportB = InMemoryCloudTransport()
        let hubA = try makeSession("hub-a", base: base, scope: .private, remote: remoteA)
        let hubB = try makeSession(
            "hub-b", base: base, transport: transportB, scope: .shared(ownerName: "_owner-acme"), remote: remoteB
        )
        let env = try makeEnvironment([hubA, hubB])
        try await bootAll(env)

        let shared = await env.handlePush(inForeground: true, scope: .shared)
        XCTAssertEqual(shared, .noData)
        XCTAssertEqual(remoteA.pushCount, 0, "a shared-database push leaves the private hub alone")
        XCTAssertEqual(remoteB.pushCount, 1)

        try await transportB.save([try workbench("Home")])
        let any = await env.handlePush(inForeground: true, scope: nil)
        XCTAssertEqual(any, .newData, "one hub brought something")
        XCTAssertEqual(remoteA.pushCount, 1, "an unknown scope reaches every hub")
        XCTAssertEqual(remoteB.pushCount, 2)

        remoteA.failing = true
        remoteB.failing = true
        let failed = await env.handlePush(inForeground: true, scope: nil)
        XCTAssertEqual(failed, .failed, "every hub failed")
        remoteB.failing = false
        let mixed = await env.handlePush(inForeground: true, scope: nil)
        XCTAssertEqual(mixed, .noData, "one failure among no news is no news")

        let empty = AppEnvironment(transportKind: .cloudKit, defaults: try makeDefaults()) { _ in }
        let none = await empty.handlePush(inForeground: false, scope: .private)
        XCTAssertEqual(none, .noData)
    }

    func testPushCompletionServesEverySessionOnTheMultiHubEnvironment() async throws {
        let base = try makeBase()
        let transportA = InMemoryCloudTransport()
        let remoteA = RemoteFetchRecorder()
        let remoteB = RemoteFetchRecorder()
        let hubA = try makeSession("hub-a", base: base, transport: transportA, remote: remoteA)
        let hubB = try makeSession("hub-b", base: base, remote: remoteB)
        let env = try makeEnvironment([hubA, hubB])
        try await bootAll(env)
        try await transportA.save([try workbench("Acme")])
        let tasks = FakeBackgroundTasks()
        var completions: [FetchOutcome] = []

        PushCompletion.serve(
            env, arrivedAt: Date(), inForeground: false, scope: nil,
            startWork: BackgroundWork.starter(runner: tasks, suspension: DatabaseSuspension { _ in }) { true },
            sleep: { _ in try await Task.sleep(for: .seconds(86_400)) },
            completion: { completions.append($0) }
        )

        XCTAssertEqual(tasks.begun, ["silent-push-fetch"])
        try await poll({ completions.count == 1 }, "the push never completed")
        XCTAssertEqual(completions, [.newData], "the merged outcome, once")
        XCTAssertEqual(remoteA.pushCount, 1)
        XCTAssertEqual(remoteB.pushCount, 1)
        try await poll({ tasks.ended.count == 1 }, "the push's work never ended")
    }

    // MARK: - Forwarding

    func testActivateSwitchesWhatTheForwardedPropertiesRead() async throws {
        let base = try makeBase()
        let transportA = InMemoryCloudTransport()
        let transportB = InMemoryCloudTransport()
        try await transportA.save([try workbench("Acme")])
        try await transportB.save([try workbench("Home")])
        let hubA = try makeSession("hub-a", base: base, transport: transportA)
        let hubB = try makeSession("hub-b", base: base, transport: transportB)
        let env = try makeEnvironment([hubA, hubB])
        try await bootAll(env)

        let fetched = await env.refreshAll(.pull)
        XCTAssertTrue(fetched)
        try await poll({ env.workbenchReplica.snapshot.workbenches.map(\.name) == ["Acme"] }, "hub-a's board is not shown")
        XCTAssertTrue(env.store === hubA.store)

        env.activate("hub-b")

        try await poll({ env.workbenchReplica.snapshot.workbenches.map(\.name) == ["Home"] }, "hub-b's board is not shown")
        XCTAssertTrue(env.askDrafts === hubB.askDrafts)
        XCTAssertTrue(env.store === hubB.store)
        XCTAssertTrue(env.recorder === hubB.recorder, "no capture runs: the active hub's recorder")
        XCTAssertTrue(env.deviceSettings === hubB.deviceSettings)
    }

    func testRefreshAllRefreshesEverySession() async throws {
        let base = try makeBase()
        let clock = MutableClock()
        let remoteB = RemoteFetchRecorder()
        let hubA = try makeSession("hub-a", base: base, clock: clock)
        let hubB = try makeSession("hub-b", base: base, clock: clock, remote: remoteB)
        let env = try makeEnvironment([hubA, hubB])
        try await bootAll(env)
        clock.advance(60)

        let fetched = await env.refreshAll(.pull)

        XCTAssertTrue(fetched)
        XCTAssertEqual(hubA.lastSyncAt, clock.now)
        XCTAssertEqual(hubB.lastSyncAt, clock.now)

        remoteB.failing = true
        clock.advance(60)
        let partly = await env.refreshAll(.pull)
        XCTAssertTrue(partly, "one hub fetched")
        XCTAssertEqual(hubA.lastSyncAt, clock.now)
        XCTAssertNotEqual(hubB.lastSyncAt, clock.now)
        XCTAssertNotNil(hubB.lastFetchError, "the hub's row shows why")
        XCTAssertNil(hubA.lastFetchError)

        remoteB.failing = false
        _ = await env.refreshAll(.pull)
        XCTAssertNil(hubB.lastFetchError, "a successful fetch clears it")
    }

    /// Every successful fetch leaves the Mac's heartbeat on the session.
    func testAFetchReadsTheHeartbeat() async throws {
        let base = try makeBase()
        let transport = InMemoryCloudTransport()
        let hubA = try makeSession("hub-a", base: base, transport: transport)
        let env = try makeEnvironment([hubA])
        try await bootAll(env)
        XCTAssertNil(hubA.heartbeat, "no heartbeat published yet")

        let now = Date()
        let heartbeat = HeartbeatPayload(
            updatedAt: now, appVersion: "1.0", hubID: "hub-a", macName: "Acme Mac", flavor: .default,
            lastPublishAt: now, lastRelayAt: now, relayBacklog: 0, accounts: [],
            enabledAt: now, ownerUser: "_owner-acme", sharing: .none
        )
        try await transport.save([try CloudRecordFactory.record(for: heartbeat, modifiedAt: now)])
        var seenInOnFetched: String?
        hubA.onFetched = { [weak hubA] in seenInOnFetched = hubA?.heartbeat?.macName }
        _ = await env.refreshAll(.pull)

        XCTAssertEqual(hubA.heartbeat?.hubID, "hub-a")
        XCTAssertEqual(seenInOnFetched, "Acme Mac", "read before onFetched")
    }

    /// A frozen session stops for good and sends nothing, but its replica
    /// stays readable.
    func testAFrozenSessionKeepsItsReplicaAndFetchesNothing() async throws {
        let base = try makeBase()
        let transport = InMemoryCloudTransport()
        try await transport.save([try workbench("Acme")])
        let remote = RemoteFetchRecorder()
        let hubA = try makeSession("hub-a", base: base, transport: transport, remote: remote)
        let env = try makeEnvironment([hubA])
        try await bootAll(env)
        let fetches = remote.depths.count

        await hubA.freeze()

        XCTAssertFalse(hubA.isLooping)
        XCTAssertFalse(hubA.writesAllowed)
        XCTAssertEqual(hubA.linkedDevice, device, "the link stands")
        let pushed = await env.handlePush(inForeground: true, scope: nil)
        XCTAssertEqual(pushed, .noData)
        XCTAssertEqual(remote.depths.count, fetches, "a frozen session fetches nothing")
        env.setActive(false)
        env.setActive(true)
        XCTAssertFalse(hubA.isLooping, "the return to the foreground does not wake it")
        let rows = try await hubA.store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0
        }
        XCTAssertEqual(rows, 1, "the replica stays readable")
        do {
            _ = try await hubA.outbox.enqueue(kind: .targetDone, entityRecordName: "workbench_target-415")
            XCTFail("a frozen session sends nothing")
        } catch {
            XCTAssertEqual(error as? ActionOutboxError, .notLinked)
        }
    }

    /// Ruling 6: removing the active session leaves no active hub behind
    /// (the root activates the next one first; with none, onboarding).
    func testRemovingTheActiveSessionLeavesNoDanglingActiveHub() throws {
        let base = try makeBase()
        let hubA = try makeSession("hub-a", base: base)
        let hubB = try makeSession("hub-b", base: base)
        let env = try makeEnvironment([hubA, hubB])

        env.remove("hub-b")
        XCTAssertEqual(env.activeHubID, "hub-a", "an inactive removal leaves the active hub")
        env.remove("hub-a")

        XCTAssertNil(env.activeHubID)
        XCTAssertNil(env.active)
    }

    // MARK: - The badge

    func testTheBadgeIsTheSumOfOpenAsksAcrossSessions() async throws {
        let base = try makeBase()
        let transportA = InMemoryCloudTransport()
        let transportB = InMemoryCloudTransport()
        try await transportA.save([try openAsk(11)])
        try await transportB.save([try openAsk(21), try openAsk(22)])
        var badges: [Int] = []
        let hubA = try makeSession("hub-a", base: base, transport: transportA)
        let hubB = try makeSession("hub-b", base: base, transport: transportB)
        let env = try makeEnvironment([hubA, hubB]) { badges.append($0) }
        try await bootAll(env)

        try await poll({ badges.last == 3 }, "the badge is not the sum: \(badges)")
        XCTAssertEqual(env.openAskTotal, 3)

        try await transportB.delete(recordNames: [SliceKind.ownerAsk.recordName(id: "22")], in: .data)
        _ = await env.refreshAll(.pull)

        try await poll({ badges.last == 2 }, "the answered ask still counts: \(badges)")
        XCTAssertFalse(badges.contains(0), "ruling 7: never written as 0 before any hub has hydrated: \(badges)")
        XCTAssertEqual(zip(badges, badges.dropFirst()).filter { $0 == $1 }.count, 0, "never set to the same total twice: \(badges)")
    }

    /// A hub the Mac removed (frozen, writes off) cannot answer its asks:
    /// they leave the badge, and the chip's other-Macs count, at the freeze.
    func testAFrozenHubsAsksLeaveTheBadgeAndTheChip() async throws {
        let base = try makeBase()
        let transportA = InMemoryCloudTransport()
        let transportB = InMemoryCloudTransport()
        try await transportA.save([try openAsk(11)])
        try await transportB.save([try openAsk(21), try openAsk(22)])
        var badges: [Int] = []
        let hubA = try makeSession("hub-a", base: base, transport: transportA)
        let hubB = try makeSession("hub-b", base: base, transport: transportB)
        let env = try makeEnvironment([hubA, hubB]) { badges.append($0) }
        try await bootAll(env)
        try await poll({ badges.last == 3 }, "the badge is not the sum: \(badges)")

        await hubB.freeze(as: device)

        try await poll({ badges.last == 1 }, "the frozen hub's asks still count: \(badges)")
        XCTAssertEqual(env.openAskTotal, 1)
        XCTAssertEqual(hubB.workbenchReplica.openAskCount, 2, "its replica still holds them, readable")
        func row(_ hubID: String, _ order: Int, _ state: HubRow.State) -> HubRow {
            HubRow(
                link: LinkRecord(
                    hubID: hubID, macName: "Mac \(hubID)", scope: .private, ownerName: "_owner-acme", userRecordName: "_owner-acme",
                    nonce: "nonce-\(hubID)", dataShareURL: nil, relayShareURL: nil, deviceID: device.deviceID, linkedAt: nil
                ),
                flavor: nil, sortOrder: order, state: state, grantMissingSince: nil, lastHeartbeatAt: nil, linkedOn: Date()
            )
        }
        let linked = row("hub-a", 0, .linked)
        let removed = row("hub-b", 1, .unlinkedByMac)
        let items = HubListModel.items(rows: [linked, removed], sessions: env.sessions, activeHubID: "hub-a", now: Date())
        XCTAssertEqual(items.map(\.openAsks), [1, 2], "each row still shows its own")
        XCTAssertEqual(HubListModel.otherHubsOpenAsks(items), 0, "the chip leaves the removed Mac out")
    }

    // MARK: - Recordings

    /// Review Focus 2: a session's launch sweep reaches its own folder
    /// only; another hub's audio, with its row in that hub's replica, stays.
    func testEachSessionSweepsOnlyItsOwnRecordingsFolder() async throws {
        let base = try makeBase()
        let paths = paths(base)
        try paths.prepare("hub-a")
        try paths.prepare("hub-b")
        let otherFile = paths.recordingsDirectory("hub-b").appendingPathComponent("orphan.m4a")
        try Data(repeating: 0x5A, count: 256).write(to: otherFile)
        let otherUploader = RecordingUploader(
            transport: InMemoryCloudTransport(),
            store: try ReplicaStore(path: paths.replicaPath("hub-b")),
            directory: paths.recordingsDirectory("hub-b")
        )
        let now = Date()
        let registered = try await otherUploader.register(
            fileURL: otherFile, startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-60), titleHint: "Acme sync"
        )
        XCTAssertNotNil(registered)
        let stray = paths.recordingsDirectory("hub-a").appendingPathComponent("stray.m4a")
        try Data(repeating: 0x5A, count: 256).write(to: stray)

        let hubA = try makeSession("hub-a", base: base)
        _ = await hubA.adoption?.value
        await hubA.waitForBoot()

        XCTAssertTrue(hubA.isBootstrapped, "the launch recovery ran")
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherFile.path), "hub-b's recording is not hub-a's to sweep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path), "a file with no row in hub-a's own folder is swept")
    }
}
