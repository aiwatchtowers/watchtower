import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The native actions of a Mail waiting sender row (Open, Mark All Done…,
/// Mute) and of Waiting for me's Older row (Mark All Done… only).
final class MailSenderActionsTests: XCTestCase {
    func testSenderRowOffersOpenMarkAllDoneMute() {
        let kind = InboxRowActionsContent.mailSenderKind(
            address: " Colleague-A@Example.com", newestPermalink: "https://mail.example.com/m/1", navScreens: [])
        XCTAssertEqual(kind, .mailSender(address: "colleague-a@example.com", openEnabled: true))
        let content = InboxRowActionsContent(kind: kind)
        XCTAssertEqual(content.bulkRowPresses, [.open, .markAllDone, .mute])
        XCTAssertTrue(InboxRowPress.markAllDone.writes)
        XCTAssertTrue(InboxRowPress.mute.writes)
        XCTAssertTrue(content.usesCLI(.markAllDone), "Mark All Done… runs watchtower inbox resolve")
        XCTAssertFalse(content.usesCLI(.mute), "Mute is the Desktop's rules writer")
        XCTAssertFalse(content.usesCLI(.open))

        let missing = InboxRowActionsContent(kind: kind, cliMissing: true)
        XCTAssertTrue(missing.isOff(.markAllDone))
        XCTAssertFalse(missing.isOff(.mute))
        XCTAssertTrue(missing.showsCLIMissingLine)
    }

    func testOpenDisabledWithoutPermalink() {
        XCTAssertEqual(
            InboxRowActionsContent.mailSenderKind(address: "a@example.com", newestPermalink: nil, navScreens: []),
            .mailSender(address: "a@example.com", openEnabled: false))
        XCTAssertEqual(
            InboxRowActionsContent.mailSenderKind(address: "a@example.com", newestPermalink: "", navScreens: []),
            .mailSender(address: "a@example.com", openEnabled: false))
        XCTAssertEqual(
            InboxRowActionsContent.mailSenderKind(
                address: "a@example.com", newestPermalink: "file:///etc/hosts", navScreens: []),
            .mailSender(address: "a@example.com", openEnabled: false), "refused by InboxCardLinkPolicy")
    }

    /// A disabled Open says why: no link, or a link the policy refuses.
    func testOpenHelpSaysWhyItIsOff() {
        XCTAssertEqual(InboxRowActionsContent.senderLink(nil, navScreens: []), .missing)
        XCTAssertEqual(InboxRowActionsContent.senderLink("", navScreens: []), .missing)
        XCTAssertEqual(InboxRowActionsContent.senderLink("file:///etc/hosts", navScreens: []), .refused)
        XCTAssertEqual(InboxRowActionsContent.senderLink("https://mail.example.com/m/1", navScreens: []), .opens)
        let helps = [InboxRowActionsContent.SenderLink.missing, .refused, .opens].map(\.help)
        XCTAssertEqual(Set(helps).count, 3, "three different reasons")
    }

    func testOlderRowOffersMarkAllDoneOnly() {
        let content = InboxRowActionsContent(kind: .waitingOlder)
        XCTAssertEqual(content.bulkRowPresses, [.markAllDone])
        XCTAssertTrue(content.usesCLI(.markAllDone))
        XCTAssertEqual(InboxRowActionsContent(kind: .reminder).bulkRowPresses, [], "other kinds draw their own")
    }

    /// Open's link is the sender's newest open mail, read with the folder,
    /// whatever spelling the row's ref carries.
    func testRefStateReadsTheNewestLinkOfAShownSender() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try pool.write { db in
            _ = try TestDatabase.insertInboxItem(
                db, messageTS: "1700000000.000100", senderUserID: "a@example.com", triggerType: "email_received",
                permalink: "https://mail.example.com/m/old")
            _ = try TestDatabase.insertInboxItem(
                db, messageTS: "1700000000.000200", senderUserID: "A@Example.com", triggerType: "email_received",
                permalink: "https://mail.example.com/m/new")
            try db.execute(sql: "UPDATE inbox_items SET created_at = '2026-01-02T00:00:00Z' WHERE message_ts LIKE '%200'")
            try db.execute(sql: "UPDATE inbox_items SET created_at = '2026-01-01T00:00:00Z' WHERE message_ts LIKE '%100'")
        }
        let raw = InboxRef(kind: .mailSender, key: " A@example.com")
        let gone = InboxRef(kind: .mailSender, key: "b@example.com")
        let state = try pool.read { db in
            try InboxRefState.read(db, refs: [raw, gone], nowUTC: "2026-01-03T00:00:00Z")
        }
        XCTAssertTrue(state.isShown(raw))
        XCTAssertFalse(state.isShown(gone))
        XCTAssertEqual(state.senderLinks[raw], "https://mail.example.com/m/new")
        XCTAssertNil(state.senderLinks[gone])
    }
}
