import Foundation
import os
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
@testable import WatchtowerSync
import XCTest

/// Live link R1: a zone event whose records continue the zone's cursor is buffered from the event, with no
/// `changes` read; every other event is a read, as before.
extension HostedRelayTransportTests {
    /// The Mac saves `names` in one call (envelope = the name); the stored records, in order.
    @discardableResult
    private func macSaveAll(_ mac: HostedRelayClient, _ zone: String, _ names: [String]) async throws -> [Relay_V1_Record] {
        var save = Relay_V1_Save()
        save.items = names.map { name in
            var item = Relay_V1_SaveItem()
            item.record.zone = zone
            item.record.name = name
            item.record.envelope = Data(name.utf8)
            return item
        }
        return try await mac.save(save).saved.map { saved in
            var record = saved
            record.envelope = Data(saved.name.utf8)
            return record
        }
    }

    /// A transport that is not started (no socket: events are handed to `handle`), its data zone read up to
    /// the Mac's record "a" (cursor 1).
    private func readToOne(
        phoneHTTP: ((any RelayHTTP) -> any RelayHTTP)? = nil
    ) async throws -> (HostedRelayTransport, TransportStore, TransportEventLog, mac: HostedRelayClient) {
        let (mac, phone) = try await hub(phoneHTTP: phoneHTTP)
        let store = try TransportStore.inMemory()
        let (transport, log) = try await makeTransport(phone, mac: mac, store: store)
        try await macSave(mac, dataZone(mac), "a")
        try await transport.pull(only: [.data])
        XCTAssertEqual(try store.relayCursor(zone: .data), 1)
        return (transport, store, log, mac)
    }

    /// A started transport on a live socket whose data zone holds the Mac's "before", once the reads of its
    /// start and of its connect's record-less event are over (one `changes` of the data zone each).
    private func liveAtOne() async throws -> (HostedRelayTransport, TransportStore, TransportEventLog, mac: HostedRelayClient) {
        let (mac, phone) = try await hub()
        let store = try TransportStore.inMemory()
        let (transport, log) = try await makeTransport(phone, mac: mac, store: store)
        let zone = dataZone(mac)
        try await macSave(mac, zone, "before")
        await transport.start()
        await waitUntilLive(await transport.session)
        await eventually { ((try? self.changesSinces(zone).count) ?? 0) >= 2 }
        await settle("the start's pulls are over") { await transport.pullTask == nil }
        XCTAssertEqual(try changesSinces(zone), [0, 1])
        return (transport, store, log, mac)
    }

    private func names(_ store: TransportStore) throws -> [String] {
        try buffered(store, .data).changed.map(\.recordName)
    }

    /// A two-record save of the hub reaches the buffer from its event alone: no `changes` after it.
    func testInlineRecordsAppliedWithoutChangesRead() async throws {
        let (_, store, log, mac) = try await liveAtOne()
        let zone = dataZone(mac)
        let fetches = log.fetches

        try await macSaveAll(mac, zone, ["x", "y"])
        await eventually { (try? self.names(store)) == ["before", "x", "y"] }
        XCTAssertEqual(try store.relayCursor(zone: .data), 3)
        XCTAssertEqual(try changesSinces(zone), [0, 1], "no read for the event's own records")
        XCTAssertEqual(log.fetches, fetches + 1, "the engine is told as after a pull")
        let batch = try buffered(store, .data)
        XCTAssertEqual(batch.changed.map(\.payload), [Data("before".utf8), Data("x".utf8), Data("y".utf8)])
        XCTAssertEqual(batch.changed.map(\.recordSeq), [1, 2, 3])

        try await macSave(mac, zone, "z")
        await eventually { (try? self.names(store)) == ["before", "x", "y", "z"] }
        XCTAssertEqual(try changesSinces(zone), [0, 1], "nor for the next one")
        XCTAssertEqual(try store.relayCursor(zone: .data), 4)
    }

    /// Records that do not continue the cursor (a write in between was missed) are not applied: the zone is read.
    func testInlineGapFallsBackToRead() async throws {
        let (transport, store, _, mac) = try await readToOne()
        let zone = dataZone(mac)
        let saved = try await macSaveAll(mac, zone, ["b", "c"])

        await transport.handle(.zoneChanged(zone: zone, seq: 3, records: [saved[1]]))

        XCTAssertEqual(try changesSinces(zone), [0, 1], "the gap is read from the cursor")
        XCTAssertEqual(try names(store), ["a", "b", "c"])
        XCTAssertEqual(try store.relayCursor(zone: .data), 3)
    }

