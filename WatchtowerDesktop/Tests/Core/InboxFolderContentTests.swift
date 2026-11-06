import XCTest
@testable import WatchtowerCore

/// Inbox builder B: the folder menu's values — the Needs approval note's
/// words and press per state, the ⋯ menus' entries, the tree rules and the
/// delete confirmation's sentence. Sample data only.
final class InboxFolderContentTests: XCTestCase {
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
        let folder = InboxArtifactMenuContent.folderEntries(tree[2], icons: [
            InboxFolderIcon(symbol: "folder", label: "Folder"), InboxFolderIcon(symbol: "flag", label: "Flag")
        ])
        XCTAssertEqual(folder.map(\.title), ["Rename…", "Icon", "New Folder Inside", "Hide", "Delete…"])
        XCTAssertEqual(folder[1].children.filter(\.checked).map(\.title), ["Flag"], "a human name, not the symbol")
        XCTAssertEqual(folder[1].children.map(\.command), [.icon("folder"), .icon("flag")])
        var hidden = tree[2]
        hidden.hidden = true
        XCTAssertEqual(InboxArtifactMenuContent.folderEntries(hidden, icons: [])[3].title, "Show")
        XCTAssertEqual(InboxArtifactMenuContent.rootEntries(showingHidden: false).map(\.title),
                       ["Learned Rules", "Assistant Profile", "Show Hidden Folders", "New Folder"])
        XCTAssertEqual(InboxArtifactMenuContent.approvalsEntries(isEnabled: true).map(\.title),
                       ["Edit the Look…", "Turn Off", "Run History"])
        XCTAssertEqual(InboxArtifactMenuContent.ideaFinderEntries.map(\.title), ["Find Ideas in Past Messages…"])
    }

    func testCollapsedFolderHidesItsDescendantsOnly() {
        var rows = tree + [InboxFolderRow(id: 5, kind: .owner, title: "Team", icon: "person.2", depth: 1, count: 0)]
        rows[2].isExpanded = false
        let content = InboxFolderMenuContent(rows: rows)
        XCTAssertEqual(content.visibleRows.map(\.title), ["Inbox", "Needs approval", "Release", "Team"])
        XCTAssertTrue(content.hasChildren(rows[2]))
        XCTAssertFalse(content.hasChildren(rows[4]))
    }

    func testHiddenFolderAndItsSubtreeLeaveUnlessShown() {
        var rows = tree + [InboxFolderRow(id: 5, kind: .owner, title: "Team", icon: "person.2", depth: 1, count: 0)]
        rows[2].hidden = true
        XCTAssertEqual(InboxFolderMenuContent(rows: rows).visibleRows.map(\.title),
                       ["Inbox", "Needs approval", "Team"], "Release and its Blockers leave")
        XCTAssertEqual(InboxFolderMenuContent(rows: rows, showsHidden: true).visibleRows.map(\.title),
                       ["Inbox", "Needs approval", "Release", "Blockers", "Team"])
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

    func testIdeaRowButtonsFollowTodaysIdeaPane() {
        let buttons = InboxRowActionsContent.ideaButtons
        XCTAssertEqual(buttons(.idea, .proposed, true), [.approve, .makeTask, .notNow, .reject])
        XCTAssertEqual(buttons(.note, .proposed, true), [.approve, .reject])
        XCTAssertEqual(buttons(.decision, .proposed, true), [.approve, .notNow, .reject])
        XCTAssertEqual(buttons(.idea, .active, false), [.makeTask, .notNow, .drop])
        XCTAssertEqual(buttons(.idea, .notNow, false), [.activate, .makeTask, .drop])
        XCTAssertEqual(buttons(.note, .active, false), [.drop])
        XCTAssertEqual(buttons(.idea, .rejected, false), [.activate], "rejected: Activate only")
        XCTAssertEqual(buttons(.idea, .dropped, false), [.activate], "dropped: Activate only")
        XCTAssertEqual(buttons(.decision, .active, false), [], "Supersede / Reverse stay in the pane")
        XCTAssertEqual(buttons(.decision, .notNow, false), [.activate])
        XCTAssertEqual(buttons(.idea, .converted, false), [])
    }

    func testApprovalsMenuFollowsTheBuiltinSwitch() {
        XCTAssertTrue(InboxFolderMenuContent(rows: tree).approvalsEnabled)
        XCTAssertEqual(InboxArtifactMenuContent.approvalsEntries(isEnabled: false).map(\.title),
                       ["Edit the Look…", "Turn On", "Run History"])
    }

    // MARK: - Helpers

    private let tree = [
        InboxFolderRow(id: 1, kind: .root, title: "Inbox", icon: "", depth: 0, count: 9),
        InboxFolderRow(id: 2, kind: .approvals, title: "Needs approval", icon: "", depth: 1, count: 3),
        InboxFolderRow(id: 3, kind: .owner, title: "Release", icon: "flag", depth: 1, count: 2),
        InboxFolderRow(id: 4, kind: .owner, title: "Blockers", icon: "shippingbox", depth: 2, count: 1)
    ]
}
