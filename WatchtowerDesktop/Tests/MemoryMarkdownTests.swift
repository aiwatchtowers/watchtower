import XCTest
@testable import WatchtowerDesktop

final class MemoryMarkdownTests: XCTestCase {

    // MARK: - splitFrontmatter

    func testSplitFrontmatter() {
        let raw = "---\nid: ent_A\ntype: entity\n---\n# Title\n\nBody text\n"
        let (fm, body) = MemoryMarkdown.splitFrontmatter(raw)
        XCTAssertEqual(fm, "id: ent_A\ntype: entity")
        XCTAssertEqual(body, "# Title\n\nBody text\n")
    }

    func testSplitFrontmatterMissingFenceDegradesToBody() {
        let raw = "# Just markdown, no frontmatter\n"
        let (fm, body) = MemoryMarkdown.splitFrontmatter(raw)
        XCTAssertEqual(fm, "")
        XCTAssertEqual(body, raw)
    }

    func testSplitFrontmatterUnterminatedFenceDegradesToBody() {
        let raw = "---\nid: ent_A\nno closing fence"
        let (fm, body) = MemoryMarkdown.splitFrontmatter(raw)
        XCTAssertEqual(fm, "")
        XCTAssertEqual(body, raw)
    }

    // MARK: - parseWikiLinks

    func testParseWikiLinks() {
        let body = "See [[ent_A]] and [[ep_B|the incident]]; not a [link](x)."
        let links = MemoryMarkdown.parseWikiLinks(body)
        XCTAssertEqual(links, [
            MemoryWikiLink(target: "ent_A", label: ""),
            MemoryWikiLink(target: "ep_B", label: "the incident")
        ])
    }

    func testParseWikiLinksAliasTargetWithColon() {
        let links = MemoryMarkdown.parseWikiLinks("From [[situation:23|the situation]].")
        XCTAssertEqual(links, [MemoryWikiLink(target: "situation:23", label: "the situation")])
    }

    // MARK: - convertWikiLinks

    func testConvertWikiLinksResolvedBecomesMarkdownLink() {
        let body = "See [[ent_A|Alice]]."
        let out = MemoryMarkdown.convertWikiLinks(in: body) { _ in "Alice" }
        XCTAssertEqual(out, "See [Alice](watchtower-memory://open/ent_A).")
    }

    func testConvertWikiLinksUnresolvedFallsBackToPlainText() {
        let body = "See [[ent_gone|Ghost]] and [[ent_gone2]]."
        let out = MemoryMarkdown.convertWikiLinks(in: body) { _ in nil }
        XCTAssertEqual(out, "See Ghost and ent_gone2.")
    }

    func testConvertWikiLinksEscapesBracketsInDisplayText() {
        // Labels can't contain brackets (regex), but resolved TITLES from the
        // index can — they must not terminate the markdown link early.
        let out = MemoryMarkdown.convertWikiLinks(in: "[[ent_A]]") { _ in
            "a [b] c"
        }
        XCTAssertEqual(out, "[a (b) c](watchtower-memory://open/ent_A)")
    }

    // MARK: - linkURL / linkTarget round-trip

    func testLinkRoundTripPlainID() throws {
        let urlString = try XCTUnwrap(MemoryMarkdown.linkURL(for: "ent_01ABC"))
        let url = try XCTUnwrap(URL(string: urlString))
        XCTAssertEqual(MemoryMarkdown.linkTarget(from: url), "ent_01ABC")
    }

    func testLinkRoundTripAliasWithColon() throws {
        let urlString = try XCTUnwrap(MemoryMarkdown.linkURL(for: "situation:23"))
        let url = try XCTUnwrap(URL(string: urlString))
        XCTAssertEqual(MemoryMarkdown.linkTarget(from: url), "situation:23")
    }

    func testLinkTargetRejectsForeignScheme() {
        XCTAssertNil(MemoryMarkdown.linkTarget(from: URL(string: "https://example.com/x")!))
    }

    // MARK: - importance_override

    func testPatchImportanceOverrideInsertsWhenAbsent() {
        let fm = "id: ent_A\ntype: entity"
        let out = MemoryMarkdown.patchImportanceOverride(frontmatter: fm, value: 5.0)
        XCTAssertEqual(out, "id: ent_A\ntype: entity\nimportance_override: 5")
    }

    func testPatchImportanceOverrideReplacesExistingValueInPlace() {
        let fm = "id: ent_A\nimportance_override: 2.0\ntype: entity"
        let out = MemoryMarkdown.patchImportanceOverride(frontmatter: fm, value: 7.5)
        XCTAssertEqual(out, "id: ent_A\nimportance_override: 7.5\ntype: entity")
    }

    func testPatchImportanceOverrideRemovesWhenValueIsNil() {
        let fm = "id: ent_A\nimportance_override: 2.0\ntype: entity"
        let out = MemoryMarkdown.patchImportanceOverride(frontmatter: fm, value: nil)
        XCTAssertEqual(out, "id: ent_A\ntype: entity")
    }

    func testPatchImportanceOverrideNoOpWhenAbsentAndNil() {
        let fm = "id: ent_A\ntype: entity"
        let out = MemoryMarkdown.patchImportanceOverride(frontmatter: fm, value: nil)
        XCTAssertEqual(out, fm)
    }

    func testCurrentImportanceOverrideParsesValue() {
        XCTAssertEqual(MemoryMarkdown.currentImportanceOverride(frontmatter: "id: ent_A\nimportance_override: 3.5"), 3.5)
    }

    func testCurrentImportanceOverrideNilWhenAbsent() {
        XCTAssertNil(MemoryMarkdown.currentImportanceOverride(frontmatter: "id: ent_A"))
    }

    func testCurrentImportanceOverrideNilWhenUnparsable() {
        XCTAssertNil(MemoryMarkdown.currentImportanceOverride(frontmatter: "id: ent_A\nimportance_override: not-a-number"))
    }
}
