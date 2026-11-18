import Foundation
import os
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
@testable import WatchtowerSync
import XCTest

/// Live link R2: the transport's ops ride the open socket; a socket lost after the request was written
/// falls back to HTTPS only for an op that is safe to run twice (fake only: it cuts the socket mid-op).
extension HostedRelayTransportTests {
    /// The phone with an `InterceptingRelayHTTP`, its transport started and its socket live.
    private func liveTransport() async throws -> (HostedRelayTransport, TransportStore, InterceptingRelayHTTP, mac: HostedRelayClient) {
        let box = OSAllocatedUnfairLock<InterceptingRelayHTTP?>(initialState: nil)
        let (mac, phone) = try await hub { base in
            let http = InterceptingRelayHTTP(base)
            box.withLock { $0 = http }
            return http
        }
        let http = try XCTUnwrap(box.withLock { $0 })
        let store = try TransportStore.inMemory()
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        await transport.start()
        await waitUntilLive(await transport.session)
        return (transport, store, http, mac)
    }

    private func count(_ op: String, _ http: InterceptingRelayHTTP) -> Int {
        http.ops.filter { $0 == op }.count
    }

    /// A conditional save whose socket is cut after the relay ran it is sent again over HTTPS; the resend
    /// meets the record its first write left, which is success, and the zone holds that record once.
    func testSaveAfterSocketDropMeetsItsOwnRecord() async throws {
        let relay = try relay
        let (transport, _, http, mac) = try await liveTransport()
        let phone = await transport.client
        relay.cutSocketAfterNext("save")

        let outcomes = try await transport.save([ConditionalSave(record: mailboxRecord("once"), expect: .absent)])

        guard case .saved(let seq)? = outcomes.first, outcomes.count == 1 else { return XCTFail("not saved: \(outcomes)") }
        XCTAssertEqual(count("save", http), 1, "the resend went over HTTPS")
        XCTAssertEqual(try savedNames(), [["once"], ["once"]], "the socket's save, then the HTTPS one")
        var changes = Relay_V1_Changes()
        changes.zone = mailbox(mac, phone)
        let page = try await phone.changes(changes)
        XCTAssertEqual(page.changed.map(\.name), ["once"], "one record")
        XCTAssertEqual(page.changed.first?.recordSeq, seq)
    }

    /// An `expected_seq` rewrite of identical bytes (`resend_from`) on a seq the record is not at: the first
    /// try, lost on the socket, could not commit, so the HTTPS resend's conflict with the identical copy is
    /// a conflict, never "saved" without a new version.
    func testAResendOfIdenticalBytesOnAStaleSeqStaysAConflict() async throws {
        let relay = try relay
        let (transport, _, _, _) = try await liveTransport()
        let first = try await transport.save([ConditionalSave(record: mailboxRecord("same"), expect: .absent)])
        guard case .saved(let seq)? = first.first else { return XCTFail("not saved: \(first)") }
        relay.cutSocketAfterNext("save")

        let outcomes = try await transport.save([ConditionalSave(record: mailboxRecord("same"), expect: .seq(seq + 1))])

        guard case .conflict(let current)? = outcomes.first else { return XCTFail("not a conflict: \(outcomes)") }
        XCTAssertEqual(current.recordSeq, seq, "no new version")
    }

    /// A conditional delete lost on the socket is resent over HTTPS once and meets its own tombstone.
    func testADeleteAfterSocketDropIsResent() async throws {
        let relay = try relay
        let (transport, _, http, _) = try await liveTransport()
        let saved = try await transport.save([ConditionalSave(record: mailboxRecord("gone"), expect: .absent)])
        guard case .saved(let seq)? = saved.first else { return XCTFail("not saved: \(saved)") }
        relay.cutSocketAfterNext("delete")

        let outcomes = try await transport.delete([ConditionalDelete(recordName: "gone", zone: .relay, expect: .seq(seq))])

        XCTAssertEqual(outcomes, [.deleted])
        XCTAssertEqual(count("delete", http), 1, "resent over HTTPS once")
    }

    /// A read lost on the socket is resent over HTTPS once. `get_download`: no background pull reads it.
    func testAReadAfterSocketDropIsResent() async throws {
        let relay = try relay
        let (transport, _, http, mac) = try await liveTransport()
        let phone = await transport.client
        relay.cutSocketAfterNext("getDownload")

        _ = try? await (await transport.session).getDownload(missingDownload(mailbox(mac, phone)))

        XCTAssertEqual(count("getDownload", http), 1)
        XCTAssertEqual(relay.log.filter { HostedRelayClient.name($0) == "getDownload" }.count, 2, "the socket's, then HTTPS")
    }

