import XCTest
@testable import WatchtowerCore

final class ReviewFileTreeTests: XCTestCase {
    typealias Node = ReviewFileTree.Node

    func testBuildsFoldersFirstSorted() {
        let tree = ReviewFileTree.build(["b.txt", "src/z.swift", "src/a.swift", "a.txt", "docs/x.md", "docs/y.md"])
        XCTAssertEqual(tree, [
            .folder(name: "docs", path: "docs", children: [.file(path: "docs/x.md"), .file(path: "docs/y.md")]),
            .folder(name: "src", path: "src", children: [.file(path: "src/a.swift"), .file(path: "src/z.swift")]),
            .file(path: "a.txt"),
            .file(path: "b.txt")
        ])
    }

    func testCompactsSingleChildChains() {
        XCTAssertEqual(ReviewFileTree.build(["a/b/c/x.swift"]), [
            .folder(name: "a/b/c", path: "a/b/c", children: [.file(path: "a/b/c/x.swift")])
        ])
        // A fork stops the chain; the single-child tail below it still compacts.
        XCTAssertEqual(ReviewFileTree.build(["a/b/x.swift", "a/c/d/y.swift"]), [
            .folder(name: "a", path: "a", children: [
                .folder(name: "b", path: "a/b", children: [.file(path: "a/b/x.swift")]),
                .folder(name: "c/d", path: "a/c/d", children: [.file(path: "a/c/d/y.swift")])
            ])
        ])
    }

    func testRootFilesStayAtTop() {
        XCTAssertEqual(ReviewFileTree.build(["README.md", "Makefile"]), [.file(path: "Makefile"), .file(path: "README.md")])
    }

    func testRenamedFileAppearsOnceUnderItsNewPath() {
        let tree = ReviewFileTree.build(["new/name.swift", "new/other.swift"])
        XCTAssertEqual(tree, [
            .folder(name: "new", path: "new", children: [.file(path: "new/name.swift"), .file(path: "new/other.swift")])
        ])
    }

    func testEmpty() {
        XCTAssertEqual(ReviewFileTree.build([]), [])
    }
}
