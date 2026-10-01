import XCTest
@testable import WatchtowerCore

final class NewProjectFolderTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("npf-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    func testNewNameIsCreatedOnlyByPrepare() throws {
        let url = root.appendingPathComponent("acme", isDirectory: true)
        XCTAssertEqual(try NewProjectFolder.check(url), .create)
        XCTAssertFalse(fm.fileExists(atPath: url.path), "check must not touch the disk")

        XCTAssertEqual(try NewProjectFolder.prepare(url), .create)
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testExistingEmptyFolderIsReused() throws {
        let url = root.appendingPathComponent("acme", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        try Data().write(to: url.appendingPathComponent(".DS_Store"))

        XCTAssertEqual(try NewProjectFolder.check(url), .reuseEmpty)
        XCTAssertEqual(try NewProjectFolder.prepare(url), .reuseEmpty)
    }

    func testExistingNonEmptyFolderIsRefused() throws {
        let url = root.appendingPathComponent("acme", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: url.appendingPathComponent("README.md"))

        XCTAssertThrowsError(try NewProjectFolder.prepare(url)) { error in
            XCTAssertEqual(error as? NewProjectFolder.Failure, .notEmpty(path: url.path))
        }
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent("README.md").path), "content untouched")
    }

    func testExistingFileIsRefused() throws {
        let url = root.appendingPathComponent("acme")
        try Data("x".utf8).write(to: url)

        XCTAssertThrowsError(try NewProjectFolder.check(url)) { error in
            XCTAssertEqual(error as? NewProjectFolder.Failure, .notADirectory(path: url.path))
        }
    }

    func testCreationFailureIsReported() throws {
        // The parent is a regular file, so the folder cannot be created.
        let file = root.appendingPathComponent("plain")
        try Data("x".utf8).write(to: file)
        let url = file.appendingPathComponent("acme", isDirectory: true)

        XCTAssertEqual(try NewProjectFolder.check(url), .create)
        XCTAssertThrowsError(try NewProjectFolder.prepare(url)) { error in
            guard case let .createFailed(path, reason)? = error as? NewProjectFolder.Failure else {
                return XCTFail("expected createFailed, got \(error)")
            }
            XCTAssertEqual(path, url.path)
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testMissingParentIsNotCreatedImplicitly() throws {
        let url = root.appendingPathComponent("missing/acme", isDirectory: true)
        XCTAssertThrowsError(try NewProjectFolder.prepare(url))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("missing").path))
    }

    func testDefaultParentPrefersProjectsFolder() throws {
        XCTAssertEqual(NewProjectFolder.defaultParent(home: root), root)
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        try fm.createDirectory(at: projects, withIntermediateDirectories: false)
        XCTAssertEqual(NewProjectFolder.defaultParent(home: root).path, projects.path)
    }

    func testResolvedFollowsASymlinkedParent() throws {
        let real = root.appendingPathComponent("real", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let resolved = NewProjectFolder.resolved(link.appendingPathComponent("acme"))
        XCTAssertEqual(resolved.path, real.resolvingSymlinksInPath().appendingPathComponent("acme").path)
    }

    func testResolvedFollowsASymlinkedLeaf() throws {
        // ~/Projects/acme -> ~/Documents/acme: the TCC check must see Documents.
        let documents = root.appendingPathComponent("Documents/acme", isDirectory: true)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        let leaf = root.appendingPathComponent("acme")
        try fm.createSymbolicLink(at: leaf, withDestinationURL: documents)

        let resolved = NewProjectFolder.resolved(leaf)
        XCTAssertEqual(resolved.path, documents.resolvingSymlinksInPath().path)
        XCTAssertEqual(try NewProjectFolder.check(resolved), .reuseEmpty)
        let home = root.resolvingSymlinksInPath().path
        XCTAssertEqual(ProjectFolderPolicy.tccSensitiveLocation(path: resolved.path, home: home), "~/Documents")
    }
}