    /// `UNAUTHENTICATED` on the socket: the op did not run, so it goes over HTTPS once.
    func testUnauthenticatedOnTheSocketGoesOverHTTPS() async throws {
        let relay = try relay
        let (transport, _, http, mac) = try await liveTransport()
        let phone = await transport.client
        relay.failNext("getDownload", with: .unauthenticated)

        do {
            _ = try await (await transport.session).getDownload(missingDownload(mailbox(mac, phone)))
        } catch {
            XCTAssertNotEqual(error as? HostedRelayError, .server(code: .unauthenticated, retryAfter: nil))
        }

        XCTAssertEqual(count("getDownload", http), 1)
    }

    private func missingDownload(_ zone: String) -> Relay_V1_GetDownload {
        var download = Relay_V1_GetDownload()
        download.zone = zone
        download.attachmentID = "missing"
        return download
    }

    /// A plain (unconditional) save lost on the socket after its frame was written is not resent: it
    /// stays queued for the flush's own retry, and HTTPS sees no save.
    func testAPlainSaveLostOnTheSocketIsNotResent() async throws {
        let relay = try relay
        let (transport, store, http, _) = try await liveTransport()
        relay.cutSocketAfterNext("save")

        try await transport.save([mailboxRecord("plain")])
        await transport.sendNow()

        XCTAssertEqual(count("save", http), 0, "not resent over HTTPS")
        XCTAssertEqual(try savedNames(), [["plain"]], "sent once, over the socket")
        XCTAssertTrue(try store.isPending(recordName: "plain", zone: .relay), "still queued")
    }

    /// Which ops may be resent after a socket lost after the write.
    func testIdempotentOps() {
        func save(_ expects: [Relay_V1_SaveItem.OneOf_Expect?]) -> Relay_V1_Request.OneOf_Op {
            var save = Relay_V1_Save()
            save.items = expects.map { expect in
                var item = Relay_V1_SaveItem()
                item.expect = expect
                return item
            }
            return .save(save)
        }
        func delete(_ seqs: [UInt64?]) -> Relay_V1_Request.OneOf_Op {
            var delete = Relay_V1_Delete()
            delete.items = seqs.map { seq in
                var item = Relay_V1_DeleteItem()
                if let seq { item.expectedSeq = seq }
                return item
            }
            return .delete(delete)
        }
        let cases: [(Relay_V1_Request.OneOf_Op, Bool, String)] = [
            (.changes(Relay_V1_Changes()), true, "changes"),
            (.getAccountState(Relay_V1_GetAccountState()), true, "account state"),
            (.getDownload(Relay_V1_GetDownload()), true, "download"),
            (.createUpload(Relay_V1_CreateUpload()), false, "upload"),
            (save([.mustNotExist(true), .expectedSeq(3)]), true, "conditional saves"),
            (save([.mustNotExist(false)]), false, "must_not_exist false"),
            (save([.expectedSeq(3), nil]), false, "a mixed batch"),
            (save([]), false, "no items"),
            (delete([4]), true, "a conditional delete"),
            (delete([4, nil]), false, "a delete without expected_seq"),
            (delete([]), false, "an empty delete")
        ]
        for (op, idempotent, label) in cases {
            XCTAssertEqual(HostedRelaySession.idempotent(op), idempotent, label)
        }
    }

    /// `ownWrites`: only a byte-identical copy past an `expected_seq` is the item's own write; another
    /// record's conflict stays; an answer that does not cover the request comes back as it was.
    func testOwnWritesKeepsAnotherRecordsConflict() {
        var item = Relay_V1_SaveItem()
        item.record.name = "a"
        item.record.envelope = Data("mine".utf8)
        item.mustNotExist = true
        var save = Relay_V1_Save()
        save.items = [item, item, item]
        save.items[1].record.name = "b"
        save.items[2].record.name = "c"
        save.items[2].expectedSeq = 9
        var other = item.record
        other.envelope = Data("theirs".utf8)
        other.recordSeq = 7
        var own = save.items[1].record
        own.recordSeq = 8
        var stale = save.items[2].record
        stale.recordSeq = 9
        var result = Relay_V1_SaveResult()
        for (index, current) in [(0, other), (1, own), (2, stale)] {
            var conflict = Relay_V1_SaveConflict()
            conflict.index = UInt32(index)
            conflict.current = current
            result.conflicts.append(conflict)
        }
        var response = Relay_V1_Response()
        response.save = result

        let mapped = HostedRelaySession.ownWrites(in: response, of: .save(save)).save
        XCTAssertEqual(mapped.saved.map(\.name), ["b"])
        XCTAssertEqual(mapped.saved.first?.recordSeq, 8)
        XCTAssertEqual(mapped.conflicts.map(\.index), [0, 2], "another record's, and a copy not past expected_seq")
        let items = [mailboxRecord("a"), mailboxRecord("b"), mailboxRecord("c")]
        XCTAssertEqual(HostedRelayTransport.saveOutcomes(mapped, items: items)?.count, 3)

        var short = result
        short.conflicts.removeLast()
        var shortResponse = Relay_V1_Response()
        shortResponse.save = short
        XCTAssertEqual(HostedRelaySession.ownWrites(in: shortResponse, of: .save(save)), shortResponse, "short answer untouched")
    }
}
