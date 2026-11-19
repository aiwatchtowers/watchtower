import Foundation
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
@testable import WatchtowerSync
import XCTest

/// The sim run of the phone's lost slot (relay client Phase 5, Task 13). Not a twin: relay@3a99bd7's
/// `sim/sim_interop_test.go` has no such test, so it stays out of `RelaySimSwitchTwins` and the census.
final class RelaySimSlotLostTests: HostedRelayScenarioCase {
    /// The policy's `slotLost` run by the twin: the action written on the relay is withdrawn before the hub reads it,
    /// listed, and never applied; the phone moves to CloudKit without waiting for `hub_on_relay`, the hub stays.
    func testSlotLostWithdrawsMovesAndIsNeverApplied() async throws {
        let (world, phones) = try await newWorld(2)
        let (a, b) = (phones[0], phones[1])
        await a.act("a1") // written on the relay, not yet read by the hub
        await a.slotLost()
        try await world.syncAll()
        await wantTransport("phone", a.transport, .cloudkit)
        await wantTransport("hub", world.hub.transport, .relay)
        await wantApplied(world, a)
        let undelivered = await a.undelivered
        XCTAssertEqual(undelivered, [SimUndelivered(seq: 1, payload: "a1")], "withdrawn and listed")
        let dropped = await a.droppedEphemeral
        XCTAssertFalse(dropped, "no key goes on a lost slot")
        await b.act("b1")
        try await world.syncAll()
        await wantApplied(world, b, "1:b1")
    }

    // MARK: - Helpers (as `RelaySimSwitchTwins`' Go helpers)

    /// Go `newWorld(t, n)`: a Mac with `n` paying phones, everything on the relay in epoch 1.
    private func newWorld(_ count: Int) async throws -> (SimWorld, [SimPhone]) {
        let world = try await simWorld()
        for _ in 0..<count {
            _ = try await world.addPhone(paying: true)
        }
        return (world, world.phones)
    }

    private func wantTransport(
        _ name: String, _ got: SimKind, _ want: SimKind, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(got, want, "\(name) on \(got), want \(want)", file: file, line: line)
    }

    private func wantApplied(
        _ world: SimWorld, _ phone: SimPhone, _ want: String..., file: StaticString = #filePath, line: UInt = #line
    ) async {
        let got = await world.hub.applied(from: phone)
        XCTAssertEqual(got, want, "applied from \(phone.id.prefix(6))", file: file, line: line)
    }
}
