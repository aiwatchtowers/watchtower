import XCTest
@testable import WatchtowerCore

final class SessionDeletePolicyTests: XCTestCase {
    private typealias Kind = SessionSwitcherPresentation.State.Kind

    private static let allKinds: [Kind] = [
        .notStarted, .running, .working, .needsApproval, .failed, .waitingOnAsk, .stopped, .finished, .background
    ]

    /// Live: only an agent that is done (finished, stopped, failed) goes
    /// without the confirmation.
    private static let quickWhenLive: Set<String> = ["finished", "stopped", "failed"]

    private func isQuick(_ kind: Kind, live: Bool, workbench: Bool) -> Bool {
        SessionDeletePolicy.isQuick(
            SessionSwitcherPresentation.State(kind: kind, live: live, openAsks: kind == .waitingOnAsk ? 1 : 0),
            isWorkbenchSession: workbench
        )
    }

    func testQuickDeleteTable() {
        for kind in Self.allKinds {
            let name = "\(kind)"
            XCTAssertTrue(isQuick(kind, live: false, workbench: true), "\(name) not live: no process to kill")
            XCTAssertEqual(isQuick(kind, live: true, workbench: true), Self.quickWhenLive.contains(name),
                           "\(name) live")
            XCTAssertFalse(isQuick(kind, live: false, workbench: false), "\(name) standalone, not live")
            XCTAssertFalse(isQuick(kind, live: true, workbench: false), "\(name) standalone, live")
        }
    }
}
