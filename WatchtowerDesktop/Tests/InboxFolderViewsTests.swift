import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Inbox builder B Task 1: the folder views over plain values — the note's
/// words and press per state, the ⋯ menus' entries, the menu's tree rules,
/// and the menu laid out at the edges (no rows, one deep row, 100 rows).
@MainActor
final class InboxFolderViewsTests: XCTestCase {
    // MARK: - Needs approval's note

    func testNoteHasOneTextPerStateAndStoppedOffersTurnOn() {
        XCTAssertEqual(NeedsApprovalNoteContent(state: .off).text,
                       "Showing approvals in the standard card — Needs approval is off.")
        XCTAssertEqual(NeedsApprovalNoteContent(state: .stopped).text,
                       "Showing approvals in the standard card — Needs approval was stopped after a run that would not end.")
        XCTAssertEqual(NeedsApprovalNoteContent(state: .lastRunFailed).text,
                       "Showing approvals in the standard card — the last run failed.")
        XCTAssertEqual(NeedsApprovalNoteContent(state: .off).buttonTitle, "Turn On")
        XCTAssertEqual(NeedsApprovalNoteContent(state: .stopped).buttonTitle, "Turn On",
                       "the stopped note resumes the built-in: Turn On, not Run History")
        XCTAssertEqual(NeedsApprovalNoteContent(state: .lastRunFailed).buttonTitle, "Run History")
    }

    func testEveryNoteStateRenders() throws {
        let states: [NeedsApprovalNoteContent] = [
            .init(state: .off), .init(state: .stopped), .init(state: .lastRunFailed),
            .init(state: .off, failure: "Feature changes are being applied in Settings — try again"),
            .init(state: .stopped, failure: "watchtower exited with error: database is locked")
        ]
        for content in states {
            try assertRenders(NeedsApprovalNote(content: content), width: 640)
        }
    }

    // MARK: - The ⋯ menus

    func testArtifactMenuOffersEveryEntryForAnOwnerAutomation() {
        let titles = InboxArtifactMenuContent(folders: tree).entries.map(\.title)
        XCTAssertEqual(titles, ["Run Now", "Edit What It Collects…", "Edit the Look…", "Schedule…", "Move to Folder",
                                "Turn Off", "Run History", "Delete…"])
    }

    func testBuiltinHasNoDeleteAndNoRunNowWhenItOffersNone() {
        let titles = InboxArtifactMenuContent(isBuiltin: true, offersRunNow: false, isEnabled: false, folders: tree)
            .entries.map(\.title)
        XCTAssertFalse(titles.contains("Delete…"))
        XCTAssertFalse(titles.contains("Run Now"))
        XCTAssertTrue(titles.contains("Turn On"))
    }

    func testNeedsApprovalAutomationHasNoMoveToFolder() {
        let titles = InboxArtifactMenuContent(isBuiltin: true, movable: false, folders: tree).entries.map(\.title)
        XCTAssertFalse(titles.contains("Move to Folder"))
    }

    func testMoveTargetsLeaveOutNeedsApprovalAndCheckTheCurrentFolder() {
        let rootChecked = InboxArtifactMenuContent.moveTargets(tree, current: nil)
        XCTAssertEqual(rootChecked.map(\.title), ["Inbox", "Release", "Blockers"])
        XCTAssertEqual(rootChecked.filter(\.checked).map(\.title), ["Inbox"], "no route = the root")
        XCTAssertEqual(rootChecked.map(\.indent), [0, 1, 2])
        let releaseChecked = InboxArtifactMenuContent.moveTargets(tree, current: 3)
        XCTAssertEqual(releaseChecked.filter(\.checked).map(\.title), ["Release"])
    }

    func testFolderRootAndApprovalsMenus() {
        let folder = InboxArtifactMenuContent.folderEntries(tree[2], icons: ["folder", "flag"])
        XCTAssertEqual(folder.map(\.title), ["Rename…", "Icon", "New Folder Inside", "Hide", "Delete…"])
        XCTAssertEqual(folder[1].children.filter(\.checked).map(\.title), ["flag"])
        var hidden = tree[2]
        hidden.hidden = true
        XCTAssertEqual(InboxArtifactMenuContent.folderEntries(hidden, icons: [])[3].title, "Show")
        XCTAssertEqual(InboxArtifactMenuContent.rootEntries(showingHidden: false).map(\.title),
                       ["Learned Rules", "Assistant Profile", "Show Hidden Folders", "New Folder"])
        XCTAssertEqual(InboxArtifactMenuContent.approvalsEntries(isEnabled: true).map(\.title),
                       ["Edit the Look…", "Turn Off", "Run History"])
        XCTAssertEqual(InboxArtifactMenuContent.ideaFinderEntries.map(\.title), ["Find Ideas in Past Messages…"])
    }

