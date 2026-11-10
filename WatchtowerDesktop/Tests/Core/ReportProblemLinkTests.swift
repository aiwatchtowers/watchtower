import XCTest
@testable import WatchtowerCore

/// The prefilled GitHub bug-form link: keys, the 6 000-character budget on
/// the encoded URL, and the three shortening steps.
final class ReportProblemLinkTests: XCTestCase {
    private let answer = DiagnosticsAnswer(
        text: "Watchtower 0.30.0 (commit abc1234, flavor: default) · app 0.30.0\nmacOS 15.5 · Apple M3\nConfig: ok",
        version: "0.30.0",
        macos: "macOS 15.5",
        chip: "Apple M3",
        provider: "Claude Code",
        flavor: "default",
        sources: ["Slack"],
        partial: false
    )

    private func items(_ url: URL) -> [String: String] {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var out: [String: String] = [:]
        for item in comps?.queryItems ?? [] {
            XCTAssertNil(out[item.name], "duplicate key \(item.name)")
            out[item.name] = item.value
        }
        return out
    }

    private func make(_ text: String, answer: DiagnosticsAnswer?) -> (url: URL, shortened: Bool) {
        ReportProblemLink.make(
            userText: text,
            answer: answer,
            appVersion: "0.30.0-app",
            macOS: "macOS 15.6",
            repository: URL(string: "https://github.com/example/repo")!
        )
    }

    func testShortTextYieldsFullLink() {
        let text = "Sync stops & never resumes +1\nsecond line = more"
        let link = make(text, answer: answer)
        XCTAssertFalse(link.shortened)
        XCTAssertTrue(link.url.absoluteString.hasPrefix("https://github.com/example/repo/issues/new?"))
        XCTAssertEqual(items(link.url), [
            "template": "bug_report.yml",
            "title": "Sync stops & never resumes +1",
            "version": "0.30.0",
            "macos": "macOS 15.5",
            "chip": "Apple M3",
            "provider": "Claude Code",
            "actual": text,
            "logs": answer.text
        ])
        // `+` and `&` stay escaped: GitHub would read a bare `+` as a space.
        XCTAssertFalse(link.url.query?.contains("+") ?? true)
    }

    func testASCIIAtCapFits() {
        assertFits(String(repeating: "a", count: ReportProblemLink.maxTextLength))
    }

    func testCyrillicAtCapFits() {
        assertFits(String(repeating: "ж", count: ReportProblemLink.maxTextLength))
    }

    func testCJKAtCapFits() {
        assertFits(String(repeating: "漢", count: ReportProblemLink.maxTextLength))
    }

    private func assertFits(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for ans in [answer, nil] {
            let link = make(text, answer: ans)
            XCTAssertLessThanOrEqual(
                link.url.absoluteString.count, ReportProblemLink.maxURLLength, file: file, line: line
            )
            XCTAssertNotNil(items(link.url)["actual"], file: file, line: line)
        }
    }

    func testStep3NeverSplitsCharacterOrEscape() throws {
        // Mixed widths, a combining sequence and an emoji with modifiers,
        // so a byte- or scalar-level cut would show up.
        let unit = "aж漢e\u{301}👍🏽&+% "
        let text = String(String(repeating: unit, count: 400).prefix(ReportProblemLink.maxTextLength))
        let link = make(text, answer: answer)
        XCTAssertTrue(link.shortened)
        XCTAssertLessThanOrEqual(link.url.absoluteString.count, ReportProblemLink.maxURLLength)
        let fields = items(link.url)
        XCTAssertEqual(fields["logs"], ReportProblemCopy.logsPlaceholder)
        // A split percent escape would not decode: `actual` would be nil.
        let actual = try XCTUnwrap(fields["actual"])
        XCTAssertTrue(actual.hasSuffix(ReportProblemCopy.truncatedSuffix))
        let kept = String(actual.dropLast(ReportProblemCopy.truncatedSuffix.count))
        XCTAssertFalse(kept.isEmpty)
        XCTAssertTrue(text.hasPrefix(kept))
        XCTAssertLessThan(kept.count, text.count)
        // A whole number of characters: the kept part ends on a boundary of the input.
        XCTAssertEqual(Array(text.prefix(kept.count)), Array(kept))
    }

    func testOverBudgetReplacesLogs() {
        // The user text fits alone, but not together with a long report.
        let long = DiagnosticsAnswer(
            text: String(repeating: "Recent errors line · ", count: 300),
            version: answer.version, macos: answer.macos, chip: answer.chip,
            provider: answer.provider, flavor: answer.flavor, sources: answer.sources, partial: false
        )
        let link = make("Short text", answer: long)
        XCTAssertTrue(link.shortened)
        let fields = items(link.url)
        XCTAssertEqual(fields["logs"], "Paste the report from Watchtower here.")
        XCTAssertEqual(fields["actual"], "Short text")
        XCTAssertLessThanOrEqual(link.url.absoluteString.count, ReportProblemLink.maxURLLength)
    }

    func testFailedStateLink() {
        let link = make("It broke", answer: nil)
        XCTAssertFalse(link.shortened)
        XCTAssertEqual(items(link.url), [
            "template": "bug_report.yml",
            "title": "It broke",
            "version": "0.30.0-app",
            "macos": "macOS 15.6",
            "actual": "It broke"
        ])
    }

    func testFailedStateOverBudgetCarriesNoLogs() throws {
        let text = String(repeating: "漢", count: ReportProblemLink.maxTextLength)
        let link = make(text, answer: nil)
        XCTAssertTrue(link.shortened)
        XCTAssertLessThanOrEqual(link.url.absoluteString.count, ReportProblemLink.maxURLLength)
        let fields = items(link.url)
        XCTAssertEqual(Set(fields.keys), ["template", "title", "version", "macos", "actual"])
        let actual = try XCTUnwrap(fields["actual"])
        XCTAssertTrue(actual.hasSuffix(ReportProblemCopy.truncatedSuffix))
    }

    func testEmptyProviderIsLeftUnset() {
        let invalid = DiagnosticsAnswer(
            text: "x", version: "1", macos: "macOS 15.5", chip: "Other",
            provider: "", flavor: "default", sources: [], partial: false
        )
        XCTAssertNil(items(make("t", answer: invalid).url)["provider"])
    }

    func testTitleIsFirstLineCapped80() {
        let first = String(repeating: "x", count: 100)
        let title = items(make("  \n" + first + "\nrest", answer: answer).url)["title"]
        XCTAssertEqual(title, String(repeating: "x", count: 80))
        let spaced = String(repeating: "x", count: 79) + " tail"
        XCTAssertEqual(items(make(spaced, answer: answer).url)["title"], String(repeating: "x", count: 79))
        let short = items(make("  Short title  \nrest", answer: answer).url)["title"]
        XCTAssertEqual(short, "Short title")
    }

    func testLinkKeysMatchForm() throws {
        let form = URL(fileURLWithPath: #filePath) // …/WatchtowerDesktop/Tests/Core/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".github/ISSUE_TEMPLATE/bug_report.yml")
        let yaml = try String(contentsOf: form, encoding: .utf8)
        let ids = Set(yaml.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("id:") else { return nil }
            return trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        })
        XCTAssertFalse(ids.isEmpty)
        let fields = items(make("text", answer: answer).url)
        XCTAssertEqual(Set(fields.keys).subtracting(["template", "title"]).subtracting(ids), [])
        // `template` names this very form.
        XCTAssertEqual(fields["template"], form.lastPathComponent)
    }
}
