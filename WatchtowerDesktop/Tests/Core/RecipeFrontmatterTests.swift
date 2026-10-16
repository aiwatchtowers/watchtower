import XCTest
@testable import WatchtowerCore

final class RecipeFrontmatterTests: XCTestCase {
    /// The sample the shared fixture holds; Go's
    /// `TestRecipe_ParsesSwiftWrittenFrontmatter` expects these fields.
    static let sample = RecipeFrontmatter(
        name: #"Mail: "triage" # weekly \ done — ok"#,
        trigger: .schedule("30 8 * * 1-5"),
        missed: "skip",
        concurrency: 2,
        permissions: ["gmail:read@work", "llm:light"],
        outputs: ["inbox", "report"],
        budgetTokens: 120_000,
        budgetMinutes: 10,
        pauseTimeoutHours: 24
    )

    private static let body = "Reads mail: every weekday.\n\n```js\n// ---\nconst a = 1;\n"
        + "output.inbox({ title: \"t\", body: \"b\" });\n```\n\n---\nTrailing notes.\n"

    /// Keys at an indent, in order (list items and `---` lines skipped).
    private func keys(_ text: String, indent: Int) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let pad = line.prefix { $0 == " " }.count
            guard pad == indent, line != "---", !line.dropFirst(pad).hasPrefix("- ") else { return nil }
            return line.dropFirst(pad).split(separator: ":", maxSplits: 1).first.map(String.init)
        }
    }

    func testRenderOnlySpecKeys() {
        let text = RecipeFrontmatter.render(Self.sample)
        XCTAssertTrue(text.hasPrefix("---\n"))
        XCTAssertTrue(text.hasSuffix("\n---\n"))
        XCTAssertEqual(keys(text, indent: 0),
                       ["name", "trigger", "missed", "concurrency", "permissions", "outputs", "budget",
                        "pause_timeout_hours"])
        XCTAssertEqual(keys(text, indent: 2), ["schedule", "tokens", "minutes"])

        var button = Self.sample
        button.trigger = .button(label: "Release", confirm: true)
        button.permissions = []
        let buttonText = RecipeFrontmatter.render(button)
        XCTAssertEqual(keys(buttonText, indent: 2), ["button", "tokens", "minutes"])
        XCTAssertEqual(keys(buttonText, indent: 4), ["label", "confirm"])
        XCTAssertTrue(buttonText.contains("    confirm: true\n"))
        XCTAssertTrue(buttonText.contains("permissions: []\n"))

        var event = Self.sample
        event.trigger = .event(type: "gmail.new_messages", where: ["from": "*@example.com", "account": "work"])
        let eventText = RecipeFrontmatter.render(event)
        XCTAssertEqual(keys(eventText, indent: 4), ["type", "where"])
        XCTAssertTrue(eventText.contains("      \"account\": \"work\"\n      \"from\": \"*@example.com\"\n"),
                      "where keys are sorted and quoted")

        var manual = Self.sample
        manual.trigger = .manual
        XCTAssertTrue(RecipeFrontmatter.render(manual).contains("trigger:\n  manual: true\n"))
    }

    func testSpliceKeepsDescriptionAndScriptByteIdentical() {
        let original = "---\n# a comment the splice drops\nname: Old\ntrigger:\n  manual: true\n---\n" + Self.body
        let spliced = RecipeFrontmatter.splice(Self.sample, into: original)
        XCTAssertEqual(spliced, RecipeFrontmatter.render(Self.sample) + Self.body)

        let crlfBody = "Line one.\r\n\r\n```js\r\nconst a = 1;\r\n```\r\n"
        let crlf = "---\r\nname: Old\r\n---\r\n" + crlfBody
        XCTAssertEqual(Array(RecipeFrontmatter.splice(Self.sample, into: crlf).utf8),
                       Array((RecipeFrontmatter.render(Self.sample) + crlfBody).utf8))

        XCTAssertEqual(RecipeFrontmatter.splice(Self.sample, into: "No frontmatter.\n"),
                       RecipeFrontmatter.render(Self.sample) + "No frontmatter.\n")
        XCTAssertEqual(RecipeFrontmatter.block(in: original), "---\n# a comment the splice drops\nname: Old\ntrigger:\n  manual: true\n---\n")
        XCTAssertNil(RecipeFrontmatter.block(in: "---\nname: never closed\n"))
    }

    func testQuotesSpecialCharacters() {
        var f = Self.sample
        f.name = "a: b # c"
        f.trigger = .schedule("*/5 * * * *")
        let text = RecipeFrontmatter.render(f)
        XCTAssertTrue(text.contains("name: \"a: b # c\"\n"))
        XCTAssertTrue(text.contains("  schedule: \"*/5 * * * *\"\n"))

        XCTAssertEqual(RecipeFrontmatter.quoted(#"say "hi" \ bye"#), #""say \"hi\" \\ bye""#)
        XCTAssertEqual(RecipeFrontmatter.quoted("two\nlines\tand\u{7}bell"), #""two\nlines\tand\u0007bell""#)
        XCTAssertEqual(RecipeFrontmatter.quoted("Ünïcode — ok"), "\"Ünïcode — ok\"")
    }

    /// The Swift half of the dual path: Go parses this file to `sample`'s fields.
    func testRenderMatchesSharedFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/automations/testdata/recipes/swift_written.md")
        let data = try Data(contentsOf: fixture)
        XCTAssertEqual(Array(RecipeFrontmatter.render(Self.sample).utf8), Array(data))
    }

    func testTriggerFromSpecJSON() {
        XCTAssertEqual(RecipeFrontmatter.trigger(kind: "schedule", specJSON: #"{"schedule":"0 9 * * 1-5"}"#),
                       .schedule("0 9 * * 1-5"))
        XCTAssertEqual(RecipeFrontmatter.trigger(kind: "button", specJSON: #"{"button":{"label":"Go","confirm":true}}"#),
                       .button(label: "Go", confirm: true))
        XCTAssertEqual(
            RecipeFrontmatter.trigger(kind: "event", specJSON: #"{"event":{"type":"gmail.new_messages","where":{"a":"b"}}}"#),
            .event(type: "gmail.new_messages", where: ["a": "b"])
        )
        XCTAssertEqual(RecipeFrontmatter.trigger(kind: "manual", specJSON: #"{"manual":true}"#), .manual)
    }
}
