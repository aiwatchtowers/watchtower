import WatchtowerInterface
import XCTest

final class InboxCardModelTests: XCTestCase {
    private typealias Fix = InboxFixtures

    private func model(
        _ card: Card,
        platform: Platform,
        grants: Grants = .all,
        readable: Bool = true,
        now: String = "2026-11-16T12:00:00Z"
    ) throws -> InboxCardModel {
        InboxCardModel(
            card: card, platform: platform, grants: grants, blocksReadable: readable,
            now: try Fix.date(now), timeZone: try Fix.zone("UTC")
        )
    }

    private var macOnlyCard: Card {
        get throws {
            try Fix.artifact("o1", actions: [
                Fix.action(0, kind: "chat", label: "Discuss", state: .macOnly),
                Fix.action(1, kind: "agent", label: "Hand to Agent", state: .macOnly),
                Fix.action(2, kind: "save_automation", label: "Open Draft"),
                Fix.action(3, kind: "link", label: "Open", state: .macOnly),
                Fix.action(4, kind: "reply", label: "Reply")
            ])
        }
    }

    func testMacOnlyActionsAreDisabledOnThePhoneWithOnYourMac() throws {
        let actions = try model(macOnlyCard, platform: .phone).actions
        XCTAssertEqual(actions.map(\.label), ["Discuss", "Hand to Agent", "Open Draft", "Open", "Reply"])
        XCTAssertEqual(actions.map(\.enabled), [false, false, false, false, true])
        XCTAssertEqual(actions.map(\.note), ["On your Mac", "On your Mac", "On your Mac", "On your Mac", nil])
    }

    func testMacKeepsThemEnabled() throws {
        let actions = try model(macOnlyCard, platform: .mac).actions
        XCTAssertEqual(actions.map(\.enabled), [true, true, true, true, true])
        XCTAssertEqual(actions.map(\.note), [nil, nil, nil, nil, nil])
    }

    func testPhoneGrantsGateReplyAndTarget() throws {
        let card = try Fix.artifact("o1", actions: [Fix.action(0, kind: "reply"), Fix.action(1, kind: "target")])
        let none = try model(card, platform: .phone, grants: Grants(permissions: false, typing: false)).actions
        XCTAssertEqual(none.map(\.enabled), [false, false])
        let typing = try model(card, platform: .phone, grants: Grants(permissions: false, typing: true)).actions
        XCTAssertEqual(typing.map(\.enabled), [true, false])
    }

    func testUnreadIsADotOnly() throws {
        let unread = try model(Fix.artifact("o1", unread: true), platform: .phone)
        let read = try model(Fix.artifact("o1", unread: false), platform: .phone)
        XCTAssertTrue(unread.showsUnreadDot)
        XCTAssertFalse(read.showsUnreadDot)
        XCTAssertEqual(unread.title, read.title)
        XCTAssertEqual(unread.sourceLine, read.sourceLine)
        XCTAssertEqual(unread.sourceLine, "Waiting for me · 11:50")
    }

    func testCreatingTargetPastUntilIsStuck() throws {
        let card = try Fix.artifact("o1", actions: [
            Fix.action(0, kind: "target", state: .pressed, detail: "creating", until: "2026-11-16T12:02:00Z")
        ])
        let before = try XCTUnwrap(model(card, platform: .mac, now: "2026-11-16T12:01:59Z").actions.first)
        XCTAssertEqual(before.detail, "creating")
        XCTAssertFalse(before.enabled)
        let after = try XCTUnwrap(model(card, platform: .mac, now: "2026-11-16T12:02:00Z").actions.first)
        XCTAssertEqual(after.detail, "stuck")
        XCTAssertTrue(after.enabled)
        XCTAssertEqual(after.note, "Didn't finish")
    }

    func testPressCarriesTheActionKindAndTheDrawnHash() throws {
        let card = try Fix.artifact("o1", actions: [Fix.action(3, kind: "reply")])
        let model = try model(card, platform: .phone)
        let press = model.press(try XCTUnwrap(model.actions.first), requestID: "r1", text: "ok")
        XCTAssertEqual(press, ActRequest(
            requestID: "r1", target: "o1", verb: .press,
            params: ActParams(contentHash: card.contentHash, index: 3, actionKind: "reply", text: "ok")
        ))
        XCTAssertEqual(
            model.request(.done, requestID: "r2"),
            ActRequest(requestID: "r2", target: "o1", verb: .done, params: ActParams(contentHash: card.contentHash))
        )
    }
}
