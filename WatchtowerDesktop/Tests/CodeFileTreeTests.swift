import XCTest
@testable import WatchtowerDesktop

@MainActor
final class CodeFileTreeTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)")
        for dir in ["src/inner", ".git", "node_modules/x", "b"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["file10.txt", "file2.txt", "src/a.go", "src/inner/deep.go", ".env"] {
            try "x".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testListsFoldersFirstInNaturalOrderAndHidesBuildAndVCSFolders() {
        let tree = CodeFileTree(root: root)
        tree.loadIfNeeded()
        XCTAssertEqual(tree.rows.map(\.entry.name), ["b", "src", ".env", "file2.txt", "file10.txt"])
    }

    func testExpandingShowsChildrenOneLevelDeeper() {
        let tree = CodeFileTree(root: root)
        tree.loadIfNeeded()
        tree.toggle("src")
        let rows = tree.rows.map { "\($0.depth):\($0.entry.relPath)" }
        XCTAssertEqual(rows, ["0:b", "0:src", "1:src/inner", "1:src/a.go", "0:.env", "0:file2.txt", "0:file10.txt"])
        tree.expand("src/inner")
        XCTAssertTrue(tree.rows.contains { $0.entry.relPath == "src/inner/deep.go" && $0.depth == 2 })
    }

    func testRefreshReadsOnlyListedFolders() throws {
        let tree = CodeFileTree(root: root)
        tree.loadIfNeeded()
        try "y".write(to: root.appendingPathComponent("src/new.go"), atomically: true, encoding: .utf8)
        tree.refresh(directories: ["src"])
        XCTAssertNil(tree.listings["src"], "a folder never opened is read when it is")
        tree.toggle("src")
        XCTAssertTrue(tree.rows.contains { $0.entry.relPath == "src/new.go" })
    }

    func testAVanishedFolderDropsOutAndAVanishedRootSaysSo() throws {
        let tree = CodeFileTree(root: root)
        tree.loadIfNeeded()
        tree.toggle("src")
        try FileManager.default.removeItem(at: root.appendingPathComponent("src"))
        tree.refresh(directories: ["", "src"])
        XCTAssertFalse(tree.expanded.contains("src"))
        XCTAssertFalse(tree.rows.contains { $0.entry.relPath.hasPrefix("src") })
        try FileManager.default.removeItem(at: root)
        tree.reloadAll()
        XCTAssertEqual(tree.errors[""], "The workbench folder no longer exists.")
    }
}
