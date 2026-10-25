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

    private func comment(_ id: Int64, path: String?, status: ReviewComment.Status) -> ReviewComment {
        ReviewComment(
            id: id, roundID: 1, path: path, side: "new", startLine: 1, endLine: 1, quote: "", quotePrefix: "",
            quoteSuffix: "", treeSHA: "", lens: "", body: "c\(id)", status: status, carriedFrom: nil, agentReply: ""
        )
    }

    /// A folder row counts the files under it at any depth that are not
    /// viewed, and their comments that are not resolved.
    func testFolderCounts() {
        let tree = ReviewFileTree.build(["src/a.swift", "src/deep/b.swift", "src/deep/c.swift", "other.txt"])
        guard case let .folder(_, _, children) = tree[0] else { return XCTFail("src is not a folder") }
        let comments = [
            comment(1, path: "src/a.swift", status: .draft),
            comment(2, path: "src/deep/b.swift", status: .carried),
            comment(3, path: "src/deep/b.swift", status: .resolved),
            comment(4, path: "other.txt", status: .draft),
            comment(5, path: nil, status: .draft)
        ]
        let counts = ReviewFileTree.counts(of: children, isViewed: { $0 == "src/deep/c.swift" }, comments: comments)
        XCTAssertEqual(counts, ReviewFileTree.FolderCounts(unviewed: 2, openComments: 2))
        let none = ReviewFileTree.counts(of: children, isViewed: { _ in true }, comments: [])
        XCTAssertEqual(none, ReviewFileTree.FolderCounts(unviewed: 0, openComments: 0))
    }

    /// Selecting a file opens every folder that holds it, and only those.
    func testRevealingOpensTheFoldersOfTheFile() {
        let collapsed: Set<String> = ["src", "src/deep", "src/deeper", "docs"]
        XCTAssertEqual(ReviewFileTree.revealing("src/deep/b.swift", in: collapsed), ["src/deeper", "docs"])
        XCTAssertEqual(ReviewFileTree.revealing("top.txt", in: collapsed), collapsed)
    }
}
