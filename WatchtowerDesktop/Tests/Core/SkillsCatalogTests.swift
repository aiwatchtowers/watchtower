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

    /// The overload every chat VM goes through: the context type it stores on
    /// its conversation picks the persona, and a context type nobody mapped
    /// gets no block rather than a default persona's skills.
    func testPromptBlockByContextTypeResolvesThroughTheTable() throws {
        seedMixedCatalog()

        let secretary = try XCTUnwrap(SkillsCatalog.promptBlock(contextType: "situation", dir: dir))
        XCTAssertTrue(secretary.contains("sec-on"))
        XCTAssertFalse(secretary.contains("asst-on"))

        let assistant = try XCTUnwrap(SkillsCatalog.promptBlock(contextType: "idea", dir: dir))
        XCTAssertTrue(assistant.contains("asst-on"))
        XCTAssertFalse(assistant.contains("sec-on"))

        XCTAssertNil(SkillsCatalog.promptBlock(contextType: "onboarding", dir: dir),
                     "an unmapped surface must not inherit a persona by accident")
    }

    // MARK: - yaml.v3 equivalence

    /// The `enabled` values yaml.v3 accepts for a typed `*bool` — a closed,
    /// case-sensitive set pinned against `internal/skills.Parse`. The 1.1 words
    /// (`yes`/`no`/`on`/`off`/`y`/`n`) are accepted even quoted, because Go
    /// applies them while decoding a string into a bool; the core-schema words
    /// are not, so `enabled: "false"` is a rejected file, not a disabled skill.
    func testEnabledAcceptsExactlyWhatYamlDoes() {
        let disabling = ["false", "False", "FALSE", "no", "No", "NO", "n", "N",
                         "off", "Off", "OFF", "'no'", "\"off\"", "false # too noisy"]
        for value in disabling {
            XCTAssertEqual(parseEnabled(value)?.enabled, false,
                           "`enabled: \(value)` must disable the skill")
        }
        let enabling = ["true", "True", "TRUE", "yes", "Yes", "YES", "y", "Y",
                        "on", "On", "ON", "'yes'", "true # back on", "", "~", "null", "NULL"]
        for value in enabling {
            XCTAssertEqual(parseEnabled(value)?.enabled, true,
                           "`enabled: \(value)` must leave the skill enabled")
        }
        let rejected = ["maybe", "1", "0", "\"false\"", "'true'", "yEs", "oFF", "no#comment"]
        for value in rejected {
            XCTAssertNil(parseEnabled(value),
                         "`enabled: \(value)` is not a YAML bool — Go rejects the file, so must we")
        }
    }

    /// The parsed skill, or nil when that `enabled` value gets the whole file
    /// rejected.
    private func parseEnabled(_ value: String) -> SkillSummary? {
        SkillsCatalog.parse(name: "probe", content: """
            ---
            description: A description.
            persona: both
            enabled: \(value)
            ---
            Body.
            """)
    }

    func testRejectsShapesYamlWouldRefuse() {
        // A frontmatter line that is not a `key: value` pair.
        XCTAssertNil(SkillsCatalog.parse(name: "bare", content: """
            ---
            description: A description.
            persona: secretary
            this line has no colon
            ---
            Body.
            """))
        // An indented opening fence opens nothing (Go matches the literal
        // prefix "---\\n"), so the file has no frontmatter at all.
        XCTAssertNil(SkillsCatalog.parse(name: "indented", content: """
             ---
            description: A description.
            persona: secretary
            ---
            Body.
            """))
        // An unterminated quoted scalar breaks the whole YAML document.
        XCTAssertNil(SkillsCatalog.parse(name: "unclosed", content: """
            ---
            description: "never closed
            persona: secretary
            ---
            Body.
            """))
        // …on any key, not just the ones we read.
        XCTAssertNil(SkillsCatalog.parse(name: "unclosed-extra", content: """
            ---
            description: A description.
            persona: secretary
            author: "never closed
            ---
            Body.
            """))
        // Junk after a closing quote is a syntax error, not a longer value.
        XCTAssertNil(SkillsCatalog.parse(name: "junk", content: """
            ---
            description: 'quoted' junk
            persona: secretary
            ---
            Body.
            """))
        // A repeated key, even one neither parser reads.
        XCTAssertNil(SkillsCatalog.parse(name: "dup", content: """
            ---
            description: A description.
            persona: secretary
            author: first
            author: second
            ---
            Body.
            """))
    }

    func testDescriptionMustSurviveUnquotingAndTrimming() {
        XCTAssertNil(SkillsCatalog.parse(name: "blank", content: """
            ---
            description: "   "
            persona: secretary
            ---
            Body.
            """), "quoted whitespace is an empty description once unquoted")
        XCTAssertNil(SkillsCatalog.parse(name: "empty-quoted", content: """
            ---
            description: ''
            persona: secretary
            ---
            Body.
            """))
    }

    /// The shape `SkillFileEditor.yamlScalar` writes: single-quoted, with an
    /// embedded quote doubled. Every YAML indicator inside it is inert.
    func testReadsSingleQuotedScalarsBack() {
        let parsed = SkillsCatalog.parse(name: "quoted", content: """
            ---
            description: 'it''s a fix: x # y'
            persona: secretary
            ---
            Body.
            """)
        XCTAssertEqual(parsed?.description, "it's a fix: x # y")
    }

    /// `#` opens a comment only at the start of a value or after whitespace —
    /// `a#b` is the literal text, as it is on the Go side.
    func testHashWithoutLeadingSpaceIsNotAComment() {
        let parsed = SkillsCatalog.parse(name: "hash", content: """
            ---
            description: rollback#2 plan
            persona: secretary
            ---
            Body.
            """)
        XCTAssertEqual(parsed?.description, "rollback#2 plan")
    }

    func testShippedMarkerIsReadFromTheFile() {
        let content = """
            ---
            description: A shipped skill.
            persona: secretary
            x-watchtower-shipped: v1
            ---
            Body.
            """
        XCTAssertEqual(SkillsCatalog.parse(name: "shipped", content: content)?.shipped, true)
        XCTAssertEqual(
            SkillsCatalog.parse(name: "owned", content: content.replacingOccurrences(
                of: "x-watchtower-shipped: v1\n", with: ""))?.shipped,
            false,
            "a file without the marker is the owner's")
    }

    // MARK: - Shared Go fixtures

    /// `internal/skills/testdata` — the fixture set `internal/skills`'
    /// `TestListFixtures` pins. Both parsers read the SAME files here, so a
    /// change that makes one side stricter than the other fails on one of the
    /// two sides instead of drifting silently.
    private static func goFixturesDir() -> String {
        URL(fileURLWithPath: #filePath)          // …/WatchtowerDesktop/Tests/Core/<this file>
            .deletingLastPathComponent()          // …/Tests/Core
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/WatchtowerDesktop
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("internal/skills/testdata")
            .path
    }

    func testSharedGoFixturesGetTheSameVerdict() throws {
        let fixtures = Self.goFixturesDir()
        let stems = try FileManager.default.contentsOfDirectory(atPath: fixtures)
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            .sorted()
        XCTAssertFalse(stems.isEmpty, "shared fixtures must be reachable at \(fixtures)")

        let listed = SkillsCatalog.list(dir: fixtures)
        XCTAssertEqual(listed, [
            SkillSummary(name: "enabled-comment",
                         description: "Switched off with the reason written as an inline comment.",
                         persona: .both, enabled: false),
            SkillSummary(name: "enabled-no",
                         description: "Switched off with YAML 1.1's `no` rather than `false`.",
                         persona: .assistant, enabled: false),
            SkillSummary(name: "valid-basic",
                         description: "Use when the owner asks for the shape of a valid skill file.",
                         persona: .secretary, enabled: true),
            SkillSummary(name: "valid-disabled",
                         description: "A skill both personas could use, switched off by its own frontmatter.",
                         persona: .both, enabled: false)
        ], "must match internal/skills/skills_test.go's wantListed, in the same order")

        let skipped = stems.filter { stem in !listed.contains { $0.name == stem } }
        XCTAssertEqual(skipped, [
            "bad-enabled", "bad-persona", "bare-line", "blank-description",
            "duplicate-key", "indented-fence", "no-frontmatter", "unterminated-quote"
        ], "must match internal/skills/skills_test.go's wantSkipped")
    }
}
