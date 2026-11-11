import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// **Find Ideas in Past Messages…** moved from the Ideas filter's menu into
/// the Idea finder legacy entry's ⋯ (spec "Root ⋯", plan Task 12): there,
/// and nowhere else in the folder menus or entries.
@MainActor
final class InboxLegacyEntryMenuTests: XCTestCase {
    private static let command = InboxMenuCommand.findIdeasInPastMessages

    private static func commands(_ entries: [InboxMenuEntry]) -> [InboxMenuCommand] {
        entries.flatMap { [$0.command].compactMap { $0 } + commands($0.children) }
    }

    func testFindIdeasInPastMessagesInIdeaFinderMenu() throws {
        XCTAssertEqual(Self.commands(InboxFolderEntry.legacyIdeas.menuEntries), [Self.command])

        let card = AutomationOutputCard(id: 1, automationID: 2, automationName: "Weekly", runID: 3, title: "Weekly",
                                        body: "", priority: "medium", createdAt: Date())
        let day = InboxDayCard(date: "2026-11-06", briefing: nil, plan: nil, planDone: 0, planTotal: 0, stamp: Date())
        let notice = BuiltinUpgradeNotice(builtinID: "morning-brief", error: "", updatedAt: Date())
        let others: [InboxFolderEntry] = [
            .legacyTracks, .legacyMessages, .legacyDay(day), .artifact(card), .builtinNotice(notice)
        ]
        for entry in others {
            XCTAssertFalse(Self.commands(entry.menuEntries).contains(Self.command), entry.id)
        }
        for showing in [false, true] {
            XCTAssertFalse(Self.commands(InboxArtifactMenuContent.rootEntries(showingHidden: showing))
                .contains(Self.command), "not in the root ⋯")
        }
        XCTAssertFalse(Self.commands(InboxArtifactMenuContent.approvalsEntries(isEnabled: true)).contains(Self.command))
    }

    /// The list draws the entry's ⋯ on the Idea finder row only.
    func testIdeaFinderRowDrawsItsMenu() throws {
        let ideas = InboxFolderListRow(id: "ideas", content: InboxRowContent(kind: .ideas, title: "Idea finder"),
                                       menu: InboxFolderEntry.legacyIdeas.menuEntries)
        let tracks = InboxFolderListRow(id: "tracks", content: InboxRowContent(kind: .threads, title: "Track my threads"))
        var pressed: InboxMenuCommand?
        let row = InboxFolderListRowView(row: ideas) { pressed = $0 }
        XCTAssertNoThrow(try row.inspect().find(InboxMoreMenu.self))
        try row.inspect().find(InboxMoreMenu.self).actualView().onCommand(Self.command)
        XCTAssertEqual(pressed, Self.command)
        XCTAssertThrowsError(try InboxFolderListRowView(row: tracks).inspect().find(InboxMoreMenu.self))
    }
}
