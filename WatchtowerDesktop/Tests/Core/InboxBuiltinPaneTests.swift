import XCTest
@testable import WatchtowerCore

/// Which pane each built-in's artifact gets in the reading pane, and where
/// the Morning brief's **All in Waiting for me** goes.
final class InboxBuiltinPaneTests: XCTestCase {
    private static func pane(_ automationID: Int64) -> InboxBuiltinPane {
        InboxBuiltinPane.of(automationID: automationID, slackToday: 1, waitingForMe: 2, mailWaiting: 3)
    }

    private static func card(id: Int64, automationID: Int64) -> InboxFolderEntry {
        .artifact(AutomationOutputCard(id: id, automationID: automationID, automationName: "Built in", runID: 9,
                                       title: "T", body: "", priority: "medium", createdAt: Date()))
    }

    func testEachBuiltInGetsItsPane() {
        XCTAssertEqual(Self.pane(1), .slackToday)
        XCTAssertEqual(Self.pane(2), .waitingForMe)
        XCTAssertEqual(Self.pane(3), .mailWaiting)
        XCTAssertEqual(Self.pane(4), .other)
        XCTAssertEqual(InboxBuiltinPane.of(automationID: 4, slackToday: nil, waitingForMe: nil, mailWaiting: nil),
                       .other, "no built-ins read: every artifact is an ordinary one")
    }

    func testRunLinkAndMuteSendersPerPane() {
        XCTAssertTrue(InboxBuiltinPane.other.showsRunLink)
        for pane in [InboxBuiltinPane.waitingForMe, .mailWaiting, .slackToday] {
            XCTAssertFalse(pane.showsRunLink, "\(pane): the count line, no Run link")
        }
        XCTAssertTrue(InboxBuiltinPane.mailWaiting.offersMuteSenders)
        for pane in [InboxBuiltinPane.waitingForMe, .slackToday, .other] {
            XCTAssertFalse(pane.offersMuteSenders, "\(pane)")
        }
    }

    func testAllInWaitingForMeOpensTheArtifact() {
        let entries = [Self.card(id: 7, automationID: 3), Self.card(id: 8, automationID: 2), .legacyMessages]
        XCTAssertEqual(InboxBuiltinPane.waitingForMeEntryID(entries, waitingForMe: 2), "artifact:8")
    }

    func testAllInWaitingForMeFallsBackToMessages() {
        let entries = [Self.card(id: 7, automationID: 3), .legacyMessages]
        XCTAssertEqual(InboxBuiltinPane.waitingForMeEntryID(entries, waitingForMe: 2),
                       InboxFolderEntry.legacyMessages.id, "no artifact yet: the Messages stand-in")
        XCTAssertEqual(InboxBuiltinPane.waitingForMeEntryID(entries, waitingForMe: nil),
                       InboxFolderEntry.legacyMessages.id)
    }

    func testAllInWaitingForMeHasNoLinkWithNeither() {
        XCTAssertNil(InboxBuiltinPane.waitingForMeEntryID([Self.card(id: 7, automationID: 3)], waitingForMe: 2))
    }
}
