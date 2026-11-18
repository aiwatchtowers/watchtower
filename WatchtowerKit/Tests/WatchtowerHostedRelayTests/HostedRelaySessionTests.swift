import Foundation
import os
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
@testable import WatchtowerSync
import XCTest

/// `HostedRelaySession` on `FakeHostedRelay` (R2): every relay object of the phone shares one
/// socket, because the relay displaces an older socket of the same device (close 1001 after
/// `GoingAway`). The phone's client counts its dials and its displacements.
final class HostedRelaySessionTests: HostedRelayScenarioCase {
    private var transports: [HostedRelayTransport] = []
    private var eventLogs: [TransportEventLog] = []
    private var probes: [(HostedRelaySession, Probe)] = []
    private var readers: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for transport in transports { await transport.stop() }
        for (session, probe) in probes { await session.detach(owner: ObjectIdentifier(probe)) }
        for log in eventLogs { log.cancel() }
        for reader in readers { reader.cancel() }
        transports = []
        eventLogs = []
        probes = []
        readers = []
        try await super.tearDown()
    }

    // MARK: - Tests

    func testTwoHubsAndAPairingSlotShareOneSocket() async throws {
        let (phone, tally, macs) = try await paired(macs: [1, 3])
        let session = HostedRelaySession(client: phone)
        let first = try transport(session, mac: macs[0])
        let second = try transport(session, mac: macs[1])
        await first.start()
        await second.start()
        let slot = HostedRelayZones.pair(slot: "slot-a")
        _ = await probe(session, zones: [slot])

        let zones = macs.flatMap { [dataZone($0), mailbox($0, phone)] } + [slot]
        await eventually { Set(zones).isSubset(of: self.subscribed()) }
        XCTAssertEqual(tally.dials, 1, "one socket for two hubs and a pairing slot")
        XCTAssertEqual(tally.displacements, 0)
    }

    func testAZoneEventReachesOnlyItsTransport() async throws {
        let (phone, _, macs) = try await paired(macs: [1, 3])
        let session = HostedRelaySession(client: phone)
        let zoneA = dataZone(macs[0])
        let zoneB = dataZone(macs[1])
        let ownerA = await probe(session, zones: [zoneA])
        let ownerB = await probe(session, zones: [zoneB])
        await eventually { ownerA.zoneEvents.contains { $0.zone == zoneA } && ownerB.zoneEvents.contains { $0.zone == zoneB } }

        let seqA = try await save(macs[0], zoneA, "for-a")
        await eventually { ownerA.zoneEvents.contains { $0 == ZoneEvent(zone: zoneA, seq: seqA) } }
        // B's inbox is in order: once B has its own later event, an event of A's zone would be before it.
        let seqB = try await save(macs[1], zoneB, "for-b")
        await eventually { ownerB.zoneEvents.contains { $0 == ZoneEvent(zone: zoneB, seq: seqB) } }

        XCTAssertEqual(ownerA.zoneEvents.map(\.zone).filter { $0 != zoneA }, [], "A sees its zone only")
        XCTAssertEqual(ownerB.zoneEvents.map(\.zone).filter { $0 != zoneB }, [], "B sees its zone only")
        XCTAssertEqual(ownerA.zoneEvents.filter { $0.zone == zoneA && $0.seq == 0 }.count, 1, "the connect's marker once")
        XCTAssertEqual(ownerB.zoneEvents.filter { $0.zone == zoneB && $0.seq == 0 }.count, 1, "the connect's marker once")
    }

    /// An owner busy with one event holds at most `inboxRecordBytes` of unread records: the events past it
    /// reach it without their records, so it reads the zone (live link R1; memory stays bounded under a
    /// slow pull).
    func testAnOwnersUnreadRecordsAreBounded() async throws {
        let (phone, _, macs) = try await paired(macs: [1])
        let session = HostedRelaySession(client: phone)
        let zone = dataZone(macs[0])
        let probe = Probe()
        probes.append((session, probe))
        let busy = Latch()
        let release = Latch()
        await session.attach(owner: ObjectIdentifier(probe), zones: [zone]) { event in
            probe.record(event)
            if case .zoneChanged(_, 1, _) = event {
                busy.fire()
                await release.wait()
            }
        }
        await eventually { probe.zoneEvents.contains { $0.zone == zone } }
        // 250 KiB a record: the first is being handled, four wait within the 1 MiB bound, the sixth does not.
        let body = Data(repeating: 1, count: 250 << 10)
        for index in 1...6 {
            var item = Relay_V1_SaveItem()
            item.record.zone = zone
            item.record.name = "r\(index)"
            item.record.envelope = body
            var save = Relay_V1_Save()
            save.items = [item]
            _ = try await macs[0].save(save)
            if index == 1 { await eventually { busy.fired } }
        }
        // A small one after them fits again: once it waits too, the session has routed all seven.
        _ = try await self.save(macs[0], zone, "tail")
        while await session.unreadRecordBytes(owner: ObjectIdentifier(probe)) != 4 * body.count + "tail".utf8.count {
            pump()
            await Task.yield()
        }
        release.fire()
        await eventually { probe.zoneEvents.contains { $0.seq == 7 } }

        let counts = probe.events.compactMap { event -> Int? in
            guard case .zoneChanged(_, let seq, let records) = event, seq > 0 else { return nil }
            return records.count
        }
        XCTAssertEqual(counts, [1, 1, 1, 1, 1, 0, 1], "the sixth is over the bound; the small seventh fits")
    }

    func testRemovingATransportKeepsTheOthersSubscribed() async throws {
        let (phone, tally, macs) = try await paired(macs: [1, 3])
        let session = HostedRelaySession(client: phone)
        let first = try transport(session, mac: macs[0])
        let store = try TransportStore.inMemory()
        let second = try transport(session, mac: macs[1], store: store)
        await first.start()
        await second.start()
        let zones = macs.flatMap { [dataZone($0), mailbox($0, phone)] }
        await eventually { Set(zones).isSubset(of: self.subscribed()) }

        await first.stop()
        try await save(macs[1], dataZone(macs[1]), "after-the-stop")
        await eventually {
            (try? store.changes(in: .data, since: nil).changed.map(\.recordName))?.contains("after-the-stop") == true
        }
        XCTAssertEqual(tally.dials, 1, "the socket stayed open")
        let connection = await session.connection
        XCTAssertNotNil(connection)
    }

    func testTheLastDetachClosesTheSocket() async throws {
        let (phone, tally, macs) = try await paired(macs: [1, 3])
        let session = HostedRelaySession(client: phone)
        let first = try transport(session, mac: macs[0])
        let second = try transport(session, mac: macs[1])
        await first.start()
        await second.start()
        let zones = macs.flatMap { [dataZone($0), mailbox($0, phone)] }
        await eventually { Set(zones).isSubset(of: self.subscribed()) }
        let open = await session.connection
        let connection = try XCTUnwrap(open)

        await first.stop()
        let afterFirst = await session.connection
        XCTAssertTrue(afterFirst === connection, "another owner is attached")
        XCTAssertTrue(connection.isLive)

        await second.stop()
        let afterLast = await session.connection
        XCTAssertNil(afterLast)
        XCTAssertFalse(connection.isLive, "closed")
        XCTAssertEqual(tally.dials, 1)
    }

    func testAReconnectResubscribesTheUnion() async throws {
        let relay = try requireFake("displaces the phone's socket (fake only, R15)")
        let (phone, tally, macs) = try await paired(macs: [1, 3])
        let session = HostedRelaySession(client: phone)
        let first = try transport(session, mac: macs[0])
        let second = try transport(session, mac: macs[1])
        await first.start()
        await second.start()
        let zones = macs.flatMap { [dataZone($0), mailbox($0, phone)] }
        await eventually { Set(zones).isSubset(of: self.subscribed()) }

        let mark = backend.opLog.count
        relay.displace(deviceID: phone.deviceID)
        await eventually { Set(zones).isSubset(of: self.subscribed(after: mark)) }
        XCTAssertEqual(tally.dials, 2, "one redial")
    }

    func testAccountControlsGoToTheSession() async throws {
        let (phone, _, macs) = try await paired(macs: [1, 3])
        let session = HostedRelaySession(client: phone)
        let accountEvents = collect(session.events)
        let marker = await probe(session, zones: [])
        let first = try transport(session, mac: macs[0])
        let second = try transport(session, mac: macs[1])
        let firstLog = await log(first)
        let secondLog = await log(second)
        await first.start()
        await second.start()
        await eventually { marker.events.contains(.connected) }

        let account = try await stand.accountID(ofPhone: phone.deviceID)
        try await stand.setEntitlement(accountID: account, state: "expired", for: .zero)
        await eventually { accountEvents.events.contains(.control(kind: .entitlementExpired, detail: "")) }
        XCTAssertEqual(accountEvents.events.filter { $0 == .control(kind: .entitlementExpired, detail: "") }.count, 1, "once")
        for log in [firstLog, secondLog] {
            XCTAssertFalse(log.relayEvents.contains { if case .control = $0 { true } else { false } }, "not on a transport")
        }
        XCTAssertTrue(firstLog.relayEvents.contains(.reachable(true)), "each transport keeps its reachability")
        XCTAssertTrue(secondLog.relayEvents.contains(.reachable(true)))
    }

    func testDisplacementNeverLoops() async throws {
        let (phone, tally, macs) = try await paired(macs: [1, 3])
        let session = HostedRelaySession(client: phone)
        let first = try transport(session, mac: macs[0])
        let second = try transport(session, mac: macs[1])
        async let started: Void = first.start()
        async let alsoStarted: Void = second.start()
        _ = await (started, alsoStarted)
        let zones = macs.flatMap { [dataZone($0), mailbox($0, phone)] }
        await eventually { Set(zones).isSubset(of: self.subscribed()) }
        // Give a displacement loop the reconnect waits it would need.
        for _ in 0..<10 {
            pump()
            await Task.yield()
        }
        XCTAssertEqual(tally.displacements, 0, "no 1001 from the relay")
        XCTAssertEqual(tally.dials, 1)
    }

    /// `events` is level-like: a latched account case is reported once per state, until the
    /// socket is reachable again or another case comes.
    func testALatchedAccountCaseIsReportedOncePerState() async throws {
        let (phone, _, _) = try await paired(macs: [])
        let session = HostedRelaySession(client: phone)
        let collected = collect(session.events)
        let marker = HostedRelayEvent.control(kind: .slotRemoved, detail: "end")
        for event: HostedRelayEvent in [
            .entitlementInactive, .entitlementInactive, // one transport and another: one notice
            .reachable(true), .entitlementInactive, // a new state
            .unsupportedVersion, .unsupportedVersion, .entitlementInactive, marker
        ] {
            session.publish(event)
        }
        await eventually { collected.events.contains(marker) }
        XCTAssertEqual(collected.events, [
            .entitlementInactive, .reachable(true), .entitlementInactive, .unsupportedVersion, .entitlementInactive, marker
        ])
    }

    /// An App Attest stop or an unsupported version met by the account read is reported, not only logged.
    func testTheAccountReadReportsAStop() async throws {
        let relay = try requireFake("fails the phone's login (fake only, R15)")
        let (phone, _, _) = try await paired(macs: [])
        let session = HostedRelaySession(client: phone)
        let collected = collect(session.events)
        relay.expireSessions(of: phone.deviceID)
        relay.failNext("login", with: .attestationRequired)
        await session.readAccountState()
        await eventually { collected.events.contains(.attestation(.updateRequired)) }
    }

    /// An owner attaching to an open socket is told its state at once.
    func testAnOwnerAttachingToAnOpenSocketGetsItsState() async throws {
        let (phone, _, macs) = try await paired(macs: [1])
        let session = HostedRelaySession(client: phone)
        let first = await probe(session, zones: [dataZone(macs[0])])
        await eventually { first.events.contains(.connected) }
        let late = await probe(session, zones: [])
        await eventually { late.events.contains(.connected) }
    }

    /// A `.stopped` routed to an earlier attach of the transport leaves the current one attached.
    func testAStoppedFromAnOlderAttachIsIgnored() async throws {
        let (phone, _, macs) = try await paired(macs: [1])
        let session = HostedRelaySession(client: phone)
        let transport = try transport(session, mac: macs[0])
        await transport.start()
        let generation = await transport.attachGeneration
        await transport.handle(.stopped(.unsupportedVersion), generation: generation - 1)
        let attached = await transport.attached
        let wantsSocket = await transport.wantsSocket
        XCTAssertTrue(attached)
        XCTAssertTrue(wantsSocket)
    }

    /// Final review I2: right after `promote_pairing` the phone is not a reader of the hub's data zone yet (Phase 3
    /// R5), so the socket refuses it. Once the hub names the phone, the next successful pull of the data lane
    /// subscribes it again: the zone's next record arrives live, with no stop and start and no second socket.
    func testARefusedZoneGetsLiveEventsOnceTheHubAddsThePhoneAsAReader() async throws {
        let (phone, tally, macs) = try await paired(macs: [1])
        let mac = macs[0]
        _ = try await mac.perform(.setHubReaders(Relay_V1_SetHubReaders()))
        let session = HostedRelaySession(client: phone)
        let store = try TransportStore.inMemory()
        let transport = try transport(session, mac: mac, store: store)
        await transport.start()
        let data = dataZone(mac)
        let refused = await until { await transport.refusedZones.contains(data) }
        XCTAssertTrue(refused, "the socket never refused the data zone")

        var readers = Relay_V1_SetHubReaders()
        readers.phoneDeviceIds = [phone.deviceID]
        _ = try await mac.perform(.setHubReaders(readers))
        let mark = backend.opLog.count
        try await transport.pull()
        await eventually { self.subscribed(after: mark).contains(data) }

        try await save(mac, data, "live")
        await eventually {
            (try? store.changes(in: .data, since: nil).changed.map(\.recordName))?.contains("live") == true
        }
        let left = await transport.refusedZones
        XCTAssertTrue(left.isEmpty)
        XCTAssertEqual(tally.dials, 1, "no stop and start")
    }

    // MARK: - Ops over the socket (live link R2)

    /// With the socket live, a pull and a conditional save go over it: HTTPS sees no `changes` or `save`.
    func testOpsUseTheSocketWhenLive() async throws {
        let http = HTTPBox()
        let (phone, _, macs) = try await paired(macs: [1], wrapHTTP: http.wrap)
        let session = HostedRelaySession(client: phone)
        let store = try TransportStore.inMemory()
        let hub = try transport(session, mac: macs[0], store: store)
        await hub.start()
        await waitUntilLive(session)
        let mark = try http.ops().count

        try await save(macs[0], dataZone(macs[0]), "from-the-mac")
        _ = await until {
            (try? store.changes(in: .data, since: nil).changed.map(\.recordName))?.contains("from-the-mac") == true
        }
        let outcomes = try await hub.save([ConditionalSave(record: Self.record("from-the-phone"), expect: .absent)])
        guard case .saved? = outcomes.first else { return XCTFail("not saved: \(outcomes)") }
        try await hub.pull()

        let overHTTPS = try http.ops().dropFirst(mark).filter { ["changes", "save", "delete"].contains($0) }
        XCTAssertEqual(overHTTPS, [], "ops over the socket")
        XCTAssertTrue(backend.opLog.contains { if case .save = $0 { return true } else { return false } })
    }

    /// Without a socket the same ops go over HTTPS.
    func testOpsFallBackToHTTPSWithoutSocket() async throws {
        let http = HTTPBox()
        let (phone, tally, macs) = try await paired(macs: [1], wrapHTTP: http.wrap)
        let session = HostedRelaySession(client: phone)
        let hub = try transport(session, mac: macs[0])

        try await hub.pull()
        let outcomes = try await hub.save([ConditionalSave(record: Self.record("no-socket"), expect: .absent)])
        guard case .saved? = outcomes.first else { return XCTFail("not saved: \(outcomes)") }
        let direct = try await session.changes(Self.changes(mailbox(macs[0], phone)))
        XCTAssertEqual(direct.changed.map(\.name), ["no-socket"])

        let ops = try http.ops()
        XCTAssertTrue(ops.contains("changes"))
        XCTAssertEqual(ops.filter { $0 == "save" }.count, 1)
        XCTAssertEqual(tally.dials, 0, "no socket")
    }

    /// A connection that is not live (its dials refused) refuses the frame before any write: even an
    /// unconditional save then goes over HTTPS.
    func testANotSentRequestFallsBackForAnyOp() async throws {
        let relay = try requireFake("refuses dials (fake only, R15)")
        let http = HTTPBox()
        let (phone, _, macs) = try await paired(macs: [1], wrapHTTP: http.wrap)
        relay.refuseNextDial(status: 503, times: 1_000)
        let session = HostedRelaySession(client: phone)
        _ = await probe(session, zones: [])
        let connection = await session.connection
        XCTAssertEqual(connection?.isLive, false, "a connection, not live")
        var item = Relay_V1_SaveItem()
        item.record.zone = mailbox(macs[0], phone)
        item.record.name = "plain"
        item.record.envelope = Data("plain".utf8)
        var save = Relay_V1_Save()
        save.items = [item]

        let result = try await session.save(save)

        XCTAssertEqual(result.saved.map(\.name), ["plain"])
        XCTAssertEqual(try http.ops().filter { $0 == "save" }.count, 1)
    }

    // MARK: - Wake reads (live link R6)

    /// The pull reads its zones at once: both `changes` are in flight together, not one after the other.
    func testWakeReadsZonesConcurrently() async throws {
        let http = HTTPBox()
        let (phone, _, macs) = try await paired(macs: [1], wrapHTTP: http.wrap)
        let session = HostedRelaySession(client: phone)
        let store = try TransportStore.inMemory()
        let hub = try transport(session, mac: macs[0], store: store)
        let intercept = try http.intercept()
        intercept.answer(Self.scriptedPages(data: dataZone(macs[0]), mailbox: mailbox(macs[0], phone)))
        intercept.park { if case .changes = $0.op { true } else { false } }

        let pull = Task { try await hub.pull() }
        guard await within({ intercept.parked.count == 2 }) else {
            intercept.park(where: nil)
            intercept.releaseParked()
            _ = await pull.result
            return XCTFail("the reads went out one after the other")
        }

        XCTAssertEqual(
            intercept.parked.compactMap { if case .changes(let changes) = $0.op { changes.zone } else { nil } },
            [dataZone(macs[0]), mailbox(macs[0], phone)], "both zones' reads in flight together, the data zone's sent first")
        intercept.park(where: nil)
        intercept.releaseParked()
        try await pull.value
        XCTAssertEqual(try store.changes(in: .data, since: nil).changed.map(\.recordName), ["a1", "a2", "a3"])
        XCTAssertEqual(try store.changes(in: .relay, since: nil).changed.map(\.recordName), ["b1"])
    }

    /// The app leaves mid-read: the caller of the wake's reads is cancelled (`HubSession.setActive(false)` cancels its
    /// fetch, which waits on this pull) after zone A's first page is stored and before zone B answers. The next wake reads A from its stored cursor and B from its old one: nothing applied twice, nothing
    /// skipped.
    func testBackgroundMidConcurrentReadResumesFromStoredCursor() async throws {
        let http = HTTPBox()
        let (phone, _, macs) = try await paired(macs: [1], wrapHTTP: http.wrap)
        let session = HostedRelaySession(client: phone)
        let store = try TransportStore.inMemory()
        let hub = try transport(session, mac: macs[0], store: store)
        let (data, box) = (dataZone(macs[0]), mailbox(macs[0], phone))
        let intercept = try http.intercept()
        let reads = OSAllocatedUnfairLock<[String]>(initialState: [])
        let pages = Self.scriptedPages(data: data, mailbox: box)
        intercept.answer { request in
            if case .changes(let changes) = request.op {
                reads.withLock { $0.append("\(changes.zone == data ? "A" : "B")@\(changes.sinceSeq)") }
            }
            return try pages(request)
        }
        // A's first page goes through; A's second page and B's only page wait.
        intercept.park { request in
            guard case .changes(let changes) = request.op else { return false }
            return !(changes.zone == data && changes.sinceSeq == 0)
        }

        let pull = Task { try await hub.pull() }
        guard await within({ intercept.parked.count == 2 }) else {
            intercept.park(where: nil)
            intercept.releaseParked()
            _ = await pull.result
            return XCTFail("the reads went out one after the other")
        }
        XCTAssertEqual(try store.relayCursor(zone: .data), 2, "A's first page is stored")
        pull.cancel()
        let cancelled = await pull.result
        XCTAssertThrowsError(try cancelled.get())
        XCTAssertEqual(try store.relayCursor(zone: .data), 2)
        XCTAssertEqual(try store.relayCursor(zone: .relay), 0)

        intercept.park(where: nil)
        reads.withLock { $0 = [] }
        try await hub.pull()

        XCTAssertEqual(Set(reads.withLock { $0 }), ["A@2", "B@0"], "A from its stored cursor, B from its old one")
        XCTAssertEqual(try store.changes(in: .data, since: nil).changed.map(\.recordName), ["a1", "a2", "a3"])
        XCTAssertEqual(try store.changes(in: .relay, since: nil).changed.map(\.recordName), ["b1"])
    }

    /// Against the relay: a silent socket is dropped at once and the wake returns while the second dial is still
    /// held before the relay (it never waits on a dial); once through, the second socket takes over with no
    /// `disconnected`, no backoff and no third dial.
    func testAWakeRedialHandsOverWithoutWaitingOrBackingOff() async throws {
        let relay = try requireFake("holds pongs (fake only, R15)")
        let gate = DialGate()
        let (phone, tally, _) = try await paired(macs: [1], gate: gate)
        let session = HostedRelaySession(client: phone)
        let owner = await probe(session, zones: [])
        await waitUntilLive(session)
        let current = await session.connection
        let connection = try XCTUnwrap(current)
        relay.setPongs(false)
        defer { relay.setPongs(true) }
        gate.hold()

        let woke = OSAllocatedUnfairLock(initialState: false)
        let wake = Task {
            await session.wake()
            woke.withLock { $0 = true }
        }
        _ = await until { woke.withLock { $0 } }
        XCTAssertNil(connection.liveGeneration, "the silent socket is dropped: reads go over HTTPS")
        _ = await until { gate.waiting == 1 }
        relay.setPongs(true)
        gate.release()
        await wake.value
        _ = await until { owner.events.filter { $0 == .connected }.count == 2 }

        XCTAssertEqual(connection.liveGeneration, 2)
        XCTAssertFalse(owner.events.contains(.disconnected), "a handover, not a disconnect")
        XCTAssertEqual(tally.dials, 2, "no third dial")
        XCTAssertTrue(connection.isLive)
    }

    /// A caller of the wake that is cancelled (the app left) returns at once, though the wake itself still waits for
    /// its pong: the shared wake goes on, and the next caller joins it.
    func testACancelledWakeCallerReturnsWhileTheWakeGoesOn() async throws {
        let relay = try requireFake("holds pongs (fake only, R15)")
        let (phone, _, _) = try await paired(macs: [1])
        let session = HostedRelaySession(client: phone)
        _ = await probe(session, zones: [])
        await waitUntilLive(session)
        let current = await session.connection
        let connection = try XCTUnwrap(current)
        relay.setPongs(false)
        defer { relay.setPongs(true) }

        let returned = OSAllocatedUnfairLock(initialState: 0)
        let first = Task {
            await session.wake()
            returned.withLock { $0 += 1 }
        }
        for _ in 0..<1_000 { await Task.yield() }
        first.cancel()
        // The clock does not move: only the cancel can end the caller's wait.
        var back = false
        for _ in 0..<20_000 where !back {
            back = returned.withLock { $0 } == 1
            await Task.yield()
        }
        XCTAssertTrue(back, "the cancelled caller waited for the wake")
        XCTAssertEqual(connection.liveGeneration, 1, "the wake itself was not cancelled: still waiting for its pong")

        let second = Task {
            await session.wake()
            returned.withLock { $0 += 1 }
        }
        _ = await until { returned.withLock { $0 } == 2 }
        await first.value
        await second.value
        XCTAssertNil(connection.liveGeneration, "the shared wake ran to its end: the silent socket is dropped")
    }

    /// A pull that joins one its caller cancelled is not lost with it: it waits for the cancelled pull to end and
    /// reads its zones afresh.
    func testAPullJoiningACancelledPullReadsItsZones() async throws {
        let http = HTTPBox()
        let (phone, _, macs) = try await paired(macs: [1], wrapHTTP: http.wrap)
        let session = HostedRelaySession(client: phone)
        let store = try TransportStore.inMemory()
        let hub = try transport(session, mac: macs[0], store: store)
        let intercept = try http.intercept()
        intercept.answer(Self.scriptedPages(data: dataZone(macs[0]), mailbox: mailbox(macs[0], phone)))
        // Held without regard to cancellation: the cancelled pull is still running when the next one joins.
        intercept.holdNext { if case .changes = $0.op { true } else { false } }

        let first = Task { try await hub.pull() }
        _ = await until { intercept.holding }
        first.cancel()
        let second = Task { try await hub.pull() }
        for _ in 0..<1_000 { await Task.yield() }
        intercept.release()

        _ = await first.result
        try await second.value
        XCTAssertEqual(try store.changes(in: .data, since: nil).changed.map(\.recordName), ["a1", "a2", "a3"])
        XCTAssertEqual(try store.changes(in: .relay, since: nil).changed.map(\.recordName), ["b1"])
    }

    /// `changes` answered from a script: the data zone in two pages (a1 a2, then a3), the mailbox in one (b1).
    private static func scriptedPages(data: String, mailbox: String) -> @Sendable (Relay_V1_Request) throws -> Relay_V1_Response? {
        { request in
            guard case .changes(let changes) = request.op else { return nil }
            var page = Relay_V1_ChangesResult()
            func records(_ names: [String], from seq: UInt64) -> [Relay_V1_Record] {
                names.enumerated().map { offset, name in
                    var record = Relay_V1_Record()
                    record.zone = changes.zone
                    record.name = name
                    record.envelope = Data("envelope-\(name)".utf8)
                    record.recordSeq = seq + UInt64(offset)
                    record.clientModifiedAtMs = 1_700_000_000_000
                    return record
                }
            }
            switch (changes.zone, changes.sinceSeq) {
            case (data, 0):
                (page.changed, page.newSeq, page.more) = (records(["a1", "a2"], from: 1), 2, true)
            case (data, _):
                (page.changed, page.newSeq) = (records(["a3"], from: 3), 3)
            case (mailbox, 0):
                (page.changed, page.newSeq) = (records(["b1"], from: 1), 1)
            default:
                page.newSeq = changes.sinceSeq
            }
            var response = Relay_V1_Response()
            response.id = request.id
            response.changes = page
            return response
        }
    }

    // MARK: - Helpers

    /// The phone's `InterceptingRelayHTTP`, once `paired` built it.
    final class HTTPBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<InterceptingRelayHTTP?>(initialState: nil)

        func wrap(_ base: any RelayHTTP) -> any RelayHTTP {
            let http = InterceptingRelayHTTP(base)
            lock.withLock { $0 = http }
            return http
        }

        func ops() throws -> [String] {
            try intercept().ops
        }

        func intercept() throws -> InterceptingRelayHTTP {
            try XCTUnwrap(lock.withLock { $0 })
        }
    }

    static func record(_ name: String) -> CloudRecord {
        CloudRecord(
            recordName: name, zone: .relay, kind: WireKind.envelope, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            payload: Data("envelope-\(name)".utf8))
    }

    static func changes(_ zone: String) -> Relay_V1_Changes {
        var changes = Relay_V1_Changes()
        changes.zone = zone
        return changes
    }

    /// Re-checks `condition` (pumping the fake's clock) until it holds; no wall-clock cap.
    private func until(_ condition: @escaping () async -> Bool) async -> Bool {
        while !(await condition()) {
            pump()
            await Task.yield()
        }
        return true
    }

    /// Whether `condition` holds within a bounded number of yields (pumping the fake's clock; no wall clock).
    private func within(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<50_000 {
            if condition() { return true }
            pump()
            await Task.yield()
        }
        return condition()
    }

    /// Dials and displacements (`GoingAway`) of one client.
    final class SocketTally: Sendable {
        private let counts = OSAllocatedUnfairLock(initialState: (dials: 0, displacements: 0))

        var dials: Int {
            counts.withLock { $0.dials }
        }

        var displacements: Int {
            counts.withLock { $0.displacements }
        }

        func dialed() {
            counts.withLock { $0.dials += 1 }
        }

        func displaced() {
            counts.withLock { $0.displacements += 1 }
        }
    }

    /// Holds dials before they reach the relay (before the upgrade) while `hold()` is on; a held dial whose task is
    /// cancelled throws.
    final class DialGate: Sendable {
        private struct State {
            var holding = false
            var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]
            var nextID = 0
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var waiting: Int {
            state.withLock { $0.waiting.count }
        }

        func hold() {
            state.withLock { $0.holding = true }
        }

        func release() {
            let all = state.withLock { state in
                state.holding = false
                defer { state.waiting = [:] }
                return Array(state.waiting.values)
            }
            for waiter in all { waiter.resume() }
        }

        func pass() async throws {
            let id = state.withLock { state in
                state.nextID += 1
                return state.nextID
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let now: Result<Void, any Error>? = state.withLock { state in
                        if Task.isCancelled { return .failure(CancellationError()) }
                        guard state.holding else { return .success(()) }
                        state.waiting[id] = continuation
                        return nil
                    }
                    if let now { continuation.resume(with: now) }
                }
            } onCancel: {
                let waiter = state.withLock { $0.waiting.removeValue(forKey: id) }
                waiter?.resume(throwing: CancellationError())
            }
        }
    }

    struct CountingDialer: RelaySocketDialer {
        let base: any RelaySocketDialer
        let tally: SocketTally

        var gate: DialGate?

        func dial(_ url: URL, headers: [String: String]) async throws -> any RelaySocket {
            tally.dialed()
            try await gate?.pass()
            return try await base.dial(url, headers: headers)
        }
    }

    struct ZoneEvent: Equatable {
        let zone: String
        let seq: UInt64
    }

    /// An owner that records what the session routes to it.
    final class Probe: Sendable {
        private let received = OSAllocatedUnfairLock<[HostedRelayClientEvent]>(initialState: [])

        var events: [HostedRelayClientEvent] {
            received.withLock { $0 }
        }

        var zoneEvents: [ZoneEvent] {
            events.compactMap { event in
                guard case let .zoneChanged(zone, seq, _) = event else { return nil }
                return ZoneEvent(zone: zone, seq: seq)
            }
        }

        func record(_ event: HostedRelayClientEvent) {
            received.withLock { $0.append(event) }
        }
    }

    /// Collects a stream of relay events.
    final class EventCollector: Sendable {
        private let received = OSAllocatedUnfairLock<[HostedRelayEvent]>(initialState: [])

        var events: [HostedRelayEvent] {
            received.withLock { $0 }
        }

        func record(_ event: HostedRelayEvent) {
            received.withLock { $0.append(event) }
        }
    }

    /// A paying phone (seed 2) whose dials are counted, paired with the Macs of `seeds`.
    private func paired(
        macs seeds: [UInt8], wrapHTTP: ((any RelayHTTP) -> any RelayHTTP)? = nil, gate: DialGate? = nil
    ) async throws -> (HostedRelayClient, SocketTally, [HostedRelayClient]) {
        let tally = SocketTally()
        let signer = try backend.signer(seed: 2)
        let clock = backend.clock
        let phone = HostedRelayClient(
            origin: try backend.origin,
            signer: signer,
            kind: .phone,
            attestor: RelayAttestor(attest: fakeAttest(seed: 2), keys: InMemoryAppAttestKeyStore(), clock: clock),
            http: wrapHTTP?(backend.http) ?? backend.http,
            sockets: CountingDialer(base: backend.sockets, tally: tally, gate: gate),
            clock: clock,
            backoff: Self.quickBackoff
        ) { tally.displaced() }
        _ = try await phone.register()
        try await phone.login()
        try await pay(phone)
        var macs: [HostedRelayClient] = []
        for seed in seeds {
            let mac = try await makeClient(kind: .mac, seed: seed)
            try await stand.pair(mac: mac.deviceID, phones: [phone.deviceID])
            macs.append(mac)
        }
        return (phone, tally, macs)
    }

    private func transport(
        _ session: HostedRelaySession, mac: HostedRelayClient, store: TransportStore? = nil
    ) throws -> HostedRelayTransport {
        let transport = try HostedRelayTransport(session: session, store: store ?? TransportStore.inMemory(), macDeviceID: mac.deviceID)
        transports.append(transport)
        return transport
    }

    private func log(_ transport: HostedRelayTransport) async -> TransportEventLog {
        let log = TransportEventLog()
        await log.attach(to: transport)
        eventLogs.append(log)
        return log
    }

    private func probe(_ session: HostedRelaySession, zones: [String]) async -> Probe {
        let probe = Probe()
        probes.append((session, probe))
        await session.attach(owner: ObjectIdentifier(probe), zones: zones) { event in probe.record(event) }
        return probe
    }

    private func collect(_ stream: AsyncStream<HostedRelayEvent>) -> EventCollector {
        let collector = EventCollector()
        let reader = Task {
            for await event in stream { collector.record(event) }
        }
        readers.append(reader)
        return collector
    }

    private func dataZone(_ mac: HostedRelayClient) -> String {
        HostedRelayZones.data(mac: mac.deviceID)
    }

    private func mailbox(_ mac: HostedRelayClient, _ phone: HostedRelayClient) -> String {
        HostedRelayZones.mailbox(mac: mac.deviceID, phone: phone.deviceID)
    }

    /// Every zone subscribed on a socket after the first `after` ops.
    private func subscribed(after: Int = 0) -> Set<String> {
        Set(backend.opLog.dropFirst(after).flatMap { op -> [String] in
            guard case .subscribe(let subscribe) = op else { return [] }
            return subscribe.zones
        })
    }
}
