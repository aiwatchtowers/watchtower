import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
@testable import WatchtowerCore

/// A card with blocks in today's Inbox (spec "Today's Inbox", "Press
/// address"): the reading pane's choice by `ArtifactDocument.decode`, the
/// flattened index and the drawn hash on a press, people resolved locally.
@MainActor
final class InboxArtifactCardTests: XCTestCase {
    private let reply = #"{"label":"Backlog","kind":"reply","reply":"backlog"}"#
    private let chat = #"{"label":"Draft","kind":"chat","chat":"Draft a reply"}"#

    private func card(blocks: String, actions: String = "[]", hash: String = "h1") -> AutomationOutputCard {
        AutomationOutputCard(
            id: 5, automationID: 2, automationName: "Threads waiting for me", runID: 212,
            title: "Threads", body: "- Thread A — colleague A", priority: "medium",
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000), actionsJSON: actions,
            blocksJSON: blocks, outputKey: "threads", contentHash: hash)
    }

    // MARK: - The four states

    func testLayoutPicksByDecode() {
        XCTAssertEqual(InboxCardLayout.of(card(blocks: "")), .markdown)
        guard case let .artifact(.document(document), actions) = InboxCardLayout.of(
            card(blocks: #"{"v":1,"blocks":[{"type":"heading","text":"Threads","level":1}]}"#,
                 actions: "[\(chat)]")) else { return XCTFail("a v1 document draws its blocks") }
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(actions.map(\.label), ["Draft"])
        XCTAssertEqual(InboxCardLayout.of(card(blocks: #"{"v":2,"blocks":[]}"#)),
                       .artifact(.unsupported(version: 2), cardActions: []))
        XCTAssertEqual(InboxCardLayout.of(card(blocks: #"{"v":1,"blocks":[{"type":"chart"}]}"#)),
                       .artifact(.unreadable, cardActions: []))
        // Card buttons that cannot be read would shift every block press
        // index: the whole card falls back to unreadable.
        XCTAssertEqual(InboxCardLayout.of(card(blocks: #"{"v":1,"blocks":[]}"#, actions: "{}")),
                       .artifact(.unreadable, cardActions: []))
    }

    func testReadingPaneDrawsEachState() throws {
        func pane(_ blocks: String) -> InboxReadingPane<
            InboxCardPlaceholder, InboxCardColumn<InboxCardPlaceholder>, InboxCardPlaceholder> {
            InboxReadingPane(item: .output(card(blocks: blocks)), navScreens: []) { _ in }
        }
        XCTAssertNoThrow(try pane("").inspect().find(MarkdownView.self))
        XCTAssertNoThrow(try pane(#"{"v":1,"blocks":[{"type":"heading","text":"Due today","level":1}]}"#)
            .inspect().find(ArtifactView.self))
        XCTAssertNoThrow(try pane(#"{"v":3,"blocks":[]}"#).inspect().find(text: ArtifactCardBody.unsupportedLine))
        XCTAssertNoThrow(try pane("[1,2]").inspect().find(text: ArtifactCardBody.unreadableLine))
        XCTAssertNoThrow(try pane("[1,2]").inspect().find(text: "- Thread A — colleague A"),
                         "the plain-text body still shows")
    }

    // MARK: - Presses

    /// The card's own buttons come first, then each block's in document
    /// order; a Reply inside a list row presses by that flattened index, with
    /// the hash the card was drawn at.
    func testReplyInARowPassesFlattenedIndexAndDrawnHash() throws {
        let blocks = #"{"v":1,"blocks":[{"type":"actions","actions":[\#(chat)]},"#
            + #"{"type":"list","rows":[{"title":"Thread A","actions":[\#(chat)]},"#
            + #"{"title":"Thread B","actions":[\#(reply)]}]}]}"#
        let shown = card(blocks: blocks, actions: "[\(chat)]", hash: "h7")
        let layout = InboxCardLayout.of(shown)
        XCTAssertEqual(layout.pressable.map(\.index), [0, 1, 2, 3])
        XCTAssertTrue(layout.hasReply)
        let press = try XCTUnwrap(layout.pressable.last)

        XCTAssertEqual(InboxCardPress.resolve(press, card: shown, reply: .ready, workbenches: []),
                       .command(.reply(outputID: 5, action: 3, contentHash: "h7")))
        XCTAssertEqual(InboxCardPress.resolve(press, card: shown, reply: .off, workbenches: []),
                       .command(.openAutomation(shown)), "a recipe that cannot run opens its card")
        XCTAssertTrue(InboxCardPress.isDisabled(press, reply: .sent(runID: 9), isWriting: false, navScreens: []))
        XCTAssertEqual(InboxArtifactCard.replyCaption(.sent(runID: 9)), "Sent — run #9")
    }

    /// A target button is the approval-card flow's; the Inbox does not map it
    /// to a press here, and it keeps its flattened slot.
    func testTargetActionKeepsItsSlotButIsNotPressedHere() {
        let target = #"{"label":"Make a task","kind":"target","target":{"title":"Follow up"}}"#
        let shown = card(blocks: #"{"v":1,"blocks":[{"type":"actions","actions":[\#(target),\#(chat)]}]}"#)
        XCTAssertEqual(InboxCardLayout.of(shown).pressable.map(\.index), [1])
    }

    /// In the Inbox the target button is drawn disabled until it is wired,
    /// while a chat button beside it stays pressable.
    func testTargetButtonIsDrawnDisabledInTheInbox() throws {
        let target = #"{"label":"Make a task","kind":"target","target":{"title":"Follow up"}}"#
        let shown = card(blocks: #"{"v":1,"blocks":[{"type":"actions","actions":[\#(target),\#(chat)]}]}"#)
        let sut = InboxReadingPane(item: .output(shown), navScreens: []) { _ in }
        XCTAssertTrue(try sut.inspect().find(ArtifactTargetButton.self).find(ViewType.Button.self).isDisabled())
        XCTAssertFalse(try sut.inspect().find(button: "Draft").isDisabled())
    }

    // MARK: - People

    func testAvatarFallsBackToInitialsForAnUnknownUser() {
        XCTAssertNil(InboxArtifactCard.avatar(nil), "unknown user: the block draws its own initials")
        XCTAssertNotNil(InboxArtifactCard.avatar("Colleague A"))
    }

    /// The pane's environment resolves a person block's `slack_user` through
    /// the people map: a known user draws the initials of their local name,
    /// an unknown one the initials of the name the recipe wrote.
    func testPersonBlockAvatarThroughThePanesEnvironment() throws {
        func person(_ name: String, _ user: String) -> String {
            #"{"type":"person","name":"\#(name)","avatar":{"slack_user":"\#(user)"},"lines":[]}"#
        }
        let blocks = #"{"v":1,"blocks":["# + person("Ann Example", "acme:U1") + ","
            + person("Bo Example", "acme:U9") + "]}"
        let sut = InboxReadingPane(item: .output(card(blocks: blocks)), navScreens: [], onCommand: { _ in },
                                   artifactPeople: ["acme:U1": "Colleague Alpha"])
        let view = try sut.inspect()
        XCTAssertNoThrow(try view.find(text: "CA"), "known user: initials of the local name")
        XCTAssertThrowsError(try view.find(text: "AE"), "a resolved avatar replaces the block's initials")
        XCTAssertNoThrow(try view.find(text: "BE"), "unknown user: initials of the block's name")
    }
}
