import XCTest
@testable import WatchtowerCore

final class AutomationRowSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        enabled: Bool = true,
        confirmed: Bool = true,
        lastRun: AutomationRunStatus? = nil,
        next: Date? = nil
    ) -> AutomationListItem {
        let automation = Automation(
            id: 1, slug: "a", name: "A", approvalHash: "h",
            confirmedHash: confirmed ? "h" : "", enabled: enabled, nextRunAt: next
        )
        let run = lastRun.map {
            AutomationRun(id: 1, automationID: 1, status: $0, finishedAt: now.addingTimeInterval(-300))
        }
        return AutomationListItem(
            automation: automation, lastRun: run, activeRun: nil, tokens7d: 0,
            badges: AutomationListItem.badges(for: automation, grants: []), triggerText: "Manual"
        )
    }

    func testSummaryFromFrontmatter() {
        let text = "---\nname: \"A\"\nsummary: \"Your brief and plan\"\ntrigger:\n  manual: true\n---\nBody. More.\n"
            + "```js\noutput.inbox({});\n```\n"
        XCTAssertEqual(AutomationRowSummary.summary(recipeText: text), "Your brief and plan")
        let body = text.replacingOccurrences(of: "summary: \"Your brief and plan\"\n", with: "")
        XCTAssertEqual(AutomationRowSummary.summary(recipeText: body), "Body.")
    }

    func testFallbackMatchesGoCases() {
        XCTAssertEqual(AutomationRowSummary.fallback(description: "Every morning, writes your brief. Then plans."),
                       "Every morning, writes your brief.")
        let long = String(repeating: "abcdefghi ", count: 10).trimmingCharacters(in: .whitespaces)
        let out = AutomationRowSummary.fallback(description: long)
        XCTAssertLessThanOrEqual(out.count, 61)
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertEqual(out, String(repeating: "abcdefghi ", count: 6).trimmingCharacters(in: .whitespaces) + "…")
        XCTAssertEqual(AutomationRowSummary.fallback(description: ""), "")
    }

    func testNoDescriptionIsNil() {
        let text = "---\nname: \"A\"\ntrigger:\n  manual: true\n---\n```js\noutput.inbox({});\n```\n"
        XCTAssertNil(AutomationRowSummary.summary(recipeText: text))
    }

    func testStatePrecedence() {
        XCTAssertEqual(AutomationRowPresentation.state(item(confirmed: false, lastRun: .failed), now: now),
                       .chip(.needsConfirmation))
        XCTAssertEqual(AutomationRowPresentation.state(item(lastRun: .failed), now: now), .failed)
        XCTAssertEqual(AutomationRowPresentation.state(item(enabled: false, lastRun: .succeeded), now: now), .off)
        XCTAssertEqual(AutomationRowPresentation.state(item(lastRun: .succeeded, next: now.addingTimeInterval(60)),
                                                       now: now), .lastRun(ok: true, ago: "5 min ago"))
        XCTAssertEqual(AutomationRowPresentation.state(item(next: now.addingTimeInterval(120)), now: now),
                       .next("in 2 min"))
        XCTAssertEqual(AutomationRowPresentation.state(item(), now: now), .none)
    }

    func testAttentionSuffix() {
        let draft = AutomationDraftRow(conversationID: 1, contextID: "d", workbenchID: nil, name: "x", updatedAt: now)
        let section = AutomationListSection(
            id: "personal", title: "Personal", drafts: [draft],
            items: [item(lastRun: .failed), item(confirmed: false)]
        )
        XCTAssertEqual(section.attention, "1 failed · 1 draft · 1 needs confirmation")
        XCTAssertNil(AutomationListSection(id: "p", title: "P", drafts: [], items: [item()]).attention)
    }
}
