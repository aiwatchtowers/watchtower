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
        while await transport.connection?.isLive != true {
            pump()
            await Task.yield()
        }
        return (transport, store, http, mac)
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
        XCTAssertEqual(http.ops.filter { $0 == "save" }.count, 1, "the resend went over HTTPS")
        XCTAssertEqual(try savedNames(), [["once"], ["once"]], "the socket's save, then the HTTPS one")
        var changes = Relay_V1_Changes()
        changes.zone = mailbox(mac, phone)
        let page = try await phone.changes(changes)
        XCTAssertEqual(page.changed.map(\.name), ["once"], "one record")
        XCTAssertEqual(page.changed.first?.recordSeq, seq)
    }

    /// A plain (unconditional) save lost on the socket after its frame was written is not resent: it
    /// stays queued for the flush's own retry, and HTTPS sees no save.
    func testAPlainSaveLostOnTheSocketIsNotResent() async throws {
        let relay = try relay
        let (transport, store, http, _) = try await liveTransport()
        relay.cutSocketAfterNext("save")

        try await transport.save([mailboxRecord("plain")])
        await transport.sendNow()

        XCTAssertEqual(http.ops.filter { $0 == "save" }.count, 0, "not resent over HTTPS")
        XCTAssertEqual(try savedNames(), [["plain"]], "sent once, over the socket")
        XCTAssertTrue(try store.isPending(recordName: "plain", zone: .relay), "still queued")
    }

    /// A save after a lost socket's resend whose conflict is another record stays a conflict.
    func testOwnWritesKeepsAnotherRecordsConflict() {
        var item = Relay_V1_SaveItem()
        item.record.name = "a"
        item.record.envelope = Data("mine".utf8)
        item.mustNotExist = true
        var save = Relay_V1_Save()
        save.items = [item, item]
        save.items[1].record.name = "b"
        var other = item.record
        other.envelope = Data("theirs".utf8)
        other.recordSeq = 7
        var own = save.items[1].record
        own.recordSeq = 8
        var result = Relay_V1_SaveResult()
        for (index, current) in [(0, other), (1, own)] {
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
        XCTAssertEqual(mapped.conflicts.map(\.index), [0])
        XCTAssertEqual(HostedRelayTransport.saveOutcomes(mapped, items: [mailboxRecord("a"), mailboxRecord("b")])?.count, 2)
    }
}
