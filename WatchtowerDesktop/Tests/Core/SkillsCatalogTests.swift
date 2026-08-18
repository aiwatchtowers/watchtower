import Foundation
import XCTest
@testable import WatchtowerCore

/// `SkillsCatalog` — the Swift half of the persona-skills dual-path. The
/// fixtures here mirror the Go parser's cases in `internal/skills` so both
/// sides can be checked against the same file shapes: strict on what matters
/// (frontmatter fences, non-empty `description`, known `persona`), lenient
/// elsewhere (unknown keys ignored, `enabled` defaulting to true), and one bad
/// file never breaks the catalog.
final class SkillsCatalogTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "skills_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    /// Writes `<dir>/<file>` verbatim (the file name carries its own suffix so
    /// non-`.md` and invalid-stem cases can be exercised too).
    private func write(_ file: String, _ content: String) {
        try? Data(content.utf8).write(to: URL(fileURLWithPath: dir + "/" + file))
    }

    private func skill(named name: String, in skills: [SkillSummary]) -> SkillSummary? {
        skills.first { $0.name == name }
    }

    // MARK: - Parser

    func testParsesFullFrontmatter() {
        let parsed = SkillsCatalog.parse(name: "thread-untangle", content: """
            ---
            description: Reconstruct who asked what in a tangled thread.
            persona: secretary
            enabled: true
            ---
            Body instructions.
            """)
        XCTAssertEqual(parsed, SkillSummary(
            name: "thread-untangle",
            description: "Reconstruct who asked what in a tangled thread.",
            persona: .secretary,
            enabled: true))
    }

    func testEnabledDefaultsToTrueWhenAbsent() {
        let parsed = SkillsCatalog.parse(name: "status-update", content: """
            ---
            description: Draft a status update.
            persona: both
            ---
            Body.
            """)
        XCTAssertEqual(parsed?.enabled, true, "an absent `enabled` key means enabled")
        XCTAssertEqual(parsed?.persona, .both)
    }

    func testExplicitDisabledIsHonoured() {
        let parsed = SkillsCatalog.parse(name: "target-breakdown", content: """
            ---
            description: Decompose a target into sub-targets.
            persona: assistant
            enabled: false
            ---
            Body.
            """)
        XCTAssertEqual(parsed?.enabled, false)
    }

    func testUnknownFrontmatterKeysAreIgnored() {
        let parsed = SkillsCatalog.parse(name: "extra-keys", content: """
            ---
            description: Still valid.
            persona: secretary
            author: someone
            version: 3
            ---
            Body.
            """)
        XCTAssertEqual(parsed?.description, "Still valid.", "an extra key must not knock a skill out")
    }

    func testInlineCommentAndQuotesAreStripped() {
        let parsed = SkillsCatalog.parse(name: "quoted", content: """
            ---
            description: "Use when the owner asks for a recap."
            persona: secretary   # secretary | assistant | both
            ---
            Body.
            """)
        XCTAssertEqual(parsed?.description, "Use when the owner asks for a recap.")
        XCTAssertEqual(parsed?.persona, .secretary)
    }

    func testRejectsMissingOpeningFence() {
        XCTAssertNil(SkillsCatalog.parse(name: "no-fence", content: """
            description: No frontmatter block at all.
            persona: secretary
            """))
    }

    func testRejectsUnterminatedFrontmatter() {
        XCTAssertNil(SkillsCatalog.parse(name: "unterminated", content: """
            ---
            description: Never closed.
            persona: secretary
            """))
    }

    func testRejectsEmptyDescription() {
        XCTAssertNil(SkillsCatalog.parse(name: "empty-desc", content: """
            ---
            description:
            persona: secretary
            ---
            Body.
            """))
    }

    func testRejectsMissingDescription() {
        XCTAssertNil(SkillsCatalog.parse(name: "no-desc", content: """
            ---
            persona: secretary
            ---
            Body.
            """))
    }

    func testRejectsUnknownPersona() {
        XCTAssertNil(SkillsCatalog.parse(name: "bad-persona", content: """
            ---
            description: Valid description.
            persona: butler
            ---
            Body.
            """))
    }

    func testRejectsMissingPersona() {
        XCTAssertNil(SkillsCatalog.parse(name: "no-persona", content: """
            ---
            description: Valid description.
            ---
            Body.
            """))
    }

    func testRejectsInvalidName() {
        let content = """
            ---
            description: Valid description.
            persona: secretary
            ---
            Body.
            """
        for name in ["Thread-Untangle", "-leading-hyphen", "under_score", "", "../escape"] {
            XCTAssertNil(SkillsCatalog.parse(name: name, content: content),
                         "\(name) must not be a legal skill identity")
        }
    }

    // MARK: - list

    func testListParsesSortsAndSkipsInvalidFiles() {
        write("zeta.md", """
            ---
            description: Zeta skill.
            persona: assistant
            ---
            """)
        write("alpha.md", """
            ---
            description: Alpha skill.
            persona: secretary
            ---
            """)
        // Skipped: malformed frontmatter, unknown persona, invalid stem, non-md.
        write("broken.md", "no frontmatter here")
        write("wrong-persona.md", """
            ---
            description: Bad persona.
            persona: butler
            ---
            """)
        write("Upper.md", """
            ---
            description: Invalid stem.
            persona: secretary
            ---
            """)
        write("notes.txt", """
            ---
            description: Not markdown.
            persona: secretary
            ---
            """)

        let skills = SkillsCatalog.list(dir: dir)

        XCTAssertEqual(skills.map(\.name), ["alpha", "zeta"], "valid files only, sorted by name")
    }

    func testListOnMissingDirIsEmpty() {
        XCTAssertEqual(SkillsCatalog.list(dir: dir + "/nope").count, 0)
        XCTAssertEqual(SkillsCatalog.list(dir: nil).count, 0, "no active workspace means no skills")
        XCTAssertEqual(SkillsCatalog.list(dir: "").count, 0)
    }

    func testListReportsDisabledSkillsWithTheirFlag() {
        write("off.md", """
            ---
            description: Disabled skill.
            persona: secretary
            enabled: false
            ---
            """)
        let skills = SkillsCatalog.list(dir: dir)
        XCTAssertEqual(skill(named: "off", in: skills)?.enabled, false,
                       "list reports the flag; filtering is promptBlock's job")
    }

    // MARK: - promptBlock

    /// Seeds one skill file per persona/enabled combination used below.
    private func seedMixedCatalog() {
        write("sec-on.md", """
            ---
            description: Secretary skill.
            persona: secretary
            ---
            """)
        write("asst-on.md", """
            ---
            description: Assistant skill.
            persona: assistant
            ---
            """)
        write("both-on.md", """
            ---
            description: Shared skill.
            persona: both
            ---
            """)
        write("sec-off.md", """
            ---
            description: Disabled secretary skill.
            persona: secretary
            enabled: false
            ---
            """)
    }

    func testPromptBlockFiltersBySecretaryPersona() throws {
        seedMixedCatalog()
        let block = try XCTUnwrap(SkillsCatalog.promptBlock(persona: .secretary, dir: dir))

        XCTAssertTrue(block.contains("AVAILABLE SKILLS"))
        XCTAssertTrue(block.contains("sec-on — Secretary skill."))
        XCTAssertTrue(block.contains("both-on — Shared skill."), "`both` matches either persona")
        XCTAssertFalse(block.contains("asst-on"), "the other persona's skills must not leak in")
        XCTAssertFalse(block.contains("sec-off"), "a disabled skill is never listed")
        XCTAssertTrue(block.contains("load_skill"), "the block must point at the load tool")
    }

    func testPromptBlockFiltersByAssistantPersona() throws {
        seedMixedCatalog()
        let block = try XCTUnwrap(SkillsCatalog.promptBlock(persona: .assistant, dir: dir))

        XCTAssertTrue(block.contains("asst-on — Assistant skill."))
        XCTAssertTrue(block.contains("both-on — Shared skill."))
        XCTAssertFalse(block.contains("sec-on"))
    }

    func testPromptBlockNilWhenNothingMatches() {
        write("asst-on.md", """
            ---
            description: Assistant skill.
            persona: assistant
            ---
            """)
        XCTAssertNil(SkillsCatalog.promptBlock(persona: .secretary, dir: dir),
                     "no matching enabled skill must leave the prompt byte-identical")
    }

    func testPromptBlockNilOnEmptyOrMissingDir() {
        XCTAssertNil(SkillsCatalog.promptBlock(persona: .secretary, dir: dir))
        XCTAssertNil(SkillsCatalog.promptBlock(persona: .assistant, dir: dir + "/nope"))
        XCTAssertNil(SkillsCatalog.promptBlock(persona: .assistant, dir: nil))
    }

    func testPromptBlockNilWhenEveryMatchIsDisabled() {
        write("sec-off.md", """
            ---
            description: Disabled secretary skill.
            persona: secretary
            enabled: false
            ---
            """)
        XCTAssertNil(SkillsCatalog.promptBlock(persona: .secretary, dir: dir))
    }

    // MARK: - Persona mapping

    func testPersonaByContextTypeMatchesTheContract() {
        XCTAssertEqual(SkillsCatalog.personaByContextType, [
            "situation": .secretary,
            "meeting": .secretary,
            "target": .assistant,
            "track": .assistant,
            "idea": .assistant
        ])
    }
}
