import XCTest
@testable import WatchtowerCore

/// The reviewer beside Branch review (board #1025, tech spec §6): the thread
/// key, the draft-only spec that reads the round's folder, and the compact
/// per-turn branch map.
@MainActor
final class ReviewerSurfaceTests: XCTestCase {
    private func round(branch: String = "", source: String = "session") throws -> ReviewRoundInfo {
        let json = """
        {"id":3,"status":"open","mode":"deep","folderRoot":"/tmp/acme-wt","baseSha":"b","baseLabel":"origin/main",
         "treeSha":"t3","prevRoundId":0,"prevTreeSha":"","prevTreeLost":false,"source":"\(source)","branch":"\(branch)"}
        """
        return try JSONDecoder().decode(ReviewRoundInfo.self, from: Data(json.utf8))
    }

    // MARK: - Thread key

    func testThreadKeyIsTheRoundBranchWhenSet() throws {
        let folder = WorkbenchGitStatus(branch: "main")
        let key = ReviewerSurface.threadBranch(round: try round(branch: "feature/tip", source: "pr"),
                                               folderStatus: folder, sessionID: 9)
        XCTAssertEqual(key, "feature/tip", "a branch-tip round names its branch, whatever the folder is on")
    }

    func testThreadKeyFallsBackToTheFoldersBranch() throws {
        let folder = WorkbenchGitStatus(branch: "feature/registry")
        XCTAssertEqual(ReviewerSurface.threadBranch(round: try round(), folderStatus: folder, sessionID: 9), "feature/registry")
        XCTAssertEqual(ReviewerSurface.threadBranch(round: nil, folderStatus: folder, sessionID: 9), "feature/registry")
    }

    func testTwoSessionsOnOneBranchShareTheKey() throws {
        let folder = WorkbenchGitStatus(branch: "feature/registry")
        let first = ReviewerSurface.threadBranch(round: try round(), folderStatus: folder, sessionID: 1)
        let second = ReviewerSurface.threadBranch(round: try round(), folderStatus: folder, sessionID: 2)
        XCTAssertEqual(first, second)
        XCTAssertEqual(ReviewerSurface.contextID(projectID: 4, branch: try XCTUnwrap(first)), "4:feature/registry")
    }

    func testDetachedHeadKeysByTheSession() throws {
        let detached = WorkbenchGitStatus(branch: "", detached: true, head: "abc1234")
        XCTAssertEqual(ReviewerSurface.threadBranch(round: try round(), folderStatus: detached, sessionID: 9), "session:9")
        let noBranch = WorkbenchGitStatus(git: false)
        XCTAssertEqual(ReviewerSurface.threadBranch(round: nil, folderStatus: noBranch, sessionID: 9), "session:9")
    }

    func testNoKeyWhileTheFoldersStatusIsUnknown() throws {
        XCTAssertNil(ReviewerSurface.threadBranch(round: try round(), folderStatus: nil, sessionID: 9))
    }

    // MARK: - Spec

    private let context = ReviewerSurface.Context(
        projectID: 4, branch: "feature/registry", branchLabel: "feature/registry",
        readFolder: "/tmp/acme-wt", inWorktree: true
    )

    func testSpecIsDraftOnlyAndReadsTheRoundsFolder() {
        let spec = ReviewerSurface.spec(context: context, conversationID: 11, reader: { .claudeTools }, map: { .empty })
        XCTAssertEqual(spec.toolAccess, .draftOnly)
        XCTAssertNil(spec.toolAccess.toolMode(key: spec.key, turnID: "t"), "no Watchtower tools (AGENT-04)")
        XCTAssertEqual(spec.persistence, .database(conversationID: 11))
        XCTAssertEqual(spec.key, EmbeddedChatKey(contextType: "review_reviewer", contextID: "4:feature/registry", conversationID: 11))
        XCTAssertEqual(spec.runOptions(), ChatRunOptions(readFolder: "/tmp/acme-wt"))
        XCTAssertTrue(spec.ownerInstructions)
    }

    func testAProviderThatCannotReadRunsWithoutTheFolder() {
        let spec = ReviewerSurface.spec(context: context, conversationID: 11, reader: { .none }, map: { .empty })
        XCTAssertNil(spec.runOptions().readFolder)
        XCTAssertTrue(spec.systemPrompt().contains("You cannot read any file"))
    }

    func testSystemPromptSaysItIsNotTheAuthor() {
        let prompt = ReviewerSurface.systemPrompt(context: context, reader: .codexSandbox)
        XCTAssertTrue(prompt.contains("\"feature/registry\""))
        XCTAssertTrue(prompt.contains("never talk to it"))
        XCTAssertTrue(prompt.contains("read-only sandbox"))
    }

    /// Each turn carries the map as it is when the turn starts: the chapter
    /// open on screen then.
    func testEachTurnCarriesTheMapOfThatMoment() {
        var open = "dir:a"
        let chapters: [ReviewerMapInput.Chapter] = [
            .init(key: "dir:a", title: "Capability table", level: "breaking", paths: ["a/caps.go"]),
            .init(key: "dir:b", title: "Fallback chain", level: "", paths: ["b/fallback.go"])
        ]
        let input = {
            ReviewerMapInput(chapters: chapters, summary: "Moves capabilities into a table.", openChapterKey: open)
        }
        let spec = ReviewerSurface.spec(context: context, conversationID: 11, reader: { .claudeTools }, map: { input() })
        let turn = { spec.turnPrompt(ChatTurnInput(text: "What breaks?", previousOwnerMessageAt: nil, turnID: "t")) }
        XCTAssertTrue(turn().contains("Open on the owner's screen: Capability table (dir:a)"))
        XCTAssertTrue(turn().hasSuffix("=== THE OWNER'S QUESTION ===\nWhat breaks?"))
        open = "dir:b"
        XCTAssertTrue(turn().contains("Open on the owner's screen: Fallback chain (dir:b)"))
    }

