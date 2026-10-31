import CryptoKit
import Foundation
import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
import XCTest

/// `FakeHostedRelay` driven through `handle`, with requests signed by
/// `Ed25519RelaySigner` and attested by `FakeAppAttest` (relay@3a99bd7 `proto/README.md`).
final class FakeHostedRelayTests: XCTestCase {
    private let origin = "https://relay.example.com"
    private let year: Duration = .seconds(365 * 86_400)
    private var clock = ManualRelayClock()

    // MARK: - Zones

    func testConditionalSaveOutcomesPerItem() async throws {
        let (relay, mac, _) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        let first = try saveResult(relay, mac, [item(zone, "a", "1", mustNotExist: true)])
        XCTAssertEqual(first.saved.map(\.recordSeq), [1])
        XCTAssertEqual(first.saved.first?.zone, zone)
        XCTAssertEqual(first.saved.first?.envelope, Data(), "save answers metadata only")

        let mixed = try saveResult(relay, mac, [
            item(zone, "a", "2", mustNotExist: true),
            item(zone, "b", "3", mustNotExist: true),
            item(zone, "a", "4", expectedSeq: 1),
            item(zone, "c", "5", expectedSeq: 5)
        ])
        XCTAssertEqual(mixed.saved.map(\.name), ["b", "a"])
        XCTAssertEqual(mixed.saved.map(\.recordSeq), [2, 3])
        XCTAssertEqual(mixed.conflicts.map(\.index), [0, 3])
        XCTAssertTrue(mixed.conflicts[0].hasCurrent)
        XCTAssertEqual(mixed.conflicts[0].current.recordSeq, 1)
        XCTAssertEqual(mixed.conflicts[0].current.envelope, Data("1".utf8))
        XCTAssertFalse(mixed.conflicts[1].hasCurrent, "no record, no current")

        // A tombstone counts as absent for must_not_exist.
        _ = try deleteResult(relay, mac, zone, [deleteItem("b")])
        let again = try saveResult(relay, mac, [item(zone, "b", "6", mustNotExist: true)])
        XCTAssertEqual(again.saved.map(\.recordSeq), [5])
        XCTAssertTrue(again.conflicts.isEmpty)
    }

    func testDeleteIsConditionalPerItem() async throws {
        let (relay, mac, _) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        _ = try saveResult(relay, mac, [item(zone, "a", "1"), item(zone, "b", "2")])
        let result = try deleteResult(relay, mac, zone, [
            deleteItem("a", expectedSeq: 9),
            deleteItem("b", expectedSeq: 2),
            deleteItem("missing"),
            deleteItem("missing2", expectedSeq: 1)
        ])
        XCTAssertEqual(result.conflicts.map(\.index), [0, 3])
        XCTAssertEqual(result.conflicts[0].current.recordSeq, 1)
        XCTAssertFalse(result.conflicts[1].hasCurrent)

        let page = try changes(relay, mac, zone, since: 0)
        XCTAssertEqual(page.changed.map(\.name), ["a"])
        XCTAssertEqual(page.deleted, ["b"])
        XCTAssertEqual(page.newSeq, 3)
    }

