import XCTest
@testable import WatchtowerCore

/// The Branch review identity bar's lines and the header Review button rule.
final class ReviewIdentityPresentationTests: XCTestCase {
    private typealias Identity = ReviewIdentityPresentation

    private func round(baseLabel: String, baseSha: String = "abc123") throws -> ReviewRoundInfo {
        let json = """
        {"id":1,"status":"open","mode":"quick","folderRoot":"/tmp/acme","baseSha":"\(baseSha)",
         "baseLabel":"\(baseLabel)","treeSha":"t1","prevRoundId":0,"prevTreeSha":"","prevTreeLost":false}
        """
        return try JSONDecoder().decode(ReviewRoundInfo.self, from: Data(json.utf8))
    }

    private func files(_ pairs: [(Int, Int)]) -> [ReviewDiffFile] {
        pairs.enumerated().map { ReviewDiffFile(path: "f\($0.offset).go", additions: $0.element.0, deletions: $0.element.1) }
    }

    func testWorktreeBranchAgainstMain() throws {
        let status = WorkbenchGitStatus(branch: "feature/x", dirty: true, changes: 2)
        let place = SessionPlace.worktree(name: "x", root: URL(fileURLWithPath: "/tmp/acme-x"), status: status)
        let list = files([(100, 20), (50, 10), (62, 10)] + Array(repeating: (0, 0), count: 5))
        let line = Identity.branchLine(place: place, status: status, round: try round(baseLabel: "origin/main"),
                                       files: list, stale: false)
        XCTAssertEqual(line.branch, "feature/x")
        XCTAssertEqual(line.base, "main")
        XCTAssertEqual(line.baseHelp, "abc123")
        XCTAssertEqual(line.place, "worktree x")
        XCTAssertEqual(line.size, "8 files · +212 −40")
        XCTAssertEqual(line.uncommitted, "2 uncommitted")
        XCTAssertFalse(line.onDefaultBranch)
    }

    func testSingleFileSizeIsSingular() throws {
        let status = WorkbenchGitStatus(branch: "feature/x")
        let line = Identity.branchLine(place: .main, status: status, round: try round(baseLabel: "origin/main"),
                                       files: files([(3, 1)]), stale: false)
        XCTAssertEqual(line.size, "1 file · +3 −1")
        XCTAssertNil(line.uncommitted)
    }

    func testOnTheDefaultBranch() throws {
        // HEAD is the base commit: nothing committed past it.
        let status = WorkbenchGitStatus(branch: "main", head: "abc1234")
        let line = Identity.branchLine(place: .main, status: status,
                                       round: try round(baseLabel: "origin/main", baseSha: "abc1234def5678"),
                                       files: files([(1, 1)]), stale: false)
        XCTAssertTrue(line.onDefaultBranch)
        XCTAssertNil(line.base)
        XCTAssertEqual(line.size, "On main — only uncommitted edits are reviewed")
        XCTAssertEqual(Identity.emptyDescription(line), "No uncommitted edits in the main folder.")

        let noRound = Identity.branchLine(place: .main, status: status, round: nil, files: [], stale: false)
        XCTAssertTrue(noRound.onDefaultBranch)
        XCTAssertEqual(noRound.size, "On main — only uncommitted edits are reviewed")
    }

    func testMainAheadOfOriginShowsTheBranchLine() throws {
        let status = WorkbenchGitStatus(branch: "main", head: "fff0001", ahead: 2)
        let line = Identity.branchLine(place: .main, status: status,
                                       round: try round(baseLabel: "origin/main", baseSha: "abc1234def5678"),
                                       files: files([(3, 1)]), stale: false)
        XCTAssertFalse(line.onDefaultBranch)
        XCTAssertEqual(line.base, "main")
        XCTAssertEqual(line.size, "1 file · +3 −1")
        XCTAssertEqual(Identity.emptyDescription(line), "No commits past main and no uncommitted edits.")

        let noRound = Identity.branchLine(place: .main, status: status, round: nil, files: [], stale: false)
        XCTAssertFalse(noRound.onDefaultBranch)
        XCTAssertNil(noRound.size)
    }

