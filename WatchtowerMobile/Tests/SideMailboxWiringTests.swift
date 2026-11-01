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
        await bed.fetch(first)
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
        await bed.root.routeMoves[hubID]?.value
    }

    /// `TestSwitchToCloudKitDuringRelayOutage`'s second phone: another phone switched the hub to CloudKit while the
    /// relay was down; this one stays on the relay before 60 s and follows after, its unread action sent on CloudKit.
    func testASwitchWrittenDuringAnOutageIsFollowed() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let first = try await bed.orderedSession()
        let envelopes = try await bed.sendTwoActions(first)
        let reader = try XCTUnwrap(first.sideReader)
        bed.fake.crash()
        await bed.fetch(first)
        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .cloudKit)

        for step in [0, 30, 29] as [TimeInterval] {
            bed.clock.advance(step)
            await reader.tick()
        }
        XCTAssertEqual(try bed.row()?.link.transport, .relay, "before 60 s")
        XCTAssertTrue(bed.root.env.session(hubID) === first)

        bed.clock.advance(2)
        await reader.tick()
        await bed.root.routeMoves[hubID]?.value
        let second = try bed.session()
        XCTAssertFalse(second === first, "the session moved")
        XCTAssertEqual(second.route, .cloudKit(.private), "after 60 s")
        XCTAssertEqual(try bed.row()?.link.leftTransport, .relay)
        XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), [1, 2])
        await second.waitForBoot()
        await bed.fetch(second)
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

    /// Sim rule 16: a lapsed account's relay refuses the deletes; the refusal is logged and the drain stops until the
    /// next launch (the row keeps the transport to drain), nothing is tried again meanwhile.
    func testARefusedDrainStopsUntilTheNextLaunch() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let second = try await bed.switchedToCloudKit()
        let reader = try XCTUnwrap(second.sideReader)
        bed.fake.failNext("delete", with: .entitlementInactive)

        await reader.tick()
        let deletes = bed.fake.log.filter { if case .delete = $0 { true } else { false } }.count
        await reader.tick()

        XCTAssertEqual(try bed.row()?.link.leftTransport, .relay)
        let after = try await bed.relayMailbox()
        XCTAssertFalse(after.isEmpty)
        let deletesAfter = bed.fake.log.filter { if case .delete = $0 { true } else { false } }.count
        XCTAssertEqual(deletesAfter, deletes, "no second try in this launch")
    }

    // MARK: - Which hubs, and how

    /// A relay link from a code without CloudKit has no CloudKit route: no reader, no poll, nothing built.
    func testNoPollWithoutACloudKitRoute() async throws {
        let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
        let first = try await bed.orderedSession()
        bed.fake.crash()
        await bed.fetch(first)

        XCTAssertNil(try bed.row()?.link.otherRoute)
        XCTAssertNil(first.sideReader)
        XCTAssertTrue(bed.sides.routes.isEmpty)
        let both = try await Bed.make(self, on: .relay)
        XCTAssertNotNil(try both.session().sideReader, "a hub with both routes gets one")
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
