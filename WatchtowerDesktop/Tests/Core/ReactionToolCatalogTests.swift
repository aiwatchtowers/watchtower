import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The one tool-id → human-name mapping (`ReactionToolCatalog`), the
/// shortcode → glyph rendering the cheat sheet uses (`SlackEmoji.glyph`/
/// `label`), and the cheat-sheet row builder over the live dictionary.
final class ReactionToolCatalogTests: XCTestCase {
    func testEveryReactionToolHasAHumanNameDescriptionAndDestination() {
        for tool in ReactionDictionaryTools.all {
            guard let info = ReactionToolCatalog.info(for: tool) else {
                XCTFail("\(tool) has no catalog entry")
                continue
            }
            XCTAssertFalse(info.title.isEmpty, tool)
            XCTAssertNotEqual(info.title, tool, "\(tool) must read as words, not the tool id")
            XCTAssertFalse(info.summary.isEmpty, tool)
            XCTAssertFalse(info.destination.isEmpty, tool)
        }
    }

    func testNamedTitles() {
        XCTAssertEqual(ReactionToolCatalog.title(for: "brief_context"), "Brief me")
        XCTAssertEqual(ReactionToolCatalog.title(for: "create_target"), "Create a target")
        XCTAssertEqual(ReactionToolCatalog.title(for: "remind_me"), "Remind me")
    }

    func testUnknownToolFallsBackToItsID() {
        XCTAssertNil(ReactionToolCatalog.info(for: "frobnicate"))
        XCTAssertEqual(ReactionToolCatalog.title(for: "frobnicate"), "frobnicate")
    }

    /// External tools (`create_jira_issue`) always land behind Approve —
    /// `SetTrust` refuses `execute` for them (AGENT-03).
    func testExternalToolsAlwaysAsk() {
        XCTAssertEqual(ReactionToolCatalog.info(for: "create_jira_issue")?.alwaysAsks, true)
        XCTAssertEqual(ReactionToolCatalog.info(for: "create_idea")?.alwaysAsks, false)
    }

    // MARK: - Emoji

    func testGlyphForKnownShortcodes() {
        XCTAssertEqual(SlackEmoji.glyph(forShortcode: "alarm_clock"), "⏰")
        XCTAssertEqual(SlackEmoji.glyph(forShortcode: "white_check_mark"), "✅")
        XCTAssertEqual(SlackEmoji.glyph(forShortcode: "pushpin"), "📌")
        XCTAssertEqual(SlackEmoji.glyph(forShortcode: "eyes"), "👀")
        XCTAssertEqual(SlackEmoji.glyph(forShortcode: "bulb"), "💡")
        XCTAssertEqual(SlackEmoji.glyph(forShortcode: "ticket"), "🎫")
    }

    func testGlyphForUnknownShortcodeIsNil() {
        XCTAssertNil(SlackEmoji.glyph(forShortcode: "our_custom_parrot"))
        XCTAssertNil(SlackEmoji.glyph(forShortcode: ""))
    }

    func testLabelPairsGlyphWithShortcodeAndFallsBackToText() {
        XCTAssertEqual(SlackEmoji.label(forShortcode: "bulb"), "💡 :bulb:")
        XCTAssertEqual(SlackEmoji.label(forShortcode: "our_custom_parrot"), ":our_custom_parrot:")
    }

    // MARK: - Cheat-sheet rows

    private func mapping(_ emoji: String, _ tool: String, enabled: Bool = true) -> ReactionCommandMapping {
        ReactionCommandMapping(row: ["emoji": emoji, "kind": "builtin_tool", "tool": tool, "enabled": enabled])
    }

    func testRowsComeFromTheDictionaryIncludingACustomMapping() {
        let rows = ReactionCheatSheet.rows(
            mappings: [mapping("rocket", "create_idea"), mapping("bulb", "brief_context")],
            trustByTool: [:]
        )
        XCTAssertEqual(rows.map(\.emoji), ["rocket", "bulb"])
        XCTAssertEqual(rows.map(\.title), ["Save as idea", "Brief me"])
        XCTAssertEqual(rows.first?.destination, "Ideas")
    }

    func testDisabledAndToolLessMappingsAreOmitted() {
        let rows = ReactionCheatSheet.rows(
            mappings: [mapping("eyes", "create_track", enabled: false), mapping("pushpin", ""), mapping("bulb", "create_idea")],
            trustByTool: [:]
        )
        XCTAssertEqual(rows.map(\.emoji), ["bulb"])
    }

    func testApprovalFollowsTrustExceptForExternalTools() {
        let rows = ReactionCheatSheet.rows(
            mappings: [mapping("bulb", "create_idea"), mapping("eyes", "create_track"), mapping("ticket", "create_jira_issue")],
            trustByTool: ["create_idea": "execute", "create_jira_issue": "execute"]
        )
        let byEmoji = Dictionary(uniqueKeysWithValues: rows.map { ($0.emoji, $0.needsApproval) })
        XCTAssertEqual(byEmoji["bulb"], false, "trust execute runs immediately")
        XCTAssertEqual(byEmoji["eyes"], true, "no tool_trust row is Go's default: ask")
        XCTAssertEqual(byEmoji["ticket"], true, "an External tool always asks, whatever tool_trust says")
    }

    func testUnknownToolRowShowsItsID() {
        let rows = ReactionCheatSheet.rows(mappings: [mapping("parrot", "frobnicate")], trustByTool: [:])
        XCTAssertEqual(rows.map(\.title), ["frobnicate"])
        XCTAssertEqual(rows.first?.summary, "")
        XCTAssertEqual(rows.first?.needsApproval, true)
    }

    func testStatusLineWithAndWithoutALastCheck() {
        XCTAssertEqual(ReactionCheatSheet.statusLine(lastCheck: nil), "Watching your Slack reactions")
        let fiveMinutesAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5 * 60))
        XCTAssertEqual(
            ReactionCheatSheet.statusLine(lastCheck: fiveMinutesAgo),
            "Watching your Slack reactions — last check 5m ago"
        )
    }
}
