import XCTest
@testable import WatchtowerCore

/// View → Go to Item (⌘1…⌘9) and View → Back (⌘[), one set for the
/// Workbench page and the Chats tab (spec 2026-10-26 §4, §5.4).
final class ItemShortcutTargetTests: XCTestCase {
    private typealias Target = ItemShortcutTarget

    func testAWorkbenchPageGetsItsSessionsAndItsOwnBack() {
        for back in [Target.Back.popSubagent, .showAllWorkbenches, nil] {
            let resolution = Target.resolve(workbench: .init(canUseSessionKeys: true, back: back), chats: nil)
            XCTAssertEqual(resolution.items, .workbenchSessions)
            XCTAssertEqual(resolution.back, back, "the workbench context's backAction, unchanged")
        }
    }

    /// Under the Go to… palette (or with no workbench page) the items are
    /// off; Back is whatever the workbench's backAction said (nil there).
    func testAWorkbenchWithoutAPageOrUnderThePaletteHasNoItems() {
        let resolution = Target.resolve(workbench: .init(canUseSessionKeys: false, back: nil), chats: nil)
        XCTAssertNil(resolution.items)
        XCTAssertNil(resolution.back)
        let listOnly = Target.resolve(workbench: .init(canUseSessionKeys: false, back: .popSubagent), chats: nil)
        XCTAssertNil(listOnly.items)
        XCTAssertEqual(listOnly.back, .popSubagent)
    }

    func testTheChatsTabGetsItsRowsAndBackToAllChatsInAProject() {
        let all = Target.resolve(workbench: nil, chats: .init(canUseRowKeys: true, projectSelected: false))
        XCTAssertEqual(all.items, .chatRows)
        XCTAssertNil(all.back, "All chats: nowhere to go back to")
        let project = Target.resolve(workbench: nil, chats: .init(canUseRowKeys: true, projectSelected: true))
        XCTAssertEqual(project.items, .chatRows)
        XCTAssertEqual(project.back, .showAllChats)
    }

    func testChatsWithASheetOrRenameFieldTakingTheKeysAreOff() {
        let resolution = Target.resolve(workbench: nil, chats: .init(canUseRowKeys: false, projectSelected: true))
        XCTAssertNil(resolution.items)
        XCTAssertNil(resolution.back)
    }

    func testAnotherTabDisablesBoth() {
        XCTAssertEqual(Target.resolve(workbench: nil, chats: nil), .init(items: nil, back: nil))
    }
}
