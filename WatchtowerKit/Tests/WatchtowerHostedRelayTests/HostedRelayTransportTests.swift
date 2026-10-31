import Foundation
import os
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
@testable import WatchtowerSync
import XCTest

/// `HostedRelayTransport` in the phone role on `FakeHostedRelay`: a phone and a test Mac,
/// the Mac writing its data zone through `perform`. Twins of the Go hub's
/// `internal/hub/transport/relay/transport_test.go` (same names) plus the phone's own
/// rules (R4–R11). Not final: `HostedRelayTransportInteropTests` runs it against the stand.
class HostedRelayTransportTests: HostedRelayScenarioCase {
    static let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    static let stampMs: Int64 = 1_700_000_000_000

    private var transports: [HostedRelayTransport] = []
    private var eventLogs: [TransportEventLog] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        for transport in transports { await transport.stop() }
        for log in eventLogs { log.cancel() }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        transports = []
        eventLogs = []
        directories = []
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// A fresh directory for this test, removed at tear-down.
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-transport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    /// A store file in a fresh directory (its asset stash beside it).
    func storePath() throws -> String {
        try directory().appendingPathComponent("transport.sqlite").path
    }

    func makeTransport(
        _ phone: HostedRelayClient,
        mac: HostedRelayClient,
        store: TransportStore,
        maxAttachmentBytes: Int64 = 100 << 20
    ) async throws -> (HostedRelayTransport, TransportEventLog) {
        let transport = try HostedRelayTransport(
            client: phone, store: store, macDeviceID: mac.deviceID, maxAttachmentBytes: maxAttachmentBytes)
        transports.append(transport)
        let log = TransportEventLog()
        await log.attach(to: transport)
        eventLogs.append(log)
        return (transport, log)
    }

    /// The fake (its faults and limits); `XCTSkip` on the stand (R15).
    var relay: FakeHostedRelay {
        get throws { try requireFake("needs the fake's faults or limits (fake only, R15)") }
    }

    /// Why a test that moves the relay's clock (session ends, 30-day tombstone purge,
    /// attestation deadlines) runs on the fake only.
    static let needsClock = "moves the relay's clock (fake only, R15)"

    func mailboxRecord(_ name: String, asset: URL? = nil) -> CloudRecord {
        CloudRecord(
            recordName: name, zone: .relay, kind: WireKind.envelope, modifiedAt: Self.stamp,
            payload: Data("envelope-\(name)".utf8), assetFileURL: asset)
    }

    func dataZone(_ mac: HostedRelayClient) -> String {
        HostedRelayZones.data(mac: mac.deviceID)
    }

    func mailbox(_ mac: HostedRelayClient, _ phone: HostedRelayClient) -> String {
        HostedRelayZones.mailbox(mac: mac.deviceID, phone: phone.deviceID)
    }

    /// The Mac writes one record (envelope = its name) at `modifiedMs`; returns its seq.
    @discardableResult
    func macSave(
        _ mac: HostedRelayClient, _ zone: String, _ name: String, modifiedMs: Int64 = 0, attachmentID: String = ""
    ) async throws -> UInt64 {
        var item = Relay_V1_SaveItem()
        item.record.zone = zone
        item.record.name = name
        item.record.envelope = Data(name.utf8)
        item.record.clientModifiedAtMs = modifiedMs
        item.record.attachmentID = attachmentID
        var save = Relay_V1_Save()
        save.items = [item]
        guard let saved = try await mac.save(save).saved.first else { throw ScenarioFailure.unexpected("save \(name)") }
        return saved.recordSeq
    }

    func macDelete(_ mac: HostedRelayClient, _ zone: String, _ names: [String]) async throws {
        var delete = Relay_V1_Delete()
        delete.zone = zone
        delete.items = names.map { name in
            var item = Relay_V1_DeleteItem()
            item.name = name
            return item
        }
        _ = try await mac.delete(delete)
    }

    /// The Mac uploads `bytes` as an attachment of `zone`; returns its id.
    func macUpload(_ mac: HostedRelayClient, _ zone: String, _ bytes: Data) async throws -> String {
        var create = Relay_V1_CreateUpload()
        create.zone = zone
        create.size = UInt64(bytes.count)
        let upload = try await mac.createUpload(create)
        let file = try directory().appendingPathComponent("upload")
        try bytes.write(to: file)
        let status = try await backend.http.put(try XCTUnwrap(URL(string: upload.url)), file: file, headers: upload.headers)
        XCTAssertEqual(status, 200)
        return upload.attachmentID
    }

    /// The `since_seq` of every `changes` of `zone`, in order.
    func changesSinces(_ zone: String) throws -> [UInt64] {
        backend.opLog.compactMap { op in
            guard case .changes(let changes) = op, changes.zone == zone else { return nil }
            return changes.sinceSeq
        }
    }

    /// The case names of the ops in the log, in order.
    func opNames() throws -> [String] {
        backend.opLog.map { HostedRelayClient.name($0) }
    }

    func savedNames() throws -> [[String]] {
        backend.opLog.compactMap { op in
            guard case .save(let save) = op else { return nil }
            return save.items.map(\.record.name)
        }
    }

    func buffered(_ store: TransportStore, _ zone: CloudZoneID, since token: CloudChangeToken? = nil) throws -> CloudChangeBatch {
        try store.changes(in: zone, since: token)
    }

    func waitForRelayEvent(_ log: TransportEventLog, _ event: HostedRelayEvent, file: StaticString = #filePath, line: UInt = #line) async {
        await eventually(file: file, line: line) { log.relayEvents.contains(event) }
    }

    // MARK: - Go twins