    func testMapLine() {
        XCTAssertEqual(ReviewerSurface.mapLine(context, reader: .claudeTools),
                       "Read-only · reads feature/registry in the session's worktree · sees the chapters, their danger"
                       + " and the summary · never talks to the author's session")
        let folder = ReviewerSurface.Context(projectID: 4, branch: "session:9", branchLabel: "", readFolder: "/tmp/acme",
                                             inWorktree: false)
        XCTAssertTrue(ReviewerSurface.mapLine(folder, reader: .codexSandbox)
            .hasPrefix("Read-only · reads this branch in the workbench folder"))
        XCTAssertTrue(ReviewerSurface.mapLine(context, reader: .none)
            .hasPrefix("Read-only · answers from the branch map only — this AI provider cannot read files"))
    }

    /// A branch-tip round's folder is on another branch: the line and the
    /// prompt say so instead of claiming the branch is read.
    func testBranchTipRoundSaysTheFolderIsNotTheBranch() {
        let tip = ReviewerSurface.Context(projectID: 4, branch: "feature/x", branchLabel: "feature/x", readFolder: "/tmp/acme",
                                          inWorktree: false, branchTip: true)
        XCTAssertTrue(ReviewerSurface.mapLine(tip, reader: .claudeTools)
            .hasPrefix("Read-only · reads the workbench folder, which is not on feature/x"))
        let codex = ReviewerSurface.systemPrompt(context: tip, reader: .codexSandbox)
        XCTAssertTrue(codex.contains("checked out on another branch, not on \"feature/x\""))
        XCTAssertTrue(codex.contains("git show feature/x:<path>"))
        XCTAssertTrue(ReviewerSurface.systemPrompt(context: tip, reader: .claudeTools).contains("checked out on another branch"))
        XCTAssertFalse(ReviewerSurface.systemPrompt(context: tip, reader: .none).contains("checked out on another branch"))
        XCTAssertFalse(ReviewerSurface.systemPrompt(context: context, reader: .codexSandbox).contains("checked out on another branch"))
    }

    // MARK: - Brief

    func testBriefListsDangerSummaryAndCountsTheSkippable() {
        let brief = ReviewerMapBrief.render(ReviewerMapInput(chapters: [
            .init(key: "lane:tn/g7", title: "Provider capability table", level: "breaking",
                  paths: ["internal/providers/capabilities.go", "internal/providers/registry.go"]),
            .init(key: "dir:internal/auth", title: "Token store", level: "significant",
                  paths: ["a.go", "b.go", "c.go", "d.go"]),
            .init(key: "collapsed", title: "Can skip", level: "", paths: ["go.sum", "gen.pb.go"])
        ], summary: "Providers come from a table.", openChapterKey: nil))
        XCTAssertTrue(brief.contains("3 chapters, 8 files"))
        XCTAssertTrue(brief.contains("Summary: Providers come from a table."))
        XCTAssertTrue(brief.contains(
            "- [breaking] Provider capability table (lane:tn/g7) — 2 files: internal/providers/capabilities.go, internal/providers/registry.go"))
        XCTAssertTrue(brief.contains("- [significant] Token store (dir:internal/auth) — 4 files: a.go, b.go, c.go (+1 more)"))
        XCTAssertTrue(brief.contains("- Can skip (generated, lock and vendored files): 2 files"))
        XCTAssertFalse(brief.contains("go.sum"), "the skippable files are counted, not listed")
        XCTAssertFalse(brief.contains("Open on the owner's screen"))
    }

    func testBriefWithoutASummarySaysSo() {
        XCTAssertTrue(ReviewerMapBrief.render(.empty).contains("Summary: none yet."))
    }

    /// A 700-file branch in 140 chapters with long titles and a long summary:
    /// the brief stays under its cap, keeps the most dangerous chapters (they
    /// come first) and counts the rest.
    func testBriefStaysUnderItsCapOnA700FileMap() {
        var chapters: [ReviewerMapInput.Chapter] = []
        for n in 0..<140 {
            let paths = (0..<5).map { "internal/package\(n)/subsystem/with/a/long/path/file\($0)_implementation.go" }
            chapters.append(.init(key: "dir:internal/package\(n)", title: String(repeating: "Chapter \(n) ", count: 20),
                                  level: n < 10 ? "breaking" : "normal", paths: paths))
        }
        let input = ReviewerMapInput(chapters: chapters, summary: String(repeating: "A long summary. ", count: 400),
                                     openChapterKey: "dir:internal/package3")
        let brief = ReviewerMapBrief.render(input)
        XCTAssertEqual(Set(chapters.flatMap(\.paths)).count, 700)
        XCTAssertLessThanOrEqual(brief.count, ReviewerMapBrief.maxCharacters)
        XCTAssertTrue(brief.contains("(dir:internal/package0)"), "the first (most dangerous) chapter is kept")
        XCTAssertTrue(brief.contains("Open on the owner's screen:"))
        XCTAssertTrue(brief.contains("more chapters not listed"))
    }
}
