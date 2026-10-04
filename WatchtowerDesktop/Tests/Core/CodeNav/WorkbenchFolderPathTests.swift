import XCTest
@testable import WatchtowerCore

/// A link into a workbench folder is resolved without touching anything
/// outside it (board #361): `..` and symlinks leaving the folder are
/// refused before their target is looked at.
final class WorkbenchFolderPathTests: XCTestCase {
    private var root: URL!
    private var folder: String!
    private var realFolder: String!
    /// Every path the resolver looked up.
    private var lookups: [String] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wt folder \(UUID().uuidString)", isDirectory: true)
        let workbench = root.appendingPathComponent("acme", isDirectory: true)
        for path in ["Sources/A.swift", "docs/guide.md"] {
            let file = workbench.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x\n".utf8).write(to: file)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("private"), withIntermediateDirectories: true)
        try Data("secret\n".utf8).write(to: root.appendingPathComponent("private/outside.txt"))
        folder = workbench.path
        realFolder = WorkbenchFolderPath.FileSystem.live.realPath(folder)
        lookups = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func link(_ name: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: (folder as NSString).appendingPathComponent(name),
                                                   withDestinationPath: destination)
    }

    private func resolve(_ path: String) -> String? {
        let live = WorkbenchFolderPath.FileSystem.live
        let recorder = Recorder()
        let seam = WorkbenchFolderPath.FileSystem(
            entryKind: { recorder.add($0); return live.entryKind($0) },
            linkTarget: { recorder.add($0); return live.linkTarget($0) },
            realPath: { recorder.add($0); return live.realPath($0) })
        defer { lookups = recorder.paths }
        return WorkbenchFolderPath.resolve(path, folder: folder, folderRealPath: realFolder, fileSystem: seam)
    }

    private var outsideLookups: [String] {
        lookups.filter { !$0.hasPrefix(realFolder + "/") && $0 != realFolder }
    }

    func testAFileOfTheFolderResolves() {
        XCTAssertEqual(resolve("Sources/A.swift"), "Sources/A.swift")
        XCTAssertEqual(resolve("./Sources/../Sources/A.swift"), "Sources/A.swift")
    }

    func testMissingFilesDirectoriesAndAbsolutePathsAreRefused() {
        XCTAssertNil(resolve("Sources/Missing.swift"))
        XCTAssertNil(resolve("Sources"))
        XCTAssertNil(resolve("Sources/A.swift/x"))
        XCTAssertNil(resolve("/etc/hosts"))
        XCTAssertNil(resolve(""))
    }

    func testDotDotOutOfTheFolderIsRefusedWithoutALookup() {
        XCTAssertNil(resolve("../private/outside.txt"))
        XCTAssertNil(resolve("Sources/../../private/outside.txt"))
        XCTAssertEqual(outsideLookups, [])
    }

    func testASymlinkInsideTheFolderIsFollowed() throws {
        try link("alias.swift", to: "Sources/A.swift")
        try link("src", to: "\(folder ?? "")/Sources")
        XCTAssertEqual(resolve("alias.swift"), "Sources/A.swift")
        XCTAssertEqual(resolve("src/A.swift"), "Sources/A.swift")
    }

    /// The P0 case: a link to a file or a folder outside (a protected one
    /// in real life) is refused, and its target is never looked up.
    func testASymlinkLeavingTheFolderIsRefusedWithoutTouchingItsTarget() throws {
        try link("leak.txt", to: root.appendingPathComponent("private/outside.txt").path)
        try link("relative-leak.txt", to: "../private/outside.txt")
        try link("private", to: root.appendingPathComponent("private").path)
        for path in ["leak.txt", "relative-leak.txt", "private/outside.txt"] {
            XCTAssertNil(resolve(path), path)
            XCTAssertEqual(outsideLookups, [], path)
        }
    }

    /// A relative link in a subfolder resolves from that subfolder, `..`
    /// after a followed folder link climbs from its target, and a nested
    /// `../..` out of the folder is refused without a lookup outside.
    func testRelativeLinksAndDotDotResolveFromTheRealFolder() throws {
        try FileManager.default.createSymbolicLink(atPath: (folder as NSString).appendingPathComponent("docs/a.swift"),
                                                   withDestinationPath: "../Sources/A.swift")
        XCTAssertEqual(resolve("docs/a.swift"), "Sources/A.swift")
        try link("src", to: "Sources")
        XCTAssertEqual(resolve("src/../docs/guide.md"), "docs/guide.md")
        try FileManager.default.createSymbolicLink(atPath: (folder as NSString).appendingPathComponent("docs/up"),
                                                   withDestinationPath: "../../private")
        XCTAssertNil(resolve("docs/up/outside.txt"))
        XCTAssertNil(resolve("docs/../../private/outside.txt"))
        XCTAssertEqual(outsideLookups, [])
    }

    func testASymlinkLoopIsRefused() throws {
        try link("a", to: "b")
        try link("b", to: "a")
        XCTAssertNil(resolve("a"))
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var paths: [String] { lock.withLock { stored } }
    func add(_ path: String) { lock.withLock { stored.append(path) } }
}