    func testSaveConditionalOutcomes() async throws {
        let (mac, phone) = try await hub()
        let (transport, _) = try await makeTransport(phone, mac: mac, store: TransportStore.inMemory())
        let first = try await transport.save([
            ConditionalSave(record: mailboxRecord("a"), expect: .absent),
            ConditionalSave(record: mailboxRecord("b"), expect: .none)
        ])
        XCTAssertEqual(first, [.saved(recordSeq: 1), .saved(recordSeq: 2)])
        guard case .save(let wire) = backend.opLog.last else { return XCTFail("no save on the wire") }
        XCTAssertEqual(wire.items.map(\.record.zone), [mailbox(mac, phone), mailbox(mac, phone)])
        XCTAssertEqual(wire.items[0].mustNotExist, true)
        XCTAssertNil(wire.items[1].expect)
        XCTAssertEqual(wire.items[0].record.clientModifiedAtMs, Self.stampMs)
        XCTAssertEqual(wire.items[0].record.envelope, Data("envelope-a".utf8), "the envelope goes out as is")

        let second = try await transport.save([
            ConditionalSave(record: mailboxRecord("a"), expect: .absent),
            ConditionalSave(record: mailboxRecord("b"), expect: .seq(2))
        ])
        guard case .conflict(let current) = second[0] else { return XCTFail("conflict expected: \(second)") }
        XCTAssertEqual(current.recordName, "a")
        XCTAssertEqual(current.zone, .relay)
        XCTAssertEqual(current.recordSeq, 1)
        XCTAssertEqual(current.payload, Data("envelope-a".utf8))
        XCTAssertEqual(second[1], .saved(recordSeq: 3))

        let deleted = try await transport.delete([
            ConditionalDelete(recordName: "a", zone: .relay, expect: .seq(9)),
            ConditionalDelete(recordName: "b", zone: .relay, expect: .none),
            ConditionalDelete(recordName: "never", zone: .relay, expect: .seq(4))
        ])
        guard case .conflict(let kept) = deleted[0] else { return XCTFail("conflict expected: \(deleted)") }
        XCTAssertEqual(kept.recordSeq, 1)
        XCTAssertEqual(deleted[1], .deleted)
        XCTAssertEqual(deleted[2], .deleted, "no record under the name: deleted (R6)")
    }

    func testZoneTokensPersist() async throws {
        let (mac, phone) = try await hub()
        let path = try storePath()
        for index in 0..<3 { try await macSave(mac, dataZone(mac), "n\(index)") }
        var limits = try relay.limits
        limits.changesPageBytes = 1
        try relay.limits = limits

        let store = try TransportStore(path: path)
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        try await transport.pull()
        XCTAssertEqual(try buffered(store, .data).changed.map(\.recordName), ["n0", "n1", "n2"])
        XCTAssertEqual(try changesSinces(dataZone(mac)), [0, 1, 2], "one page per record")
        XCTAssertEqual(try store.relayCursor(zone: .data), 3)

        // A page that cannot be buffered keeps the cursor where it was.
        let floor = try buffered(store, .data).newToken
        try await macSave(mac, dataZone(mac), "n3")
        try store.failInserts(true)
        do {
            try await transport.pull()
            XCTFail("a failed buffer was swallowed")
        } catch {}
        try store.failInserts(false)
        XCTAssertEqual(try store.relayCursor(zone: .data), 3)
        await transport.stop()
        try store.close()

        // A new transport on the same store file resumes from the stored cursor.
        let reopened = try TransportStore(path: path)
        let (again, _) = try await makeTransport(phone, mac: mac, store: reopened)
        try await again.pull()
        XCTAssertEqual(try changesSinces(dataZone(mac)).last, 3)
        XCTAssertEqual(try buffered(reopened, .data, since: floor).changed.map(\.recordName), ["n3"])
        XCTAssertEqual(try reopened.relayCursor(zone: .data), 4)
    }

    /// `TOKEN_EXPIRED` sends the zone back to 0; the resync deletes what the server purged (R10).
    func testTokenExpiredResetsZoneToZero() async throws {
        _ = try requireFake(Self.needsClock)
        let (mac, phone) = try await hub()
        try await macSave(mac, dataZone(mac), "a")
        try await macSave(mac, dataZone(mac), "b")
        let store = try TransportStore.inMemory()
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        try await transport.pull()
        let floor = try buffered(store, .data).newToken
        XCTAssertEqual(try store.relayCursor(zone: .data), 2)

        // b is deleted, and its tombstone purged after 30 days: the phone's cursor is below the floor.
        try await macDelete(mac, dataZone(mac), ["b"])
        manualClock?.advance(by: .seconds(31 * 86_400))
        try await transport.pull()

        // The 31 days also ended the session: the first `changes` is repeated after a login.
        XCTAssertEqual(try changesSinces(dataZone(mac)), [0, 2, 2, 0])
        XCTAssertEqual(try store.relayCursor(zone: .data), 3)
        let after = try buffered(store, .data, since: floor)
        XCTAssertEqual(after.changed.map(\.recordName), ["a"], "the resync buffers the live set again")
        XCTAssertEqual(after.deletedRecordNames, ["b"], "the purged record is deleted here too")
        XCTAssertFalse(try store.relayResyncPending(.data))
    }

    func testSaveErrorRereadsZone() async throws {
        let (mac, phone) = try await hub()
        let (transport, log) = try await makeTransport(phone, mac: mac, store: TransportStore.inMemory())
        try relay.failNext("save", with: .mailboxQuotaExceeded)
        let outcomes = try await transport.save([
            ConditionalSave(record: mailboxRecord("a"), expect: .absent),
            ConditionalSave(record: mailboxRecord("b"), expect: .absent)
        ])
        XCTAssertEqual(outcomes, [.refused(.quotaExceeded), .refused(.quotaExceeded)])
        XCTAssertEqual(log.transportEvents, [.quotaExceeded])
        let names = try opNames()
        let save = try XCTUnwrap(names.lastIndex(of: "save"))
        XCTAssertEqual(try changesSinces(mailbox(mac, phone)), [0], "the mailbox was re-read")
        XCTAssertEqual(names.last, "changes")
        XCTAssertGreaterThan(names.count - 1, save)
    }

