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

    /// Go `TestFallbackSummary`'s cases.
    func testFallbackMatchesGoCases() {
        let nine = "abcdefghi "
        let cases: [(String, String)] = [
            ("Every morning, writes your brief. Then plans.", "Every morning, writes your brief."),
            ("", ""),
            ("Writes the brief.\nThen plans.", "Writes the brief."),
            ("Writes the\nbrief\n\n and plans", "Writes the brief and plans"),
            ("Writes the brief.", "Writes the brief."),
            ("Writes the brief", "Writes the brief"),
            (String(repeating: nine, count: 10).trimmingCharacters(in: .whitespaces) + ". Next.",
             String(repeating: nine, count: 5) + "abcdefghi…"),
            (String(repeating: nine, count: 5) + "abcdefghij tail words here",
             String(repeating: nine, count: 5) + "abcdefghij…"),
            (String(repeating: "привет мир ", count: 6).trimmingCharacters(in: .whitespaces),
             Array(repeating: "привет мир", count: 5).joined(separator: " ") + "…"),
            (String(repeating: "x", count: 100), String(repeating: "x", count: 60) + "…")
        ]
        for (input, want) in cases {
            XCTAssertEqual(AutomationRowSummary.fallback(description: input), want, input)
        }
    }

    func testFallbackTrimsTrailingPunctuationBeforeEllipsis() {
        let comma = String(repeating: "a", count: 55) + ", " + String(repeating: "b", count: 20)
        XCTAssertEqual(AutomationRowSummary.fallback(description: comma), String(repeating: "a", count: 55) + "…")
    }

    func testDescriptionMatchesGoBodyParsing() {
        let fm = "---\nname: \"A\"\ntrigger:\n  manual: true\n---\n"
        // js fence dropped (info token only), other fences stay in, text after kept.
        let text = fm + "Intro line.\n\n```js title\ncode();\n```\n~~~\nnot script\n~~~\nTail.\n"
        XCTAssertEqual(AutomationRowSummary.description(recipeText: text), "Intro line.\n\n~~~\nnot script\n~~~\nTail.")
        // Go normalises CRLF and lone CR to LF (and drops a BOM) before splitting.
        let crlf = fm + "Intro.\r\nMore.\r\n```js\r\ncode();\r\n```\r\nAfter.\r\n"
        XCTAssertEqual(AutomationRowSummary.description(recipeText: crlf), "Intro.\nMore.\nAfter.")
        let cr = "\u{FEFF}" + fm.replacingOccurrences(of: "\n", with: "\r") + "Lone.\r```js\rx();\r```\rEnd.\r"
        XCTAssertEqual(AutomationRowSummary.description(recipeText: cr), "Lone.\nEnd.")
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
                                                       now: now), .lastRun(word: "ok", ago: "5 min ago"))
        XCTAssertEqual(AutomationRowPresentation.state(item(lastRun: .cancelled), now: now),
                       .lastRun(word: "cancelled", ago: "5 min ago"))
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
        // Failed and needs confirmation are warnings; a draft is not.
        XCTAssertEqual(section.attention, [
            AutomationAttentionPart(text: "1 failed", isWarning: true),
            AutomationAttentionPart(text: "1 draft", isWarning: false),
            AutomationAttentionPart(text: "1 needs confirmation", isWarning: true)
        ])
        let many = AutomationListSection(
            id: "p", title: "P", drafts: [draft, draft],
            items: [item(lastRun: .failed), item(lastRun: .failed), item(confirmed: false), item(confirmed: false)]
        )
        XCTAssertEqual(many.attention.map(\.text), ["2 failed", "2 drafts", "2 need confirmation"])
        XCTAssertEqual(AutomationListSection(id: "p", title: "P", drafts: [], items: [item()]).attention, [])
    }
}