    /// Records that are not the writes up to the event's seq, or not contiguous, are a read too.
    func testInlineRecordsThatDoNotEndAtTheSeqAreARead() async throws {
        let (transport, store, _, mac) = try await readToOne()
        let zone = dataZone(mac)
        let saved = try await macSaveAll(mac, zone, ["b", "c", "d"])

        await transport.handle(.zoneChanged(zone: zone, seq: 4, records: [saved[0], saved[1]]))
        XCTAssertEqual(try changesSinces(zone), [0, 1], "the last record is below the seq")
        XCTAssertEqual(try names(store), ["a", "b", "c", "d"])

        let more = try await macSaveAll(mac, zone, ["e", "f", "g"])
        await transport.handle(.zoneChanged(zone: zone, seq: 7, records: [more[0], more[2]]))
        XCTAssertEqual(try changesSinces(zone), [0, 1, 4], "a hole among the records")
        XCTAssertEqual(try names(store), ["a", "b", "c", "d", "e", "f", "g"])
    }

    /// Records that start at or before the cursor and reach the seq cover it: only the new ones are buffered.
    /// An event at or below the cursor is already read.
    func testInlineRecordsOverlappingTheCursorBufferOnlyTheNewOnes() async throws {
        let (transport, store, log, mac) = try await readToOne()
        let zone = dataZone(mac)
        let saved = try await macSaveAll(mac, zone, ["b", "c"])
        var first = Relay_V1_Record()
        first.zone = zone
        first.name = "a"
        first.envelope = Data("a".utf8)
        first.recordSeq = 1

        await transport.handle(.zoneChanged(zone: zone, seq: 3, records: [first] + saved))
        XCTAssertEqual(try names(store), ["a", "b", "c"])
        XCTAssertEqual(try store.relayCursor(zone: .data), 3)
        let fetches = log.fetches

        await transport.handle(.zoneChanged(zone: zone, seq: 3, records: saved))
        await transport.handle(.zoneChanged(zone: zone, seq: 3))
        XCTAssertEqual(try names(store), ["a", "b", "c"], "nothing twice")
        XCTAssertEqual(log.fetches, fetches, "nothing new: the engine is not told")
        XCTAssertEqual(try changesSinces(zone), [0], "an event at the cursor is already read: no read at all")
    }

    /// An event below the cursor does not continue it: the zone is read (spec R3), with or without records, so a
    /// zone the relay rebuilt below the cursor is still noticed (`TOKEN_EXPIRED`, then the resync from 0).
    func testAnEventBelowTheCursorIsARead() async throws {
        let relay = try relay
        let (transport, store, _, mac) = try await readToOne()
        let zone = dataZone(mac)
        let saved = try await macSaveAll(mac, zone, ["b", "c"])
        try await transport.pull(only: [.data])
        XCTAssertEqual(try changesSinces(zone), [0, 1])

        await transport.handle(.zoneChanged(zone: zone, seq: 2))
        XCTAssertEqual(try changesSinces(zone), [0, 1, 3], "a bare event below the cursor reads")
        await transport.handle(.zoneChanged(zone: zone, seq: 2, records: [saved[0]]))
        XCTAssertEqual(try changesSinces(zone), [0, 1, 3, 3], "so does one with records")
        XCTAssertEqual(try names(store), ["a", "b", "c"], "nothing twice")

        // The relay answers that read TOKEN_EXPIRED when the cursor is beyond its zone: the lane resyncs from 0.
        relay.failNext("changes", with: .tokenExpired)
        await transport.handle(.zoneChanged(zone: zone, seq: 1))
        XCTAssertEqual(
            Array(try changesFlags(zone).suffix(2)), [ChangesFlag(since: 3, resync: false), ChangesFlag(since: 0, resync: true)])
        XCTAssertEqual(try store.relayCursor(zone: .data), 3)
    }