    func testUnknownPlaceReadsAsMainFolder() {
        let status = WorkbenchGitStatus(branch: "feature/x")
        XCTAssertEqual(Identity.branchLine(place: .unknown, status: status, round: nil, files: [], stale: false).place, "main folder")
        XCTAssertEqual(Identity.branchLine(place: .main, status: status, round: nil, files: [], stale: false).place, "main folder")
        XCTAssertEqual(Identity.branchLine(place: .removed(name: "x", path: "/tmp/gone"), status: nil, round: nil,
                                           files: [], stale: false).place, "worktree removed")
    }

    func testDetachedHeadAndEmptyBase() throws {
        let status = WorkbenchGitStatus(detached: true, head: "abc1234")
        let line = Identity.branchLine(place: .main, status: status, round: try round(baseLabel: "", baseSha: ""),
                                       files: [], stale: false)
        XCTAssertEqual(line.branch, "detached at abc1234")
        XCTAssertNil(line.base)
        XCTAssertEqual(line.baseHelp, "empty tree")
        XCTAssertNil(line.size)
        XCTAssertFalse(line.onDefaultBranch)
    }

    func testStatusPicksTheWorktreesOwn() {
        let main = WorkbenchGitStatus(branch: "main")
        let own = WorkbenchGitStatus(branch: "feature/x")
        let wt = SessionPlace.worktree(name: "x", root: URL(fileURLWithPath: "/tmp/acme-x"), status: own)
        XCTAssertEqual(Identity.status(place: wt, mainStatus: main), own)
        XCTAssertEqual(Identity.status(place: .main, mainStatus: main), main)
        XCTAssertEqual(Identity.status(place: .unknown, mainStatus: main), main)
        XCTAssertNil(Identity.status(place: .main, mainStatus: nil))
    }

    func testForLine() {
        XCTAssertNil(Identity.forLine([]))
        let items = (1...3).map { ReviewContextItem(targetId: Int64($0), text: "t\($0)") }
        let line = Identity.forLine(items)
        XCTAssertEqual(line?.first, items[0])
        XCTAssertEqual(line?.more, 2)
        XCTAssertEqual(Identity.forLine([items[0]])?.more, 0)
    }

    func testReviewButtonRule() {
        let feature = WorkbenchGitStatus(branch: "feature/x")
        let clean = WorkbenchGitStatus(branch: "main")
        let dirty = WorkbenchGitStatus(branch: "main", dirty: true, changes: 1)
        let detached = WorkbenchGitStatus(detached: true, head: "abc1234")
        XCTAssertTrue(Identity.showsReviewButton(isAgent: false, status: clean, paneOnScreen: true))
        XCTAssertFalse(Identity.showsReviewButton(isAgent: false, status: feature, paneOnScreen: false))
        XCTAssertFalse(Identity.showsReviewButton(isAgent: true, status: nil, paneOnScreen: false))
        XCTAssertTrue(Identity.showsReviewButton(isAgent: true, status: dirty, paneOnScreen: false))
        XCTAssertTrue(Identity.showsReviewButton(isAgent: true, status: detached, paneOnScreen: false))
        XCTAssertTrue(Identity.showsReviewButton(isAgent: true, status: feature, paneOnScreen: false))
        XCTAssertFalse(Identity.showsReviewButton(isAgent: true, status: clean, paneOnScreen: false))
        XCTAssertFalse(Identity.showsReviewButton(isAgent: true, status: WorkbenchGitStatus(branch: "master"), paneOnScreen: false))
    }

    func testReviewButtonShowsForUnpushedCommits() {
        let ahead = WorkbenchGitStatus(branch: "main", ahead: 2)
        XCTAssertTrue(Identity.showsReviewButton(isAgent: true, status: ahead, paneOnScreen: false))
    }

    func testDirtyWithZeroChangesShowsTheButton() {
        let dirty = WorkbenchGitStatus(branch: "main", dirty: true, changes: 0)
        XCTAssertTrue(Identity.showsReviewButton(isAgent: true, status: dirty, paneOnScreen: false))
    }
}
