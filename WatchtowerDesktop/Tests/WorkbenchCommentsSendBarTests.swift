import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class WorkbenchCommentsSendBarTests: XCTestCase {
    func testSendTapsOnce() throws {
        var sent = 0
        let bar = WorkbenchCommentsSendBar(count: 2, delivery: nil, onSend: { sent += 1 }, onOpenTerminal: {})
        try bar.inspect().find(button: "Send 2 comments to Claude").tap()
        XCTAssertEqual(sent, 1)
    }

    func testNoSessionExplainsTheBriefAndOffersTheTerminal() throws {
        var opened = 0
        let bar = WorkbenchCommentsSendBar(count: 1, delivery: .noSession, onSend: {}, onOpenTerminal: { opened += 1 })
        XCTAssertNoThrow(try bar.inspect().find(text: WorkbenchCommentsSendBar.noSessionNote))
        try bar.inspect().find(button: "Open terminal").tap()
        XCTAssertEqual(opened, 1)
    }

    func testCopiedTellsTheOwnerToPaste() throws {
        let bar = WorkbenchCommentsSendBar(count: 1, delivery: .copied, onSend: {}, onOpenTerminal: {})
        XCTAssertNoThrow(try bar.inspect().find(text: WorkbenchCommentsSendBar.copiedNote))
    }

    func testNothingOpenHidesTheButton() throws {
        let bar = WorkbenchCommentsSendBar(count: 0, delivery: nil, onSend: {}, onOpenTerminal: {})
        XCTAssertThrowsError(try bar.inspect().find(ViewType.Button.self))
    }

    func testUnsentDraftsAreNamedBeforeTheFirstSend() throws {
        let bar = WorkbenchCommentsSendBar(count: 3, drafts: 2, delivery: nil, onSend: {}, onOpenTerminal: {})
        XCTAssertNoThrow(try bar.inspect().find(text: "2 drafts — Claude sees them only when you send."))
        XCTAssertNoThrow(try bar.inspect().find(button: "Send 3 comments to Claude"))
    }

    func testDraftsThatCannotBeSentAreNamedAndSendingDisablesTheButton() throws {
        let bar = WorkbenchCommentsSendBar(count: 1, drafts: 1, unsendableDrafts: 2, sending: true,
                                           delivery: nil, onSend: {}, onOpenTerminal: {})
        XCTAssertNoThrow(try bar.inspect().find(text: "2 drafts can't be sent — see Drafts."))
        XCTAssertTrue(try bar.inspect().find(button: "Send 1 comment to Claude").isDisabled())
    }
}