    func testErrorMapping() async throws {
        func server(_ code: Relay_V1_ErrorCode, _ retry: UInt32? = nil) -> HostedRelayError {
            .server(code: code, retryAfter: retry)
        }
        let cases: [(any Error, TransportRefusal)] = [
            (server(.mailboxQuotaExceeded), .quotaExceeded),
            (server(.rateLimited, 7), .rateLimited(retryAfter: 7)),
            (server(.trafficLimitExceeded), .rateLimited(retryAfter: nil)),
            (server(.entitlementInactive), .entitlementInactive),
            (HostedRelayError.unreachable, .unreachable),
            (server(.unavailable), .unreachable),
            (HostedRelayError.undecodable(status: 503), .unreachable),
            (HostedRelayError.attestation(.notSupported), .unreachable),
            (HostedRelayError.attestation(.updateRequired), .unreachable),
            (HostedRelayError.unsupportedVersion, .unreachable),
            (CancellationError(), .transient(code: "cancelled")),
            (HostedRelayError.undecodable(status: 200), .transient(code: "malformed_answer")),
            (HostedRelayError.attestation(.retryLater(after: .seconds(1))), .transient(code: "attestation_backoff")),
            (server(.unauthenticated), .transient(code: "unauthenticated")),
            (server(.pairingExpired), .transient(code: "relay_16")),
            (server(.UNRECOGNIZED(99)), .transient(code: "relay_99")),
            (server(.recordTooLarge), .permanent(code: "record_too_large")),
            (server(.attachmentTooLarge), .permanent(code: "record_too_large")),
            (server(.forbidden), .permanent(code: "forbidden")),
            (server(.notFound), .permanent(code: "not_found")),
            (server(.unspecified), .permanent(code: "unspecified"))
        ]
        for (error, refusal) in cases {
            XCTAssertEqual(HostedRelayTransport.refusal(for: error), refusal, "\(error)")
        }

        // Through the transport: a refused zone is reported on relayEvents, a pull throws as the client does.
        let (mac, phone) = try await hub()
        let (transport, log) = try await makeTransport(phone, mac: mac, store: TransportStore.inMemory())
        try relay.failNext("save", with: .forbidden)
        let outcomes = try await transport.save([ConditionalSave(record: mailboxRecord("a"), expect: .absent)])
        XCTAssertEqual(outcomes, [.refused(.permanent(code: "forbidden"))])
        await waitForRelayEvent(log, .forbidden(zone: .relay))
        try relay.failNext("changes", with: .notFound)
        do {
            try await transport.pull()
            XCTFail("a refused pull did not throw")
        } catch {
            XCTAssertEqual(error as? HostedRelayError, .server(code: .notFound, retryAfter: nil))
        }

        // R6 amendment: R6 asks for `.transient(code: "response_lost")` when the answer is lost after
        // the request was sent. The client cannot tell that from a request never sent (both are
        // `HostedRelayError.unreachable`), so today a lost answer is `.unreachable`.
        try relay.crashAfterNext("save")
        let lost = try await transport.save([ConditionalSave(record: mailboxRecord("b"), expect: .absent)])
        XCTAssertEqual(lost, [.refused(.unreachable)], "response_lost")
        try relay.restart()
    }

    /// A record-less `ZoneChanged` (the reconnect marker) is a pull, and so is a live one (R9).
    func testZoneChangedWithoutRecordMeansPull() async throws {
        let (mac, phone) = try await hub()
        let store = try TransportStore.inMemory()
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        try await macSave(mac, dataZone(mac), "before")
        await transport.start()
        await eventually { (try? self.buffered(store, .data).changed.map(\.recordName)) == ["before"] }
        let states = backend.opLog.filter { if case .getAccountState = $0 { true } else { false } }.count

        // Written while the phone is away: only the reconnect's record-less event tells it.
        try relay.deploy()
        try await macSave(mac, dataZone(mac), "missed")
        await eventually { (try? self.buffered(store, .data).changed.map(\.recordName)) == ["before", "missed"] }
        await eventually {
            ((try? self.relay.log.filter { if case .getAccountState = $0 { true } else { false } }.count) ?? 0) > states
        }

        // A live event carrying a record is still just a pull.
        try await macSave(mac, dataZone(mac), "live")
        await eventually { (try? self.buffered(store, .data).changed.map(\.recordName)) == ["before", "missed", "live"] }
    }

