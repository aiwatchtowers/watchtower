import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop

@MainActor
final class SecretaryProfileViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func insertWorkspace() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db)
        }
    }

    func testLoadReadsBriefAndStyle() throws {
        try insertWorkspace()
        try dbManager.dbPool.write { db in
            try db.execute(sql: "UPDATE workspace SET secretary_profile = 'brief', style_profile = 'style'")
        }
        let vm = SecretaryProfileViewModel(dbManager: dbManager)
        vm.load()
        XCTAssertEqual(vm.briefText, "brief")
        XCTAssertEqual(vm.styleText, "style")
        XCTAssertFalse(vm.hasUnsavedStyleChanges)
    }

    func testSaveStylePersistsAndClearsUnsavedFlag() async throws {
        try insertWorkspace()
        let vm = SecretaryProfileViewModel(dbManager: dbManager)
        vm.load()
        vm.styleText = "edited style"
        XCTAssertTrue(vm.hasUnsavedStyleChanges)

        await vm.saveStyle()

        XCTAssertFalse(vm.hasUnsavedStyleChanges)
        let stored = try await dbManager.dbPool.read { try SecretaryProfileQueries.fetchStyle($0).text }
        XCTAssertEqual(stored, "edited style")
    }

    func testGenerateStyleInvokesCLIAndReloads() async throws {
        try insertWorkspace()
        let runner = FakeCLIRunner(stdout: Data())
        let vm = SecretaryProfileViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()

        await vm.generateStyle()

        XCTAssertEqual(runner.invocations, [["inbox", "style-sample"]])
        XCTAssertFalse(vm.isGenerating)
        XCTAssertNil(vm.errorMessage)
    }

    func testGenerateStyleBlockedByUnsavedEdits() async throws {
        try insertWorkspace()
        let runner = FakeCLIRunner(stdout: Data())
        let vm = SecretaryProfileViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()
        vm.styleText = "unsaved edit"

        XCTAssertFalse(vm.canGenerate)
        await vm.generateStyle()

        XCTAssertTrue(runner.invocations.isEmpty, "generate must not run over unsaved edits")
    }

    func testGenerateStyleGuardsReentry() async throws {
        try insertWorkspace()
        let runner = FakeCLIRunner(stdout: Data())
        let vm = SecretaryProfileViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()
        vm.isGenerating = true

        await vm.generateStyle()

        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(vm.isGenerating, "the guard must not clear the in-flight flag")
    }

    func testGenerateStyleSurfacesCLIFailure() async throws {
        try insertWorkspace()
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "not enough messages"))
        let vm = SecretaryProfileViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()

        await vm.generateStyle()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isGenerating)
    }

    func testAppStateOwnsVMIdentityAcrossAccesses() throws {
        // Mirrors AppStateTests' dashboardViewModel identity check — navigation
        // must not recreate the VM (async ops survive navigation).
        let appState = AppState()
        appState.initSecretaryProfile(dbManager: dbManager)
        let first = appState.secretaryProfileViewModel
        let second = appState.secretaryProfileViewModel
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
    }
}
