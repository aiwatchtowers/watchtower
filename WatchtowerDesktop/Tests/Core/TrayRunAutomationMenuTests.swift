import XCTest
@testable import WatchtowerCore

/// The tray's "Run automation ▸" submenu (spec §12.7, mockup 7).
final class TrayRunAutomationMenuTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_152_000) // 2026-10-16T12:00:00Z
    private let acme = QuickRunRow.Group.workbench(id: 10, name: "acme")

    private func row(
        _ id: Int64,
        _ name: String,
        group: QuickRunRow.Group = .personal,
        kind: QuickRunRow.Kind = .manual,
        asksFirst: Bool = false,
        state: QuickRunRow.State = .runnable,
        lastRun: AutomationRun? = nil
    ) -> QuickRunRow {
        QuickRunRow(id: id, name: name, group: group, kind: kind, asksFirst: asksFirst, state: state, lastRun: lastRun)
    }

    private func run(_ status: AutomationRunStatus, daysAgo: Double) -> AutomationRun {
        AutomationRun(id: 1, automationID: 1, status: status, finishedAt: now.addingTimeInterval(-daysAgo * 86400))
    }

    private func item(_ row: QuickRunRow) throws -> TrayRunAutomationMenu.Item {
        try XCTUnwrap(TrayRunAutomationMenu.sections([row], now: now).first?.items.first)
    }

    func testSectionsByWorkbenchThenPersonal() {
        let rows = [
            row(1, "Release", group: acme),
            row(2, "Deploy to test", group: acme),
            row(3, "Ship", group: .workbench(id: 20, name: "zeta")),
            row(4, "Release notes draft"),
            row(5, "Morning mail digest", kind: .scheduledOrEvent)
        ]
        let sections = TrayRunAutomationMenu.sections(rows, now: now)
        XCTAssertEqual(sections.map(\.title), ["acme", "zeta", "Personal"])
        XCTAssertEqual(sections.map(\.id), ["workbench-10", "workbench-20", "personal"])
        XCTAssertEqual(sections.map { $0.items.map(\.id) }, [[1, 2], [3], [4, 5]])
        XCTAssertEqual(TrayRunAutomationMenu.sections([], now: now), [])
    }

    func testItemTitles() throws {
        XCTAssertEqual(try item(row(1, "Release", kind: .button, asksFirst: true)).title, "Release…")
        XCTAssertEqual(try item(row(2, "Morning mail digest", kind: .scheduledOrEvent)).title,
                       "Morning mail digest (run now)")
        XCTAssertEqual(try item(row(3, "Release notes draft")).title, "Release notes draft")
    }

    func testStatusText() throws {
        XCTAssertEqual(try item(row(1, "A", lastRun: run(.succeeded, daysAgo: 2))).status, "✓ 2 d ago")
        XCTAssertEqual(try item(row(1, "A", lastRun: run(.failed, daysAgo: 2))).status, "✗ 2 d ago")
        XCTAssertEqual(try item(row(1, "A", state: .running(runID: 7), lastRun: run(.succeeded, daysAgo: 2))).status,
                       "● running")
        XCTAssertEqual(try item(row(1, "A", state: .needsConfirmation, lastRun: run(.succeeded, daysAgo: 2))).status,
                       "— needs confirmation")
        XCTAssertEqual(try item(row(1, "A", state: .disabled)).status, "— disabled")
        XCTAssertEqual(try item(row(1, "A", state: .parseError)).status, "— can't be read")
        XCTAssertEqual(try item(row(1, "A")).status, "")
        // The label carries the status: a menu item has no trailing detail column.
        XCTAssertEqual(try item(row(1, "A", lastRun: run(.succeeded, daysAgo: 2))).label, "A  ✓ 2 d ago")
        XCTAssertEqual(try item(row(1, "A")).label, "A")
    }

    func testAges() {
        XCTAssertEqual(TrayRunAutomationMenu.age(of: now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(TrayRunAutomationMenu.age(of: now.addingTimeInterval(-300), now: now), "5 min ago")
        XCTAssertEqual(TrayRunAutomationMenu.age(of: now.addingTimeInterval(-3 * 3600), now: now), "3 h ago")
        XCTAssertEqual(TrayRunAutomationMenu.age(of: now.addingTimeInterval(-2 * 86400), now: now), "2 d ago")
    }

    /// Review Focus 8: a disabled or unreadable recipe runs nothing from the tray.
    func testDisabledItemsAreNotActionable() throws {
        XCTAssertFalse(try item(row(1, "A", state: .disabled)).isActionable)
        XCTAssertFalse(try item(row(1, "A", state: .parseError)).isActionable)
        XCTAssertTrue(try item(row(1, "A", state: .needsConfirmation)).isActionable, "it opens the sheet")
        XCTAssertTrue(try item(row(1, "A", state: .running(runID: 7))).isActionable, "it opens the run")
        XCTAssertTrue(try item(row(1, "A")).isActionable)
    }
}
