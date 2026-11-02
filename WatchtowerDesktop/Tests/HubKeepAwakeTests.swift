import Foundation
import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// "Keep this Mac awake for the iPhone" over the Go hub (go hub plan 3
/// Task 23): the Swift hub's `KeepAwakeCompanion` rule, taken by Desktop.
@MainActor
final class HubKeepAwakeTests: XCTestCase {
    private final class FakePower: PowerAsserting {
        var created = 0
        var released: [UInt32] = []

        func create(reason: String) -> UInt32? {
            created += 1
            return UInt32(created)
        }

        func release(_ id: UInt32) { released.append(id) }
    }

    private final class Inputs {
        var enabled = true
        var running = true
        var sessions = 1
        var contact: Date?
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func make(_ inputs: Inputs, power: FakePower) -> HubKeepAwake {
        let clock: () -> Date = { [now] in now }
        return HubKeepAwake(
            assertion: MacAwakeAssertion(power: power),
            inputs: .init(
                enabled: { inputs.enabled }, hubRunning: { inputs.running },
                liveBoardSessions: { inputs.sessions }, lastPhoneContact: { inputs.contact }
            ),
            now: clock
        )
    }

    /// Held while the hub runs, the switch is on, a board session runs and a
    /// phone was in touch within 24 hours; released as soon as any of them
    /// stops, and by `stop()`.
    func testHoldsOnlyWhileEveryConditionHolds() {
        let power = FakePower()
        let inputs = Inputs()
        inputs.contact = now.addingTimeInterval(-60)
        let keepAwake = make(inputs, power: power)
        keepAwake.evaluate()
        XCTAssertTrue(keepAwake.isHolding)

        for change in [
            { inputs.enabled = false }, { inputs.running = false }, { inputs.sessions = 0 },
            { inputs.contact = self.now.addingTimeInterval(-86_401) }, { inputs.contact = nil }
        ] {
            inputs.enabled = true
            inputs.running = true
            inputs.sessions = 1
            inputs.contact = now.addingTimeInterval(-60)
            keepAwake.evaluate()
            XCTAssertTrue(keepAwake.isHolding)
            change()
            keepAwake.evaluate()
            XCTAssertFalse(keepAwake.isHolding)
        }

        inputs.enabled = true
        inputs.contact = now.addingTimeInterval(-60)
        keepAwake.evaluate()
        XCTAssertTrue(keepAwake.isHolding)
        keepAwake.stop()
        XCTAssertFalse(keepAwake.isHolding, "a quit or a rebuilt hub center drops it")
        XCTAssertEqual(power.released.count, power.created)
    }

    /// The live board sessions: workbenches with a live agent session; a
    /// live plain shell alone is not one.
    func testALiveShellAloneIsNotABoardSession() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (shell, agent) = try pool.write { db -> (Int64, Int64) in
            let project = try TestDatabase.insertWorkbench(db)
            return (
                try SliceSeed.insertSession(db, projectID: project, kind: "shell"),
                try SliceSeed.insertSession(db, projectID: project, kind: "claude")
            )
        }
        XCTAssertEqual(HubKeepAwake.liveBoardSessions(pool, liveIDs: []), 0)
        XCTAssertEqual(HubKeepAwake.liveBoardSessions(pool, liveIDs: [shell]), 0)
        XCTAssertEqual(HubKeepAwake.liveBoardSessions(pool, liveIDs: [shell, agent]), 1)
        XCTAssertEqual(HubKeepAwake.liveBoardSessions(nil, liveIDs: [agent]), 0)
    }

    /// The heartbeat answer's last phone contact reaches the keep-awake.
    func testHeartbeatAnswerCarriesThePhoneContact() throws {
        let line = #"{"op":"desktop_heartbeat","ok":true,"phone_contact_at":"2026-11-02T10:42:00.5Z"}"#
        let answer = try JSONDecoder().decode(HubControlAnswer.self, from: Data(line.utf8))
        XCTAssertEqual(answer.phoneContactAt?.timeIntervalSince1970 ?? 0, 1_793_616_120.5, accuracy: 0.01)
        let none = try JSONDecoder().decode(HubControlAnswer.self, from: Data(#"{"op":"desktop_heartbeat","ok":true}"#.utf8))
        XCTAssertNil(none.phoneContactAt)
    }
}
