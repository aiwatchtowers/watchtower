import XCTest
@testable import WatchtowerDesktop

/// Which folder a workbench html preview serves (#563): judged against the
/// tab's code root, so a session worktree under `<repo>/.claude/worktrees/`
/// previews its files while a hidden folder below a root does not.
final class CodeHTMLPreviewContentTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("preview-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    func testASessionWorktreeRootPreviewsItsFiles() throws {
        let worktree = repo.appendingPathComponent(".claude/worktrees/feature-x")
        let slides = worktree.appendingPathComponent("slides")
        try FileManager.default.createDirectory(at: slides, withIntermediateDirectories: true)
        for file in [worktree.appendingPathComponent("index.html"), slides.appendingPathComponent("deck.html")] {
            guard case let .file(served, folder) = CodeHTMLPreview.content(file, root: worktree) else {
                return XCTFail("\(file.lastPathComponent) in a worktree root is previewed")
            }
            XCTAssertEqual(served.lastPathComponent, file.lastPathComponent)
            XCTAssertEqual(folder.resolvingSymlinksInPath().path, file.deletingLastPathComponent().resolvingSymlinksInPath().path)
        }
    }

    func testAHiddenFolderBelowTheRootIsNotPreviewed() throws {
        let hidden = repo.appendingPathComponent(".github")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        guard case let .page(html) = CodeHTMLPreview.content(hidden.appendingPathComponent("a.html"), root: repo) else {
            return XCTFail("a hidden folder below the root is refused")
        }
        XCTAssertTrue(html.contains("Files in a hidden folder are not previewed."))
        // The same worktree judged against the main repo as root is hidden.
        let worktree = repo.appendingPathComponent(".claude/worktrees/feature-x")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        guard case .page = CodeHTMLPreview.content(worktree.appendingPathComponent("index.html"), root: repo) else {
            return XCTFail("against the main repo the worktree is a hidden folder")
        }
    }
}
