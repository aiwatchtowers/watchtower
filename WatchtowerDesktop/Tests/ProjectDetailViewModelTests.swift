import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore
@testable import WatchtowerDesktop

@MainActor
final class ProjectDetailViewModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var projectID: Int64 = 0
    private var importedURLs: [URL] = []
    /// Project ids reported through `onPromptChanged`.
    private var promptChanges: [Int64] = []

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        projectID = try pool.write { try ChatProjectQueries.create($0, name: "Payments").id }
        importedURLs = []
        promptChanges = []
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM(debounce: Duration = .zero) -> ProjectDetailViewModel {
        ProjectDetailViewModel(projectID: projectID, dbPool: pool, debounce: debounce, importFile: { [weak self] url, pid in
            guard let self else { throw CancellationError() }
            self.importedURLs.append(url)
            return try self.pool.write { d in
                try d.execute(
                    sql: """
                        INSERT INTO chat_attachments (project_id, name, mime, size, path, sha256, created_at)
                        VALUES (?, ?, 'application/pdf', 1, ?, 'h', 1)
                        """,
                    arguments: [pid, url.lastPathComponent, url.path]
                )
                return try XCTUnwrap(ChatProjectQueries.files(d, projectID: pid).last)
            }
        }, onPromptChanged: { [weak self] in self?.promptChanges.append($0) })
    }

    private func storedInstructions() throws -> String? {
        let pid = projectID
        return try pool.read { try ChatProjectQueries.fetchByID($0, id: pid)?.instructions }
    }

    func testLoadFillsDraftsAndLists() throws {
        try pool.write { d in
            try ChatProjectQueries.updateInstructions(d, id: self.projectID, instructions: "Be brief.")
            try ChatProjectQueries.addSource(d, projectID: self.projectID, kind: .jiraProject, ref: "PAY", label: "PAY")
        }
        let vm = makeVM()
        vm.load()
        XCTAssertEqual(vm.project?.name, "Payments")
        XCTAssertEqual(vm.nameDraft, "Payments")
        XCTAssertEqual(vm.instructionsDraft, "Be brief.")
        XCTAssertEqual(vm.sources.map(\.ref), ["PAY"])
        XCTAssertNil(vm.errorMessage)
    }

    func testInstructionsEditIsDebouncedThenSaved() async throws {
        let vm = makeVM(debounce: .milliseconds(50))
        vm.load()
        vm.instructionsEdited("First")
        vm.instructionsEdited("Second")
        await vm.pendingSave?.value
        let stored = try storedInstructions()
        XCTAssertEqual(stored, "Second", "only the latest draft is written")
    }

    /// Every committed change to what the prompt holds is reported, so the
    /// chat retires the project's warm sessions; a no-op write is not.
    func testPromptChangingEditsAreReported() async throws {
        let vm = makeVM()
        vm.load()
        vm.instructionsEdited("Be brief.")
        await vm.pendingSave?.value
        XCTAssertEqual(promptChanges, [projectID])

        let hit = ChatEntityHit(kind: .channel, ref: "1:C1", label: "#payments", detail: "")
        vm.addSource(hit)
        vm.addSource(hit)
        XCTAssertEqual(promptChanges.count, 2, "a duplicate source changes nothing")
        vm.removeSource(try XCTUnwrap(vm.sources.first))
        XCTAssertEqual(promptChanges.count, 3)

        vm.addFiles([URL(fileURLWithPath: NSTemporaryDirectory() + "imported_\(UUID().uuidString).pdf")])
        XCTAssertEqual(promptChanges.count, 4)
        vm.removeFile(try XCTUnwrap(vm.files.first))
        XCTAssertEqual(promptChanges.count, 5)
        XCTAssertEqual(Set(promptChanges), [projectID])
    }

    /// Leaving the page before the debounce fires must not lose the edit.
    func testFlushWritesPendingDraftImmediately() async throws {
        let vm = makeVM(debounce: .seconds(60))
        vm.load()
        vm.instructionsEdited("Keep me")
        await vm.flush()
        let stored = try storedInstructions()
        XCTAssertEqual(stored, "Keep me")
    }

    func testRenameAddRemoveSource() throws {
        let vm = makeVM()
        vm.load()
        vm.rename("Q3 payments")
        XCTAssertEqual(vm.project?.name, "Q3 payments")
        vm.addSource(ChatEntityHit(kind: .channel, ref: "1:C1", label: "#payments", detail: ""))
        vm.addSource(ChatEntityHit(kind: .jiraIssue, ref: "PAY-1", label: "PAY-1", detail: ""))
        XCTAssertEqual(vm.sources.map(\.kind), ["slack_channel"], "an issue hit is not a project source")
        vm.removeSource(vm.sources[0])
        XCTAssertTrue(vm.sources.isEmpty)
    }

    func testAddAndRemoveFilesRemovesDiskFile() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory() + "proj_\(UUID().uuidString).pdf")
        try Data("x".utf8).write(to: file)
        let vm = makeVM()
        vm.load()
        vm.addFiles([file])
        XCTAssertEqual(importedURLs, [file])
        XCTAssertEqual(vm.files.map(\.name), [file.lastPathComponent])
        vm.removeFile(vm.files[0])
        XCTAssertTrue(vm.files.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "disk file removed post-commit")
    }

    func testImportFailureSurfacesError() {
        let vm = ProjectDetailViewModel(projectID: projectID, dbPool: pool, debounce: .zero) { _, _ in
            throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "too big"])
        }
        vm.load()
        vm.addFiles([URL(fileURLWithPath: "/tmp/huge.pdf")])
        XCTAssertEqual(vm.errorMessage, "huge.pdf: too big")
        XCTAssertTrue(vm.files.isEmpty)
    }

    func testStoreImporterWithoutWorkspaceFailsVisibly() {
        let vm = ProjectDetailViewModel(
            projectID: projectID, dbPool: pool, debounce: .zero,
            importFile: ProjectDetailViewModel.storeImporter(dbPool: pool, rootDir: nil)
        )
        vm.load()
        vm.addFiles([URL(fileURLWithPath: "/tmp/spec.pdf")])
        XCTAssertEqual(vm.errorMessage, "spec.pdf: Attachments need an active workspace")
    }

    /// The real store end to end: an imported file lands under
    /// `projects/<id>/`, and deleting the project removes that directory.
    func testDeleteProjectRemovesItsStoredFilesDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wt_proj_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("in.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("%PDF-1.4\n%fake body\n".utf8).write(to: source)

        let vm = ProjectDetailViewModel(
            projectID: projectID, dbPool: pool, debounce: .zero, attachmentsRoot: root,
            importFile: ProjectDetailViewModel.storeImporter(dbPool: pool, rootDir: root)
        )
        vm.load()
        vm.addFiles([source])
        XCTAssertNil(vm.errorMessage)
        let stored = try XCTUnwrap(vm.files.first?.path)
        XCTAssertTrue(stored.hasPrefix(root.appendingPathComponent("projects/\(projectID)").path))

        XCTAssertTrue(vm.deleteProject())
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("projects/\(projectID)").path))
    }

    func testDeleteProjectKeepsChats() throws {
        let chatID = try pool.write { d -> Int64 in
            try d.execute(
                sql: "INSERT INTO chat_conversations (title, created_at, updated_at, project_id) VALUES ('c', 1, 1, ?)",
                arguments: [self.projectID]
            )
            return d.lastInsertedRowID
        }
        let vm = makeVM()
        vm.load()
        XCTAssertEqual(vm.chats.map(\.id), [chatID])
        XCTAssertTrue(vm.deleteProject())
        let remaining = try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_conversations") }
        XCTAssertEqual(remaining, 1)
        XCTAssertNil(try pool.read { try ChatProjectQueries.fetchByID($0, id: self.projectID) })
    }

    /// A rename or source change inside the debounce window must not reset the
    /// instructions draft the owner is still typing.
    func testListChangeDuringDebounceKeepsInstructionsDraft() async throws {
        let vm = makeVM(debounce: .seconds(60))
        vm.load()
        vm.instructionsEdited("Still typing")
        vm.rename("Renamed")
        vm.addSource(ChatEntityHit(kind: .track, ref: "7", label: "T", detail: ""))
        XCTAssertEqual(vm.instructionsDraft, "Still typing")
        await vm.flush()
        let stored = try storedInstructions()
        XCTAssertEqual(stored, "Still typing")
    }

    /// Typing and undoing back to the stored text saves nothing, so no
    /// chat's session is retired for an unchanged prompt.
    func testUnchangedInstructionsAreNotSavedNorReported() async throws {
        let vm = makeVM(debounce: .seconds(60))
        vm.load()
        vm.instructionsEdited("x")
        vm.instructionsEdited("")
        let saved = await vm.flush()
        XCTAssertTrue(saved)
        XCTAssertTrue(promptChanges.isEmpty)
    }

    /// "New chat in this project" waits on this result: a failed save must
    /// say so (and not report a prompt change), so no chat starts on the
    /// old instructions.
    func testFlushReportsAFailedSave() async throws {
        let vm = makeVM(debounce: .seconds(60))
        vm.load()
        try await pool.write { d in
            try d.execute(sql: """
                CREATE TRIGGER fail_project_update BEFORE UPDATE ON chat_projects
                BEGIN SELECT RAISE(ABORT, 'locked'); END
                """)
        }
        vm.instructionsEdited("New text")
        let saved = await vm.flush()
        XCTAssertFalse(saved)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(promptChanges.isEmpty)
    }

    func testFlushWithNothingPendingWritesNothing() async throws {
        let pid = projectID
        try await pool.write { try ChatProjectQueries.updateInstructions($0, id: pid, instructions: "Kept") }
        let vm = makeVM()
        vm.load()
        await vm.flush()
        let stored = try storedInstructions()
        XCTAssertEqual(stored, "Kept")
    }

    /// Review M3: after a failed load the drafts are blank placeholders; an
    /// edit must not reach the stored instructions.
    func testFailedLoadBlocksInstructionEdits() async throws {
        let pid = projectID
        try await pool.write { d in
            try ChatProjectQueries.updateInstructions(d, id: pid, instructions: "Stored")
            try d.execute(sql: "DROP TABLE chat_project_sources")
        }
        let vm = makeVM()
        vm.load()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.draftsLoaded)
        vm.instructionsEdited("partial")
        await vm.flush()
        XCTAssertEqual(try storedInstructions(), "Stored")
    }

    /// A later successful list refresh (not `load`) does not unlock editing:
    /// only a load puts the stored text into the drafts.
    func testRefreshWithoutLoadKeepsEditingOff() throws {
        let vm = makeVM()
        vm.addSource(ChatEntityHit(kind: .track, ref: "7", label: "T", detail: ""))
        XCTAssertNotNil(vm.project)
        XCTAssertFalse(vm.draftsLoaded)
        vm.load()
        XCTAssertTrue(vm.draftsLoaded)
    }
}