    /// A record with an attachment is read: the read downloads the file.
    func testInlineWithAttachmentReads() async throws {
        let (transport, store, _, mac) = try await readToOne()
        let zone = dataZone(mac)
        let bytes = Data(repeating: 7, count: 2048)
        let attachment = try await macUpload(mac, zone, bytes)
        try await macSave(mac, zone, "att", attachmentID: attachment)
        var record = Relay_V1_Record()
        record.zone = zone
        record.name = "att"
        record.envelope = Data("att".utf8)
        record.recordSeq = 2
        record.attachmentID = attachment

        await transport.handle(.zoneChanged(zone: zone, seq: 2, records: [record]))

        XCTAssertEqual(try changesSinces(zone), [0, 1])
        let event = try XCTUnwrap(try buffered(store, .data).changed.last)
        XCTAssertEqual(event.recordName, "att")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(event.assetFileURL)), bytes)
    }

    /// A tombstone among the records is a read (the relay sends none: a deletion's event is bare).
    func testInlineTombstoneReads() async throws {
        let (transport, store, _, mac) = try await readToOne()
        let zone = dataZone(mac)
        try await macDelete(mac, zone, ["a"])
        var record = Relay_V1_Record()
        record.zone = zone
        record.name = "a"
        record.recordSeq = 2
        record.deleted = true

        await transport.handle(.zoneChanged(zone: zone, seq: 2, records: [record]))

        XCTAssertEqual(try changesSinces(zone), [0, 1])
        XCTAssertEqual(try buffered(store, .data).deletedRecordNames, ["a"])
    }

    /// A phone over the relay's traffic budget gets its events without records: each is a read.
    func testRecordlessEventOverTrafficBudgetReads() async throws {
        let relay = try relay
        let (transport, store, _, mac) = try await liveAtOne()
        let zone = dataZone(mac)
        relay.setTrafficOver(true, deviceID: await transport.client.deviceID)

        try await macSaveAll(mac, zone, ["x", "y"])
        await eventually { (try? self.names(store)) == ["before", "x", "y"] }
        XCTAssertEqual(try changesSinces(zone), [0, 1, 1], "a bare event is a read from the cursor")
    }

    /// While a pull is in flight the event's records are not applied (the pull reads from the cursor they would
    /// move): the event joins the pull, which reads the zone again.
    func testInlineDuringPullDefersToPull() async throws {
        let box = OSAllocatedUnfairLock<InterceptingRelayHTTP?>(initialState: nil)
        let (transport, store, _, mac) = try await readToOne { base in
            let http = InterceptingRelayHTTP(base)
            box.withLock { $0 = http }
            return http
        }
        let intercepting = try XCTUnwrap(box.withLock { $0 })
        let zone = dataZone(mac)
        let saved = try await macSaveAll(mac, zone, ["b"])

        intercepting.holdNext { request in
            if case .changes(let changes) = request.op { return changes.zone == zone }
            return false
        }
        let pull = Task { await transport.handle(.zoneChanged(zone: zone, seq: 0)) }
        await eventually { intercepting.holding }

        let applied = await transport.applyInline(zone: .data, seq: 2, records: saved)
        XCTAssertFalse(applied, "a pull is in flight")
        let event = Task { await transport.handle(.zoneChanged(zone: zone, seq: 2, records: saved)) }
        await settle("the event joined the pull") { await transport.zonesToPull.contains(.data) }
        intercepting.release()
        await pull.value
        await event.value

        XCTAssertEqual(try names(store), ["a", "b"], "buffered once, by the pull")
        XCTAssertEqual(try changesSinces(zone), [0, 1, 2], "the event's pass reads from the pull's cursor")
    }

    /// While a resync is owed, or before the zone's first read, the records are not applied: the read runs.
    func testInlineIsAReadWhileAResyncIsOwedOrTheZoneIsUnread() async throws {
        let (transport, store, _, mac) = try await readToOne()
        let zone = dataZone(mac)
        let saved = try await macSaveAll(mac, zone, ["b"])
        try await transport.readFromStart(.data)

        await transport.handle(.zoneChanged(zone: zone, seq: 2, records: saved))
        XCTAssertEqual(try changesFlags(zone), [ChangesFlag(since: 0, resync: true), ChangesFlag(since: 0, resync: true)])
        XCTAssertEqual(try store.relayCursor(zone: .data), 2)

        // The mailbox was never read (cursor 0): its first read is a load.
        let phone = await transport.client
        let box = mailbox(mac, phone)
        let hello = try await macSaveAll(mac, box, ["m"])
        await transport.handle(.zoneChanged(zone: box, seq: 1, records: hello))
        XCTAssertEqual(try changesFlags(box), [ChangesFlag(since: 0, resync: true)])
        XCTAssertEqual(try buffered(store, .relay).changed.map(\.recordName), ["m"])
    }

    /// A relay without "records_inline" sends only the single `record` of a one-record save: that one is applied
    /// from the event, a save of several records is read.
    func testOldRelayWithoutCapabilityKeepsSingleRecordInline() async throws {
        let relay = try relay
        relay.setRecordsInline(false)
        let (_, store, _, mac) = try await liveAtOne()
        let zone = dataZone(mac)

        try await macSave(mac, zone, "one")
        await eventually { (try? self.names(store)) == ["before", "one"] }
        XCTAssertEqual(try changesSinces(zone), [0, 1], "the single record needs no read")

        try await macSaveAll(mac, zone, ["x", "y"])
        await eventually { (try? self.names(store)) == ["before", "one", "x", "y"] }
        XCTAssertEqual(try changesSinces(zone), [0, 1, 2], "two records: a read")
    }
}
