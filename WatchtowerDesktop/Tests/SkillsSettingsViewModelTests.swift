import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Settings → Skills card backing store. Everything here runs against a real
/// temp directory: the skill files ARE the state, so a mock filesystem would
/// test nothing that matters.
@MainActor
final class SkillsSettingsViewModelTests: XCTestCase {
    private var dir = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-vm-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !dir.isEmpty { try? FileManager.default.removeItem(atPath: dir) }
        dir = ""
        try super.tearDownWithError()
    }

    private func writeSkillFile(_ name: String, _ content: String) throws {
        try content.write(toFile: "\(dir)/\(name)", atomically: true, encoding: .utf8)
    }

    private func readSkillFile(_ name: String) throws -> String {
        try String(contentsOfFile: "\(dir)/\(name)", encoding: .utf8)
    }

    private let shippedFile = """
        ---
        description: Untangle a thread.
        enabled: true
        x-watchtower-shipped: v1
        ---

        Body of the shipped skill.
        """

    private let customFile = """
        ---
        description: Break a target down.
        ---

        Body of the custom skill.
        """

    // MARK: - load

    func testLoadListsSortedRowsWithOrigin() throws {
        try writeSkillFile("thread-untangle.md", shippedFile)
        try writeSkillFile("break-down.md", customFile)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        viewModel.loadSkills()

        XCTAssertEqual(viewModel.rows.map(\.name), ["break-down", "thread-untangle"])
        XCTAssertFalse(viewModel.rows[0].shipped)
        // `enabled` is absent from the custom file — the format's default is on.
        XCTAssertTrue(viewModel.rows[0].enabled)
        XCTAssertTrue(viewModel.rows[1].shipped)
        XCTAssertEqual(viewModel.rows[1].description, "Untangle a thread.")
    }

    func testLoadSkipsUnparsableFilesAndNonMarkdown() throws {
        try writeSkillFile("good.md", customFile)
        try writeSkillFile("bad-yaml.md", "---\ndescription: \"unclosed\n---\nbody\n")
        try writeSkillFile("no-frontmatter.md", "just prose\n")
        try writeSkillFile("notes.txt", customFile)
        try writeSkillFile(".watchtower-shipped.json", "{}")

        let viewModel = SkillsSettingsViewModel(dir: dir)
        viewModel.loadSkills()

        XCTAssertEqual(viewModel.rows.map(\.name), ["good"])
    }

    func testLoadWithNilDirectoryIsEmptyAndNotAnError() {
        let viewModel = SkillsSettingsViewModel(dir: nil)
        viewModel.loadSkills()

        XCTAssertTrue(viewModel.rows.isEmpty)
        XCTAssertNil(viewModel.error)
    }

    func testLoadWithMissingDirectoryIsEmpty() {
        let viewModel = SkillsSettingsViewModel(dir: "\(dir)/does-not-exist")
        viewModel.loadSkills()

        XCTAssertTrue(viewModel.rows.isEmpty)
    }

    // MARK: - setEnabled

    /// The load-bearing one: a toggle may touch the `enabled` value and
    /// nothing else — not the body the owner rewrote, not the unknown keys,
    /// not the key order, not the indentation.
    func testSetEnabledRewritesOnlyThatKey() throws {
        let original = """
            ---
            description: Untangle a thread.
            enabled: true    # owner's note
            x-watchtower-shipped: v1
            custom-key: kept
            ---

            # Body

            Owner prose with a --- rule inside it.
            """
        try writeSkillFile("thread-untangle.md", original)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        viewModel.loadSkills()
        XCTAssertTrue(viewModel.setSkillEnabled(name: "thread-untangle", enabled: false))

        let updated = try readSkillFile("thread-untangle.md")
        XCTAssertEqual(
            updated,
            original.replacingOccurrences(
                of: "enabled: true    # owner's note", with: "enabled: false"
            )
        )
        viewModel.loadSkills()
        XCTAssertFalse(try XCTUnwrap(viewModel.rows.first).enabled)
        XCTAssertTrue(try XCTUnwrap(viewModel.rows.first).shipped)
    }

    func testSetEnabledInsertsTheKeyWhenAbsent() throws {
        try writeSkillFile("break-down.md", customFile)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertTrue(viewModel.setSkillEnabled(name: "break-down", enabled: false))

        let updated = try readSkillFile("break-down.md")
        XCTAssertEqual(
            updated,
            """
            ---
            description: Break a target down.
            enabled: false
            ---

            Body of the custom skill.
            """
        )
        XCTAssertEqual(SkillsCatalog.parse(name: "break-down", content: updated)?.enabled, false)
    }

    func testSetEnabledPreservesCRLFLineEndings() throws {
        let original = "---\r\ndescription: X.\r\nenabled: true\r\n---\r\n\r\nBody\r\n"
        try writeSkillFile("crlf.md", original)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertTrue(viewModel.setSkillEnabled(name: "crlf", enabled: false))

        XCTAssertEqual(
            try readSkillFile("crlf.md"),
            original.replacingOccurrences(of: "enabled: true", with: "enabled: false")
        )
    }

    func testSetEnabledOnAFileWithoutFrontmatterFails() throws {
        try writeSkillFile("broken.md", "no frontmatter here\n")

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertFalse(viewModel.setSkillEnabled(name: "broken", enabled: false))
        XCTAssertNotNil(viewModel.error)
        XCTAssertEqual(try readSkillFile("broken.md"), "no frontmatter here\n")
    }

    func testSetEnabledRefusesAnIllegalName() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).md").path
        try "---\ndescription: X\n---\nsecret\n".write(
            toFile: outside, atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(atPath: outside) }

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertFalse(viewModel.setSkillEnabled(name: "../escape", enabled: false))
        XCTAssertNotNil(viewModel.error)
    }

    // MARK: - draft

    func testDraftReturnsBodyWithoutFrontmatter() throws {
        try writeSkillFile("thread-untangle.md", shippedFile)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        let draft = try XCTUnwrap(viewModel.skillDraft(for: "thread-untangle"))

        XCTAssertEqual(draft.name, "thread-untangle")
        XCTAssertEqual(draft.description, "Untangle a thread.")
        XCTAssertEqual(draft.body, "Body of the shipped skill.")
    }

    func testDraftForAnUnparsableFileIsNil() throws {
        try writeSkillFile("broken.md", "no frontmatter\n")

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertNil(viewModel.skillDraft(for: "broken"))
    }

    // MARK: - save (create)

    func testSaveCreatesAFileTheCatalogParses() throws {
        let viewModel = SkillsSettingsViewModel(dir: dir)
        let draft = SkillDraft(
            name: "status-update",
            description: "Use when the owner asks for a status update.",
            body: "Ask what to say, then render it."
        )

        XCTAssertTrue(viewModel.saveSkill(draft, isNew: true))

        let parsed = try XCTUnwrap(
            SkillsCatalog.parse(name: "status-update", content: try readSkillFile("status-update.md"))
        )
        XCTAssertEqual(parsed.description, "Use when the owner asks for a status update.")
        XCTAssertTrue(parsed.enabled)
        XCTAssertEqual(viewModel.rows.map(\.name), ["status-update"])
        XCTAssertFalse(try XCTUnwrap(viewModel.rows.first).shipped)
    }

    func testSaveCreatesTheSkillsDirectoryWhenMissing() throws {
        let nested = "\(dir)/nested/skills"
        let viewModel = SkillsSettingsViewModel(dir: nested)

        XCTAssertTrue(viewModel.saveSkill(
            SkillDraft(name: "x-ray", description: "Look inside.", body: "Do it."),
            isNew: true
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(nested)/x-ray.md"))
    }

    func testSaveQuotesADescriptionThatWouldBreakYAML() throws {
        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertTrue(viewModel.saveSkill(
            SkillDraft(
                name: "tricky",
                description: "Use when: the owner says #status",
                body: "Body."
            ),
            isNew: true
        ))

        let parsed = try XCTUnwrap(
            SkillsCatalog.parse(name: "tricky", content: try readSkillFile("tricky.md"))
        )
        XCTAssertEqual(parsed.description, "Use when: the owner says #status")
    }

    func testSaveRejectsAnInvalidName() {
        let viewModel = SkillsSettingsViewModel(dir: dir)
        for bad in ["Status Update", "../escape", "-leading", "under_score", ""] {
            XCTAssertFalse(
                viewModel.saveSkill(
                    SkillDraft(name: bad, description: "D.", body: "B."),
                    isNew: true
                ),
                "expected \(bad) to be rejected"
            )
            XCTAssertNotNil(viewModel.error)
        }
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: dir), [])
    }

    func testSaveRejectsAnEmptyDescription() {
        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertFalse(viewModel.saveSkill(
            SkillDraft(name: "empty", description: "   ", body: "B."),
            isNew: true
        ))
        XCTAssertNotNil(viewModel.error)
    }

    func testSaveRefusesToOverwriteWithIsNew() throws {
        try writeSkillFile("break-down.md", customFile)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertFalse(viewModel.saveSkill(
            SkillDraft(name: "break-down", description: "Other.", body: "B."),
            isNew: true
        ))
        XCTAssertEqual(try readSkillFile("break-down.md"), customFile)
    }

    func testSaveWithNilDirectoryFails() {
        let viewModel = SkillsSettingsViewModel(dir: nil)
        XCTAssertFalse(viewModel.saveSkill(
            SkillDraft(name: "nope", description: "D.", body: "B."),
            isNew: true
        ))
        XCTAssertNotNil(viewModel.error)
    }

    // MARK: - save (edit)

    /// Editing a disabled shipped skill must not silently re-enable it, and
    /// must not drop the `x-watchtower-shipped` marker — losing the marker
    /// would reclassify it as owner-created and offer a Delete the daemon's
    /// re-deploy would immediately undo.
    func testSaveOnAnExistingFileKeepsEnabledStateAndShippedMarker() throws {
        try writeSkillFile("thread-untangle.md", shippedFile)
        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertTrue(viewModel.setSkillEnabled(name: "thread-untangle", enabled: false))

        var draft = try XCTUnwrap(viewModel.skillDraft(for: "thread-untangle"))
        draft.body = "Rewritten instructions."
        draft.description = "Untangle a thread, carefully."
        XCTAssertTrue(viewModel.saveSkill(draft, isNew: false))

        let updated = try readSkillFile("thread-untangle.md")
        XCTAssertTrue(updated.contains("x-watchtower-shipped: v1"))
        XCTAssertTrue(updated.contains("Rewritten instructions."))
        let row = try XCTUnwrap(viewModel.rows.first)
        XCTAssertFalse(row.enabled)
        XCTAssertTrue(row.shipped)
        XCTAssertEqual(row.description, "Untangle a thread, carefully.")
    }

    /// The editor and the catalog must read `enabled` through the same
    /// interpreter. Before they did, both catalogs saw these files as disabled
    /// while the editor saw them as enabled, so any Save silently switched the
    /// skill back on — the owner's off switch undone by an unrelated edit.
    func testSaveKeepsEveryDisabledSpellingOff() throws {
        let spellings = [
            "commented": "enabled: false # too noisy in review threads",
            "yaml11": "enabled: no",
            "uppercase": "enabled: FALSE"
        ]
        for (name, line) in spellings {
            try writeSkillFile("\(name).md", """
                ---
                description: A disabled skill.
                \(line)
                ---

                Body.
                """)

            let viewModel = SkillsSettingsViewModel(dir: dir)
            var draft = try XCTUnwrap(viewModel.skillDraft(for: name), "\(name) must be parsable")
            draft.body = "New body."
            XCTAssertTrue(viewModel.saveSkill(draft, isNew: false))

            let row = try XCTUnwrap(viewModel.rows.first { $0.name == name })
            XCTAssertFalse(row.enabled, "`\(line)` must survive a Save as disabled")
        }
    }

    /// Round-trip guard: a composed file the catalog cannot read is never
    /// written, because a skill the parsers skip is a skill that silently
    /// vanishes from every chat's prompt.
    func testSaveRefusesToWriteAFileTheCatalogCannotRead() throws {
        // An unterminated quote on an unknown key — carried through verbatim by
        // compose, and fatal to yaml.v3 on the Go side.
        let broken = """
            ---
            description: Break a target down.
            author: "unclosed
            ---

            Body.
            """
        try writeSkillFile("break-down.md", broken)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertFalse(viewModel.saveSkill(
            SkillDraft(name: "break-down", description: "New.", body: "B."),
            isNew: false
        ))
        XCTAssertNotNil(viewModel.error)
        XCTAssertEqual(try readSkillFile("break-down.md"), broken, "the file on disk must be untouched")
    }

    /// Descriptions are written as single-quoted scalars, so a quote inside one
    /// is doubled rather than dropped — and comes back intact.
    func testSaveRoundTripsAQuoteInsideTheDescription() throws {
        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertTrue(viewModel.saveSkill(
            SkillDraft(
                name: "quoted",
                description: "Use when it's a fix: x # y",
                body: "Body."
            ),
            isNew: true
        ))

        XCTAssertTrue(try readSkillFile("quoted.md").contains("description: 'Use when it''s a fix: x # y'"))
        let parsed = try XCTUnwrap(SkillsCatalog.parse(name: "quoted", content: try readSkillFile("quoted.md")))
        XCTAssertEqual(parsed.description, "Use when it's a fix: x # y")
    }

    func testSaveOnAnExistingFileKeepsUnknownFrontmatterKeys() throws {
        try writeSkillFile("break-down.md", """
            ---
            description: Break a target down.
            persona: assistant
            author: owner
            ---

            Body.
            """)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        var draft = try XCTUnwrap(viewModel.skillDraft(for: "break-down"))
        draft.body = "New body."
        XCTAssertTrue(viewModel.saveSkill(draft, isNew: false))

        let updated = try readSkillFile("break-down.md")
        XCTAssertTrue(updated.contains("author: owner"))
        XCTAssertFalse(updated.contains("persona:"),
                       "a save is where the legacy two-persona key gets shed")
    }

    // MARK: - delete

    func testDeleteRemovesACustomSkill() throws {
        try writeSkillFile("break-down.md", customFile)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        viewModel.loadSkills()
        XCTAssertTrue(viewModel.deleteSkill(name: "break-down"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dir)/break-down.md"))
        XCTAssertTrue(viewModel.rows.isEmpty)
        XCTAssertNil(viewModel.error)
    }

    func testDeleteRefusesAShippedSkill() throws {
        try writeSkillFile("thread-untangle.md", shippedFile)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        viewModel.loadSkills()
        XCTAssertFalse(viewModel.deleteSkill(name: "thread-untangle"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/thread-untangle.md"))
        XCTAssertNotNil(viewModel.error)
    }

    func testDeleteRefusesAnIllegalName() throws {
        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertFalse(viewModel.deleteSkill(name: "../escape"))
        XCTAssertNotNil(viewModel.error)
    }

    // MARK: - round trip with the chat prompt block

    /// The card and the chat prompt read the same files through the same
    /// parser, so a skill disabled in Settings must vanish from the chat
    /// prompt block on the next build.
    func testDisablingRemovesTheSkillFromThePromptBlock() throws {
        try writeSkillFile("thread-untangle.md", shippedFile)

        XCTAssertTrue(
            try XCTUnwrap(SkillsCatalog.promptBlock(dir: dir))
                .contains("thread-untangle")
        )

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertTrue(viewModel.setSkillEnabled(name: "thread-untangle", enabled: false))

        XCTAssertNil(SkillsCatalog.promptBlock(dir: dir))
    }
}
