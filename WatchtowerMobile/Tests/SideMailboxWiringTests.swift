import Foundation
import WatchtowerE2ETesting
import WatchtowerHostedRelay
import WatchtowerRelayProto
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The mailbox on the hub's other transport (relay client Phase 3 Task 12; sim rules 12, 15 and 16): the live
/// `AppRoot` over `Bed` (CloudKit in memory, the relay on `FakeHostedRelay`), each session's `SideMailboxReader`
/// stepped by hand on the bed's clock.
@MainActor
final class SideMailboxWiringTests: XCTestCase {
    private let hubID = TestE2E.hubID.uuidString

    // MARK: - Rule 12: the CloudKit poll while the relay is down

    func testRelayDownSixtySecondsReadsTheCloudKitMailbox() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let first = try await bed.orderedSession()
        let reader = try XCTUnwrap(first.sideReader)
        bed.fake.crash()
        try await bed.fetch(first)
        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .cloudKit)

        await reader.tick() // the outage starts
        bed.clock.advance(60)
        await reader.tick()
        XCTAssertFalse(try Bed.handled(first, bed.switchID), "not past 60 s: CloudKit is not read")
        let unread = try await bed.cloudMailboxNames()
        XCTAssertTrue(unread.contains(try bed.switchWire))

        bed.clock.advance(1)
        await reader.tick()
        XCTAssertTrue(try Bed.handled(first, bed.switchID), "read on CloudKit and decided by the follower")
        let read = try await bed.cloudMailboxNames()
        XCTAssertFalse(read.contains(try bed.switchWire), "deleted where it was read")
        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        try await bed.root.routeMoves[hubID]?.value
    }

    /// `TestSwitchToCloudKitDuringRelayOutage`'s second phone: another phone switched the hub to CloudKit while the
    /// relay was down; this one stays on the relay before 60 s and follows after, its unread action sent on CloudKit.
    func testASwitchWrittenDuringAnOutageIsFollowed() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let first = try await bed.orderedSession()
        let envelopes = try await bed.sendTwoActions(first)
        let reader = try XCTUnwrap(first.sideReader)
        bed.fake.crash()
        try await bed.fetch(first)
        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .cloudKit)

        for step in [0, 30, 29] as [TimeInterval] {
            bed.clock.advance(step)
            await reader.tick()
        }
        XCTAssertEqual(try bed.row()?.link.transport, .relay, "before 60 s")
        XCTAssertTrue(bed.root.env.session(hubID) === first)

        bed.clock.advance(2)
        await reader.tick()
        try await bed.root.routeMoves[hubID]?.value
        let second = try bed.session()
        XCTAssertFalse(second === first, "the session moved")
        XCTAssertEqual(second.route, .cloudKit(.private), "after 60 s")
        XCTAssertEqual(try bed.row()?.link.leftTransport, .relay)
        XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), [1, 2])
        await second.waitForBoot()
        try await bed.fetch(second)
        let onCloud = try await bed.cloudMailbox()
        for envelope in envelopes {
            XCTAssertTrue(onCloud.contains { $0.payload == envelope }, "the same bytes on CloudKit")
        }
    }

    // MARK: - Rule 15: the drain after a switch

    /// `TestNoCopiesLeftOnRelayAfterSwitch`'s phone: nothing is left in the relay mailbox the phone left, once the
    /// relay answers again; until then the row keeps the transport to drain.
    func testTheOldMailboxIsDrainedOnceReachable() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let second = try await bed.switchedToCloudKit()
        let reader = try XCTUnwrap(second.sideReader)

        bed.fake.crash()
        await reader.tick()
        XCTAssertEqual(try bed.row()?.link.leftTransport, .relay, "the relay does not answer: nothing drained")

        bed.fake.restart()
        let before = try await bed.relayMailbox()
        XCTAssertFalse(before.isEmpty, "the phone's own actions are still there")
        await reader.tick()
        let after = try await bed.relayMailbox()
        XCTAssertTrue(after.isEmpty, "left on relay: \(after.count)")
        XCTAssertNil(try bed.row()?.link.leftTransport)
        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        XCTAssertEqual(try Bed.rows(second, .sent).count, 2, "the drain never touches the outbox")
    }

    func testUnseenHubRecordsAreHandledBeforeTheDrainDeletes() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let second = try await bed.switchedToCloudKit()
        let reader = try XCTUnwrap(second.sideReader)
        let rejected = try await bed.writeHubControl(.transportSwitchRejected, on: .relay)
        XCTAssertFalse(try Bed.handled(second, rejected.id))

        await reader.tick()

        XCTAssertTrue(try Bed.handled(second, rejected.id), "read once, then deleted with the rest")
        let after = try await bed.relayMailbox()
        XCTAssertTrue(after.isEmpty)
        XCTAssertNil(try bed.row()?.link.leftTransport)
    }

    /// The other direction: switched to the relay, the CloudKit mailbox left is read from the start (the store wiped
    /// before its engine starts), the hub's unread echo settles its row, everything else of the phone's goes but its
    /// `device` record (both hubs keep that lane), and the side stops once nothing needs it.
    func testTheLeftCloudKitMailboxIsDrainedOnceReachable() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()
        let device = CloudRecord(
            recordName: "device-\(TestE2E.deviceID.uuidString)", zone: .relay, kind: RelayRecordKind.device.rawValue,
            modifiedAt: Date(), payload: Data("{}".utf8))
        let sealedDevice = try await first.saveSealing(device)
        try await bed.sendTwoActions(first)
        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        let second = try await bed.fetchAndFollow(first)
        XCTAssertEqual(try bed.row()?.link.leftTransport, .cloudKit)
        try await bed.echoOnCloudKit(seq: 1, of: second)
        let reader = try XCTUnwrap(second.sideReader)

        await reader.tick()

        let left = try await bed.cloudMailbox().map(\.recordName)
        XCTAssertEqual(left, [sealedDevice.recordName], "only the device record stays")
        XCTAssertEqual(try Bed.rows(second, .sent).map(\.actionSeq), [2], "the echo settled seq 1; seq 2 waits on the relay")
        XCTAssertNil(try bed.row()?.link.leftTransport)
        let side = try XCTUnwrap(bed.sides.cloud.first)
        let leftover = await side.leftoverAtStart
        XCTAssertEqual(leftover, [false], "the store was wiped before the engine started")
        let stops = await side.stops
        XCTAssertEqual(stops, 1, "stopped once drained: the relay answers, no outage")
    }

    /// Sim rule 16 on the deletes: a lapsed (`ENTITLEMENT_INACTIVE`) or forbidden (`FORBIDDEN`) account stops the drain
    /// until the next launch, the row keeps the transport to drain; any other refusal is tried again on the next look.
    func testARefusedDrainStopsUntilTheNextLaunch() async throws {
        let cases: [(code: Relay_V1_ErrorCode, stops: Bool)] = [(.entitlementInactive, true), (.forbidden, true), (.rateLimited, false)]
        for (code, stops) in cases {
            let bed = try await Bed.make(self, on: .relay)
            let second = try await bed.switchedToCloudKit()
            let reader = try XCTUnwrap(second.sideReader)
            bed.fake.failNext("delete", with: code)

            await reader.tick()
            let deletes = bed.fake.log.filter { if case .delete = $0 { true } else { false } }.count
            await reader.tick()

            let deletesAfter = bed.fake.log.filter { if case .delete = $0 { true } else { false } }.count
            let after = try await bed.relayMailbox()
            if stops {
                XCTAssertEqual(try bed.row()?.link.leftTransport, .relay, "\(code)")
                XCTAssertFalse(after.isEmpty, "\(code)")
                XCTAssertEqual(deletesAfter, deletes, "\(code): no second try in this launch")
            } else {
                XCTAssertNil(try bed.row()?.link.leftTransport, "\(code): drained on the next look")
                XCTAssertTrue(after.isEmpty, "\(code)")
            }
        }
    }

    /// Rule 16 on the read: the relay refusing the mailbox read stops the drain until the next launch too; the drain
    /// reads the mailbox zone alone, never the data zone.
    func testARefusedMailboxReadStopsTheDrainUntilTheNextLaunch() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let second = try await bed.switchedToCloudKit()
        let reader = try XCTUnwrap(second.sideReader)
        let reads = bed.fake.log.count
        bed.fake.failNext("changes", with: .forbidden)

        await reader.tick()
        let firstLook = Array(bed.fake.log.dropFirst(reads))
        await reader.tick()

        XCTAssertEqual(bed.fake.log.count, reads + firstLook.count, "no read in the second look")
        let zones = firstLook.compactMap { if case .changes(let changes) = $0 { changes.zone } else { nil } }
        XCTAssertFalse(zones.isEmpty)
        XCTAssertFalse(zones.contains { $0.hasPrefix("data/") }, "the mailbox alone: \(zones)")
        XCTAssertEqual(try bed.row()?.link.leftTransport, .relay)
    }

    // MARK: - Lifecycle

    /// A stop while a look waits on the CloudKit mailbox waits for that look, which then decides nothing (the switch
    /// read there stays for the next session), deletes nothing and builds nothing more; the side is stopped once.
    func testAStopDuringALookWaitsForItAndBuildsNothingAfter() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let first = try await bed.orderedSession()
        let reader = try XCTUnwrap(first.sideReader)
        bed.fake.crash()
        try await bed.fetch(first)
        await reader.tick()
        bed.clock.advance(61)
        await reader.tick() // the first poll builds the CloudKit side; nothing there yet
        let side = try XCTUnwrap(bed.sides.cloud.first)
        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .cloudKit)
        await side.hold()
        bed.clock.advance(30)

        let looking = Task { await reader.tick() }
        let held = await side.readIsHeld()
        XCTAssertTrue(held, "the look never reached the relay-zone read")
        let stopping = Task { await reader.stop() }
        await side.release()
        try await stopping.value
        try await looking.value

        XCTAssertFalse(try Bed.handled(first, bed.switchID), "read after the stop: left undecided")
        XCTAssertEqual(try bed.row()?.link.transport, .relay)
        XCTAssertEqual(bed.sides.routes.count, 1, "nothing built after the stop")
        let stops = await side.stops
        let late = await side.callsAfterStop
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(late, 0, "nothing reaches the side after its stop")
        await reader.tick()
        XCTAssertEqual(bed.sides.routes.count, 1, "a stopped reader never looks again")
    }

    /// Final review M2: a look hung on the other transport holds `stop()` for `stopLookCap` at most; then the look is
    /// cancelled and the transport stopped anyway, and the late look reaches nothing.
    func testAStopCutsOffAHungLookAtTheCap() async throws {
        let bed = try await Bed.make(self, on: .relay, stopLookCapRunsOut: true)
        let first = try await bed.orderedSession()
        let reader = try XCTUnwrap(first.sideReader)
        bed.fake.crash()
        try await bed.fetch(first)
        await reader.tick()
        bed.clock.advance(61)
        await reader.tick() // the first poll builds the CloudKit side
        let side = try XCTUnwrap(bed.sides.cloud.first)
        await side.hold()
        bed.clock.advance(30)
        let looking = Task { await reader.tick() }
        let held = await side.readIsHeld()
        XCTAssertTrue(held, "the look never reached the relay-zone read")

        var stopped = false
        let stopping = Task {
            await reader.stop()
            stopped = true
        }
        await stopping.value
        XCTAssertTrue(stopped, "stop() returned at its cap for a look that never answers")

        let stops = await side.stops
        XCTAssertEqual(stops, 1, "stopped at the cap")
        await side.release()
        try await stopping.value
        try await looking.value
        let late = await side.callsAfterStop
        XCTAssertEqual(late, 0, "the late look reaches nothing")
    }

    /// Final review M1: a `stop()` that comes while a stand-down is still closing the other transport returns only once
    /// that close ended, so the next session never opens the same store while it is still closing.
    func testAStopWaitsForAStandDownStillClosingTheSide() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let first = try await bed.orderedSession()
        let reader = try XCTUnwrap(first.sideReader)
        bed.fake.crash()
        try await bed.fetch(first)
        await reader.tick()
        bed.clock.advance(61)
        await reader.tick() // the first poll builds the CloudKit side
        let side = try XCTUnwrap(bed.sides.cloud.first)
        await side.holdStop()
        first.setActive(false)
        let holding = await side.stopIsHeld()
        XCTAssertTrue(holding, "the stand-down never stopped the side")

        let stopping = Task {
            await reader.stop()
            return await side.stopEnded
        }
        // Main-actor jobs run in order: the stop() queued first runs up to its wait on the close before this resumes,
        // so an early return of stop() would happen here.
        await Task.yield()
        await side.releaseStop()
        let closedFirst = try await stopping.value

        let stops = await side.stops
        XCTAssertTrue(closedFirst, "stop() returned only after the close")
        XCTAssertEqual(stops, 1, "one close")
    }

    /// F4: the CloudKit side's engine stops when the outage ends, and when the app leaves the foreground.
    func testTheCloudKitSideStopsWhenTheOutageEndsOrTheAppLeaves() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let first = try await bed.orderedSession()
        let reader = try XCTUnwrap(first.sideReader)
        bed.fake.crash()
        try await bed.fetch(first)
        await reader.tick()
        bed.clock.advance(61)
        await reader.tick()
        let polled = try XCTUnwrap(bed.sides.cloud.first)
        let started = await polled.starts
        XCTAssertEqual(started, 1)
        let leftover = await polled.leftoverAtStart
        XCTAssertEqual(leftover, [true], "a poll does not wipe the store")

        bed.fake.restart()
        try await bed.fetch(first)
        await reader.tick()
        let stoppedAtTheEnd = await polled.stops
        XCTAssertEqual(stoppedAtTheEnd, 1, "the relay answers again")

        bed.fake.crash()
        try await bed.fetch(first)
        await reader.tick()
        bed.clock.advance(61)
        await reader.tick()
        let again = try XCTUnwrap(bed.sides.cloud.last)
        XCTAssertFalse(again === polled)
        first.setActive(false)
        try await reader.wake?.value
        let stoppedOnLeaving = await again.stops
        XCTAssertEqual(stoppedOnLeaving, 1, "the app left the foreground")
    }

    /// F5: a look right after the boot and on the return to the foreground, without waiting for the interval.
    func testALookRunsAtBootAndOnReturnToTheForeground() async throws {
        let bed = try await Bed.make(self, on: .relay, looksAtWake: true)
        let first = try await bed.orderedSession()
        try await bed.sendTwoActions(first)
        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .relay)
        try await bed.fetch(first)
        bed.fake.crash() // before the next session's boot look
        try await bed.root.routeMoves[hubID]?.value
        let second = try bed.session()
        await second.waitForBoot()
        let reader = try XCTUnwrap(second.sideReader)
        try await reader.wake?.value
        XCTAssertEqual(try bed.row()?.link.leftTransport, .relay, "the boot look found the relay down")

        bed.fake.restart()
        second.setActive(false)
        try await reader.wake?.value
        second.setActive(true)
        try await reader.wake?.value

        XCTAssertNil(try bed.row()?.link.leftTransport, "drained by the look on the return")
        let after = try await bed.relayMailbox()
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: - Which hubs, and how

    /// A relay link from a code without CloudKit has no CloudKit route: no reader, no poll, nothing built.
    func testNoPollWithoutACloudKitRoute() async throws {
        let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
        let first = try await bed.orderedSession()
        bed.fake.crash()
        try await bed.fetch(first)

        XCTAssertNil(try bed.row()?.link.otherRoute)
        XCTAssertNil(first.sideReader)
        XCTAssertTrue(bed.sides.routes.isEmpty)
        let both = try await Bed.make(self, on: .relay)
        XCTAssertNotNil(try both.session().sideReader, "a hub with both routes gets one")
    }

    /// A route the factory does not serve (the relay off) is refused before its store is opened: no file is left.
    func testAnUnservedSideRouteOpensNoStore() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("side-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let paths = HubPaths(groupDirectory: base, localDirectory: base, recordingsBase: base)
        let factory = HubSessionFactory.live(paths: paths, keys: try TestE2E.phoneStore())
        let route = HubRoute.hostedRelay(macDeviceID: "mac-acme")

        XCTAssertThrowsError(try factory.makeSide(hubID, route))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.transportStorePath(hubID, route: route)))
    }

    /// The relay transport the reader drains through is the factory's, on the process's one relay session: no socket
    /// of its own, no second login.
    func testThePollUsesTheSharedSocket() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let second = try await bed.switchedToCloudKit()
        let reader = try XCTUnwrap(second.sideReader)
        let dials = bed.sockets.dials
        let logins = bed.fake.log.filter { if case .login = $0 { true } else { false } }.count

        await reader.tick()

        let after = try await bed.relayMailbox()
        XCTAssertTrue(after.isEmpty, "the drain went through")
        XCTAssertEqual(bed.sides.routes, [.hostedRelay(macDeviceID: bed.mac.deviceID)])
        XCTAssertEqual(bed.sockets.dials, dials, "no socket dialed for the side transport")
        XCTAssertLessThanOrEqual(bed.sockets.mostOpenAtOnce, 1)
        let loginsAfter = bed.fake.log.filter { if case .login = $0 { true } else { false } }.count
        XCTAssertEqual(loginsAfter, logins, "the shared session's client, logged in once")
    }
}

extension Bed {
    /// The hub's `applied` echo of `session`'s ordered action `seq`, written over it in the CloudKit mailbox.
    func echoOnCloudKit(seq: UInt64, of session: HubSession) async throws {
        let row = try XCTUnwrap(try session.store.pendingActions().first { $0.actionSeq == seq })
        var echo = row.action
        echo.status = .applied
        let plain = try CloudRecordFactory.orderedRecord(for: echo, actionSeq: seq, deviceID: TestE2E.deviceID, modifiedAt: Date())
        try await TestPhone.hub(over: cloud.inner).save([plain])
    }

    /// A hub on the relay with two actions sent there, switched to CloudKit by a control in the relay mailbox: the
    /// session on CloudKit, with the relay mailbox left to drain.
    func switchedToCloudKit() async throws -> HubSession {
        let first = try await orderedSession()
        try await sendTwoActions(first)
        try await writeSwitch(target: .cloudKit, epoch: 2, on: .relay)
        let second = try await fetchAndFollow(first)
        XCTAssertEqual(try row()?.link.leftTransport, .relay)
        return second
    }
}