    func testRecordSeqGrowsPerZone() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        let data = "data/\(mac.id)"
        let mailbox = "relay/\(mac.id)/\(phone.id)"
        let saved = try saveResult(relay, mac, [item(data, "a", "1"), item(mailbox, "m", "2"), item(data, "b", "3")])
        XCTAssertEqual(saved.saved.map(\.recordSeq), [1, 2, 1], "data a, data b, then the mailbox: each zone counts alone")
        XCTAssertEqual(saved.saved.map(\.zone), [data, data, mailbox])
        _ = try deleteResult(relay, mac, data, [deleteItem("a")])
        XCTAssertEqual(try changes(relay, mac, data, since: 0).newSeq, 3)
        XCTAssertEqual(try changes(relay, phone, mailbox, since: 0).newSeq, 1)
    }

    func testChangesPagesByLimitAndBytes() async throws {
        let (relay, mac, _) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        var limits = relay.limits
        limits.maxRecordBytes = 6 << 20
        relay.limits = limits
        let big = String(repeating: "x", count: 3 << 19) // 1.5 MiB
        _ = try saveResult(relay, mac, (0..<3).map { item(zone, "big\($0)", big) })
        let firstPage = try changes(relay, mac, zone, since: 0)
        XCTAssertEqual(firstPage.changed.count, 2, "4 MiB of envelopes per page")
        XCTAssertTrue(firstPage.more)
        let lastPage = try changes(relay, mac, zone, since: firstPage.newSeq)
        XCTAssertEqual(lastPage.changed.map(\.name), ["big2"])
        XCTAssertFalse(lastPage.more)

        _ = try saveResult(relay, mac, [item(zone, "huge", String(repeating: "y", count: 5 << 20))])
        let huge = try changes(relay, mac, zone, since: lastPage.newSeq)
        XCTAssertEqual(huge.changed.map(\.name), ["huge"], "at least one record, whatever its size")

        _ = try saveResult(relay, mac, (0..<501).map { item(zone, "small\($0)", "s") })
        let unset = try changes(relay, mac, zone, since: huge.newSeq)
        XCTAssertEqual(unset.changed.count, 500)
        XCTAssertTrue(unset.more)
        let tooMany = try changes(relay, mac, zone, since: huge.newSeq, limit: 1_000)
        XCTAssertEqual(tooMany.changed.count, 500, "a larger limit is capped at 500")
        let two = try changes(relay, mac, zone, since: huge.newSeq, limit: 2)
        XCTAssertEqual(two.changed.map(\.name), ["small0", "small1"])
        XCTAssertTrue(two.more)
    }

    func testTokenExpiredAboveLastAndBelowPurgedTombstones() async throws {
        let (relay, mac, _) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        _ = try saveResult(relay, mac, [item(zone, "a", "1"), item(zone, "b", "2")])
        XCTAssertEqual(try errorCode(relay, mac, changesOp(zone, since: 3)), .tokenExpired, "above the zone's last seq")
        _ = try deleteResult(relay, mac, zone, [deleteItem("a")])
        XCTAssertNil(try errorCode(relay, mac, changesOp(zone, since: 1)), "the tombstone is still kept")

        clock.advance(by: .seconds(31 * 86_400))
        try await login(relay, mac)
        XCTAssertEqual(try errorCode(relay, mac, changesOp(zone, since: 1)), .tokenExpired, "below a purged tombstone")
        let full = try changes(relay, mac, zone, since: 0)
        XCTAssertEqual(full.changed.map(\.name), ["b"])
        XCTAssertEqual(full.deleted, [], "purged tombstones are gone")
        XCTAssertEqual(full.newSeq, 3)
        XCTAssertNil(try errorCode(relay, mac, changesOp(zone, since: 3)))
    }

    func testPhoneCannotWriteTheDataZone() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        XCTAssertEqual(try errorCode(relay, phone, saveOp([item("data/\(mac.id)", "a", "1")])), .forbidden)
        XCTAssertEqual(try errorCode(relay, phone, deleteOp("data/\(mac.id)", [deleteItem("a")])), .forbidden)
        XCTAssertEqual(try errorCode(relay, phone, saveOp([item("bogus/\(mac.id)", "a", "1")])), .forbidden)
    }

    func testOnlyReadersReadTheDataZone() async throws {
        let (relay, mac, reader) = try await pairedWorld()
        let slotted = try await onboard(relay, .phone, seed: 3)
        try await pay(relay, slotted)
        var add = Relay_V1_AddMacSlot()
        add.macDeviceID = mac.id
        XCTAssertNil(try errorCode(relay, slotted, .addSlot(add)))
        let stranger = try await onboard(relay, .phone, seed: 4)
        try await pay(relay, stranger)

        let zone = "data/\(mac.id)"
        _ = try saveResult(relay, mac, [item(zone, "a", "1")])
        XCTAssertEqual(try changes(relay, reader, zone, since: 0).changed.map(\.name), ["a"])
        XCTAssertEqual(try errorCode(relay, slotted, changesOp(zone, since: 0)), .forbidden, "slotted, not a reader")
        XCTAssertEqual(try errorCode(relay, stranger, changesOp(zone, since: 0)), .forbidden)
    }

    func testLapsedPhoneWriteIsEntitlementInactive() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        let mailbox = "relay/\(mac.id)/\(phone.id)"
        _ = try saveResult(relay, phone, [item(mailbox, "a-1", "action")])
        try await relay.setEntitlement(accountID: phone.accountID, state: "expired", for: .zero)

        XCTAssertEqual(try errorCode(relay, phone, saveOp([item(mailbox, "a-2", "action")])), .entitlementInactive)
        XCTAssertEqual(try errorCode(relay, mac, saveOp([item(mailbox, "c-1", "echo")])), .entitlementInactive)
        XCTAssertEqual(try errorCode(relay, mac, saveOp([item("data/\(mac.id)", "s", "slice")])), .entitlementInactive)
        XCTAssertEqual(try changes(relay, phone, mailbox, since: 0).changed.map(\.name), ["a-1"], "reads stay within the window")
        XCTAssertNil(try errorCode(relay, phone, deleteOp(mailbox, [deleteItem("a-1")])), "deletes ignore payment")
    }

    func testPairZoneRefusesAttachmentsAndCapsBytes() async throws {
        let relay = makeRelay()
        let mac = try await onboard(relay, .mac, seed: 1)
        let phone = try await onboard(relay, .phone, seed: 2)
        try await pay(relay, phone)
        var open = Relay_V1_OpenPairingSlot()
        open.macDeviceID = mac.id
        let opened = try ok(relay, phone, .openPairing(open))
        guard case .pairingSlot(let slot) = opened.result else { return XCTFail("want pairing_slot, got \(opened)") }
        XCTAssertEqual(slot.expiresAtMs, ms(clock.now()) + 600_000)
        XCTAssertEqual(controls(relay, mac), [control(.pairingOpened, slot.slotID)])

        let zone = "pair/\(slot.slotID)"
        var upload = Relay_V1_CreateUpload()
        upload.zone = zone
        upload.size = 10
        XCTAssertEqual(try errorCode(relay, phone, .createUpload(upload)), .forbidden)
        let chunk = String(repeating: "k", count: 600 << 10)
        XCTAssertNil(try errorCode(relay, phone, saveOp([item(zone, "hello", chunk)])))
        XCTAssertEqual(try errorCode(relay, mac, saveOp([item(zone, "keybox", chunk)])), .mailboxQuotaExceeded)
        XCTAssertEqual(try changes(relay, mac, zone, since: 0).changed.map(\.name), ["hello"])

        let stranger = try await onboard(relay, .phone, seed: 3)
        XCTAssertEqual(try errorCode(relay, stranger, changesOp(zone, since: 0)), .forbidden)

        clock.advance(by: .seconds(601))
        var promote = Relay_V1_PromotePairing()
        promote.slotID = slot.slotID
        XCTAssertEqual(try errorCode(relay, phone, .promotePairing(promote)), .pairingExpired)
        XCTAssertEqual(try errorCode(relay, mac, changesOp(zone, since: 0)), .forbidden, "an expired pairing admits nobody")
    }

    func testMailboxRecordsExpireAfter14Days() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        let mailbox = "relay/\(mac.id)/\(phone.id)"
        _ = try saveResult(relay, mac, [item(mailbox, "c-1", "hub"), item("data/\(mac.id)", "slice", "s")])
        clock.advance(by: .seconds(14 * 86_400 + 1))
        try await login(relay, mac)
        try await login(relay, phone)
        let page = try changes(relay, phone, mailbox, since: 0)
        XCTAssertEqual(page.changed, [])
        XCTAssertEqual(page.deleted, ["c-1"])
        XCTAssertEqual(try changes(relay, phone, "data/\(mac.id)", since: 0).changed.map(\.name), ["slice"], "the data zone has no TTL")

        // The stand's /dev/expire-mailboxes: expire as if the time had passed.
        _ = try saveResult(relay, phone, [item(mailbox, "a-1", "action")])
        try await relay.expireMailboxes([mailbox], elapsed: .seconds(14 * 86_400 + 1))
        XCTAssertEqual(try changes(relay, phone, mailbox, since: page.newSeq).deleted, ["a-1"])
    }

    func testRemoveSlotAnswersUnavailableUntilDelivered() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        relay.holdRevocations = true
        _ = controls(relay, phone)
        _ = controls(relay, mac)
        var remove = Relay_V1_RemoveMacSlot()
        remove.phoneDeviceID = phone.id
        remove.macDeviceID = mac.id
        XCTAssertNil(try errorCode(relay, phone, .removeSlot(remove)))
        XCTAssertEqual(controls(relay, phone), [control(.slotRemoved, mac.id)])
        XCTAssertEqual(controls(relay, mac), [control(.slotRemoved, phone.id)])
        XCTAssertEqual(try errorCode(relay, phone, .removeSlot(remove)), .unavailable)
        XCTAssertEqual(try errorCode(relay, mac, .removeSlot(remove)), .unavailable, "the Mac may remove itself too")

        relay.markRevocationsDelivered()
        XCTAssertNil(try errorCode(relay, phone, .removeSlot(remove)))

        clock.advance(by: .seconds(86_401))
        try await login(relay, phone)
        XCTAssertEqual(try errorCode(relay, phone, .removeSlot(remove)), .notFound, "remembered for 24 h only")
    }

    func testRetriedRemoveSlotAnswersOkByDefault() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        XCTAssertNil(try errorCode(relay, phone, .removeSlot(removeOp(phone, mac))))
        XCTAssertNil(try errorCode(relay, phone, .removeSlot(removeOp(phone, mac))), "delivered at once, as on the stand")
        XCTAssertNil(try errorCode(relay, mac, .removeSlot(removeOp(phone, mac))))
    }

    func testRemovedSlotDropsTheHubReader() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        XCTAssertNil(try errorCode(relay, phone, changesOp(zone, since: 0)))
        XCTAssertNil(try errorCode(relay, phone, .removeSlot(removeOp(phone, mac))))
        XCTAssertNil(try errorCode(relay, phone, addSlotOp(mac)))
        XCTAssertEqual(try errorCode(relay, phone, changesOp(zone, since: 0)), .forbidden, "back in the slots, not a reader")
        var readers = Relay_V1_SetHubReaders()
        readers.phoneDeviceIds = [phone.id]
        XCTAssertNil(try errorCode(relay, mac, .setHubReaders(readers)))
        XCTAssertNil(try errorCode(relay, phone, changesOp(zone, since: 0)))
    }

    func testLazyMailboxExpiryPurgesAtTheStandsTime() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        let mailbox = "relay/\(mac.id)/\(phone.id)"
        _ = try saveResult(relay, mac, [item(mailbox, "c-1", "hub"), item(mailbox, "c-2", "hub")])
        let seen = try changes(relay, phone, mailbox, since: 0).newSeq
        // Expired at day 14, so purged at day 44, though nobody looked at the zone in between.
        clock.advance(by: .seconds(44 * 86_400 + 1))
        try await login(relay, phone)
        XCTAssertEqual(try errorCode(relay, phone, changesOp(mailbox, since: seen)), .tokenExpired)
    }

    func testSlotLimit() async throws {
        let relay = makeRelay()
        let phone = try await onboard(relay, .phone, seed: 2)
        try await pay(relay, phone)
        for seed: UInt8 in 10...12 {
            let mac = try await onboard(relay, .mac, seed: seed)
            XCTAssertNil(try errorCode(relay, phone, addSlotOp(mac)))
        }
        let fourth = try await onboard(relay, .mac, seed: 13)
        XCTAssertEqual(try errorCode(relay, phone, addSlotOp(fourth)), .slotLimit)
    }

    func testSlotReplacementLimit() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        for _ in 0..<5 {
            XCTAssertNil(try errorCode(relay, phone, .removeSlot(removeOp(phone, mac))))
            XCTAssertNil(try errorCode(relay, phone, addSlotOp(mac)))
        }
        XCTAssertNil(try errorCode(relay, phone, .removeSlot(removeOp(phone, mac))))
        XCTAssertEqual(try errorCode(relay, phone, addSlotOp(mac)), .slotReplacementLimit)
    }

    func testRecordTooLargeAndTheBodyLimit() async throws {
        let (relay, mac, _) = try await pairedWorld()
        var limits = relay.limits
        limits.maxRecordBytes = 1_024
        relay.limits = limits
        let zone = "data/\(mac.id)"
        XCTAssertEqual(try errorCode(relay, mac, saveOp([item(zone, "a", String(repeating: "x", count: 1_025))])), .recordTooLarge)
        let (status, response) = relay.handle(request(saveOp([item(zone, "a", String(repeating: "x", count: 70 << 10))])), bearer: mac.token)
        XCTAssertEqual(status, 413)
        XCTAssertEqual(code(response), .recordTooLarge)
    }

    func testMailboxQuotaSpansThePhonesMailboxes() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        let other = try await onboard(relay, .mac, seed: 5)
        try await relay.pair(mac: other.id, phones: [phone.id])
        var limits = relay.limits
        limits.mailboxQuotaBytes = 100
        relay.limits = limits
        let body = String(repeating: "m", count: 60)
        XCTAssertNil(try errorCode(relay, phone, saveOp([item("relay/\(mac.id)/\(phone.id)", "a-1", body)])))
        XCTAssertEqual(
            try errorCode(relay, phone, saveOp([item("relay/\(other.id)/\(phone.id)", "a-1", body)])), .mailboxQuotaExceeded
        )
    }

    func testHubQuota() async throws {
        let (relay, mac, _) = try await pairedWorld()
        var limits = relay.limits
        limits.hubQuotaBytes = 100
        relay.limits = limits
        let zone = "data/\(mac.id)"
        XCTAssertNil(try errorCode(relay, mac, saveOp([item(zone, "a", String(repeating: "h", count: 60))])))
        XCTAssertEqual(try errorCode(relay, mac, saveOp([item(zone, "b", String(repeating: "h", count: 60))])), .hubQuotaExceeded)
        XCTAssertEqual(try errorCode(relay, mac, uploadOp(zone, size: 50)), .hubQuotaExceeded, "attachments count too")
    }

    func testAttachmentRules() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        XCTAssertEqual(try errorCode(relay, mac, uploadOp(zone, size: 0)), .unspecified)
        XCTAssertEqual(try errorCode(relay, mac, uploadOp(zone, size: UInt64(100 << 20) + 1)), .attachmentTooLarge)
        XCTAssertEqual(try errorCode(relay, phone, uploadOp(zone, size: 10)), .forbidden, "the phone cannot write the data zone")
        let x = try await upload(relay, mac, zone)
        XCTAssertEqual(x.url, "https://relay.example.com/v1/blob/\(x.attachmentID)")
        XCTAssertEqual(try errorCode(relay, mac, saveOp([item(zone, "a", "1", attachment: "missing")])), .notFound)
        _ = try saveResult(relay, mac, [item(zone, "a", "1", attachment: x.attachmentID)])
        XCTAssertEqual(try errorCode(relay, mac, saveOp([item(zone, "b", "2", attachment: x.attachmentID)])), .conflict, "one live record")
        XCTAssertNil(try errorCode(relay, phone, downloadOp(zone, x.attachmentID)))
        _ = try saveResult(relay, mac, [item(zone, "a", "3")])
        XCTAssertEqual(try errorCode(relay, phone, downloadOp(zone, x.attachmentID)), .notFound, "the overwrite dropped it")
    }

    func testAttachmentMovesBetweenRecordsInOneSave() async throws {
        let (relay, mac, _) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        let x = try await upload(relay, mac, zone)
        _ = try saveResult(relay, mac, [item(zone, "a", "1", attachment: x.attachmentID)])
        let moved = try saveResult(relay, mac, [item(zone, "a", "2"), item(zone, "b", "3", attachment: x.attachmentID)])
        XCTAssertEqual(moved.saved.map(\.attachmentID), ["", x.attachmentID])
        XCTAssertNil(try errorCode(relay, mac, downloadOp(zone, x.attachmentID)), "b holds it, so it stays")
    }

    func testAttachmentCommitsOnlyAfterItsUpload() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        guard case .upload(let x) = try ok(relay, mac, uploadOp(zone, size: 4)).result else { return XCTFail("want an upload") }
        let url = try XCTUnwrap(URL(string: x.url))
        XCTAssertEqual(try errorCode(relay, mac, saveOp([item(zone, "a", "1", attachment: x.attachmentID)])), .notFound, "nothing uploaded yet")
        let tooLong = try await relay.http.put(url, file: try file(Data("abcde".utf8)), headers: [:])
        XCTAssertEqual(tooLong, 413)
        let tooShort = try await relay.http.put(url, file: try file(Data("abc".utf8)), headers: [:])
        XCTAssertEqual(tooShort, 400)
        XCTAssertEqual(try errorCode(relay, phone, downloadOp(zone, x.attachmentID)), .notFound, "not committed")

        let stored = try await relay.http.put(url, file: try file(Data("abcd".utf8)), headers: [:])
        XCTAssertEqual(stored, 200)
        _ = try saveResult(relay, mac, [item(zone, "a", "1", attachment: x.attachmentID)])
        guard case .download(let download) = try ok(relay, phone, downloadOp(zone, x.attachmentID)).result else { return XCTFail("want a download") }
        let out = try file(nil)
        let tooSmall = try? await relay.http.get(try XCTUnwrap(URL(string: download.url)), to: out, maxBytes: 3, headers: [:])
        XCTAssertNil(tooSmall, "past maxBytes")
        let got = try await relay.http.get(try XCTUnwrap(URL(string: download.url)), to: out, maxBytes: 4, headers: [:])
        XCTAssertEqual(got, 200)
        XCTAssertEqual(try Data(contentsOf: out), Data("abcd".utf8))

        _ = try saveResult(relay, mac, [item(zone, "a", "2")])
        let gone = try await relay.http.get(url, to: try file(nil), maxBytes: 4, headers: [:])
        XCTAssertEqual(gone, 404, "the overwrite dropped it")
    }

    // MARK: - Network seams

    func testOpOverHTTPChecksTheProtocolVersion() async throws {
        let relay = makeRelay()
        let url = try XCTUnwrap(URL(string: "\(origin)/v1/op"))
        let body = try request(.challenge(challengeOp(device(.phone, seed: 2), .register))).serializedData()
        let missing = try await relay.http.post(url, body: body, headers: [:])
        XCTAssertEqual(missing.status, 400)
        XCTAssertEqual(code(try Relay_V1_Response(serializedBytes: missing.body)), .unsupportedVersion)
        let fine = try await relay.http.post(url, body: body, headers: ["Relay-Protocol-Version": "1"])
        XCTAssertEqual(fine.status, 200)
        XCTAssertNil(code(try Relay_V1_Response(serializedBytes: fine.body)))
        let unauthenticated = try await relay.http.post(
            url, body: try request(.getAccountState(.init())).serializedData(), headers: ["Relay-Protocol-Version": "1"]
        )
        XCTAssertEqual(unauthenticated.status, 401)
    }

    func testHeaderNamesAreCaseInsensitive() async throws {
        let (relay, _, phone) = try await pairedWorld()
        let url = try XCTUnwrap(URL(string: "\(origin)/v1/op"))
        let body = try request(.getAccountState(.init())).serializedData()
        let answer = try await relay.http.post(url, body: body, headers: ["relay-protocol-version": "1", "authorization": "Bearer \(phone.token)"])
        XCTAssertEqual(answer.status, 200)
        XCTAssertNil(code(try Relay_V1_Response(serializedBytes: answer.body)))
        _ = try await relay.sockets.dial(Self.socketURL, headers: ["AUTHORIZATION": "Bearer \(phone.token)"])
    }

    func testSocketHelloSubscribeAndZoneEvents() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        let url = try XCTUnwrap(URL(string: "wss://relay.example.com/v1/ws"))
        let bearer = ["Authorization": "Bearer \(phone.token)"]
        do {
            _ = try await relay.sockets.dial(url, headers: [:])
            XCTFail("an upgrade without a token is refused")
        } catch {
            XCTAssertEqual(error as? RelayDialError, .http(status: 401))
        }
        let mismatched = try await relay.sockets.dial(url, headers: bearer)
        try await mismatched.send(hello("another token"))
        let refused = try await mismatched.receive()
        XCTAssertEqual(refused, .closed(code: 4001))

        let socket = try await relay.sockets.dial(url, headers: bearer)
        try await socket.send(hello(phone.token))
        guard case .helloOk = try await frame(socket).kind else { return XCTFail("want HelloOk") }
        var subscribe = Relay_V1_Frame()
        subscribe.request = request(.subscribe(Relay_V1_Subscribe.with { $0.zones = [zone] }))
        try await socket.send(subscribe.serializedData())
        let answer = try await frame(socket).response
        XCTAssertEqual(answer.id, 7)
        XCTAssertNil(code(answer))

        _ = try saveResult(relay, mac, [item(zone, "small", "s")])
        let small = try await frame(socket).event.zoneChanged
        XCTAssertEqual(small.seq, 1)
        XCTAssertEqual(small.record.name, "small")
        XCTAssertEqual(small.record.envelope, Data("s".utf8))
        _ = try saveResult(relay, mac, [item(zone, "big", String(repeating: "b", count: (64 << 10) + 1))])
        let big = try await frame(socket).event.zoneChanged
        XCTAssertEqual(big.seq, 2)
        XCTAssertFalse(big.hasRecord, "over 64 KiB: no record inline")
        _ = try saveResult(relay, mac, [item(zone, "x", "1"), item(zone, "y", "2")])
        let two = try await frame(socket).event.zoneChanged
        XCTAssertEqual(two.seq, 4)
        XCTAssertFalse(two.hasRecord, "two records: no record inline")

        // A control goes to the live socket, not to the queue.
        try await relay.setEntitlement(accountID: phone.accountID, state: "expired", for: .zero)
        let expired = try await frame(socket).event.control
        XCTAssertEqual(expired, control(.entitlementExpired, ""))
        XCTAssertEqual(controls(relay, phone), [])

        // A newer socket of the device displaces this one: GoingAway, then 1001.
        _ = try await relay.sockets.dial(url, headers: bearer)
        guard case .goingAway = try await frame(socket).kind else { return XCTFail("want GoingAway") }
        let closed = try await socket.receive()
        XCTAssertEqual(closed, .closed(code: 1001))
    }

    func testDeleteFansOutABareZoneChanged() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        _ = try saveResult(relay, mac, [item(zone, "a", "1")])
        let socket = try await liveSocket(relay, phone, subscribe: [zone])
        _ = try deleteResult(relay, mac, zone, [deleteItem("a")])
        let deleted = try await frame(socket).event.zoneChanged
        XCTAssertEqual(deleted.seq, 2)
        XCTAssertFalse(deleted.hasRecord, "a tombstone is never inlined")
    }

    // MARK: - Faults

    func testFailNextAnswersNTimesThenClears() async throws {
        let (relay, _, phone) = try await pairedWorld()
        relay.failNext("getAccountState", with: .unavailable, times: 2)
        XCTAssertEqual(try errorCode(relay, phone, .getAccountState(.init())), .unavailable)
        XCTAssertEqual(try errorCode(relay, phone, .getAccountState(.init())), .unavailable)
        XCTAssertNil(try errorCode(relay, phone, .getAccountState(.init())))
    }

    func testRefuseNextDialThrowsNTimes() async throws {
        let (relay, _, phone) = try await pairedWorld()
        relay.refuseNextDial(status: 503, times: 2)
        for _ in 0..<2 {
            do {
                _ = try await relay.sockets.dial(Self.socketURL, headers: ["Authorization": "Bearer \(phone.token)"])
                XCTFail("refused")
            } catch {
                XCTAssertEqual(error as? RelayDialError, .http(status: 503))
            }
        }
        _ = try await relay.sockets.dial(Self.socketURL, headers: ["Authorization": "Bearer \(phone.token)"])
    }

    func testPingWithoutPongsHangsUntilTheSocketCloses() async throws {
        let (relay, _, phone) = try await pairedWorld()
        let socket = try await liveSocket(relay, phone, subscribe: [])
        try await socket.ping()
        relay.setPongs(false)
        let pinging = Task { try await socket.ping() }
        for _ in 0..<200 { await Task.yield() }
        relay.deploy()
        do {
            try await pinging.value
            XCTFail("a ping without a pong must not return")
        } catch {}
    }

    func testSilencedSubscribeGetsNoResponseOnce() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        let zone = "data/\(mac.id)"
        let socket = try await liveSocket(relay, phone, subscribe: [])
        relay.silenceSubscribe(zone: zone)
        try await socket.send(subscribeFrame([zone], id: 1))
        try await socket.send(subscribeFrame([zone], id: 2))
        let answer = try await frame(socket).response
        XCTAssertEqual(answer.id, 2, "the silenced subscribe got no answer")
        XCTAssertNil(code(answer))
    }

    func testDisplaceSendsGoingAwayThen1001() async throws {
        let (relay, _, phone) = try await pairedWorld()
        let socket = try await liveSocket(relay, phone, subscribe: [])
        relay.displace(deviceID: phone.id)
        guard case .goingAway = try await frame(socket).kind else { return XCTFail("want GoingAway") }
        let closed = try await socket.receive()
        XCTAssertEqual(closed, .closed(code: 1001))
    }

    func testSendAlert() async throws {
        let (relay, mac, phone) = try await pairedWorld()
        var alert = Relay_V1_SendAlert()
        alert.phoneDeviceID = phone.id
        alert.envelope = Data(repeating: 1, count: 100)
        XCTAssertEqual(try errorCode(relay, mac, .sendAlert(alert)), .notFound, "no push token")
        var push = Relay_V1_RegisterPushToken()
        push.token = "ab12"
        push.env = .sandbox
        XCTAssertNil(try errorCode(relay, phone, .registerPush(push)))
        XCTAssertNil(try errorCode(relay, mac, .sendAlert(alert)))
        alert.envelope = Data(repeating: 1, count: 3_100)
        XCTAssertEqual(try errorCode(relay, mac, .sendAlert(alert)), .recordTooLarge, "over the 4096-byte push")
    }

    func testSetEntitlementDurations() async throws {
        let relay = makeRelay()
        let phone = try await onboard(relay, .phone, seed: 2)
        do {
            try await relay.setEntitlement(accountID: phone.accountID, state: "active", for: .seconds(-1))
            XCTFail("a negative duration is the stand's 400")
        } catch {
            XCTAssertEqual(error as? RelayStandError, .invalid)
        }
        try await relay.setEntitlement(accountID: phone.accountID, state: "expired", for: .seconds(86_400))
        guard case .accountState(let state) = try ok(relay, phone, .getAccountState(.init())).result else { return XCTFail("state") }
        XCTAssertEqual(state.entitlement.state, .expired)
        XCTAssertEqual(state.entitlement.untilMs, ms(clock.now()) + 86_400_000)
    }

    func testMoveSubscription() async throws {
        let relay = makeRelay()
        let from = try await onboard(relay, .phone, seed: 2)
        let target = try await onboard(relay, .phone, seed: 3)
        try await pay(relay, from)
        try await pay(relay, target)
        let macs = [try await onboard(relay, .mac, seed: 10), try await onboard(relay, .mac, seed: 11)]
        for mac in macs { try await relay.pair(mac: mac.id, phones: [from.id]) }
        for seed: UInt8 in 12...13 { try await relay.pair(mac: try await onboard(relay, .mac, seed: seed).id, phones: [target.id]) }
        var open = Relay_V1_OpenPairingSlot()
        open.macDeviceID = macs[0].id
        guard case .pairingSlot(let slot) = try ok(relay, from, .openPairing(open)).result else { return XCTFail("want a slot") }
        _ = controls(relay, from)

        try relay.moveSubscription(fromPhone: from.id, toPhone: target.id)
        XCTAssertEqual(controls(relay, from), [control(.subscriptionMoved, "")])
        guard case .accountState(let old) = try ok(relay, from, .getAccountState(.init())).result else { return XCTFail("state") }
        XCTAssertTrue(old.moved)
        XCTAssertEqual(old.entitlement.state, .none)
        XCTAssertEqual(old.macDeviceIds, [])
        guard case .accountState(let new) = try ok(relay, target, .getAccountState(.init())).result else { return XCTFail("state") }
        XCTAssertEqual(new.macDeviceIds.count, 3, "adopted up to the slot limit")
        XCTAssertEqual(new.entitlement.state, .active)
        var close = Relay_V1_ClosePairingSlot()
        close.slotID = slot.slotID
        XCTAssertEqual(try errorCode(relay, from, .closePairing(close)), .notFound, "the move closed the pairing")
        XCTAssertEqual(try errorCode(relay, from, changesOp("data/\(macs[0].id)", since: 0)), .forbidden)
    }

    func testEntitlementExpiredControlNamesThePhoneForMacs() async throws {
        let relay = makeRelay()
        let phone = try await onboard(relay, .phone, seed: 2)
        let macA = try await onboard(relay, .mac, seed: 1)
        let macB = try await onboard(relay, .mac, seed: 5)
        try await pay(relay, phone)
        try await relay.pair(mac: macA.id, phones: [phone.id])
        try await relay.pair(mac: macB.id, phones: [phone.id])

        try await relay.setEntitlement(accountID: phone.accountID, state: "expired", for: .zero)
        XCTAssertEqual(controls(relay, phone), [control(.entitlementExpired, "")])
        XCTAssertEqual(controls(relay, macA), [control(.entitlementExpired, phone.id)])
        XCTAssertEqual(controls(relay, macB), [control(.entitlementExpired, phone.id)])

        guard case .accountState(let phoneState) = try ok(relay, phone, .getAccountState(.init())).result else {
            return XCTFail("want account_state")
        }
        XCTAssertEqual(phoneState.entitlement.state, .expired)
        XCTAssertEqual(phoneState.macDeviceIds, [macA.id, macB.id].sorted())
        guard case .accountState(let macState) = try ok(relay, macA, .getAccountState(.init())).result else {
            return XCTFail("want account_state")
        }
        XCTAssertEqual(macState.phones.map(\.phoneDeviceID), [phone.id])
        XCTAssertEqual(macState.phones.map(\.paying), [false])
    }

    // MARK: - Attestation (enforce)

    func testRegisterWithoutAttestationIsRequired() async throws {
        let relay = makeRelay()
        let phone = device(.phone, seed: 2)
        let nonce = try registerNonce(relay, phone)
        let (status, response) = relay.handle(request(.register(registerOp(phone, nonce: nonce))), bearer: nil)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(code(response), .attestationRequired)
        XCTAssertEqual(try errorCode(relay, nil, .challenge(challengeOp(phone, .login))), .unauthenticated, "nothing was created")
    }

    func testRegisterHashMismatchFails() async throws {
        let relay = makeRelay()
        let phone = device(.phone, seed: 2)
        let nonce = try registerNonce(relay, phone)
        let keyID = try await phone.attest.generateKey()
        var attestation = Relay_V1_Attestation()
        attestation.appAttest.keyID = try XCTUnwrap(Data(base64Encoded: keyID))
        attestation.appAttest.attestationObject = try await phone.attest.attestKey(keyID, clientDataHash: Data(repeating: 7, count: 32))
        XCTAssertEqual(try errorCode(relay, nil, .register(registerOp(phone, nonce: nonce, attestation: attestation))), .attestationFailed)

        // The attested key id must be the one in the request.
        let right = registerHash(phone, nonce: nonce)
        attestation.appAttest.attestationObject = try await phone.attest.attestKey(keyID, clientDataHash: right)
        attestation.appAttest.keyID = Data(repeating: 9, count: 32)
        XCTAssertEqual(try errorCode(relay, nil, .register(registerOp(phone, nonce: nonce, attestation: attestation))), .attestationFailed)
    }

    func testAssertionCounterMustGrow() async throws {
        let relay = makeRelay()
        let phone = try await onboard(relay, .phone, seed: 2) // logged in with counter 1
        let nonce = try loginNonce(relay, phone)
        let hash = RelayAuthMessages.loginClientDataHash(nonce: nonce, deviceID: phone.id, origin: try RelayOrigin(origin))
        var attestation = Relay_V1_Attestation()
        attestation.appAttestAssertion.assertion = try JSONSerialization.data(
            withJSONObject: ["key_id": try XCTUnwrap(phone.keyID), "client_data_hash": hash.base64EncodedString(), "counter": 1],
            options: [.sortedKeys]
        )
        XCTAssertEqual(try errorCode(relay, nil, .login(loginOp(phone, nonce: nonce, attestation: attestation))), .attestationFailed)
        try await login(relay, phone) // counter 2
    }

    func testAssertionWithoutStoredKeyFails() async throws {
        let relay = makeRelay(attest: .off)
        let phone = device(.phone, seed: 2)
        try register(relay, phone, attestation: nil)
        relay.attestMode = .enforce(exemptDeviceIDs: [])

        phone.keyID = try await phone.attest.generateKey()
        let nonce = try loginNonce(relay, phone)
        let assertion = try await assertion(phone, nonce: nonce)
        XCTAssertEqual(try errorCode(relay, nil, .login(loginOp(phone, nonce: nonce, attestation: assertion))), .attestationFailed)
        let plain = try loginNonce(relay, phone)
        XCTAssertEqual(try errorCode(relay, nil, .login(loginOp(phone, nonce: plain))), .attestationRequired)

        // The lost-key path: a fresh attestation over the login hash stores the key.
        let fresh = try loginNonce(relay, phone)
        let attestation = try await freshAttestation(phone, hash: loginHash(phone, nonce: fresh))
        XCTAssertNil(try errorCode(relay, nil, .login(loginOp(phone, nonce: fresh, attestation: attestation))))
        try await login(relay, phone)
    }

    func testWrongSignatureIsUnauthenticatedWhateverTheAttestation() async throws {
        let relay = makeRelay()
        let phone = try await onboard(relay, .phone, seed: 2)
        let impostor = Ed25519RelaySigner(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 99, count: 32)))

        let withAssertion = try loginNonce(relay, phone)
        var op = loginOp(phone, nonce: withAssertion, attestation: try await assertion(phone, nonce: withAssertion))
        op.signature = try impostor.sign(loginMessage(phone, nonce: withAssertion))
        let (status, response) = relay.handle(request(.login(op)), bearer: nil)
        XCTAssertEqual(status, 401)
        XCTAssertEqual(code(response), .unauthenticated)

        let withFresh = try loginNonce(relay, phone)
        op = loginOp(phone, nonce: withFresh, attestation: try await freshAttestation(phone, hash: loginHash(phone, nonce: withFresh)))
        op.signature = Data(repeating: 1, count: 64)
        XCTAssertEqual(try errorCode(relay, nil, .login(op)), .unauthenticated)

        let bare = try loginNonce(relay, phone)
        op = loginOp(phone, nonce: bare)
        op.signature = Data(repeating: 1, count: 64)
        XCTAssertEqual(try errorCode(relay, nil, .login(op)), .unauthenticated)
        XCTAssertEqual(
            try errorCode(relay, nil, .login(loginOp(phone, nonce: bare))), .unauthenticated, "a failed login burns its nonce"
        )
    }

    /// R20: the Worker verifies a fresh `app_attest` before the signature (`worker/src/http/op.ts`).
    func testBadFreshAttestationFailsBeforeTheSignature() async throws {
        let relay = makeRelay()
        let phone = try await onboard(relay, .phone, seed: 2)
        let nonce = try loginNonce(relay, phone)
        let storedKey = phone.keyID
        var op = loginOp(phone, nonce: nonce, attestation: try await freshAttestation(phone, hash: Data(repeating: 7, count: 32)))
        op.signature = Data(repeating: 1, count: 64)
        XCTAssertEqual(try errorCode(relay, nil, .login(op)), .attestationFailed)
        phone.keyID = storedKey
        let assertion = try await assertion(phone, nonce: nonce)
        XCTAssertNil(
            try errorCode(relay, nil, .login(loginOp(phone, nonce: nonce, attestation: assertion))),
            "the refused attestation did not burn the nonce"
        )
    }

    func testOffModeIgnoresAttestation() async throws {
        let relay = makeRelay(attest: .off)
        let phone = device(.phone, seed: 2)
        try register(relay, phone, attestation: nil)
        let nonce = try loginNonce(relay, phone)
        var junk = Relay_V1_Attestation()
        junk.appAttestAssertion.assertion = Data("junk".utf8)
        XCTAssertNil(try errorCode(relay, nil, .login(loginOp(phone, nonce: nonce, attestation: junk))))
        let plain = try loginNonce(relay, phone)
        XCTAssertNil(try errorCode(relay, nil, .login(loginOp(phone, nonce: plain))))
    }

    func testExemptMacRegistersWithoutAttestation() async throws {
        let mac = device(.mac, seed: 1)
        let relay = makeRelay(attest: .enforce(exemptDeviceIDs: [mac.id]))
        let registered = try register(relay, mac, attestation: nil)
        XCTAssertEqual(registered.accountID, "", "a Mac has no account")
        let nonce = try loginNonce(relay, mac)
        XCTAssertNil(try errorCode(relay, nil, .login(loginOp(mac, nonce: nonce))))

        let phone = device(.phone, seed: 2)
        let phoneNonce = try registerNonce(relay, phone)
        XCTAssertEqual(try errorCode(relay, nil, .register(registerOp(phone, nonce: phoneNonce))), .attestationRequired)
        let otherMac = device(.mac, seed: 6)
        let macNonce = try registerNonce(relay, otherMac)
        XCTAssertEqual(try errorCode(relay, nil, .register(registerOp(otherMac, nonce: macNonce))), .attestationRequired)
        XCTAssertFalse(relay.log.isEmpty)
    }

    // MARK: - Devices

    private final class Device {
        let kind: Relay_V1_DeviceKind
        let signer: Ed25519RelaySigner
        let attest = FakeAppAttest()
        var keyID: String?
        var token = ""
        var accountID = ""

        init(kind: Relay_V1_DeviceKind, seed: UInt8) {
            self.kind = kind
            // A 32-byte seed is always a valid Ed25519 private key.
            // swiftlint:disable:next force_try
            signer = Ed25519RelaySigner(try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32)))
        }

        var id: String {
            RelayAuthMessages.deviceID(publicKey: signer.publicKey)
        }
    }

    private func makeRelay(attest: FakeHostedRelay.AttestMode = .enforce(exemptDeviceIDs: [])) -> FakeHostedRelay {
        clock = ManualRelayClock()
        return FakeHostedRelay(origin: origin, attest: attest, clock: clock)
    }

    private func device(_ kind: Relay_V1_DeviceKind, seed: UInt8) -> Device {
        Device(kind: kind, seed: seed)
    }

    /// A relay in enforce mode with a paying phone, and a Mac in its slots whose data zone the phone reads.
    private func pairedWorld() async throws -> (FakeHostedRelay, Device, Device) {
        let relay = makeRelay()
        let mac = try await onboard(relay, .mac, seed: 1)
        let phone = try await onboard(relay, .phone, seed: 2)
        try await pay(relay, phone)
        try await relay.pair(mac: mac.id, phones: [phone.id])
        return (relay, mac, phone)
    }

    private func onboard(_ relay: FakeHostedRelay, _ kind: Relay_V1_DeviceKind, seed: UInt8) async throws -> Device {
        let device = device(kind, seed: seed)
        let nonce = try registerNonce(relay, device)
        let attestation = try await freshAttestation(device, hash: registerHash(device, nonce: nonce))
        try register(relay, device, attestation: attestation, nonce: nonce)
        try await login(relay, device)
        return device
    }

    private func pay(_ relay: FakeHostedRelay, _ phone: Device) async throws {
        let accountID = try await relay.accountID(ofPhone: phone.id)
        XCTAssertEqual(accountID, phone.accountID)
        try await relay.setEntitlement(accountID: phone.accountID, state: "active", for: year)
    }

    @discardableResult
    private func register(
        _ relay: FakeHostedRelay, _ device: Device, attestation: Relay_V1_Attestation?, nonce: Data? = nil
    ) throws -> Relay_V1_DeviceRegistered {
        let nonce = try nonce ?? registerNonce(relay, device)
        let response = relay.handle(request(.register(registerOp(device, nonce: nonce, attestation: attestation))), bearer: nil).response
        guard case .registered(let registered) = response.result else { throw Failure.unexpected("\(response)") }
        XCTAssertEqual(registered.deviceID, device.id)
        device.accountID = registered.accountID
        return registered
    }

    /// Logs in with an assertion by the stored key.
    private func login(_ relay: FakeHostedRelay, _ device: Device) async throws {
        let nonce = try loginNonce(relay, device)
        let attestation = try await assertion(device, nonce: nonce)
        let response = relay.handle(request(.login(loginOp(device, nonce: nonce, attestation: attestation))), bearer: nil)
        guard case .session(let session) = response.response.result else { throw Failure.unexpected("\(response.response)") }
        XCTAssertEqual(session.expiresAtMs, ms(clock.now()) + 15 * 60_000)
        device.token = session.token
    }

    private func freshAttestation(_ device: Device, hash: Data) async throws -> Relay_V1_Attestation {
        let keyID = try await device.attest.generateKey()
        device.keyID = keyID
        var attestation = Relay_V1_Attestation()
        attestation.appAttest.keyID = try XCTUnwrap(Data(base64Encoded: keyID))
        attestation.appAttest.attestationObject = try await device.attest.attestKey(keyID, clientDataHash: hash)
        return attestation
    }

    private func assertion(_ device: Device, nonce: Data) async throws -> Relay_V1_Attestation {
        let keyID = try XCTUnwrap(device.keyID)
        var attestation = Relay_V1_Attestation()
        attestation.appAttestAssertion.assertion = try await device.attest.generateAssertion(keyID, clientDataHash: loginHash(device, nonce: nonce))
        return attestation
    }

    // MARK: - Requests

    private enum Failure: Error {
        case unexpected(String)
    }

    private func request(_ op: Relay_V1_Request.OneOf_Op) -> Relay_V1_Request {
        var request = Relay_V1_Request()
        request.id = 7
        request.op = op
        return request
    }

    private func challengeOp(_ device: Device, _ purpose: Relay_V1_ChallengePurpose) -> Relay_V1_GetChallenge {
        var challenge = Relay_V1_GetChallenge()
        challenge.deviceID = device.id
        challenge.purpose = purpose
        return challenge
    }

    private func nonce(_ relay: FakeHostedRelay, _ device: Device, _ purpose: Relay_V1_ChallengePurpose) throws -> Data {
        let response = relay.handle(request(.challenge(challengeOp(device, purpose))), bearer: nil).response
        guard case .challenge(let challenge) = response.result else { throw Failure.unexpected("\(response)") }
        return challenge.nonce
    }

    private func registerNonce(_ relay: FakeHostedRelay, _ device: Device) throws -> Data {
        try nonce(relay, device, .register)
    }

    private func loginNonce(_ relay: FakeHostedRelay, _ device: Device) throws -> Data {
        try nonce(relay, device, .login)
    }

    private func registerHash(_ device: Device, nonce: Data) -> Data {
        // swiftlint:disable:next force_try
        RelayAuthMessages.registerClientDataHash(nonce: nonce, authPub: device.signer.publicKey, origin: try! RelayOrigin(origin))
    }

    private func loginHash(_ device: Device, nonce: Data) -> Data {
        // swiftlint:disable:next force_try
        RelayAuthMessages.loginClientDataHash(nonce: nonce, deviceID: device.id, origin: try! RelayOrigin(origin))
    }

    private func loginMessage(_ device: Device, nonce: Data) -> Data {
        // swiftlint:disable:next force_try
        RelayAuthMessages.loginMessage(nonce: nonce, deviceID: device.id, origin: try! RelayOrigin(origin))
    }

    private func registerOp(_ device: Device, nonce: Data, attestation: Relay_V1_Attestation? = nil) -> Relay_V1_RegisterDevice {
        var op = Relay_V1_RegisterDevice()
        op.deviceKind = device.kind
        op.authPub = device.signer.publicKey
        op.nonce = nonce
        if let attestation { op.attestation = attestation }
        // swiftlint:disable:next force_try
        op.signature = try! device.signer.sign(registerHash(device, nonce: nonce))
        return op
    }

    private func loginOp(_ device: Device, nonce: Data, attestation: Relay_V1_Attestation? = nil) -> Relay_V1_Login {
        var op = Relay_V1_Login()
        op.deviceID = device.id
        op.nonce = nonce
        if let attestation { op.attestation = attestation }
        // swiftlint:disable:next force_try
        op.signature = try! device.signer.sign(loginMessage(device, nonce: nonce))
        return op
    }

    private func item(
        _ zone: String, _ name: String, _ body: String, mustNotExist: Bool = false, expectedSeq: UInt64? = nil, attachment: String = ""
    ) -> Relay_V1_SaveItem {
        var item = Relay_V1_SaveItem()
        item.record.zone = zone
        item.record.name = name
        item.record.envelope = Data(body.utf8)
        item.record.clientModifiedAtMs = 1
        item.record.attachmentID = attachment
        if mustNotExist { item.mustNotExist = true }
        if let expectedSeq { item.expectedSeq = expectedSeq }
        return item
    }

    private func removeOp(_ phone: Device, _ mac: Device) -> Relay_V1_RemoveMacSlot {
        var remove = Relay_V1_RemoveMacSlot()
        remove.phoneDeviceID = phone.id
        remove.macDeviceID = mac.id
        return remove
    }

    private func addSlotOp(_ mac: Device) -> Relay_V1_Request.OneOf_Op {
        var add = Relay_V1_AddMacSlot()
        add.macDeviceID = mac.id
        return .addSlot(add)
    }

    private func uploadOp(_ zone: String, size: UInt64) -> Relay_V1_Request.OneOf_Op {
        var upload = Relay_V1_CreateUpload()
        upload.zone = zone
        upload.size = size
        return .createUpload(upload)
    }

    private func downloadOp(_ zone: String, _ attachmentID: String) -> Relay_V1_Request.OneOf_Op {
        var download = Relay_V1_GetDownload()
        download.zone = zone
        download.attachmentID = attachmentID
        return .getDownload(download)
    }

    /// An attachment of 10 bytes, created and uploaded.
    private func upload(_ relay: FakeHostedRelay, _ device: Device, _ zone: String) async throws -> Relay_V1_Upload {
        guard case .upload(let upload) = try ok(relay, device, uploadOp(zone, size: 10)).result else { throw Failure.unexpected("not an upload") }
        let status = try await relay.http.put(try XCTUnwrap(URL(string: upload.url)), file: try file(Data(repeating: 1, count: 10)), headers: [:])
        XCTAssertEqual(status, 200)
        return upload
    }

    /// A temporary file holding `data` (nil data: none yet), removed after the test.
    private func file(_ data: Data?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-relay-\(UUID().uuidString)")
        if let data { try data.write(to: url) }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func deleteItem(_ name: String, expectedSeq: UInt64? = nil) -> Relay_V1_DeleteItem {
        var item = Relay_V1_DeleteItem()
        item.name = name
        if let expectedSeq { item.expectedSeq = expectedSeq }
        return item
    }

    private func saveOp(_ items: [Relay_V1_SaveItem]) -> Relay_V1_Request.OneOf_Op {
        var save = Relay_V1_Save()
        save.items = items
        return .save(save)
    }

    private func deleteOp(_ zone: String, _ items: [Relay_V1_DeleteItem]) -> Relay_V1_Request.OneOf_Op {
        var delete = Relay_V1_Delete()
        delete.zone = zone
        delete.items = items
        return .delete(delete)
    }

    private func changesOp(_ zone: String, since: UInt64, limit: UInt32 = 0) -> Relay_V1_Request.OneOf_Op {
        var changes = Relay_V1_Changes()
        changes.zone = zone
        changes.sinceSeq = since
        changes.limit = limit
        return .changes(changes)
    }

    private static let socketURL = URL(string: "wss://relay.example.com/v1/ws")!

    private func subscribeFrame(_ zones: [String], id: UInt64) throws -> Data {
        var frame = Relay_V1_Frame()
        frame.request.id = id
        frame.request.subscribe.zones = zones
        return try frame.serializedData()
    }

    /// A socket of `device` past Hello, subscribed to `zones` (when any).
    private func liveSocket(_ relay: FakeHostedRelay, _ device: Device, subscribe zones: [String]) async throws -> any RelaySocket {
        let socket = try await relay.sockets.dial(Self.socketURL, headers: ["Authorization": "Bearer \(device.token)"])
        try await socket.send(hello(device.token))
        guard case .helloOk = try await frame(socket).kind else { throw Failure.unexpected("no HelloOk") }
        if !zones.isEmpty {
            try await socket.send(subscribeFrame(zones, id: 1))
            if let code = code(try await frame(socket).response) { throw Failure.unexpected("subscribe \(code)") }
        }
        return socket
    }

    private func hello(_ token: String) throws -> Data {
        var frame = Relay_V1_Frame()
        frame.hello.protocolVersion = HostedRelay.protocolVersion
        frame.hello.sessionToken = token
        return try frame.serializedData()
    }

    /// The next frame on a fake socket (the fake queues it before the call returns).
    private func frame(_ socket: any RelaySocket) async throws -> Relay_V1_Frame {
        guard case .binary(let data) = try await socket.receive() else { throw Failure.unexpected("closed") }
        return try Relay_V1_Frame(serializedBytes: data)
    }

    private func code(_ response: Relay_V1_Response) -> Relay_V1_ErrorCode? {
        if case .error(let error) = response.result { return error.code }
        return nil
    }

    /// The error code of `op` for `device` (nil = success); nil device = no session.
    private func errorCode(_ relay: FakeHostedRelay, _ device: Device?, _ op: Relay_V1_Request.OneOf_Op) throws -> Relay_V1_ErrorCode? {
        let (status, response) = relay.handle(request(op), bearer: device?.token)
        XCTAssertEqual(response.id, 7)
        let code = code(response)
        XCTAssertEqual(status, code == .unauthenticated ? 401 : 200)
        return code
    }

    private func ok(_ relay: FakeHostedRelay, _ device: Device, _ op: Relay_V1_Request.OneOf_Op) throws -> Relay_V1_Response {
        let response = relay.handle(request(op), bearer: device.token).response
        if code(response) != nil { throw Failure.unexpected("\(response)") }
        return response
    }

    private func saveResult(_ relay: FakeHostedRelay, _ device: Device, _ items: [Relay_V1_SaveItem]) throws -> Relay_V1_SaveResult {
        guard case .save(let result) = try ok(relay, device, saveOp(items)).result else { throw Failure.unexpected("not a save") }
        return result
    }

    private func deleteResult(
        _ relay: FakeHostedRelay, _ device: Device, _ zone: String, _ items: [Relay_V1_DeleteItem]
    ) throws -> Relay_V1_DeleteResult {
        guard case .delete(let result) = try ok(relay, device, deleteOp(zone, items)).result else { throw Failure.unexpected("not a delete") }
        return result
    }

    private func changes(
        _ relay: FakeHostedRelay, _ device: Device, _ zone: String, since: UInt64, limit: UInt32 = 0
    ) throws -> Relay_V1_ChangesResult {
        guard case .changes(let result) = try ok(relay, device, changesOp(zone, since: since, limit: limit)).result else {
            throw Failure.unexpected("not changes")
        }
        return result
    }

    private func controls(_ relay: FakeHostedRelay, _ device: Device) -> [Relay_V1_Control] {
        relay.takeEvents(for: device.id).compactMap { event in
            if case .control(let control) = event.kind { return control }
            return nil
        }
    }

    private func control(_ kind: Relay_V1_ControlKind, _ detail: String) -> Relay_V1_Control {
        var control = Relay_V1_Control()
        control.kind = kind
        control.detail = detail
        return control
    }

    private func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