    // MARK: - The folder menu

    func testCollapsedFolderHidesItsDescendantsOnly() {
        var rows = tree + [InboxFolderRow(id: 5, kind: .owner, title: "Team", icon: "person.2", depth: 1, count: 0)]
        rows[2].isExpanded = false
        let content = InboxFolderMenuContent(rows: rows)
        XCTAssertEqual(content.visibleRows.map(\.title), ["Inbox", "Needs approval", "Release", "Team"])
        XCTAssertTrue(content.hasChildren(rows[2]))
        XCTAssertFalse(content.hasChildren(rows[4]))
    }

    func testReadOnlyWhileCLIIsMissingOrAMoveRuns() {
        XCTAssertFalse(InboxFolderMenuContent(rows: tree).isReadOnly)
        XCTAssertTrue(InboxFolderMenuContent(rows: tree, note: .cliUnavailable).isReadOnly)
        XCTAssertTrue(InboxFolderMenuContent(rows: tree, pendingMoveID: 3).isReadOnly)
        XCTAssertFalse(InboxFolderMenuContent(rows: tree, note: .menuChanged).isReadOnly)
    }

    func testDeleteSummaryNamesWhatMovesToInbox() {
        XCTAssertEqual(InboxFolderDeleteSummary(folderID: 3, title: "Release", folders: 2, automations: 3,
                                                artifacts: 5).text,
                       "Delete “Release”? Its 2 folders, 3 automations and 5 artifacts move to Inbox.")
        XCTAssertEqual(InboxFolderDeleteSummary(folderID: 3, title: "Release", folders: 1, automations: 0,
                                                artifacts: 1).text,
                       "Delete “Release”? Its 1 folder and 1 artifact move to Inbox.")
        XCTAssertEqual(InboxFolderDeleteSummary(folderID: 3, title: "Release", folders: 0, automations: 0,
                                                artifacts: 0).text,
                       "Delete “Release”? It is empty.")
    }

    func testMenuRendersWithNoRowsOneDeepRowAndAHundredRows() throws {
        try assertRenders(InboxFolderMenu(content: InboxFolderMenuContent(rows: [])), width: 220)
        let deep = InboxFolderRow(id: 9, kind: .owner, title: "A folder three levels down with a long title",
                                  icon: "bolt", depth: 3, count: 12)
        try assertRenders(InboxFolderMenu(content: InboxFolderMenuContent(rows: tree + [deep], selection: 9)),
                          width: 220)
        let many = (0..<100).map { index in
            InboxFolderRow(id: Int64(100 + index), kind: .owner, title: "Folder \(index)", icon: "",
                           depth: 1 + index % 3, count: index)
        }
        try assertRenders(InboxFolderMenu(content: InboxFolderMenuContent(rows: [tree[0], tree[1]] + many)),
                          width: 220)
    }

    // MARK: - Helpers

    private let tree = [
        InboxFolderRow(id: 1, kind: .root, title: "Inbox", icon: "", depth: 0, count: 9),
        InboxFolderRow(id: 2, kind: .approvals, title: "Needs approval", icon: "", depth: 1, count: 3),
        InboxFolderRow(id: 3, kind: .owner, title: "Release", icon: "flag", depth: 1, count: 2),
        InboxFolderRow(id: 4, kind: .owner, title: "Blockers", icon: "shippingbox", depth: 2, count: 1)
    ]

    /// Lays the view out at `width` and its own height and draws it: not
    /// blank, not zero-sized.
    private func assertRenders(
        _ view: some View, width: CGFloat, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let height = ViewRenderProbe.fittingHeight(view, width: width)
        XCTAssertGreaterThan(height, 0, file: file, line: line)
        let bitmap = try ViewRenderProbe(size: NSSize(width: width, height: max(height, 1)))
            .render(view, try XCTUnwrap(NSAppearance(named: .aqua)))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0, file: file, line: line)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0, file: file, line: line)
    }
}
