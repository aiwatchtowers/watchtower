import XCTest
@testable import WatchtowerCore

final class GoToPresentationTests: XCTestCase {
    private let alpha = Workbench(row: ["id": 1, "name": "alpha", "folder_path": "/tmp/1"])
    private let beta = Workbench(row: ["id": 2, "name": "Beta Ünit", "folder_path": "/tmp/2"])

    private func session(_ workbench: Workbench, _ title: String) -> TerminalSession {
        TerminalSession(
            id: 1, projectID: workbench.id, kind: .claude, title: title, titleSource: .auto, targetID: nil,
            folderPath: workbench.folderPath, claudeSessionID: "uuid",
            createdAt: "2026-09-01T10:00:00Z", lastActiveAt: "2026-09-01T10:00:00Z"
        )
    }

    func testSectionTitles() {
        XCTAssertEqual(GoToPresentation.sectionTitle(.currentSessions, currentWorkbench: "Beta Ünit"), "SESSIONS · BETA ÜNIT")
        XCTAssertEqual(GoToPresentation.sectionTitle(.otherWorkbenches, currentWorkbench: "alpha"), "OTHER WORKBENCHES")
    }

    func testASessionOfAnotherWorkbenchCarriesItsName() {
        XCTAssertEqual(GoToPresentation.sessionTitle(session(alpha, "Fix login"), workbench: alpha, currentWorkbenchID: 1),
                       "Fix login")
        XCTAssertEqual(GoToPresentation.sessionTitle(session(beta, "Fix login"), workbench: beta, currentWorkbenchID: 1),
                       "Beta Ünit › Fix login")
        XCTAssertEqual(GoToPresentation.sessionTitle(session(alpha, "Fix login"), workbench: alpha, currentWorkbenchID: nil),
                       "alpha › Fix login", "no workbench page: every session is another workbench's")
    }
}
