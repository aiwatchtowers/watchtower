import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerChatText

/// The main chat's sources panel (the inspector) over one answer's sources.
@MainActor
final class ChatSourcesPanelViewTests: XCTestCase {
    private func sources(_ count: Int) -> [ChatSource] {
        (1...count).map {
            ChatSource(kind: "slack", title: "#payments — m\($0)", url: "https://acme.slack.com/archives/C1/p\($0)",
                       ref: "s\($0)", group: "#payments")
        }
    }

    func testSourcesPanelGroupsItemsAndDisablesLinklessOnes() throws {
        let jira = ChatSource(kind: "jira", title: "PAY-1: A", url: nil, ref: "jira:PAY-1", group: "PAY",
                              snippet: "In Progress", date: "2026-05-10")
        let panel = ChatSourcesPanelView(selection: ChatSourcesSelection(messageID: 1, sources: sources(2) + [jira])) {}
        XCTAssertNoThrow(try panel.inspect().find(text: "#payments"))
        XCTAssertNoThrow(try panel.inspect().find(text: "PAY"))
        XCTAssertNoThrow(try panel.inspect().find(text: "m1"), "the group prefix is dropped from item titles")
        XCTAssertNoThrow(try panel.inspect().find(text: "In Progress"))
        let rows = try panel.inspect().findAll(SourceItemRow.self)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(try rows[2].find(ViewType.Button.self).isDisabled(), "no URL and no Jira site = not clickable")
        XCTAssertFalse(try rows[0].find(ViewType.Button.self).isDisabled())
    }
}