    func testUploadThenSaveWithAttachment() async throws {
        let (mac, phone) = try await hub()
        let directory = try directory()
        let asset = directory.appendingPathComponent("sealed-audio")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: asset)
        let store = try TransportStore(path: try storePath())
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)

        try await transport.save([mailboxRecord("upload-1", asset: asset)])
        XCTAssertFalse(try opNames().contains("save"), "a plain save waits in the queue")
        await transport.sendNow()
        XCTAssertFalse(try store.isPending(recordName: "upload-1", zone: .relay))
        let names = try opNames()
        let create = try XCTUnwrap(names.firstIndex(of: "createUpload"))
        let save = try XCTUnwrap(names.firstIndex(of: "save"))
        XCTAssertLessThan(create, save)
        guard case .save(let wire) = backend.opLog[save] else { return XCTFail("save") }
        let attachment = wire.items[0].record.attachmentID
        XCTAssertFalse(attachment.isEmpty)
        XCTAssertEqual(wire.items[0].record.envelope, Data("envelope-upload-1".utf8))

        // The Mac reads it back with its attachment.
        var download = Relay_V1_GetDownload()
        download.zone = mailbox(mac, phone)
        download.attachmentID = attachment
        let url = try await mac.getDownload(download).url
        let out = directory.appendingPathComponent("mac-copy")
        let status = try await backend.http.get(try XCTUnwrap(URL(string: url)), to: out, maxBytes: 1 << 20, headers: [:])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(try Data(contentsOf: out), bytes)

        // The phone's own pull stashes the attachment beside its event.
        try await transport.pull()
        let event = try XCTUnwrap(try buffered(store, .relay).changed.first)
        XCTAssertEqual(event.recordName, "upload-1")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(event.assetFileURL)), bytes)
    }

    func testDownloadCappedAndRedirectsChecked() async throws {
        var http: InterceptingRelayHTTP?
        let (mac, phone) = try await hub { base in
            let intercepting = InterceptingRelayHTTP(base)
            http = intercepting
            return intercepting
        }
        let intercepting = try XCTUnwrap(http)
        let bytes = Data(repeating: 7, count: 1000)
        let attachment = try await macUpload(mac, dataZone(mac), bytes)
        let seq = try await macSave(mac, dataZone(mac), "report", attachmentID: attachment)

        // Over the cap: the page fails, nothing is buffered or left on disk, the cursor stays.
        let path = try storePath()
        let stash = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("transport-assets")
        let capped = try TransportStore(path: path)
        let (small, _) = try await makeTransport(phone, mac: mac, store: capped, maxAttachmentBytes: 999)
        do {
            try await small.pull()
            XCTFail("an oversize attachment was accepted")
        } catch {}
        XCTAssertEqual(try capped.relayCursor(zone: .data), 0)
        XCTAssertEqual(try buffered(capped, .data).changed, [])
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: stash.path)) ?? [], [], "no file left")
        await small.stop()

        // A redirect (or any non-2xx) fails the page too.
        intercepting.download { _ in 302 }
        let (redirected, _) = try await makeTransport(phone, mac: mac, store: capped, maxAttachmentBytes: 1000)
        do {
            try await redirected.pull()
            XCTFail("a redirected download was accepted")
        } catch {}
        XCTAssertEqual(try capped.relayCursor(zone: .data), 0)
        await redirected.stop()

        // A download URL that leaves HTTPS is refused before any GET.
        intercepting.download(nil)
        let gets = intercepting.gets.count
        intercepting.answer { request in
            guard case .getDownload = request.op else { return nil }
            var response = Relay_V1_Response()
            response.download.url = "http://relay.example.com/v1/blob/\(attachment)"
            return response
        }
        let (plain, _) = try await makeTransport(phone, mac: mac, store: capped, maxAttachmentBytes: 1000)
        do {
            try await plain.pull()
            XCTFail("a plain-HTTP download was accepted")
        } catch {}
        XCTAssertEqual(intercepting.gets.count, gets)
        XCTAssertEqual(try capped.relayCursor(zone: .data), 0)
        await plain.stop()

        // At the cap it goes through.
        intercepting.answer(nil)
        let (exact, _) = try await makeTransport(phone, mac: mac, store: capped, maxAttachmentBytes: 1000)
        try await exact.pull()
        let event = try XCTUnwrap(try buffered(capped, .data).changed.first)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(event.assetFileURL)), bytes)
        XCTAssertEqual(try capped.relayCursor(zone: .data), seq)
    }

    func testMalformedSaveAnswerIsAnError() async throws {
        func answer(saved: [UInt64], conflicts: [UInt32], names: [String] = ["a", "b"]) -> Relay_V1_SaveResult {
            var result = Relay_V1_SaveResult()
            let savedNames = names.indices.filter { !conflicts.contains(UInt32($0)) }.map { names[$0] }
            result.saved = saved.enumerated().map { position, seq in
                var record = Relay_V1_Record()
                record.name = position < savedNames.count ? savedNames[position] : "extra"
                record.recordSeq = seq
                return record
            }
            result.conflicts = conflicts.map { index in
                var conflict = Relay_V1_SaveConflict()
                conflict.index = index
                return conflict
            }
            return result
        }
        let malformed = [
            "out of range": answer(saved: [1], conflicts: [5]),
            "repeated": answer(saved: [], conflicts: [0, 0]),
            "short": answer(saved: [1], conflicts: []),
            "long": answer(saved: [1, 2, 3], conflicts: []),
            "another record's name": answer(saved: [1, 2], conflicts: [], names: ["a", "c"])
        ]
        let items = [mailboxRecord("a"), mailboxRecord("b")]
        for (name, result) in malformed {
            XCTAssertNil(HostedRelayTransport.saveOutcomes(result, items: items), name)
        }
        XCTAssertEqual(
            HostedRelayTransport.saveOutcomes(answer(saved: [4], conflicts: [0]), items: items),
            [.refused(.permanent(code: "gone")), .saved(recordSeq: 4)])

        // Through the transport: the reviewer's answer (2 items, conflict index 5, 1 saved).
        var http: InterceptingRelayHTTP?
        let (mac, phone) = try await hub { base in
            let intercepting = InterceptingRelayHTTP(base)
            http = intercepting
            return intercepting
        }
        try XCTUnwrap(http).answer { request in
            guard case .save = request.op else { return nil }
            var response = Relay_V1_Response()
            response.save = answer(saved: [1], conflicts: [5])
            return response
        }
        let (transport, _) = try await makeTransport(phone, mac: mac, store: TransportStore.inMemory())
        let outcomes = try await transport.save([
            ConditionalSave(record: mailboxRecord("a"), expect: .absent),
            ConditionalSave(record: mailboxRecord("b"), expect: .absent)
        ])
        let refused = SaveOutcome.refused(.transient(code: "malformed_answer"))
        XCTAssertEqual(outcomes, [refused, refused])
    }

    func testDeviceIDMatchesIdentity() async throws {
        let (mac, phone) = try await hub()
        let (transport, _) = try await makeTransport(phone, mac: mac, store: TransportStore.inMemory())
        let signer = try backend.signer(seed: 2)
        XCTAssertEqual(phone.deviceID, RelayAuthMessages.deviceID(publicKey: signer.publicKey))
        XCTAssertEqual(transport.mailboxZone, "relay/\(mac.deviceID)/\(phone.deviceID)")
        XCTAssertEqual(transport.dataZone, "data/\(mac.deviceID)")
        XCTAssertEqual(HostedRelayZones.pair(slot: "slot1"), "pair/slot1")
    }

    // MARK: - The phone's rules

    func testPlainSavesQueueAndFlushInOrder() async throws {
        let (mac, phone) = try await hub()
        let store = try TransportStore.inMemory()
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        try await transport.save([mailboxRecord("r1")])
        try await transport.delete(recordNames: ["r0"], in: .relay)
        try await transport.save([mailboxRecord("r2")])
        XCTAssertFalse(try opNames().contains("save"), "nothing sent before a flush")

        await transport.sendNow()
        let writes = backend.opLog.compactMap { op -> String? in
            switch op {
            case .save(let save): return "save " + save.items.map(\.record.name).joined(separator: ",")
            case .delete(let delete): return "delete " + delete.items.map(\.name).joined(separator: ",")
            default: return nil
            }
        }
        XCTAssertEqual(writes, ["save r1", "delete r0", "save r2"])
        for name in ["r0", "r1", "r2"] { XCTAssertFalse(try store.isPending(recordName: name, zone: .relay), name) }
    }

    func testCursorMovesOnlyWithTheBufferedPage() async throws {
        let (mac, phone) = try await hub()
        try await macSave(mac, dataZone(mac), "a")
        let store = try TransportStore.inMemory()
        let (transport, log) = try await makeTransport(phone, mac: mac, store: store)
        try store.failInserts(true)
        do {
            try await transport.pull()
            XCTFail("a failed buffer was swallowed")
        } catch {}
        XCTAssertEqual(try store.relayCursor(zone: .data), 0)
        XCTAssertEqual(log.fetches, 0)

        try store.failInserts(false)
        try await transport.pull()
        XCTAssertEqual(try store.relayCursor(zone: .data), 1)
        XCTAssertEqual(try buffered(store, .data).changed.map(\.recordName), ["a"])
        XCTAssertEqual(log.fetches, 1, "a pull that buffered something")
        try await transport.pull()
        XCTAssertEqual(log.fetches, 1, "a pull that buffered nothing")
    }

    func testADataZoneSaveIsRefusedWithoutARequest() async throws {
        let (mac, phone) = try await hub()
        let store = try TransportStore.inMemory()
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        let ops = backend.opLog.count
        let record = CloudRecord(recordName: "x", zone: .data, kind: WireKind.envelope, modifiedAt: Self.stamp, payload: Data())
        let forbidden = HostedRelayError.server(code: .forbidden, retryAfter: nil)

        do {
            try await transport.save([record])
            XCTFail("a plain data-zone save was queued")
        } catch {
            XCTAssertEqual(error as? HostedRelayError, forbidden)
        }
        do {
            try await transport.delete(recordNames: ["x"], in: .data)
            XCTFail("a plain data-zone delete was queued")
        } catch {
            XCTAssertEqual(error as? HostedRelayError, forbidden)
        }
        let saved = try await transport.save([ConditionalSave(record: record, expect: .none)])
        XCTAssertEqual(saved, [.refused(.permanent(code: "forbidden"))])
        let deleted = try await transport.delete([ConditionalDelete(recordName: "x", zone: .data, expect: .none)])
        XCTAssertEqual(deleted, [.refused(.permanent(code: "forbidden"))])

        XCTAssertEqual(backend.opLog.count, ops, "no request")
        XCTAssertFalse(try store.isPending(recordName: "x", zone: .data))
    }

    func testAnAbsentDeleteIsRefusedWithoutARequest() async throws {
        let (mac, phone) = try await hub()
        let (transport, _) = try await makeTransport(phone, mac: mac, store: TransportStore.inMemory())
        let ops = backend.opLog.count
        let outcomes = try await transport.delete([ConditionalDelete(recordName: "a", zone: .relay, expect: .absent)])
        XCTAssertEqual(outcomes, [.refused(.permanent(code: "unsupported_precondition"))])
        XCTAssertEqual(backend.opLog.count, ops)
    }

    /// R7: `RecordOrigin.serverAt` is the writer's `client_modified_at_ms`, kept across a reopen.
    func testServerAtIsTheWritersClock() async throws {
        let (mac, phone) = try await hub()
        let written: Int64 = 1_750_000_000_123
        let seq = try await macSave(mac, dataZone(mac), "a", modifiedMs: written)
        let path = try storePath()
        let store = try TransportStore(path: path)
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        try await transport.pull()
        await transport.stop()
        try store.close()

        let reopened = try TransportStore(path: path)
        let record = try XCTUnwrap(try buffered(reopened, .data).changed.first)
        let at = Date(timeIntervalSince1970: TimeInterval(written) / 1000)
        XCTAssertEqual(record.modifiedAt, at)
        XCTAssertEqual(record.origin, RecordOrigin(author: nil, serverAt: at))
        XCTAssertEqual(record.recordSeq, seq)
        XCTAssertEqual(record.kind, WireKind.envelope)
        XCTAssertEqual(record.payload, Data("a".utf8))
    }

    /// R8: queued plain writes reach the relay before a later conditional one; a stopped flush sends nothing more.
    func testAConditionalWriteFlushesQueuedPlainWritesFirst() async throws {
        let (mac, phone) = try await hub()
        let store = try TransportStore.inMemory()
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        try await transport.save([mailboxRecord("plain-1")])
        let outcomes = try await transport.save([ConditionalSave(record: mailboxRecord("c-1"), expect: .absent)])
        XCTAssertEqual(outcomes, [.saved(recordSeq: 2)])
        XCTAssertEqual(try savedNames(), [["plain-1"], ["c-1"]])

        try await transport.save([mailboxRecord("plain-2")])
        try relay.failNext("save", with: .rateLimited)
        let stopped = try await transport.save([ConditionalSave(record: mailboxRecord("c-2"), expect: .absent)])
        XCTAssertEqual(stopped, [.refused(.rateLimited(retryAfter: nil))])
        XCTAssertEqual(try savedNames(), [["plain-1"], ["c-1"], ["plain-2"]], "c-2 was not sent")
        XCTAssertTrue(try store.isPending(recordName: "plain-2", zone: .relay), "the plain write stays queued")
    }

    /// R10: a resync stopped after its first page deletes nothing; resumed by a new transport on
    /// the same store, it deletes after its last page, and only names the server once returned.
    func testAnInterruptedResyncDeletesNothing() async throws {
        var http: InterceptingRelayHTTP?
        let (mac, phone) = try await hub { base in
            let intercepting = InterceptingRelayHTTP(base)
            http = intercepting
            return intercepting
        }
        let intercepting = try XCTUnwrap(http)
        let zone = dataZone(mac)
        try await macSave(mac, zone, "x")
        let path = try storePath()
        let store = try TransportStore(path: path)
        let (first, _) = try await makeTransport(phone, mac: mac, store: store)
        try await first.pull()
        try store.bufferChanged([CloudRecord(
            recordName: "local-only", zone: .data, kind: WireKind.envelope, modifiedAt: Self.stamp, payload: Data())])
        let floor = try buffered(store, .data).newToken

        // x is deleted and its tombstone purged; a and b are written after the purge.
        try await macDelete(mac, zone, ["x"])
        manualClock?.advance(by: .seconds(31 * 86_400))
        try await macSave(mac, zone, "a")
        try await macSave(mac, zone, "b")
        var limits = try relay.limits
        limits.changesPageBytes = 1
        try relay.limits = limits
        intercepting.answer { request in
            if case .changes(let changes) = request.op, changes.zone == zone, changes.sinceSeq == 3 {
                throw URLError(.networkConnectionLost)
            }
            return nil
        }
        do {
            try await first.pull()
            XCTFail("the interrupted resync did not throw")
        } catch {}
        XCTAssertTrue(try store.relayResyncPending(.data))
        XCTAssertEqual(try store.relayCursor(zone: .data), 3)
        XCTAssertEqual(try buffered(store, .data, since: floor).deletedRecordNames, [], "nothing deleted mid-resync")
        await first.stop()
        try store.close()

        intercepting.answer(nil)
        let reopened = try TransportStore(path: path)
        let (second, _) = try await makeTransport(phone, mac: mac, store: reopened)
        try await second.pull()
        // [0] the first pull, [1, 1] expired (repeated after the login the 31 days cost), [0] the resync's
        // first page, [3] the resumed one (the interrupted request never reached the relay).
        XCTAssertEqual(try changesSinces(zone), [0, 1, 1, 0, 3], "resumed at the stored cursor")
        XCTAssertFalse(try reopened.relayResyncPending(.data))
        let after = try buffered(reopened, .data, since: floor)
        XCTAssertEqual(after.changed.map(\.recordName), ["a", "b"])
        XCTAssertEqual(after.deletedRecordNames, ["x"], "local-only was never the server's")
    }

    func testAttestationRetryLaterHoldsCallsUntilTheDeadline() async throws {
        let (mac, phone) = try await hub()
        let (transport, log) = try await makeTransport(phone, mac: mac, store: TransportStore.inMemory())
        let attest = fakeAttest(seed: 2)
        try relay.expireSessions(of: phone.deviceID)
        attest.script(.generateAssertion, failures: [.serverUnavailable])
        do {
            try await transport.pull()
            XCTFail("the failed login was swallowed")
        } catch {
            XCTAssertEqual(error as? HostedRelayError, .attestation(.retryLater(after: .seconds(1))))
        }
        await waitForRelayEvent(log, .attestation(.retryLater(after: .seconds(1))))

        let calls = attest.calls.count
        let ops = backend.opLog.count
        do {
            try await transport.pull()
            XCTFail("a pull before the deadline went out")
        } catch {
            guard case .attestation(.retryLater)? = error as? HostedRelayError else { return XCTFail("\(error)") }
        }
        let held = try await transport.save([ConditionalSave(record: mailboxRecord("a"), expect: .absent)])
        XCTAssertEqual(held, [.refused(.transient(code: "attestation_backoff"))])
        await transport.sendNow()
        try await transport.fetchForPush(since: Self.stamp, grace: 0, pollOnFallback: false)
        XCTAssertEqual(attest.calls.count, calls, "no App Attest call before the deadline")
        XCTAssertEqual(backend.opLog.count, ops, "no request before the deadline")

        manualClock?.advance(by: .seconds(1))
        try await transport.pull()
        let saved = try await transport.save([ConditionalSave(record: mailboxRecord("a"), expect: .absent)])
        XCTAssertEqual(saved, [.saved(recordSeq: 1)])
    }

    func testAttestationUpdateRequiredStopsTheTransport() async throws {
        let (mac, phone) = try await hub()
        let store = try TransportStore.inMemory()
        let (transport, log) = try await makeTransport(phone, mac: mac, store: store)
        try await transport.save([mailboxRecord("queued")])
        try relay.expireSessions(of: phone.deviceID)
        try relay.failNext("login", with: .attestationRequired)
        await transport.sendNow()
        await waitForRelayEvent(log, .attestation(.updateRequired))
        XCTAssertTrue(try store.isPending(recordName: "queued", zone: .relay), "the queued write is kept")

        let ops = backend.opLog.count
        let outcomes = try await transport.save([ConditionalSave(record: mailboxRecord("c"), expect: .absent)])
        XCTAssertEqual(outcomes, [.refused(.unreachable)])
        let deleted = try await transport.delete([ConditionalDelete(recordName: "c", zone: .relay, expect: .none)])
        XCTAssertEqual(deleted, [.refused(.unreachable)])
        do {
            try await transport.pull()
            XCTFail("a stopped transport pulled")
        } catch {
            XCTAssertEqual(error as? HostedRelayError, .attestation(.updateRequired))
        }
        await transport.sendNow()
        XCTAssertEqual(backend.opLog.count, ops, "no request once stopped")
        let availability = await transport.availability()
        XCTAssertEqual(availability, .unavailable("relay"))
        XCTAssertEqual(log.relayEvents.filter { $0 == .attestation(.updateRequired) }.count, 1, "reported once")
        XCTAssertTrue(try store.isPending(recordName: "queued", zone: .relay))
    }

    func testAttestationNotSupportedStopsBeforeAnyRequest() async throws {
        let attest = fakeAttest(seed: 40)
        attest.isSupported = false
        let phone = try await makeClient(kind: .phone, seed: 40, register: false)
        let mac = try await makeClient(kind: .mac, seed: 41, register: false)
        let (transport, log) = try await makeTransport(phone, mac: mac, store: TransportStore.inMemory())
        await transport.start()
        await waitForRelayEvent(log, .attestation(.notSupported))
        let outcomes = try await transport.save([ConditionalSave(record: mailboxRecord("a"), expect: .absent)])
        XCTAssertEqual(outcomes, [.refused(.unreachable)])
        XCTAssertEqual(backend.opLog.count, 0, "no request at all")
        XCTAssertEqual(attest.calls, [])
        XCTAssertEqual(log.relayEvents.filter { $0 == .attestation(.notSupported) }.count, 1)
    }

    func testAStoreBoundToCloudKitRefusesTheRelay() async throws {
        let (mac, phone) = try await hub()
        let ops = backend.opLog.count
        let cloudKit = try TransportStore.inMemory()
        try cloudKit.adoptScope(.private, hubID: "hub-a")
        XCTAssertThrowsError(try HostedRelayTransport(client: phone, store: cloudKit, macDeviceID: mac.deviceID)) {
            XCTAssertEqual($0 as? TransportStoreError, .boundToAnotherRoute)
        }
        let otherMac = try TransportStore.inMemory()
        _ = try otherMac.adoptRelayBinding(macDeviceID: "another-mac", hubID: nil)
        XCTAssertThrowsError(try HostedRelayTransport(client: phone, store: otherMac, macDeviceID: mac.deviceID)) {
            XCTAssertEqual($0 as? TransportStoreError, .boundToAnotherRoute)
        }
        XCTAssertEqual(backend.opLog.count, ops, "no request")
    }

    func testEntitlementInactiveIsReportedOnRelayEvents() async throws {
        let (mac, phone) = try await hub()
        let (transport, log) = try await makeTransport(phone, mac: mac, store: TransportStore.inMemory())
        try relay.failNext("save", with: .entitlementInactive)
        let outcomes = try await transport.save([ConditionalSave(record: mailboxRecord("a"), expect: .absent)])
        XCTAssertEqual(outcomes, [.refused(.entitlementInactive)])
        await waitForRelayEvent(log, .entitlementInactive)
    }

    func testFetchForPushPullsOverHTTPSWithoutASocket() async throws {
        let (mac, phone) = try await hub()
        try await macSave(mac, dataZone(mac), "a")
        let store = try TransportStore.inMemory()
        let (transport, log) = try await makeTransport(phone, mac: mac, store: store)
        try await transport.fetchForPush(since: Self.stamp, grace: 0, pollOnFallback: false)
        XCTAssertEqual(try buffered(store, .data).changed.map(\.recordName), ["a"])
        XCTAssertFalse(try opNames().contains("subscribe"), "no socket")
        XCTAssertEqual(log.fetches, 1)
        let availability = await transport.availability()
        XCTAssertEqual(availability, .available)
    }

    // MARK: - Review round 1

    /// Single-flight flush: two `sendNow()` at once send each queued row exactly once.
    func testConcurrentSendNowSendsEachRowOnce() async throws {
        let (mac, phone) = try await hub()
        let store = try TransportStore.inMemory()
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        for name in ["r1", "r2", "r3"] { try await transport.save([mailboxRecord(name)]) }
        async let first: Void = transport.sendNow()
        async let second: Void = transport.sendNow()
        _ = await (first, second)
        XCTAssertEqual(try savedNames(), [["r1"], ["r2"], ["r3"]])
        for name in ["r1", "r2", "r3"] { XCTAssertFalse(try store.isPending(recordName: name, zone: .relay), name) }
    }

    /// A save re-queued as a delete while it is in flight goes out as the delete after it, and the
    /// save never comes back.
    func testASaveRequeuedAsADeleteMidFlushIsNotResurrected() async throws {
        var http: InterceptingRelayHTTP?
        let (mac, phone) = try await hub { base in
            let intercepting = InterceptingRelayHTTP(base)
            http = intercepting
            return intercepting
        }
        let store = try TransportStore.inMemory()
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        let requeued = OSAllocatedUnfairLock(initialState: false)
        try XCTUnwrap(http).answer { request in
            if case .save(let save) = request.op, save.items.first?.record.name == "x",
               requeued.withLock({ done in defer { done = true }; return !done }) {
                try store.enqueueDelete(recordNames: ["x"], zone: .relay)
            }
            return nil
        }
        try await transport.save([mailboxRecord("x")])
        async let first: Void = transport.sendNow()
        async let second: Void = transport.sendNow()
        _ = await (first, second)
        await transport.sendNow()
        let writes = backend.opLog.compactMap { op -> String? in
            switch op {
            case .save(let save): return "save " + save.items.map(\.record.name).joined(separator: ",")
            case .delete(let delete): return "delete " + delete.items.map(\.name).joined(separator: ",")
            default: return nil
            }
        }
        XCTAssertEqual(writes, ["save x", "delete x"])
        XCTAssertFalse(try store.isPending(recordName: "x", zone: .relay))
    }

    /// A resync that expires again after its first page (relay `records.ts` checks the floor on
    /// middle pages) is marked stalled and held until a backoff or `start()`.
    func testAResyncThatExpiresPartwayIsHeld() async throws {
        let (mac, phone) = try await hub()
        let zone = dataZone(mac)
        for name in ["a", "b", "x"] { try await macSave(mac, zone, name) }
        let store = try TransportStore.inMemory()
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        try await transport.pull()
        let floor = try buffered(store, .data).newToken

        // x's purged tombstone (seq 4) is above the resync's first page boundary (seq 1).
        try await macDelete(mac, zone, ["x"])
        manualClock?.advance(by: .seconds(31 * 86_400))
        var limits = try relay.limits
        limits.changesPageBytes = 1
        try relay.limits = limits
        try await transport.pull()
        XCTAssertTrue(try store.relayResyncStalled(.data))
        XCTAssertTrue(try store.relayResyncPending(.data))
        XCTAssertEqual(try store.relayCursor(zone: .data), 1)
        XCTAssertEqual(try buffered(store, .data, since: floor).deletedRecordNames, [], "a stalled resync deletes nothing")

        // Held: the next pull does not ask for the zone.
        let asked = try changesSinces(zone).count
        try await transport.pull()
        XCTAssertEqual(try changesSinces(zone).count, asked, "held")

        // After the backoff it tries again (and stalls again on this relay).
        manualClock?.advance(by: .seconds(HostedRelayTransport.resyncStallHold + 1))
        try await transport.pull()
        let retried = try changesSinces(zone)
        XCTAssertGreaterThan(retried.count, asked)
        XCTAssertEqual(retried.suffix(2), [0, 1], "a fresh resync from 0")
        let held = retried.count
        try await transport.pull()
        XCTAssertEqual(try changesSinces(zone).count, held, "held again")

        // `start()` releases the hold.
        await transport.start()
        await eventually { ((try? self.changesSinces(zone).count) ?? 0) > held }
    }

    /// Upload URLs are checked like download URLs; a non-2xx PUT (a redirect included) fails.
    func testUploadURLsAreCheckedLikeDownloads() async throws {
        var http: InterceptingRelayHTTP?
        let (mac, phone) = try await hub { base in
            let intercepting = InterceptingRelayHTTP(base)
            http = intercepting
            return intercepting
        }
        let intercepting = try XCTUnwrap(http)
        let asset = try directory().appendingPathComponent("sealed")
        try Data(repeating: 1, count: 64).write(to: asset)
        let (transport, _) = try await makeTransport(phone, mac: mac, store: TransportStore.inMemory())

        intercepting.answer { request in
            guard case .createUpload = request.op else { return nil }
            var response = Relay_V1_Response()
            response.upload.attachmentID = "att"
            response.upload.url = "http://relay.example.com/v1/blob/att"
            return response
        }
        let plain = try await transport.save([ConditionalSave(record: mailboxRecord("u1", asset: asset), expect: .absent)])
        XCTAssertEqual(plain, [.refused(.transient(code: "malformed_answer"))])
        XCTAssertEqual(intercepting.puts, [], "no PUT to a URL that leaves HTTPS")

        intercepting.answer(nil)
        intercepting.upload { _ in 302 }
        let redirected = try await transport.save([ConditionalSave(record: mailboxRecord("u2", asset: asset), expect: .absent)])
        XCTAssertEqual(redirected, [.refused(.transient(code: "malformed_answer"))])
        XCTAssertFalse(try savedNames().contains(["u2"]), "no save after a failed upload")
    }

    /// A `.retryLater` at `start()` leaves no socket; the first successful pull after the deadline dials it.
    func testARetryLaterAtStartDialsAfterTheDeadline() async throws {
        _ = try requireFake(Self.needsClock)
        let (mac, _) = try await hub()
        // The same phone in a new process: not registered here yet, no App Attest key in its store.
        let phone = try await makeClient(kind: .phone, seed: 2, register: false)
        fakeAttest(seed: 2).script(.generateKey, failures: [.serverUnavailable])
        let (transport, log) = try await makeTransport(phone, mac: mac, store: TransportStore.inMemory())
        await transport.start()
        await waitForRelayEvent(log, .attestation(.retryLater(after: .seconds(1))))
        XCTAssertFalse(try opNames().contains("subscribe"), "no socket before the deadline")

        manualClock?.advance(by: .seconds(1))
        try await transport.pull()
        await eventually { (try? self.opNames().contains("subscribe")) == true }
    }

    /// `get_account_state` after a connect reports an entitlement that does not pay, and only that.
    func testAccountStateReportsAnInactiveEntitlement() async throws {
        var http: InterceptingRelayHTTP?
        let (mac, phone) = try await hub { base in
            let intercepting = InterceptingRelayHTTP(base)
            http = intercepting
            return intercepting
        }
        let intercepting = try XCTUnwrap(http)
        let (transport, log) = try await makeTransport(phone, mac: mac, store: TransportStore.inMemory())
        // The paying kinds first: an event they raised would come before the three expected ones.
        let kinds: [Relay_V1_EntitlementKind] = [.active, .grace, Relay_V1_EntitlementKind.none, .expired, .revoked]
        for kind in kinds {
            intercepting.answer { request in
                guard case .getAccountState = request.op else { return nil }
                var response = Relay_V1_Response()
                response.accountState.entitlement.state = kind
                return response
            }
            await transport.readAccountState()
        }
        await eventually { log.relayEvents.filter { $0 == .entitlementInactive }.count >= 3 }
        XCTAssertEqual(log.relayEvents.filter { $0 == .entitlementInactive }.count, 3, "none, expired and revoked only")
    }

    // MARK: - Whole-branch review

    /// A row queued while the socket cannot be dialed goes out when it connects, with no
    /// `sendNow()`, `pull()` or `start()` after the save.
    func testAConnectFlushesTheQueue() async throws {
        let (mac, phone) = try await hub()
        let (transport, _) = try await makeTransport(phone, mac: mac, store: TransportStore.inMemory())
        try relay.refuseNextDial(status: 503, times: 2)
        await transport.start()
        XCTAssertFalse(try opNames().contains("subscribe"), "no socket yet")

        try await transport.save([mailboxRecord("queued")])
        await eventually { (try? self.savedNames()) == [["queued"]] }
    }
}
