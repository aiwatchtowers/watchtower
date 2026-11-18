import XCTest
@testable import WatchtowerCore

/// The agent's folder suggestion card and its answer lines (#2003, spec
/// §6.7), and Remove from Bench… / Locate… (§6.3): every string verbatim.
final class FolderSuggestionPresentationTests: XCTestCase {
    private typealias Copy = FolderSuggestionPresentation
    private let home = "/Users/owner"

    private func suggestion(touches: Int = 3, otherBench: FolderSuggestionPayload.OtherBench? = nil) -> FolderSuggestionPayload {
        FolderSuggestionPayload(path: "/Users/owner/code/billing", repoRoot: "/Users/owner/code/billing", touches: touches,
                                why: "the export lives there", otherBench: otherBench)
    }

    func testCardStrings() {
        let card = Copy.card(suggestion(), sessionTitle: "Export reports to PDF", phase: .ready, home: home)
        XCTAssertEqual(card.title, "Put billing on the bench?")
        XCTAssertEqual(card.subtitle, "From “Export reports to PDF” · the agent worked in ~/code/billing 3 times")
        XCTAssertEqual(card.phase, .ready)
        XCTAssertNil(card.otherBench)
        XCTAssertEqual(Copy.icon, "plus.rectangle.on.folder")
        XCTAssertEqual(Copy.putOnBench, "Put on Bench")
        XCTAssertEqual(Copy.notNow, "Not Now")
        XCTAssertEqual(Copy.never, "Never for This Folder")
        XCTAssertEqual(Copy.busy, "Putting on the bench…")
        XCTAssertEqual(Copy.ok, "OK")
        XCTAssertEqual(Copy.cancel, "Cancel")
    }

    func testSubtitleWithoutSessionOrCount() {
        XCTAssertEqual(Copy.subtitle(sessionTitle: nil, path: "/Users/owner/code/billing", touches: 3, home: home),
                       "The agent worked in ~/code/billing 3 times")
        XCTAssertEqual(Copy.subtitle(sessionTitle: "Fix", path: "/Users/owner/code/billing", touches: 1, home: home),
                       "From “Fix” · the agent worked in ~/code/billing 1 time")
        XCTAssertEqual(Copy.subtitle(sessionTitle: "Fix", path: "/srv/billing", touches: 0, home: home),
                       "From “Fix” · the agent worked in /srv/billing", "a Codex session asks by itself: no count")
    }

    func testBusyAndFailedCards() {
        XCTAssertEqual(Copy.card(suggestion(), sessionTitle: "Fix", phase: .busy, home: home).phase, .busy)
        let line = Copy.failed(name: "billing", reason: "the folder was moved or deleted.")
        XCTAssertEqual(line, "Couldn’t put billing on the bench: the folder was moved or deleted.")
        let failed = Copy.card(suggestion(), sessionTitle: "Fix", phase: .failed(line), home: home)
        XCTAssertEqual(failed.subtitle, line, "the failure takes the subtitle's place")
        XCTAssertEqual(failed.title, "Put billing on the bench?")
    }

    /// §7 "suggestion" row (Swift half, flag only): a folder of another
    /// bench is flagged with that bench's name; the merge variant is §6.13's.
    func testOtherBenchIsFlagged() {
        let card = Copy.card(suggestion(otherBench: .init(id: 9, name: "tools")), sessionTitle: "Fix", phase: .ready, home: home)
        XCTAssertEqual(card.otherBench, "tools")
    }

    func testAnswerLines() {
        XCTAssertEqual(Copy.addedAnswer(name: "billing"),
                       "billing is on the bench now. Start a sub-session there with start_session(\"billing\", …).")
        XCTAssertEqual(Copy.notNowAnswer, "The owner said not now.")
        XCTAssertEqual(Copy.neverAnswer(name: "billing"), "The owner does not want billing on this bench.")
        XCTAssertEqual(Copy.folderName("/Users/owner/code/billing"), "billing")
    }

    // MARK: - Remove from Bench / Locate (§6.3)

    func testRemoveStrings() {
        typealias Folders = WorkbenchFolderPresentation
        let confirm = Folders.removeConfirm(name: "hub")
        XCTAssertEqual(confirm.title, "Remove hub from the bench?")
        XCTAssertEqual(confirm.message, "Watchtower's install in this folder is removed. Your files and git are not touched.")
        XCTAssertTrue(confirm.confirms)
        XCTAssertEqual(Folders.cancel, "Cancel")
        XCTAssertEqual(Folders.remove, "Remove")
        XCTAssertEqual(Folders.ok, "OK")

        let one = Folders.removeRefusedSessions(name: "hub", count: 1)
        XCTAssertEqual(one.title, "Can’t remove hub from the bench")
        XCTAssertEqual(one.message, "1 session is running in hub. Finish it first.")
        XCTAssertFalse(one.confirms)
        XCTAssertEqual(Folders.removeRefusedSessions(name: "hub", count: 2).message,
                       "2 sessions are running in hub. Finish them first.")
        let last = Folders.removeRefusedLast(name: "app")
        XCTAssertEqual(last.title, "Can’t remove app from the bench")
        XCTAssertEqual(last.message, "A workbench needs at least one folder.")
        XCTAssertFalse(last.confirms)
        XCTAssertEqual(Folders.removeRefused(name: "hub", reason: "1 session is running in hub. Finish it first."),
                       one, "Go's refusal after the confirmation reads as the Desktop's own")
        XCTAssertEqual(Folders.removeFailed(name: "hub", reason: "boom"), "Couldn’t remove hub from the bench: boom")
    }

    func testLocateStrings() {
        typealias Folders = WorkbenchFolderPresentation
        XCTAssertEqual(Folders.locate, "Locate…")
        XCTAssertEqual(Folders.locatePanelTitle(name: "hub"), "Locate hub")
        XCTAssertEqual(Folders.locatePanelPrompt, "Choose")
        XCTAssertEqual(Folders.locateFailed(name: "hub", reason: "nested: inside app"), "Couldn’t locate hub: nested: inside app")
    }
}
