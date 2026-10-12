import XCTest
@testable import WatchtowerCore

/// CodeRoot's identity and key depend on the folder's spelling only, never on
/// whether the directory exists when the root is built (board #565).
final class CodeRootTests: XCTestCase {
    private func makeTempBase() -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("coderoot-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }

    func testExistingAndDeletedFolderShareTheKey() throws {
        let folder = makeTempBase().appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let whileExisting = CodeRoot(workbenchID: 7, worktree: folder)
        try FileManager.default.removeItem(at: folder)
        let afterDeletion = CodeRoot(workbenchID: 7, worktree: folder)

        XCTAssertEqual(whileExisting, afterDeletion)
        XCTAssertEqual(whileExisting.hashValue, afterDeletion.hashValue)
        XCTAssertEqual(whileExisting.defaultsKeySuffix, afterDeletion.defaultsKeySuffix)
    }

    func testSymlinkedSpellingKeepsItsKeyAcrossDeletionAndRecreation() throws {
        let base = makeTempBase()
        let real = base.appendingPathComponent("wt", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let before = CodeRoot(workbenchID: 7, worktree: link)

        try FileManager.default.removeItem(at: real)
        let whileGone = CodeRoot(workbenchID: 7, worktree: link)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let recreated = CodeRoot(workbenchID: 7, worktree: link)

        XCTAssertEqual(before.defaultsKeySuffix, whileGone.defaultsKeySuffix)
        XCTAssertEqual(before.defaultsKeySuffix, recreated.defaultsKeySuffix)
        // The real spelling is a different root: identity is lexical by rule.
        XCTAssertNotEqual(before, CodeRoot(workbenchID: 7, worktree: real))
    }

    func testLexicalStandardization() {
        let plain = CodeRoot(workbenchID: 7, worktree: URL(fileURLWithPath: "/nonexistent/acme-wt/a"))
        let dotted = CodeRoot(workbenchID: 7, worktree: URL(fileURLWithPath: "/nonexistent/acme-wt/b/../a/"))
        XCTAssertEqual(plain, dotted)
        XCTAssertEqual(plain.defaultsKeySuffix, dotted.defaultsKeySuffix)
    }
}
