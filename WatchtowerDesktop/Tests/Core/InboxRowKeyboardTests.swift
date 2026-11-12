import XCTest
@testable import WatchtowerCore

/// The keys on the focused row of Waiting for me and Mail waiting (spec
/// "Waiting for me and Mail waiting", keyboard in both panes) and the
/// focus that moves over the shown rows.
final class InboxRowKeyboardTests: XCTestCase {
    private func ping(_ key: String, command: Bool = false, canReply: Bool = true) -> InboxKeyCommand? {
        InboxRowKeymap.command(key: key, command: command, kind: .inboxItem, canReply: canReply)
    }

    private func sender(_ key: String, command: Bool = false) -> InboxKeyCommand? {
        InboxRowKeymap.command(key: key, command: command, kind: .mailSender, canReply: false)
    }

    // MARK: - The keymap

    func testJMovesDown() {
        XCTAssertEqual(ping("j"), .moveDown)
        XCTAssertEqual(sender("j"), .moveDown)
        XCTAssertEqual(InboxRowKeymap.command(key: "j", command: false, kind: .waitingOlder, canReply: false),
                       .moveDown, "the Older row is passed through")
    }

    func testKMovesUp() {
        XCTAssertEqual(ping("k"), .moveUp)
        XCTAssertEqual(sender("k"), .moveUp)
        XCTAssertEqual(InboxRowKeymap.command(key: "k", command: false, kind: .waitingOlder, canReply: false), .moveUp)
    }

    func testEOnAPingIsDone() {
        XCTAssertEqual(ping("e"), .press(.done))
    }

    func testROnAPingIsReply() {
        XCTAssertEqual(ping("r"), .press(.reply))
    }

    func testReplyKeyNeedsReply() {
        XCTAssertNil(ping("r", canReply: false), "mail and other items without a write path have no R")
    }

    func testSOpensTheSnoozeMenu() {
        XCTAssertEqual(ping("s"), .openSnoozeMenu, "the key opens the menu; the owner picks the duration")
    }

    func testReturnOnAPingOpens() {
        XCTAssertEqual(ping(InboxRowKeymap.returnKey), .press(.open))
    }

    func testCommandKOnAPingHandsToAgent() {
        XCTAssertEqual(ping("k", command: true), .press(.handToAgent))
    }

    func testReturnOnASenderOpens() {
        XCTAssertEqual(sender(InboxRowKeymap.returnKey), .press(.open))
    }

    func testEOnASenderMarksAllDone() {
        XCTAssertEqual(sender("e"), .press(.markAllDone))
    }

    func testMOnASenderMutes() {
        XCTAssertEqual(sender("m"), .press(.mute))
    }

    func testNoSnoozeOrReplyOnSender() {
        XCTAssertNil(sender("s"))
        XCTAssertNil(sender("r"))
        XCTAssertNil(sender("k", command: true), "no Hand to Agent on a sender")
    }

    func testNoActionKeysOnTheOlderRow() {
        for key in ["e", "r", "s", "m", InboxRowKeymap.returnKey] {
            XCTAssertNil(InboxRowKeymap.command(key: key, command: false, kind: .waitingOlder, canReply: false), key)
        }
        XCTAssertNil(InboxRowKeymap.command(key: "k", command: true, kind: .waitingOlder, canReply: false))
    }

    func testOtherKeysAreNotCommands() {
        XCTAssertNil(ping("m"), "M is a sender's key only")
        XCTAssertNil(ping("x"))
        XCTAssertNil(ping("e", command: true))
        XCTAssertNil(ping("j", command: true))
        XCTAssertNil(sender("x"))
    }

    // MARK: - What the row's buttons allow

    func testAllowsFollowsTheDrawnButtons() {
        let ping = InboxRowActionsContent(
            kind: .inboxItem(openLabel: "Open in Slack", openEnabled: true, canReply: true, showsHandToAgent: true))
        XCTAssertTrue(InboxRowKeymap.allows(.press(.done), content: ping))
        XCTAssertTrue(InboxRowKeymap.allows(.press(.open), content: ping))
        XCTAssertTrue(InboxRowKeymap.allows(.press(.reply), content: ping))
        XCTAssertTrue(InboxRowKeymap.allows(.openSnoozeMenu, content: ping))

        var busy = ping
        busy.state = .busy
        XCTAssertFalse(InboxRowKeymap.allows(.press(.done), content: busy), "nothing while a press runs")
        XCTAssertTrue(InboxRowKeymap.allows(.moveDown, content: busy), "moving is not a press")

        var composing = ping
        composing.reply = .composing(text: "", error: nil)
        XCTAssertFalse(InboxRowKeymap.allows(.press(.reply), content: composing), "Reply… is off while one is open")

        var noCLI = ping
        noCLI.cliMissing = true
        XCTAssertFalse(InboxRowKeymap.allows(.press(.done), content: noCLI))
        XCTAssertFalse(InboxRowKeymap.allows(.openSnoozeMenu, content: noCLI))

        let noLink = InboxRowActionsContent(
            kind: .inboxItem(openLabel: nil, openEnabled: false, canReply: false, showsHandToAgent: true))
        XCTAssertFalse(InboxRowKeymap.allows(.press(.open), content: noLink))

        let refusedSender = InboxRowActionsContent(kind: .mailSender(address: "a@example.com", openEnabled: false))
        XCTAssertFalse(InboxRowKeymap.allows(.press(.open), content: refusedSender))
        XCTAssertTrue(InboxRowKeymap.allows(.press(.mute), content: refusedSender))
    }

    // MARK: - The focus

    private let rows = (1...4).map { InboxRef(kind: .inboxItem, id: Int64($0)) }

    func testFocusStartsOnTheFirstRow() {
        XCTAssertEqual(InboxRowFocus(refs: rows).focused, rows[0])
        XCTAssertNil(InboxRowFocus(refs: []).focused)
    }

    func testFocusMoveClamps() {
        var focus = InboxRowFocus(refs: rows)
        focus.move(-1)
        XCTAssertEqual(focus.focused, rows[0], "clamped at the top")
        focus.move(2)
        XCTAssertEqual(focus.focused, rows[2])
        focus.move(5)
        XCTAssertEqual(focus.focused, rows[3], "clamped at the bottom")
        focus.move(1)
        XCTAssertEqual(focus.focused, rows[3])
    }

    func testReconcileAfterRowLeaves() {
        var focus = InboxRowFocus(refs: rows)
        focus.move(1)
        // E closed the focused row: the next read leaves it out.
        focus.reconcile(refs: [rows[0], rows[2], rows[3]])
        XCTAssertEqual(focus.focused, rows[2], "the next row takes its place")
    }

    func testReconcileKeepsAListedRow() {
        var focus = InboxRowFocus(refs: rows)
        focus.move(2)
        focus.reconcile(refs: [rows[3], rows[2]])
        XCTAssertEqual(focus.focused, rows[2])
    }

    func testReconcileAfterTheLastRowLeaves() {
        var focus = InboxRowFocus(refs: rows)
        focus.move(3)
        focus.reconcile(refs: Array(rows.prefix(3)))
        XCTAssertEqual(focus.focused, rows[2], "the last row")
        focus.reconcile(refs: [])
        XCTAssertNil(focus.focused)
        focus.reconcile(refs: rows)
        XCTAssertEqual(focus.focused, rows[0], "rows again: the first")
    }
}
