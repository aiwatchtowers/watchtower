import XCTest
@testable import WatchtowerCore

/// The launch backstop's read of a folder's installed workbench (spec §6.13, D37).
final class WorkbenchInstallCheckTests: XCTestCase {
    private func settings(_ ids: [Int64]) -> Data {
        let hooks = ids.map { #"{"type":"command","command":"'/Applications/Watch Tower/watchtower' workbench session-state --workbench \#($0)","async":true}"# }
        return Data(#"{"model":"sonnet","hooks":{"UserPromptSubmit":[{"hooks":[\#(hooks.joined(separator: ","))]}]}}"#.utf8)
    }

    func testReadsEveryInstalledID() {
        XCTAssertEqual(WorkbenchInstallCheck.installedIDs(settings: settings([7, 12])), [7, 12])
        XCTAssertEqual(WorkbenchInstallCheck.installedIDs(settings: settings([])), [])
        XCTAssertEqual(WorkbenchInstallCheck.installedIDs(settings: Data("not json".utf8)), [])
    }

    func testOnlyAnotherBenchsInstallNeedsAReinstall() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(WorkbenchInstallCheck.needsReinstall(folder: dir.path, workbenchID: 1), "no install: launch as always")
        let file = URL(fileURLWithPath: WorkbenchInstallCheck.settingsPath(folder: dir.path))
        try settings([9]).write(to: file)
        XCTAssertTrue(WorkbenchInstallCheck.needsReinstall(folder: dir.path, workbenchID: 1), "the merged bench's install")
        try settings([9, 1]).write(to: file)
        XCTAssertFalse(WorkbenchInstallCheck.needsReinstall(folder: dir.path, workbenchID: 1))
    }
}
