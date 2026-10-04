import XCTest
@testable import WatchtowerCore

/// Counts the disk lookups `resolve` makes.
private final class CountingFileSystem: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    var calls: [String] { lock.withLock { paths } }

    var seam: TerminalPathLinks.FileSystem {
        TerminalPathLinks.FileSystem(
            entryKind: { [self] path in
                lock.withLock { paths.append(path) }
                return TerminalPathLinks.FileSystem.live.entryKind(path)
            },
            linkTarget: { [self] path in
                lock.withLock { paths.append(path) }
                return TerminalPathLinks.FileSystem.live.linkTarget(path)
            },
            realPath: { [self] path in
                lock.withLock { paths.append(path) }
                return TerminalPathLinks.FileSystem.live.realPath(path)
            }
        )
    }
}

/// `path:line(:col)` in a workbench session's terminal output (spec
/// 2026-10-02 §9.5): a link only when it names an existing file inside the
/// session's folder.
final class TerminalPathLinksTests: XCTestCase {
    private var root: URL!
    private var folder: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wt links \(UUID().uuidString)", isDirectory: true)
        let workbench = root.appendingPathComponent("acme", isDirectory: true)
        for path in ["Sources/A.swift", "x/y.go", "a b.txt"] {
            let file = workbench.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x\n".utf8).write(to: file)
        }
        try Data("secret\n".utf8).write(to: root.appendingPathComponent("outside.txt"))
        folder = workbench.path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func resolve(_ link: String) -> TerminalPathLinks.Location? {
        TerminalPathLinks.resolve(link, folder: folder)
    }

    func testRelativePathWithLineResolves() {
        XCTAssertEqual(resolve("Sources/A.swift:12"), .init(path: "Sources/A.swift", line: 12, col: nil))
    }

    func testDotSlashPathWithLineAndColumnResolves() {
        XCTAssertEqual(resolve("./x/y.go:3:7"), .init(path: "x/y.go", line: 3, col: 7))
    }

    func testQuotedPathWithASpaceResolves() {
        XCTAssertEqual(resolve("\"a b.txt:1\""), .init(path: "a b.txt", line: 1, col: nil))
        XCTAssertEqual(resolve("'a b.txt':1"), .init(path: "a b.txt", line: 1, col: nil))
    }

    func testAbsolutePathInsideTheFolderResolves() {
        XCTAssertEqual(resolve("\(folder ?? "")/x/y.go:9"), .init(path: "x/y.go", line: 9, col: nil))
    }

    func testPathOutsideTheFolderIsNoLink() {
        XCTAssertNil(resolve("../outside.txt:1"))
        XCTAssertNil(resolve("\(root.path)/outside.txt:1"))
        XCTAssertNil(resolve("/etc/hosts:1"))
    }

