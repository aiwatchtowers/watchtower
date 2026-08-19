import Foundation
import XCTest
@testable import WatchtowerCore

/// `SkillsCatalog` — the Swift half of the assistant-skills dual-path. The
/// fixtures here mirror the Go parser's cases in `internal/skills` so both
/// sides can be checked against the same file shapes: strict on what matters
/// (frontmatter fences, non-empty `description`), lenient elsewhere (unknown
/// keys ignored — the legacy `persona` key included — and `enabled` defaulting
/// to true), and one bad file never breaks the catalog.
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
    private func writeFixture(_ file: String, _ content: String) {
        try? Data(content.utf8).write(to: URL(fileURLWithPath: dir + "/" + file))
    }

    private func listedSkill(named name: String, in skills: [SkillSummary]) -> SkillSummary? {
        skills.first { $0.name == name }
    }

    // MARK: - Parser

    func testParsesFullFrontmatter() {
        let parsed = SkillsCatalog.parse(name: "thread-untangle", content: """
            ---
            description: Reconstruct who asked what in a tangled thread.
            enabled: true
            ---
            Body instructions.
            """)
        XCTAssertEqual(parsed, SkillSummary(
            name: "thread-untangle",
            description: "Reconstruct who asked what in a tangled thread.",
            enabled: true))
    }

    func testEnabledDefaultsToTrueWhenAbsent() {
        let parsed = SkillsCatalog.parse(name: "status-update", content: """
            ---
            description: Draft a status update.
            ---
            Body.
            """)
        XCTAssertEqual(parsed?.enabled, true, "an absent `enabled` key means enabled")
    }

    func testExplicitDisabledIsHonoured() {
        let parsed = SkillsCatalog.parse(name: "target-breakdown", content: """
            ---
            description: Decompose a target into sub-targets.
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
            author: someone
            version: 3
            ---
            Body.
            """)
        XCTAssertEqual(parsed?.description, "Still valid.", "an extra key must not knock a skill out")
    }

    /// The two-persona era stamped a `persona` key into every skill file. It
    /// is an ordinary unknown key today — whatever its value, even one that
    /// was never valid back then.
    func testLegacyPersonaKeyIsIgnored() {
        let parsed = SkillsCatalog.parse(name: "legacy", content: """
            ---
            description: Carries a legacy persona key.
            persona: butler
            ---
            Body.
            """)
        XCTAssertEqual(parsed?.description, "Carries a legacy persona key.")
        XCTAssertEqual(parsed?.enabled, true)
    }

    func testInlineCommentAndQuotesAreStripped() {
        let parsed = SkillsCatalog.parse(name: "quoted", content: """
            ---
            description: "Use when the owner asks for a recap."
            enabled: true   # switched on
            ---
            Body.
            """)
        XCTAssertEqual(parsed?.description, "Use when the owner asks for a recap.")
        XCTAssertEqual(parsed?.enabled, true)
    }

    func testRejectsMissingOpeningFence() {
        XCTAssertNil(SkillsCatalog.parse(name: "no-fence", content: """
            description: No frontmatter block at all.
            """))
    }

    func testRejectsUnterminatedFrontmatter() {
        XCTAssertNil(SkillsCatalog.parse(name: "unterminated", content: """
            ---
            description: Never closed.
            """))
    }

    func testRejectsEmptyDescription() {
        XCTAssertNil(SkillsCatalog.parse(name: "empty-desc", content: """
            ---
            description:
            ---
            Body.
            """))
    }

    func testRejectsMissingDescription() {
        XCTAssertNil(SkillsCatalog.parse(name: "no-desc", content: """
            ---
            enabled: true
            ---
            Body.
            """))
    }

    func testRejectsInvalidName() {
        let content = """
            ---
            description: Valid description.
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
        writeFixture("zeta.md", """
            ---
            description: Zeta skill.
            ---
            """)
        writeFixture("alpha.md", """
            ---
            description: Alpha skill.
            ---
            """)
        // Skipped: malformed frontmatter, invalid stem, non-md.
        writeFixture("broken.md", "no frontmatter here")
        writeFixture("Upper.md", """
            ---
            description: Invalid stem.
            ---
            """)
        writeFixture("notes.txt", """
            ---
            description: Not markdown.
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
        writeFixture("off.md", """
            ---
            description: Disabled skill.
            enabled: false
            ---
            """)
        let skills = SkillsCatalog.list(dir: dir)
        XCTAssertEqual(listedSkill(named: "off", in: skills)?.enabled, false,
                       "list reports the flag; filtering is promptBlock's job")
    }

    // MARK: - promptBlock

    /// Seeds the enabled/disabled combination used below.
    private func seedMixedCatalog() {
        writeFixture("alpha-on.md", """
            ---
            description: Alpha skill.
            ---
            """)
        writeFixture("beta-on.md", """
            ---
            description: Beta skill.
            ---
            """)
        writeFixture("gamma-off.md", """
            ---
            description: Disabled skill.
            enabled: false
            ---
            """)
    }

    func testPromptBlockListsEveryEnabledSkill() throws {
        seedMixedCatalog()
        let block = try XCTUnwrap(SkillsCatalog.promptBlock(dir: dir))

        XCTAssertTrue(block.contains("AVAILABLE SKILLS"))
        XCTAssertTrue(block.contains("alpha-on — Alpha skill."))
        XCTAssertTrue(block.contains("beta-on — Beta skill."))
        XCTAssertFalse(block.contains("gamma-off"), "a disabled skill is never listed")
        XCTAssertTrue(block.contains("load_skill"), "the block must point at the load tool")
    }

    func testPromptBlockNilOnEmptyOrMissingDir() {
        XCTAssertNil(SkillsCatalog.promptBlock(dir: dir))
        XCTAssertNil(SkillsCatalog.promptBlock(dir: dir + "/nope"))
        XCTAssertNil(SkillsCatalog.promptBlock(dir: nil))
    }

    func testPromptBlockNilWhenEverySkillIsDisabled() {
        writeFixture("gamma-off.md", """
            ---
            description: Disabled skill.
            enabled: false
            ---
            """)
        XCTAssertNil(SkillsCatalog.promptBlock(dir: dir),
                     "no enabled skill must leave the prompt byte-identical")
    }

    // MARK: - Chat surface gate

    func testChatContextTypesMatchesTheContract() {
        XCTAssertEqual(SkillsCatalog.chatContextTypes,
                       ["situation", "meeting", "target", "track", "idea"])
    }

    /// The overload every chat VM goes through: the context type it stores on
    /// its conversation decides whether skills are listed at all, and a
    /// context type nobody added gets no block rather than the full catalog.
    func testPromptBlockByContextTypeResolvesThroughTheSet() throws {
        seedMixedCatalog()

        for contextType in SkillsCatalog.chatContextTypes {
            let block = try XCTUnwrap(SkillsCatalog.promptBlock(contextType: contextType, dir: dir))
            XCTAssertTrue(block.contains("alpha-on"), "\(contextType) must list skills")
        }

        XCTAssertNil(SkillsCatalog.promptBlock(contextType: "onboarding", dir: dir),
                     "an unlisted surface must not inherit skills by accident")
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
            this line has no colon
            ---
            Body.
            """))
        // An indented opening fence opens nothing (Go matches the literal
        // prefix "---\\n"), so the file has no frontmatter at all.
        XCTAssertNil(SkillsCatalog.parse(name: "indented", content: """
             ---
            description: A description.
            ---
            Body.
            """))
        // An unterminated quoted scalar breaks the whole YAML document.
        XCTAssertNil(SkillsCatalog.parse(name: "unclosed", content: """
            ---
            description: "never closed
            ---
            Body.
            """))
        // …on any key, not just the ones we read.
        XCTAssertNil(SkillsCatalog.parse(name: "unclosed-extra", content: """
            ---
            description: A description.
            author: "never closed
            ---
            Body.
            """))
        // Junk after a closing quote is a syntax error, not a longer value.
        XCTAssertNil(SkillsCatalog.parse(name: "junk", content: """
            ---
            description: 'quoted' junk
            ---
            Body.
            """))
        // A repeated key, even one neither parser reads.
        XCTAssertNil(SkillsCatalog.parse(name: "dup", content: """
            ---
            description: A description.
            author: first
            author: second
            ---
            Body.
            """))
    }

    /// A colon only separates key from value when a space, a tab or the line
    /// end follows it — the rule yaml.v3 applies, and the reason
    /// `description:foo` is a broken file rather than a description of "foo".
    func testKeySeparatorNeedsWhitespaceAfterTheColon() {
        XCTAssertNil(parseFrontmatter("description:foo"))
        XCTAssertNil(parseFrontmatter("description:"),
                     "a bare key with no value leaves the description empty")
        // A colon inside the key name is fine as long as a real separator
        // follows later — yaml.v3 reads the key as `a:b` and so do we.
        XCTAssertEqual(
            parseFrontmatter("a:b: c\ndescription: A description.")?.description,
            "A description.")
        // …and a tab after the colon separates just as well as a space.
        XCTAssertEqual(
            parseFrontmatter("description:\tA description.")?.description,
            "A description.")
    }

    func testRejectsIndentedLinesAndTabs() {
        XCTAssertNil(parseFrontmatter("description: A description.\n  author: someone"))
        XCTAssertNil(parseFrontmatter("\tdescription: A description."))
        XCTAssertNil(parseFrontmatter("  description: A description.\n  author: someone"),
                     "uniformly indented frontmatter is legal YAML this parser does not take")
        XCTAssertNil(parseFrontmatter("description: A description.\nlist:\n  - a"))
        // An indented COMMENT is still fine — it carries no structure.
        XCTAssertEqual(
            parseFrontmatter("description: A description.\n   # a note")?.description,
            "A description.")
    }

    func testRejectsAPlainScalarCarryingAMappingSeparator() {
        XCTAssertNil(parseFrontmatter("description: Use when: the owner asks"))
        XCTAssertNil(parseFrontmatter("description: Use when:"))
        XCTAssertNil(parseFrontmatter("description: Use when:\tx"))
        // A colon with no space after it is ordinary text on both sides.
        XCTAssertEqual(
            parseFrontmatter("description: ratio 3:1 rule")?.description,
            "ratio 3:1 rule")
        // …and a separator inside a comment is not a separator at all.
        XCTAssertEqual(
            parseFrontmatter("description: fine # note: here")?.description,
            "fine")
    }

    /// A plain scalar opening with an indicator is structure, not text: yaml.v3
    /// either refuses the document or hands Go a different string (`&a hey` and
    /// `!!str hey` both arrive as `hey`), so the file is refused here.
    func testRejectsPlainScalarsOpeningWithAnIndicator() {
        for indicator in ["[", "]", "{", "}", ",", "*", "!", "&", "|", ">", "%", "@", "`"] {
            XCTAssertNil(
                parseFrontmatter("description: \(indicator)foo bar"),
                "a description opening with \(indicator) must be refused")
        }
        XCTAssertNil(parseFrontmatter("description: &a hey"),
                     "an anchor reaches Go as `hey`, not as the text on the line")
        // `-` and `?` only open a block entry when the value is the bare
        // indicator or the indicator plus whitespace.
        for indicator in ["-", "?"] {
            XCTAssertNil(parseFrontmatter("description: \(indicator) foo"))
            XCTAssertNil(parseFrontmatter("description: \(indicator)"))
            XCTAssertEqual(
                parseFrontmatter("description: \(indicator)foo")?.description,
                "\(indicator)foo",
                "tight `\(indicator)foo` is ordinary text to yaml.v3")
        }
    }

    /// Keys are scalars too, and yaml.v3 refuses a structural one outright —
    /// so a line whose key is a sequence entry, a flow collection or an alias
    /// is a rejected file here as well, not an "unknown key" to skip past.
    func testRejectsStructuralKeys() {
        for key in ["- foo", "[a]", "*a", "{a}", "}a", "]a", ",a", "%a", "@a", "`a", "|a", ">a"] {
            XCTAssertNil(
                parseFrontmatter("\(key): x\ndescription: A description."),
                "a `\(key):` key must be refused")
        }
        // An anchor or a tag on a key: yaml.v3 accepts these but reads a key
        // other than the bytes on the line, so this parser refuses them —
        // the same call it makes for an anchored value.
        XCTAssertNil(parseFrontmatter("&a k: x\ndescription: A description."))
        XCTAssertNil(parseFrontmatter("!t k: x\ndescription: A description."))
        // An empty key, a plain key carrying a comment, and junk after a
        // quoted key are all yaml.v3 errors.
        XCTAssertNil(parseFrontmatter(": x\ndescription: A description."))
        XCTAssertNil(parseFrontmatter("a #c: x\ndescription: A description."))
        XCTAssertNil(parseFrontmatter("\"a\" junk: x\ndescription: A description."))
        // …while an ordinary key with a space, a tight `-`/`?`, or a colon
        // inside it is text to yaml.v3, and stays listable here.
        for key in ["a b", "a:b", "-ak", "?ak", "\"a b\"", "'k'"] {
            XCTAssertEqual(
                parseFrontmatter("\(key): x\ndescription: A description.")?
                    .description,
                "A description.",
                "`\(key):` is an ordinary unknown key")
        }
    }

    /// yaml.v3 unquotes a key before matching it to a field, so a quoted key
    /// fills the same slot as its plain spelling — and collides with it as a
    /// duplicate rather than reading as a second, different key.
    func testQuotedKeysAreUnquotedForMatchingAndForDuplicates() {
        let quoted = parseFrontmatter("""
            "description": A quoted description key.
            "enabled": false
            """)
        XCTAssertEqual(quoted?.description, "A quoted description key.")
        XCTAssertEqual(quoted?.enabled, false)

        XCTAssertNil(parseFrontmatter("""
            description: First.
            "description": Second.
            """), "a quoted duplicate is still a duplicate")
        XCTAssertNil(parseFrontmatter("""
            description: First.
            'description': Second.
            """))
    }

    func testDoubleQuotedEscapesMatchYamlsSet() {
        XCTAssertEqual(parseFrontmatter(#"description: "a\nb""# + "")?.description,
                       "a\nb")
        XCTAssertEqual(parseFrontmatter(#"description: "a\"b""# + "")?.description,
                       "a\"b")
        XCTAssertEqual(parseFrontmatter(#"description: "a\\b""# + "")?.description,
                       #"a\b"#)
        XCTAssertEqual(parseFrontmatter(#"description: "a\_b""# + "")?.description,
                       "a\u{A0}b")
        // `\'` needs no escaping inside double quotes but is legal there, and
        // a backslash before a literal tab is an escape of the tab itself.
        XCTAssertEqual(parseFrontmatter(#"description: "it\'s fine""# + "")?
            .description, "it's fine")
        XCTAssertEqual(parseFrontmatter("description: \"a\\\tb\"")?.description,
                       "a\tb")
        // Unknown escapes are refused, not passed through — `\/` is legal JSON
        // and NOT legal YAML, which is exactly the trap.
        XCTAssertNil(parseFrontmatter(#"description: "a\qb""# + ""))
        XCTAssertNil(parseFrontmatter(#"description: "a\/b""# + ""))
        // The numeric forms are legal YAML this parser does not decode, so it
        // refuses them rather than inventing text (documented divergence).
        XCTAssertNil(parseFrontmatter(#"description: "a\x41b""# + ""))
        // A backslash is ordinary inside a single-quoted scalar.
        XCTAssertEqual(parseFrontmatter(#"description: 'a\qb'"# + "")?.description,
                       #"a\qb"#)
    }

    /// Parses a frontmatter body (without the fences) under a valid name.
    private func parseFrontmatter(_ frontmatter: String) -> SkillSummary? {
        SkillsCatalog.parse(name: "probe", content: "---\n\(frontmatter)\n---\nBody.\n")
    }

    func testDescriptionMustSurviveUnquotingAndTrimming() {
        XCTAssertNil(SkillsCatalog.parse(name: "blank", content: """
            ---
            description: "   "
            ---
            Body.
            """), "quoted whitespace is an empty description once unquoted")
        XCTAssertNil(SkillsCatalog.parse(name: "empty-quoted", content: """
            ---
            description: ''
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
            ---
            Body.
            """)
        XCTAssertEqual(parsed?.description, "rollback#2 plan")
    }

    func testShippedMarkerIsReadFromTheFile() {
        let content = """
            ---
            description: A shipped skill.
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
            // NOTE: `anchor-description`, `anchor-key` and `tagged-key` are in
            // Go's wantListed and NOT here — the deliberate asymmetries, see
            // goListsThemSwiftRefuses below.
            SkillSummary(name: "enabled-comment",
                         description: "Switched off with the reason written as an inline comment.",
                         enabled: false),
            SkillSummary(name: "enabled-no",
                         description: "Switched off with YAML 1.1's `no` rather than `false`.",
                         enabled: false),
            SkillSummary(name: "escaped-apostrophe",
                         description: "Use when it's the owner's own wording that matters.",
                         enabled: true),
            SkillSummary(name: "legacy-persona",
                         description: "Carries a legacy persona key from the two-persona era, "
                             + "ignored like any unknown key.",
                         enabled: true),
            SkillSummary(name: "quoted-key",
                         description: "Written with a quoted key, which yaml.v3 unquotes.",
                         enabled: true, shipped: true),
            SkillSummary(name: "valid-basic",
                         description: "Use when the owner asks for the shape of a valid skill file.",
                         enabled: true),
            SkillSummary(name: "valid-disabled",
                         description: "A skill any chat could use, switched off by its own frontmatter.",
                         enabled: false)
        ], "must match internal/skills/skills_test.go's wantListed, in the same order")

        let skipped = stems.filter { stem in !listed.contains { $0.name == stem } }
        XCTAssertEqual(skipped, [
            "anchor-description", "anchor-key", "bad-enabled", "bare-line",
            "blank-description", "colon-in-description", "duplicate-key",
            "indented-fence", "indented-key", "leading-indicator", "no-frontmatter",
            "no-space-after-colon", "quoted-duplicate-key", "structural-key",
            "tab-indent", "tagged-key", "unknown-escape", "unterminated-quote"
        ], "must match internal/skills/skills_test.go's wantSkipped, plus goListsThemSwiftRefuses")
    }

    /// The shipped pack is the one set of skill files that MUST parse on both
    /// sides: Go's `TestShippedPack` pins them for the daemon that deploys
    /// them, and this pins them for the chats that have to see them listed.
    /// A tightening of this parser that refuses a shipped file would otherwise
    /// show up only as three skills quietly missing from every chat.
    func testShippedPackParsesHere() throws {
        let shipped = URL(fileURLWithPath: Self.goFixturesDir())
            .deletingLastPathComponent()
            .appendingPathComponent("shipped")
            .path
        let files = try FileManager.default.contentsOfDirectory(atPath: shipped)
            .filter { $0.hasSuffix(".md") }
        XCTAssertEqual(files.count, 3, "the shipped pack must be reachable at \(shipped)")

        for file in files {
            let name = String(file.dropLast(3))
            let content = try String(contentsOfFile: "\(shipped)/\(file)", encoding: .utf8)
            let parsed = try XCTUnwrap(SkillsCatalog.parse(name: name, content: content),
                                       "shipped skill \(name) must parse")
            XCTAssertTrue(parsed.enabled, "\(name) must ship enabled")
            XCTAssertTrue(parsed.shipped, "\(name) must carry the shipped marker")
            XCTAssertFalse(parsed.description.isEmpty)
        }
    }

    /// The fixtures Go lists and this parser deliberately refuses — the whole
    /// permitted asymmetry between the two sides, written down so it stays one
    /// short, reviewed list instead of drift. Every entry is a node property
    /// (an anchor or a tag): yaml.v3 would hand Go a description, or a key, the
    /// file does not literally contain, so refusing to advertise the skill
    /// beats advertising it under invented text. The reverse direction (Swift
    /// lists, Go cannot read) has no entries and must never gain one.
    private static let goListsThemSwiftRefuses = [
        "anchor-description", "anchor-key", "tagged-key"
    ]

    func testTheOnlyGoListedFixturesWeRefuseAreTheDocumentedOnes() throws {
        let fixtures = Self.goFixturesDir()
        for stem in Self.goListsThemSwiftRefuses {
            let content = try String(
                contentsOfFile: "\(fixtures)/\(stem).md", encoding: .utf8)
            XCTAssertNil(SkillsCatalog.parse(name: stem, content: content),
                         "\(stem) is documented as refused here even though Go lists it")
        }
    }
}
