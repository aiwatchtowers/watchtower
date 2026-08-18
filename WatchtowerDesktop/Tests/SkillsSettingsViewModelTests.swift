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

    private func write(_ name: String, _ content: String) throws {
        try content.write(toFile: "\(dir)/\(name)", atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOfFile: "\(dir)/\(name)", encoding: .utf8)
    }

    private let shippedFile = """
        ---
        description: Untangle a thread.
        persona: secretary
        enabled: true
        x-watchtower-shipped: v1
        ---

        Body of the shipped skill.
        """

    private let customFile = """
        ---
        description: Break a target down.
        persona: assistant
        ---

        Body of the custom skill.
        """

    // MARK: - load

    func testLoadListsSortedRowsWithOriginAndPersona() throws {
        try write("thread-untangle.md", shippedFile)
        try write("break-down.md", customFile)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        viewModel.load()

        XCTAssertEqual(viewModel.rows.map(\.name), ["break-down", "thread-untangle"])
        XCTAssertEqual(viewModel.rows[0].persona, .assistant)
        XCTAssertFalse(viewModel.rows[0].shipped)
        // `enabled` is absent from the custom file — the format's default is on.
        XCTAssertTrue(viewModel.rows[0].enabled)
        XCTAssertEqual(viewModel.rows[1].persona, .secretary)
        XCTAssertTrue(viewModel.rows[1].shipped)
        XCTAssertEqual(viewModel.rows[1].description, "Untangle a thread.")
    }

    func testLoadSkipsUnparsableFilesAndNonMarkdown() throws {
        try write("good.md", customFile)
        try write("bad-persona.md", "---\ndescription: x\npersona: butler\n---\nbody\n")
        try write("no-frontmatter.md", "just prose\n")
        try write("notes.txt", customFile)
        try write(".watchtower-shipped.json", "{}")

        let viewModel = SkillsSettingsViewModel(dir: dir)
        viewModel.load()

        XCTAssertEqual(viewModel.rows.map(\.name), ["good"])
    }

    func testLoadWithNilDirectoryIsEmptyAndNotAnError() {
        let viewModel = SkillsSettingsViewModel(dir: nil)
        viewModel.load()

        XCTAssertTrue(viewModel.rows.isEmpty)
        XCTAssertNil(viewModel.error)
    }

    func testLoadWithMissingDirectoryIsEmpty() {
        let viewModel = SkillsSettingsViewModel(dir: "\(dir)/does-not-exist")
        viewModel.load()

        XCTAssertTrue(viewModel.rows.isEmpty)
    }

    // MARK: - setEnabled

    /// The load-bearing one: a toggle may touch the `enabled` value and
    /// nothing else — not the body the owner rewrote, not the unknown keys,
    /// not the key order, not the indentation.
    func testSetEnabledRewritesOnlyThatKey() throws {
        let original = """
            ---
            persona: secretary
            description: Untangle a thread.
            enabled: true    # owner's note
            x-watchtower-shipped: v1
            custom-key: kept
            ---

            # Body

            Owner prose with a --- rule inside it.
            """
        try write("thread-untangle.md", original)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        viewModel.load()
        XCTAssertTrue(viewModel.setEnabled(name: "thread-untangle", enabled: false))

        let updated = try read("thread-untangle.md")
        XCTAssertEqual(
            updated,
            original.replacingOccurrences(
                of: "enabled: true    # owner's note", with: "enabled: false"
            )
        )
        viewModel.load()
        XCTAssertFalse(try XCTUnwrap(viewModel.rows.first).enabled)
        XCTAssertTrue(try XCTUnwrap(viewModel.rows.first).shipped)
    }

    func testSetEnabledInsertsTheKeyWhenAbsent() throws {
        try write("break-down.md", customFile)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertTrue(viewModel.setEnabled(name: "break-down", enabled: false))

        let updated = try read("break-down.md")
        XCTAssertEqual(
            updated,
            """
            ---
            description: Break a target down.
            persona: assistant
            enabled: false
            ---

            Body of the custom skill.
            """
        )
        XCTAssertEqual(SkillsCatalog.parse(name: "break-down", content: updated)?.enabled, false)
    }

    func testSetEnabledPreservesCRLFLineEndings() throws {
        let original = "---\r\ndescription: X.\r\npersona: both\r\nenabled: true\r\n---\r\n\r\nBody\r\n"
        try write("crlf.md", original)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertTrue(viewModel.setEnabled(name: "crlf", enabled: false))

        XCTAssertEqual(
            try read("crlf.md"),
            original.replacingOccurrences(of: "enabled: true", with: "enabled: false")
        )
    }

    func testSetEnabledOnAFileWithoutFrontmatterFails() throws {
        try write("broken.md", "no frontmatter here\n")

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertFalse(viewModel.setEnabled(name: "broken", enabled: false))
        XCTAssertNotNil(viewModel.error)
        XCTAssertEqual(try read("broken.md"), "no frontmatter here\n")
    }

    func testSetEnabledRefusesAnIllegalName() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).md").path
        try "---\ndescription: X\npersona: both\n---\nsecret\n".write(
            toFile: outside, atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(atPath: outside) }

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertFalse(viewModel.setEnabled(name: "../escape", enabled: false))
        XCTAssertNotNil(viewModel.error)
    }

    // MARK: - draft

    func testDraftReturnsBodyWithoutFrontmatter() throws {
        try write("thread-untangle.md", shippedFile)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        let draft = try XCTUnwrap(viewModel.draft(for: "thread-untangle"))

        XCTAssertEqual(draft.name, "thread-untangle")
        XCTAssertEqual(draft.description, "Untangle a thread.")
        XCTAssertEqual(draft.persona, .secretary)
        XCTAssertEqual(draft.body, "Body of the shipped skill.")
    }

    func testDraftForAnUnparsableFileIsNil() throws {
        try write("broken.md", "no frontmatter\n")

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertNil(viewModel.draft(for: "broken"))
    }

    // MARK: - save (create)

    func testSaveCreatesAFileTheCatalogParses() throws {
        let viewModel = SkillsSettingsViewModel(dir: dir)
        let draft = SkillDraft(
            name: "status-update",
            description: "Use when the owner asks for a status update.",
            persona: .both,
            body: "Ask what to say, then render it."
        )

        XCTAssertTrue(viewModel.save(draft, isNew: true))

        let parsed = try XCTUnwrap(
            SkillsCatalog.parse(name: "status-update", content: try read("status-update.md"))
        )
        XCTAssertEqual(parsed.description, "Use when the owner asks for a status update.")
        XCTAssertEqual(parsed.persona, .both)
        XCTAssertTrue(parsed.enabled)
        XCTAssertEqual(viewModel.rows.map(\.name), ["status-update"])
        XCTAssertFalse(try XCTUnwrap(viewModel.rows.first).shipped)
    }

    func testSaveCreatesTheSkillsDirectoryWhenMissing() throws {
        let nested = "\(dir)/nested/skills"
        let viewModel = SkillsSettingsViewModel(dir: nested)

        XCTAssertTrue(viewModel.save(
            SkillDraft(name: "x-ray", description: "Look inside.", persona: .secretary, body: "Do it."),
            isNew: true
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(nested)/x-ray.md"))
    }

    func testSaveQuotesADescriptionThatWouldBreakYAML() throws {
        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertTrue(viewModel.save(
            SkillDraft(
                name: "tricky",
                description: "Use when: the owner says #status",
                persona: .secretary,
                body: "Body."
            ),
            isNew: true
        ))

        let parsed = try XCTUnwrap(
            SkillsCatalog.parse(name: "tricky", content: try read("tricky.md"))
        )
        XCTAssertEqual(parsed.description, "Use when: the owner says #status")
    }

    func testSaveRejectsAnInvalidName() {
        let viewModel = SkillsSettingsViewModel(dir: dir)
        for bad in ["Status Update", "../escape", "-leading", "under_score", ""] {
            XCTAssertFalse(
                viewModel.save(
                    SkillDraft(name: bad, description: "D.", persona: .secretary, body: "B."),
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
        XCTAssertFalse(viewModel.save(
            SkillDraft(name: "empty", description: "   ", persona: .secretary, body: "B."),
            isNew: true
        ))
        XCTAssertNotNil(viewModel.error)
    }

    func testSaveRefusesToOverwriteWithIsNew() throws {
        try write("break-down.md", customFile)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertFalse(viewModel.save(
            SkillDraft(name: "break-down", description: "Other.", persona: .secretary, body: "B."),
            isNew: true
        ))
        XCTAssertEqual(try read("break-down.md"), customFile)
    }

    func testSaveWithNilDirectoryFails() {
        let viewModel = SkillsSettingsViewModel(dir: nil)
        XCTAssertFalse(viewModel.save(
            SkillDraft(name: "nope", description: "D.", persona: .secretary, body: "B."),
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
        try write("thread-untangle.md", shippedFile)
        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertTrue(viewModel.setEnabled(name: "thread-untangle", enabled: false))

        var draft = try XCTUnwrap(viewModel.draft(for: "thread-untangle"))
        draft.body = "Rewritten instructions."
        draft.description = "Untangle a thread, carefully."
        XCTAssertTrue(viewModel.save(draft, isNew: false))

        let updated = try read("thread-untangle.md")
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
            try write("\(name).md", """
                ---
                description: A disabled skill.
                persona: assistant
                \(line)
                ---

                Body.
                """)

            let viewModel = SkillsSettingsViewModel(dir: dir)
            var draft = try XCTUnwrap(viewModel.draft(for: name), "\(name) must be parsable")
            draft.body = "New body."
            XCTAssertTrue(viewModel.save(draft, isNew: false))

            let row = try XCTUnwrap(viewModel.rows.first { $0.name == name })
            XCTAssertFalse(row.enabled, "`\(line)` must survive a Save as disabled")
        }
    }

    /// Round-trip guard: a composed file the catalog cannot read is never
    /// written, because a skill the parsers skip is a skill that silently
    /// vanishes from every persona's prompt.
    func testSaveRefusesToWriteAFileTheCatalogCannotRead() throws {
        // An unterminated quote on an unknown key — carried through verbatim by
        // compose, and fatal to yaml.v3 on the Go side.
        let broken = """
            ---
            description: Break a target down.
            persona: assistant
            author: "unclosed
            ---

            Body.
            """
        try write("break-down.md", broken)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertFalse(viewModel.save(
            SkillDraft(name: "break-down", description: "New.", persona: .assistant, body: "B."),
            isNew: false
        ))
        XCTAssertNotNil(viewModel.error)
        XCTAssertEqual(try read("break-down.md"), broken, "the file on disk must be untouched")
    }

    /// Descriptions are written as single-quoted scalars, so a quote inside one
    /// is doubled rather than dropped — and comes back intact.
    func testSaveRoundTripsAQuoteInsideTheDescription() throws {
        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertTrue(viewModel.save(
            SkillDraft(
                name: "quoted",
                description: "Use when it's a fix: x # y",
                persona: .secretary,
                body: "Body."
            ),
            isNew: true
        ))

        XCTAssertTrue(try read("quoted.md").contains("description: 'Use when it''s a fix: x # y'"))
        let parsed = try XCTUnwrap(SkillsCatalog.parse(name: "quoted", content: try read("quoted.md")))
        XCTAssertEqual(parsed.description, "Use when it's a fix: x # y")
    }

    func testSaveOnAnExistingFileKeepsUnknownFrontmatterKeys() throws {
        try write("break-down.md", """
            ---
            description: Break a target down.
            persona: assistant
            author: owner
            ---

            Body.
            """)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        var draft = try XCTUnwrap(viewModel.draft(for: "break-down"))
        draft.body = "New body."
        XCTAssertTrue(viewModel.save(draft, isNew: false))

        XCTAssertTrue(try read("break-down.md").contains("author: owner"))
    }

    // MARK: - delete

    func testDeleteRemovesACustomSkill() throws {
        try write("break-down.md", customFile)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        viewModel.load()
        XCTAssertTrue(viewModel.delete(name: "break-down"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dir)/break-down.md"))
        XCTAssertTrue(viewModel.rows.isEmpty)
        XCTAssertNil(viewModel.error)
    }

    func testDeleteRefusesAShippedSkill() throws {
        try write("thread-untangle.md", shippedFile)

        let viewModel = SkillsSettingsViewModel(dir: dir)
        viewModel.load()
        XCTAssertFalse(viewModel.delete(name: "thread-untangle"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/thread-untangle.md"))
        XCTAssertNotNil(viewModel.error)
    }

    func testDeleteRefusesAnIllegalName() throws {
        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertFalse(viewModel.delete(name: "../escape"))
        XCTAssertNotNil(viewModel.error)
    }

    // MARK: - round trip with the chat prompt block

    /// The card and the chat prompt read the same files through the same
    /// parser, so a skill disabled in Settings must vanish from the persona's
    /// prompt block on the next build.
    func testDisablingRemovesTheSkillFromThePersonaPromptBlock() throws {
        try write("thread-untangle.md", shippedFile)

        XCTAssertTrue(
            try XCTUnwrap(SkillsCatalog.promptBlock(persona: .secretary, dir: dir))
                .contains("thread-untangle")
        )

        let viewModel = SkillsSettingsViewModel(dir: dir)
        XCTAssertTrue(viewModel.setEnabled(name: "thread-untangle", enabled: false))

        XCTAssertNil(SkillsCatalog.promptBlock(persona: .secretary, dir: dir))
    }
}