    /// A symlink inside the folder that points out of it is outside too.
    func testSymlinkLeavingTheFolderIsNoLink() throws {
        let link = URL(fileURLWithPath: folder).appendingPathComponent("leak.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("outside.txt"))
        XCTAssertNil(resolve("leak.txt:1"))
    }

    /// Board #361: a symlink pointing out of the folder is refused by its
    /// target's text — the target itself is never looked up.
    func testSymlinkLeavingTheFolderNeverTouchesItsTarget() throws {
        let link = URL(fileURLWithPath: folder).appendingPathComponent("leak.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("outside.txt"))
        let disk = CountingFileSystem()
        let realFolder = TerminalPathLinks.FileSystem.live.realPath(folder)
        XCTAssertNil(TerminalPathLinks.resolve("leak.txt:1", folder: folder, folderRealPath: realFolder, fileSystem: disk.seam))
        XCTAssertFalse(disk.calls.contains { $0.hasSuffix("outside.txt") }, "\(disk.calls)")
    }

    /// Ruling R53: a path outside the folder is refused by its text alone —
    /// no realpath, no stat — so a ⌘-click on `~/Desktop/…` can never raise
    /// a macOS privacy prompt.
    func testAPathOutsideTheFolderTouchesNoDisk() {
        let disk = CountingFileSystem()
        let realFolder = TerminalPathLinks.FileSystem.live.realPath(folder)
        for link in ["~/Desktop/notes.txt:1", "/Users/someone/Documents/a.swift:3", "../outside.txt:1",
                     "x/../../outside.txt:2", "file:///Users/someone/Desktop/a.txt:1"] {
            XCTAssertEqual(TerminalPathLinks.action(for: link, folder: folder, folderRealPath: realFolder, fileSystem: disk.seam),
                           .none, link)
        }
        XCTAssertEqual(disk.calls, [], "nothing outside the folder was looked up")
        XCTAssertEqual(TerminalPathLinks.resolve("x/y.go:3", folder: folder, folderRealPath: realFolder, fileSystem: disk.seam),
                       .init(path: "x/y.go", line: 3, col: nil))
        XCTAssertFalse(disk.calls.isEmpty, "an in-folder candidate is resolved on disk")
    }

    /// Ruling R54(e): a `file://` link is a path — opened in Files when it is
    /// a file of the folder, else nothing (never the system's handler).
    func testFileURLsAreResolvedLikePaths() {
        let inside = "file://" + (folder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "") + "/x/y.go:4"
        XCTAssertEqual(TerminalPathLinks.action(for: inside, folder: folder, folderRealPath: nil),
                       .open(.init(path: "x/y.go", line: 4, col: nil)))
        XCTAssertEqual(TerminalPathLinks.action(for: "file://\(root.path)/outside.txt:1", folder: folder, folderRealPath: nil), .none)
        XCTAssertEqual(TerminalPathLinks.action(for: "file:///etc/hosts", folder: folder, folderRealPath: nil), .none)
        XCTAssertEqual(TerminalPathLinks.action(for: "http://host:80", folder: folder, folderRealPath: nil), .systemHandler)
        XCTAssertEqual(TerminalPathLinks.action(for: "Sources/A.swift:12", folder: folder, folderRealPath: nil),
                       .open(.init(path: "Sources/A.swift", line: 12, col: nil)))
        XCTAssertEqual(TerminalPathLinks.action(for: "/etc/hosts:1", folder: folder, folderRealPath: nil), .none)
    }

    func testMissingFileOrDirectoryIsNoLink() {
        XCTAssertNil(resolve("Sources/Missing.swift:3"))
        XCTAssertNil(resolve("Sources:3"))
    }

    func testURLIsNoPathLink() {
        XCTAssertNil(resolve("http://host:80"))
        XCTAssertNil(resolve("https://example.com/Sources/A.swift:12"))
        XCTAssertNil(resolve("file:///etc/hosts:1"))
    }

    func testPathWithoutALineOrWithLineZeroIsNoLink() {
        XCTAssertNil(resolve("Sources/A.swift"))
        XCTAssertNil(resolve("Sources/A.swift:0"))
        XCTAssertNil(resolve("Sources/A.swift:x"))
        XCTAssertNil(resolve(""))
    }

    func testTrailingPunctuationIsNotPartOfTheLink() {
        XCTAssertEqual(resolve("Sources/A.swift:12,"), .init(path: "Sources/A.swift", line: 12, col: nil))
        XCTAssertEqual(resolve("(x/y.go:3:7)."), .init(path: "x/y.go", line: 3, col: 7))
    }

    func testURLsAreRecognised() {
        XCTAssertTrue(TerminalPathLinks.isURL("http://host:80"))
        XCTAssertTrue(TerminalPathLinks.isURL("mailto:a@example.com"))
        XCTAssertFalse(TerminalPathLinks.isURL("Sources/A.swift:12"))
        XCTAssertFalse(TerminalPathLinks.isURL("A.swift:12"), "a file name is not a URL scheme")
    }

    // MARK: - The candidate around a click

    func testCandidateAroundAClickInABareToken() {
        let line = "error at Sources/A.swift:12: boom"
        XCTAssertEqual(TerminalPathLinks.candidate(inLine: line, at: 12), "Sources/A.swift:12:")
        XCTAssertNil(TerminalPathLinks.candidate(inLine: line, at: 8), "a space is no candidate")
    }

    func testCandidateAroundAClickInAQuotedPath() {
        let line = "see \"a b.txt:1\" here"
        XCTAssertEqual(TerminalPathLinks.candidate(inLine: line, at: 7), "\"a b.txt:1\"")
        let suffixed = "see 'a b.txt':4 here"
        XCTAssertEqual(TerminalPathLinks.candidate(inLine: suffixed, at: 6), "'a b.txt':4")
    }

    func testCandidateResolvesAfterTrimming() {
        let line = "error at Sources/A.swift:12: boom"
        let candidate = TerminalPathLinks.candidate(inLine: line, at: 12)
        XCTAssertEqual(candidate.flatMap(resolve), .init(path: "Sources/A.swift", line: 12, col: nil))
    }

    func testCandidateOutsideTheLineIsNil() {
        XCTAssertNil(TerminalPathLinks.candidate(inLine: "abc", at: 10))
        XCTAssertNil(TerminalPathLinks.candidate(inLine: "abc", at: -1))
    }

    // MARK: - Wrapped rows (board #361)

    private func row(_ text: String, _ continuesAbove: Bool = false) -> TerminalPathLinks.Row {
        .init(text: text, continuesAbove: continuesAbove)
    }

    /// A path wrapped over two rows is clicked whole, from either row.
    func testAWrappedPathIsJoinedBack() throws {
        let rows = [row("$ ls      "), row("see Sourc"), row("es/A.swift", true), row(":12 done  ", true), row("next      ")]
        let fromFirst = try XCTUnwrap(TerminalPathLinks.logicalLine(rows: rows, row: 1, column: 6))
        XCTAssertEqual(fromFirst.line, "see Sources/A.swift:12 done")
        XCTAssertEqual(TerminalPathLinks.candidate(inLine: fromFirst.line, at: fromFirst.column), "Sources/A.swift:12")
        let fromLast = try XCTUnwrap(TerminalPathLinks.logicalLine(rows: rows, row: 3, column: 1))
        XCTAssertEqual(fromLast.column, 20)
        XCTAssertEqual(TerminalPathLinks.candidate(inLine: fromLast.line, at: fromLast.column), "Sources/A.swift:12")
        let alone = try XCTUnwrap(TerminalPathLinks.logicalLine(rows: rows, row: 4, column: 0))
        XCTAssertEqual(alone.line, "next", "an unwrapped row is its own line, trailing blanks dropped")
        XCTAssertNil(TerminalPathLinks.logicalLine(rows: rows, row: 5, column: 0))
    }

    /// A wide character takes two cells: the column after it still lands
    /// on the clicked character, and the spill never reaches the path.
    func testAWideCharacterKeepsTheColumns() throws {
        let spill = String(TerminalPathLinks.wideSpill)
        let rows = [row("界\(spill) \"a 界\(spill).txt\":3")]
        let hit = try XCTUnwrap(TerminalPathLinks.logicalLine(rows: rows, row: 0, column: 6))
        XCTAssertEqual(TerminalPathLinks.candidate(inLine: hit.line, at: hit.column), "\"a 界.txt\":3")
    }

    /// Right-to-left text may be drawn reordered: no screen column names a
    /// character of it, so nothing is looked up.
    func testALineWithRightToLeftTextIsNoHit() {
        XCTAssertNil(TerminalPathLinks.logicalLine(rows: [row("שלום a.swift:1")], row: 0, column: 6))
        XCTAssertNil(TerminalPathLinks.logicalLine(rows: [row("a.swift:1 مرحبا")], row: 0, column: 2))
    }
}
