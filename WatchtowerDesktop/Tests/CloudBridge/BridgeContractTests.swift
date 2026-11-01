import CloudBridgeCore
import CloudKit
import Darwin
import XCTest

/// The bridge contract (Go hub spec §13): the service answers every frame as the Go side's bridgefake does,
/// over an in-memory CloudKit; the socket checks its peer; the bridge's code links nothing that holds a key
/// or opens an envelope.
final class BridgeContractTests: XCTestCase {
    private let hub = "8C1D2E3F-0000-4000-8000-00000000ACME"
    private var data: String { "DataZone-\(hub)" }
    private var relay: String { "RelayZone-\(hub)" }
    private let env = Data("WTE1-sealed-acme".utf8)

    private var hubDir: URL!
    private var cloud: FakeBridgeCloud!
    private var shares: FakeShares!
    private var service: BridgeService!
    private var nextID: UInt64 = 0

    override func setUpWithError() throws {
        hubDir = try makeHubDir()
        cloud = FakeBridgeCloud()
        shares = FakeShares()
        service = try makeService()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: hubDir)
    }

    private func makeService() throws -> BridgeService {
        let tags = try BridgeTagMap(directory: hubDir.appendingPathComponent("cloudkit"))
        let backends = BridgeService.Backends(cloud: cloud, shares: shares)
        return BridgeService(tags: tags, hubDir: hubDir) { _ in backends }
    }

    @discardableResult
    private func ask(_ op: BridgeOp, helloed: Bool = true) async -> BridgeResult? {
        nextID += 1
        let response = await service.handle(BridgeRequest(id: nextID, op: op), helloed: helloed)
        XCTAssertEqual(response.id, nextID)
        return response.result
    }

    private func hello() async throws -> String {
        guard case let .hello(version, generation) = await ask(.hello(version: 1, hubID: hub), helloed: false) else {
            throw XCTSkip("no hello")
        }
        XCTAssertEqual(version, 1)
        return generation
    }

    private func assertResult(
        _ got: BridgeResult?, _ want: BridgeResult?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(got, want, message, file: file, line: line)
    }

    private func outcomes(_ result: BridgeResult?, file: StaticString = #filePath, line: UInt = #line) -> [BridgeOutcome] {
        guard case .outcomes(let list) = result else {
            XCTFail("not outcomes: \(String(describing: result))", file: file, line: line)
            return []
        }
        return list
    }

    private func batch(_ result: BridgeResult?, file: StaticString = #filePath, line: UInt = #line) -> BridgeBatch {
        guard case .batch(let b) = result else {
            XCTFail("not a batch: \(String(describing: result))", file: file, line: line)
            return BridgeBatch()
        }
        return b
    }

    // MARK: - Frames over CloudKit

    func testSaveDeleteChangesOverAFakeTransport() async throws {
        assertResult(await ask(.accountStatus, helloed: false), .failure(class: "bad_request"), "Hello comes first")
        let generation = try await hello()

        let saved = outcomes(await ask(.save([
            BridgeSaveItem(zone: data, name: "k1a2b3", envelope: env),
            BridgeSaveItem(zone: data, name: "sig-k1a2b3"),
            BridgeSaveItem(zone: relay, name: "c-1", envelope: env, expect: BridgeExpect(mode: .absent))
        ])))
        XCTAssertEqual(saved.count, 3)
        XCTAssertTrue(saved.allSatisfy { $0.saved && $0.tagSeq != 0 })
        let savedEnvelopes = await cloud.savedEnvelopes
        XCTAssertEqual(savedEnvelopes, [env, Data(), env], "the envelope bytes reach CloudKit unchanged")

        // A phone writes into the relay zone.
        await cloud.write(zone: relay, name: "a-DEVICE-7", envelope: env)
        let first = batch(await ask(.changes(zone: relay, since: 0, generation: "")))
        XCTAssertEqual(first.generation, generation)
        XCTAssertEqual(Set(first.changed.map(\.name)), ["c-1", "a-DEVICE-7"])
        XCTAssertTrue(first.changed.allSatisfy { $0.envelope == env && $0.tagSeq != 0 && $0.serverAtMs != 0 })
        XCTAssertEqual(first.changed.first { $0.name == "c-1" }?.tagSeq, saved[2].tagSeq, "the bridge's own save keeps its tag_seq")
        XCTAssertFalse(first.more)

        let gone = outcomes(await ask(.delete(zone: relay, items: [
            BridgeDeleteItem(name: "c-1"), BridgeDeleteItem(name: "never-there")
        ])))
        XCTAssertEqual(gone.map(\.saved), [true, true])
        let next = batch(await ask(.changes(zone: relay, since: first.newSeq, generation: generation)))
        XCTAssertEqual(next.deleted, ["c-1"])
        XCTAssertTrue(next.changed.isEmpty)
        let quiet = batch(await ask(.changes(zone: relay, since: next.newSeq, generation: generation)))
        XCTAssertEqual(quiet.newSeq, next.newSeq, "nothing changed, same cursor")

        // Another hub's zone, a pairing zone and a runtime name are refused.
        for zone in ["DataZone-other", "pair/abc", "data/xyz"] {
            assertResult(await ask(.changes(zone: zone, since: 0, generation: "")), .failure(class: "unsupported_zone"))
        }
        assertResult(await ask(.save([BridgeSaveItem(zone: "RelayZone-other", name: "x", envelope: env)])), .failure(class: "unsupported_zone"))
        assertResult(await ask(.hello(version: 1, hubID: "another-hub"), helloed: false), .failure(class: "bad_request"), "one hub per bridge")
    }

    func testOldGenerationCursorsAndTagsAreExpiredNeverCompared() async throws {
        let generation = try await hello()
        let tag = outcomes(await ask(.save([BridgeSaveItem(zone: relay, name: "a-1", envelope: env)])))[0].tagSeq
        let b = batch(await ask(.changes(zone: relay, since: 0, generation: "")))
        assertResult(
            await ask(.changes(zone: relay, since: b.newSeq, generation: "0000000000000000")), .failure(class: "token_expired"))
        assertResult(await ask(.changes(zone: relay, since: 123_456, generation: generation)), .failure(class: "token_expired"))
        let stale = outcomes(await ask(.delete(zone: relay, items: [
            BridgeDeleteItem(name: "a-1", expect: BridgeExpect(mode: .seq, tagSeq: tag, generation: "0000000000000000"))
        ])))
        XCTAssertEqual(stale, [BridgeOutcome(refusedClass: "token_expired")])
        let ok = outcomes(await ask(.delete(zone: relay, items: [
            BridgeDeleteItem(name: "a-1", expect: BridgeExpect(mode: .seq, tagSeq: tag, generation: generation))
        ])))
        XCTAssertEqual(ok, [BridgeOutcome(saved: true)])
    }

    func testConditionalSaveConflictReturnsServerCopy() async throws {
        let generation = try await hello()
        let first = outcomes(await ask(.save([BridgeSaveItem(zone: relay, name: "a-DEVICE-7", envelope: env)])))[0]
        // The phone rewrites it: the hub's tag is now old.
        let newer = Data("WTE1-newer".utf8)
        await cloud.write(zone: relay, name: "a-DEVICE-7", envelope: newer)
        let old = BridgeExpect(mode: .seq, tagSeq: first.tagSeq, generation: generation)

        let conflict = outcomes(await ask(.save([BridgeSaveItem(zone: relay, name: "a-DEVICE-7", envelope: env, expect: old)])))[0]
        XCTAssertFalse(conflict.saved)
        let server = try XCTUnwrap(conflict.conflict)
        XCTAssertEqual(server.envelope, newer)
        XCTAssertNotEqual(server.tagSeq, first.tagSeq)
        let deleted = outcomes(await ask(.delete(zone: relay, items: [BridgeDeleteItem(name: "a-DEVICE-7", expect: old)])))[0]
        XCTAssertEqual(deleted.conflict?.envelope, newer, "a conditional delete on an old tag conflicts too")

        // With the server copy's tag the write goes through.
        let current = BridgeExpect(mode: .seq, tagSeq: server.tagSeq, generation: generation)
        let retried = outcomes(await ask(.save([BridgeSaveItem(zone: relay, name: "a-DEVICE-7", envelope: env, expect: current)])))[0]
        XCTAssertTrue(retried.saved)
        XCTAssertNotEqual(retried.tagSeq, server.tagSeq)

        // ExpectSeq on a record that is gone: a conflict without a copy.
        await cloud.write(zone: relay, name: "a-DEVICE-9", envelope: env)
        _ = batch(await ask(.changes(zone: relay, since: 0, generation: "")))
        _ = try await cloud.delete(zone: relay, [CloudDeletion(name: "a-DEVICE-9")])
        let missing = outcomes(await ask(.save([BridgeSaveItem(
            zone: relay, name: "a-DEVICE-9", envelope: env, expect: BridgeExpect(mode: .seq, tagSeq: 1, generation: generation))])))[0]
        XCTAssertEqual(missing, BridgeOutcome())
    }

    func testExpectAbsentRefusesAnExistingRecord() async throws {
        _ = try await hello()
        await cloud.write(zone: relay, name: "a-DEVICE-7", envelope: env)
        let refused = outcomes(await ask(.save([
            BridgeSaveItem(zone: relay, name: "a-DEVICE-7", envelope: Data("other".utf8), expect: BridgeExpect(mode: .absent)),
            BridgeSaveItem(zone: relay, name: "a-DEVICE-8", envelope: env, expect: BridgeExpect(mode: .absent))
        ])))
        XCTAssertFalse(refused[0].saved)
        XCTAssertEqual(refused[0].conflict?.envelope, env, "the conflict carries the existing record")
        XCTAssertTrue(refused[1].saved)
        let stored = try await cloud.fetch(zone: relay, name: "a-DEVICE-7")
        XCTAssertEqual(stored?.envelope, env, "the existing record is untouched")
    }

    func testABigPageIsSplitAcrossBatches() async throws {
        let generation = try await hello()
        let big = Data(count: 900 << 10)
        for i in 0..<5 { await cloud.write(zone: data, name: "s\(i)", envelope: big) }
        var names: [String] = []
        var b = batch(await ask(.changes(zone: data, since: 0, generation: "")))
        names += b.changed.map(\.name)
        XCTAssertTrue(b.more)
        while b.more {
            b = batch(await ask(.changes(zone: data, since: b.newSeq, generation: generation)))
            names += b.changed.map(\.name)
        }
        XCTAssertEqual(names, ["s0", "s1", "s2", "s3", "s4"])
        XCTAssertTrue(BridgeResponse(id: 1, result: .batch(b)).encoded().count < 4 << 20)
    }

    func testAssetsTravelAsPathsAndDownloads() async throws {
        _ = try await hello()
        let asset = hubDir.appendingPathComponent("assets/transcripts")
        try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
        let file = asset.appendingPathComponent("7.asset")
        try Data("sealed-asset".utf8).write(to: file)
        let saved = outcomes(await ask(.save([BridgeSaveItem(zone: data, name: "t9x8", envelope: env, assetPath: file.path)])))
        XCTAssertTrue(saved[0].saved)

        await cloud.write(zone: relay, name: "recupload-u1", envelope: env, asset: Data("sealed-audio".utf8))
        let b = batch(await ask(.changes(zone: relay, since: 0, generation: "")))
        let assetID = try XCTUnwrap(b.changed.first { $0.name == "recupload-u1" }?.assetID)
        XCTAssertFalse(assetID.isEmpty)
        let dst = hubDir.appendingPathComponent("downloads/ab12.part")
        assertResult(await ask(.download(zone: relay, assetID: assetID, dst: dst.path)), .done)
        XCTAssertEqual(try Data(contentsOf: dst), Data("sealed-audio".utf8))
    }

    func testAssetPathOutsideTheHubDirIsRefused() async throws {
        _ = try await hello()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("bt-outside-\(UUID().uuidString)")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        // A link inside assets/ pointing out, a ../ escape, and a relative path.
        let link = hubDir.appendingPathComponent("assets/link.asset")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let escape = hubDir.appendingPathComponent("assets/../outside.asset")
        try Data("x".utf8).write(to: hubDir.appendingPathComponent("outside.asset"))
        for path in [outside.path, link.path, escape.path, "assets/x.asset"] {
            assertResult(
                await ask(.save([BridgeSaveItem(zone: data, name: "t1", envelope: env, assetPath: path)])),
                .failure(class: "forbidden"), path)
        }
        let saved = await cloud.savedEnvelopes
        XCTAssertTrue(saved.isEmpty, "nothing was saved")
        assertResult(
            await ask(.download(zone: relay, assetID: "recupload-u1", dst: outside.path)), .failure(class: "forbidden"))
        assertResult(
            await ask(.download(zone: relay, assetID: "recupload-u1", dst: hubDir.appendingPathComponent("assets/x").path)),
            .failure(class: "forbidden"), "downloads land in downloads/ only")
    }

    func testSharesAnswer() async throws {
        _ = try await hello()
        assertResult(await ask(.accountStatus), .account(status: "temporarily_unavailable"))
        assertResult(
            await ask(.ensureShares),
            .shares(dataURL: "https://www.icloud.com/share/0data", relayURL: "https://www.icloud.com/share/0relay"))
        assertResult(await ask(.setPublicLink(open: true)), .done)
        XCTAssertTrue(shares.publicLink)
        shares.set(relay, [
            ZoneShareParticipant(userRecordName: "_user-a", accepted: true),
            ZoneShareParticipant(userRecordName: "_user-b", accepted: false),
            ZoneShareParticipant(userRecordName: nil, accepted: false)
        ])
        assertResult(await ask(.participants(zone: relay)), .participants([
            BridgeParticipant(userRecordName: "_user-a", accepted: true), BridgeParticipant(userRecordName: "_user-b")
        ]))
        assertResult(await ask(.removeParticipants(zone: relay, userRecordNames: ["_user-a"])), .done)
        assertResult(await ask(.participants(zone: relay)), .participants([BridgeParticipant(userRecordName: "_user-b")]))
        assertResult(await ask(.participants(zone: "RelayZone-other")), .failure(class: "unsupported_zone"))
    }

    func testRecordsCarryTheirCreatorAndOwnerUserAnswers() async throws {
        _ = try await hello()
        await cloud.write(zone: relay, name: "hello-DEVICE-9", envelope: env, creator: "_user-b")
        await cloud.write(zone: relay, name: "device-DEVICE-9", envelope: env, creator: "__defaultOwner__")
        await cloud.write(zone: relay, name: "a-DEVICE-9-1", envelope: env, creator: nil)
        let b = batch(await ask(.changes(zone: relay, since: 0, generation: "")))
        let creators = Dictionary(uniqueKeysWithValues: b.changed.map { ($0.name, $0.creator) })
        XCTAssertEqual(creators, ["hello-DEVICE-9": "_user-b", "device-DEVICE-9": "__defaultOwner__", "a-DEVICE-9-1": ""])
        let conflict = outcomes(await ask(.save([
            BridgeSaveItem(zone: relay, name: "hello-DEVICE-9", envelope: env, expect: BridgeExpect(mode: .absent))
        ])))
        XCTAssertEqual(conflict.first?.conflict?.creator, "_user-b")

        assertResult(await ask(.ownerUser), .ownerUser(userRecordName: ""), "no account yet: empty")
        await cloud.setOwner("_owner-acme")
        assertResult(await ask(.ownerUser), .ownerUser(userRecordName: "_owner-acme"))
    }

    func testAccountChangeIsAnEvent() throws {
        let server = try startServer()
        let client = try SocketClient(path: hubDir.appendingPathComponent("bridge.sock").path)
        defer { client.close() }
        try client.send(BridgeRequest(id: 1, op: .hello(version: 1, hubID: hub)))
        _ = try client.read()
        let center = NotificationCenter()
        let push = PushReceiver { server.broadcast($0) }
        let token = push.observeAccountChanges(on: center)
        defer { center.removeObserver(token) }
        center.post(name: .CKAccountChanged, object: nil)
        XCTAssertEqual(try client.read(), BridgeResponse(id: 0, result: .event(BridgeEvent(accountChanged: true))))
    }

    func testAccountWordsMatchTheProtocol() {
        XCTAssertEqual(ZoneShareAccount.available.wireStatus, "available")
        XCTAssertEqual(ZoneShareAccount.noAccount.wireStatus, "no_account")
        XCTAssertEqual(ZoneShareAccount.restricted.wireStatus, "restricted")
        XCTAssertEqual(ZoneShareAccount.noEntitlement.wireStatus, "no_entitlement")
        XCTAssertEqual(ZoneShareAccount.couldNotDetermine.wireStatus, "temporarily_unavailable")
    }

    // MARK: - Socket

    private func startServer(
        idleExit: TimeInterval = 60,
        onIdle: @escaping @Sendable () -> Void = {}
    ) throws -> BridgeSocketServer {
        let server = BridgeSocketServer(
            socketPath: hubDir.appendingPathComponent("bridge.sock").path, service: service, idleExit: idleExit, onIdle: onIdle)
        try server.start()
        addTeardownBlock { server.stop() }
        return server
    }

    func testSocketIsPrivateAndAnswersFrames() throws {
        _ = try startServer()
        var st = stat()
        XCTAssertEqual(lstat(hubDir.appendingPathComponent("bridge.sock").path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        let client = try SocketClient(path: hubDir.appendingPathComponent("bridge.sock").path)
        defer { client.close() }
        try client.send(BridgeRequest(id: 1, op: .hello(version: 1, hubID: hub)))
        guard case .hello(1, let generation)? = try client.read().result else { return XCTFail("no HelloOk") }
        XCTAssertFalse(generation.isEmpty)
        try client.send(BridgeRequest(id: 2, op: .accountStatus))
        XCTAssertEqual(try client.read(), BridgeResponse(id: 2, result: .account(status: "temporarily_unavailable")))
    }

    func testPeerWithAnotherUIDIsClosed() throws {
        // Another user's process, and one whose credentials cannot be read: closed before any answer.
        for (socket, peer) in [("bridge.sock", geteuid() + 1), ("bridge2.sock", nil)] as [(String, uid_t?)] {
            let path = hubDir.appendingPathComponent(socket).path
            let server = BridgeSocketServer(socketPath: path, service: service) { _ in peer }
            try server.start()
            defer { server.stop() }
            let client = try SocketClient(path: path)
            defer { client.close() }
            try? client.send(BridgeRequest(id: 1, op: .hello(version: 1, hubID: hub)))
            XCTAssertNil(try? client.read(), "\(socket): the bridge closed the connection without an answer")
            XCTAssertEqual(server.connectionCount, 0)
        }
    }

    func testSilentPushEmitsPullNow() throws {
        let server = try startServer()
        let client = try SocketClient(path: hubDir.appendingPathComponent("bridge.sock").path)
        defer { client.close() }
        try client.send(BridgeRequest(id: 1, op: .hello(version: 1, hubID: hub)))
        _ = try client.read()
        let push = PushReceiver { server.broadcast($0) }
        push.didReceiveRemoteNotification(["ck": ["met": ["dbs": 1]], "aps": ["content-available": 1]])
        XCTAssertEqual(try client.read(), BridgeResponse(id: 0, result: .event(BridgeEvent(pullNow: true))))
    }

    func testThePhonesAlertSubscriptionIsNeverTouched() async throws {
        let saved = Locked<[String]>([])
        await PushReceiver.register(hubID: hub) { subscription in saved.update { $0.append(subscription.subscriptionID) } }
        XCTAssertEqual(saved.value, [PushReceiver.databaseSubscriptionID(hubID: hub)], "one save, the bridge's own subscription")
        XCTAssertEqual(PushReceiver.phoneAlertSubscriptionID(hubID: hub), "ask-alert-\(hub)")
        XCTAssertNotEqual(PushReceiver.databaseSubscriptionID(hubID: hub), PushReceiver.phoneAlertSubscriptionID(hubID: hub))
        let subscription = try XCTUnwrap(PushReceiver.subscription(hubID: hub) as? CKDatabaseSubscription)
        XCTAssertEqual(subscription.notificationInfo?.shouldSendContentAvailable, true, "a silent push, as CKSyncEngine's was")
        // Nothing in the bridge builds, saves or deletes another subscription.
        for (file, text) in try Self.bridgeSources() {
            for call in ["AskAlertSubscription.subscription(", "deleteSubscription", "unsubscribeAlerts", "subscribeAlerts", "CKQuerySubscription("] {
                XCTAssertNil(text.range(of: call), "\(file) calls \(call)")
            }
        }
    }

    func testALateAnswerNeverReachesAnotherConnection() async throws {
        _ = try startServer()
        let path = hubDir.appendingPathComponent("bridge.sock").path
        let first = try SocketClient(path: path)
        try first.send(BridgeRequest(id: 1, op: .hello(version: 1, hubID: hub)))
        _ = try first.read()
        await cloud.holdChanges()
        try first.send(BridgeRequest(id: 77, op: .changes(zone: relay, since: 0, generation: "")))
        try await cloud.waitUntilHeld()
        first.close()
        // The next connection likely gets the same descriptor number on the bridge's side.
        let second = try SocketClient(path: path)
        defer { second.close() }
        try second.send(BridgeRequest(id: 1, op: .hello(version: 1, hubID: hub)))
        XCTAssertEqual(try second.read().id, 1)
        await cloud.releaseChanges()
        try await Task.sleep(nanoseconds: 200_000_000)
        try second.send(BridgeRequest(id: 2, op: .accountStatus))
        XCTAssertEqual(try second.read().id, 2, "the closed connection's late answer was dropped")
    }

    func testARefusedFrameIsAnsweredAndClosed() throws {
        _ = try startServer()
        let client = try SocketClient(path: hubDir.appendingPathComponent("bridge.sock").path)
        defer { client.close() }
        try client.sendRaw(Data([0x00, 0x50, 0x00, 0x00])) // 5 MiB announced
        XCTAssertEqual(try client.read(), BridgeResponse(id: 0, result: .failure(class: "bad_request")))
        XCTAssertNil(try? client.read(), "then the connection closes")

        let garbage = try SocketClient(path: hubDir.appendingPathComponent("bridge.sock").path)
        defer { garbage.close() }
        try garbage.sendRaw(Data([0, 0, 0, 1, 0x07])) // a lone key of wire type 7
        XCTAssertEqual(try garbage.read(), BridgeResponse(id: 0, result: .failure(class: "bad_request")))
    }

    func testExitsWhenTheDaemonStaysAway() throws {
        XCTAssertEqual(BridgeSocketServer.defaultIdleExit, 600, "well past the supervisor's 60 s healthy run")
        let idle = expectation(description: "idle")
        let server = try startServer(idleExit: 0.3) { idle.fulfill() }
        let client = try SocketClient(path: hubDir.appendingPathComponent("bridge.sock").path)
        try client.send(BridgeRequest(id: 1, op: .hello(version: 1, hubID: hub)))
        _ = try client.read()
        client.close()
        wait(for: [idle], timeout: 5)
        XCTAssertEqual(server.connectionCount, 0)
    }

    // MARK: - Review Focus 5

    /// WatchtowerSync types outside `Secure/` that open, seal or hold keys, directly or through it.
    static let openingEntryPoints: Set<String> = [
        "DeviceHello", "Keybox", "KeyboxKeys", "DeviceGrant", "ReplicaOpening", "EnvelopeReplicaOpener",
        "ReplicaHydrator", "ReplicaStore", "RelayFeed", "ActionOutbox", "RecordingUploader"
    ]

    /// The bridge holds no hub key and opens no envelope: CloudBridgeCore's own object code references no
    /// sealing, opening or key type of WatchtowerSync (nested types included) nor any of its entry points that
    /// reach one, and nothing of CryptoKit; its package target depends on WatchtowerSync and GRDB only; and
    /// its sources name none of those types.
    func testBridgeNeverOpensEnvelopes() throws {
        let root = repoRoot()
        let declared = try Self.kitTypes(root: root)
        let renamed = Self.openingEntryPoints.subtracting(declared.all)
        XCTAssertTrue(renamed.isEmpty, "an entry point was renamed: \(renamed)")
        let forbidden = try Self.keyTypes(root: root).union(Self.openingEntryPoints)
        XCTAssertTrue(forbidden.isSuperset(of: ["SecureTransport", "EnvelopeSealer", "AlertOpener", "SecureKeyProvider", "HubKeyStore"]))

        // 1. Linked symbols of the built library.
        let objects = try Self.objectFiles(of: "CloudBridgeCore")
        XCTAssertFalse(objects.isEmpty, "CloudBridgeCore's object files not found next to the test bundle")
        let symbols = try Self.demangledUndefinedSymbols(objects)
        XCTAssertTrue(symbols.contains { $0.contains("WatchtowerSync.HubZones") }, "positive control: the bridge does use WatchtowerSync")
        let pattern = #"WatchtowerSync\.(?:[A-Za-z0-9_]+\.)*("# + forbidden.sorted().joined(separator: "|") + #")\b"#
        let regex = try NSRegularExpression(pattern: pattern)
        let hits = symbols.filter { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        XCTAssertTrue(hits.isEmpty, "CloudBridgeCore references key or opening code: \(hits.prefix(5))")
        XCTAssertFalse(symbols.contains { $0.contains("CryptoKit.") }, "CloudBridgeCore uses CryptoKit")

        // 2. The package graph: CloudBridgeCore's dependencies.
        let manifest = try String(contentsOf: root.appendingPathComponent("WatchtowerDesktop/Package.swift"), encoding: .utf8)
        let deps = try XCTUnwrap(Self.targetDependencies(manifest, target: "CloudBridgeCore"))
        XCTAssertEqual(deps.sorted(), ["product:GRDB", "product:WatchtowerSync"])

        // 3. The sources: top-level names only (a nested name such as `Kind` is too common to scan text for).
        for (file, text) in try Self.bridgeSources() {
            XCTAssertNil(text.range(of: "import CryptoKit"), file)
            for type in forbidden.intersection(declared.topLevel.union(Self.openingEntryPoints))
            where text.range(of: "\\b\(type)\\b", options: .regularExpression) != nil {
                XCTFail("\(file) names \(type)")
            }
        }
    }

    func testTheDependencyParserReadsEveryForm() {
        let manifest = """
            .target(
                name: "X",
                dependencies: [
                    // a comment with .product(name: "Nope", package: "p")
                    .product(name: "A", package: "a"), "B",
                    .target(name: "C"), .byName(name: "D"),
                ],
                path: "Sources/X"
            ),
            .target(name: "Y", dependencies: ["Z"])
            """
        XCTAssertEqual(Self.targetDependencies(manifest, target: "X")?.sorted(), ["name:B", "product:A", "target:C", "target:D"])
        XCTAssertEqual(Self.targetDependencies(manifest, target: "Y"), ["name:Z"])
        XCTAssertNil(Self.targetDependencies(manifest, target: "W"))
    }

    /// The `dependencies:` list of the target named `target`, comments stripped, bracket-balanced, each entry as
    /// `product:<name>`, `target:<name>` (`.target`/`.byName`) or `name:<name>` (a bare string).
    static func targetDependencies(_ manifest: String, target: String) -> [String]? {
        let lines = manifest.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            line.range(of: "//").map { line[..<$0.lowerBound] } ?? line
        }
        let text = lines.joined(separator: "\n")
        guard let name = text.range(of: "name: \"\(target)\"") else { return nil }
        guard let key = text.range(of: "dependencies:", range: name.upperBound..<text.endIndex),
              let open = text.range(of: "[", range: key.upperBound..<text.endIndex) else { return [] }
        // The target's dependencies must come before its next sibling target starts.
        if let next = text.range(of: ".target(", range: name.upperBound..<text.endIndex), next.lowerBound < key.lowerBound { return [] }
        var depth = 0, end = open.lowerBound
        for index in text[open.lowerBound...].indices {
            if text[index] == "[" { depth += 1 }
            if text[index] == "]" { depth -= 1 }
            if depth == 0 { end = index; break }
        }
        let list = String(text[text.index(after: open.lowerBound)..<end])
        var out: [String] = []
        var rest = list
        for (pattern, kind) in [
            (#"\.product\(\s*name:\s*"([^"]+)"[^)]*\)"#, "product"),
            (#"\.(?:target|byName)\(\s*name:\s*"([^"]+)"[^)]*\)"#, "target")
        ] {
            out += captures(pattern, in: rest).map { "\(kind):\($0)" }
            rest = rest.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return out + captures(#""([^"]+)""#, in: rest).map { "name:\($0)" }
    }

    static func bridgeSources() throws -> [(String, String)] {
        let sources = repoRoot().appendingPathComponent("WatchtowerDesktop/Sources/CloudBridgeCore")
        return try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }.map { file in
            (file, try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8))
        }
    }

    /// The types WatchtowerSync declares, top-level and every one.
    static func kitTypes(root: URL) throws -> (topLevel: Set<String>, all: Set<String>) {
        let dir = root.appendingPathComponent("WatchtowerKit/Sources/WatchtowerSync")
        var top: Set<String> = [], all: Set<String> = []
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            top.formUnion(captures(Self.topLevelDecl, in: text))
            all.formUnion(captures(Self.anyDecl, in: text))
        }
        return (top, all)
    }

    static let declModifiers = "(?:public |internal |fileprivate |private |final |open |indirect )*"
    static let declKind = "(?:struct|class|enum|protocol|actor) ([A-Za-z_][A-Za-z0-9_]+)"
    static let topLevelDecl = "(?m)^" + declModifiers + declKind
    static let anyDecl = #"(?m)^\s*"# + declModifiers + declKind

    /// Every type the Kit's Secure layer declares (keys, sealing, opening), nested ones included, less the pure
    /// metadata types a record carries (`EnvelopeClass`, `AssetDescriptor` and its `AssetHeader`) that the
    /// Kit's `CloudRecord` initializer names, plus `HubKeyring` (the Swift hub's, should one move into the Kit).
    static func keyTypes(root: URL) throws -> Set<String> {
        let dir = root.appendingPathComponent("WatchtowerKit/Sources/WatchtowerSync/Secure")
        var names: Set<String> = ["HubKeyring"]
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            names.formUnion(captures(anyDecl, in: text))
        }
        return names.subtracting(["EnvelopeClass", "AssetDescriptor", "AssetHeader"])
    }

    /// The first capture group of every match.
    static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// `<target>.build/*.o` beside the test bundle (SwiftPM's build products dir).
    /// One object file per current source (a stale object of a deleted source is left out); a source
    /// without its object fails the test.
    static func objectFiles(of target: String) throws -> [URL] {
        let bundle = Bundle(for: BridgeContractTests.self).bundleURL
        let dir = bundle.deletingLastPathComponent().appendingPathComponent("\(target).build")
        let objects = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let sources = try bridgeSources().map(\.0)
        let wanted = objects.filter { object in sources.contains { object.lastPathComponent == "\($0).o" } }
        XCTAssertEqual(wanted.count, sources.count, "an object file is missing for one of \(sources)")
        return wanted
    }

    static func demangledUndefinedSymbols(_ objects: [URL]) throws -> [String] {
        let mangled = try run("/usr/bin/nm", ["-u", "-j"] + objects.map(\.path))
        let demangled = try run("/usr/bin/xcrun", ["swift-demangle"], input: mangled)
        return demangled.split(separator: "\n").map(String.init)
    }

    static func run(_ tool: String, _ args: [String], input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let inPipe = Pipe()
        if input != nil { process.standardInput = inPipe }
        try process.run()
        if let input {
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) failed")
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

/// A plain blocking client of the bridge socket.
final class SocketClient {
    private let fd: Int32

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }
    }

    func send(_ request: BridgeRequest) throws {
        let frame = try BridgeFraming.frame(request.encoded())
        let n = frame.withUnsafeBytes { raw in raw.baseAddress.map { write(fd, $0, raw.count) } ?? -1 }
        guard n == frame.count else { throw POSIXError(.EPIPE) }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw POSIXError(.EINVAL) }
            while offset < count {
                let n = Darwin.read(fd, base + offset, count - offset)
                guard n > 0 else { throw POSIXError(.ECONNRESET) }
                offset += n
            }
        }
        return data
    }

    func read() throws -> BridgeResponse {
        let length = try BridgeFraming.length(ofHeader: try readExactly(4))
        return try BridgeResponse.decode(length == 0 ? Data() : try readExactly(length))
    }

    func sendRaw(_ bytes: Data) throws {
        let n = bytes.withUnsafeBytes { raw in raw.baseAddress.map { write(fd, $0, raw.count) } ?? -1 }
        guard n == bytes.count else { throw POSIXError(.EPIPE) }
    }

    func close() { Darwin.close(fd) }
}

/// A value shared with a `@Sendable` closure in a test.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T { lock.withLock { stored } }

    func update(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}
