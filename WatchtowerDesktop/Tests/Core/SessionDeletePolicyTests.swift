import XCTest
@testable import WatchtowerCore

final class SessionDeletePolicyTests: XCTestCase {
    private typealias Kind = SessionSwitcherPresentation.State.Kind

    /// Live: only an agent that is done goes without the confirmation. An
    /// exhaustive switch, so a new kind fails to compile until classified.
    private static func quickWhenLive(_ kind: Kind) -> Bool {
        switch kind {
        case .finished, .stopped, .failed:
            return true
        case .notStarted, .running, .working, .needsApproval, .waitingOnAsk, .readyToCheck, .background:
            return false
        }
    }

    private func isQuick(_ kind: Kind, live: Bool, workbench: Bool) -> Bool {
        SessionDeletePolicy.isQuick(
            SessionSwitcherPresentation.State(kind: kind, live: live, openAsks: kind == .waitingOnAsk ? 1 : 0),
            isWorkbenchSession: workbench
        )
    }

    func testQuickDeleteTable() {
        for kind in Kind.allCases {
            let name = "\(kind)"
            XCTAssertTrue(isQuick(kind, live: false, workbench: true), "\(name) not live: no process to kill")
            XCTAssertEqual(isQuick(kind, live: true, workbench: true), Self.quickWhenLive(kind),
                           "\(name) live")
            XCTAssertFalse(isQuick(kind, live: false, workbench: false), "\(name) standalone, not live")
            XCTAssertFalse(isQuick(kind, live: true, workbench: false), "\(name) standalone, live")
        }
    }
}
