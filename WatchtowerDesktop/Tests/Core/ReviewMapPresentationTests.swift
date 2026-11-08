import XCTest
@testable import WatchtowerCore

/// Board #1025, Task 12: the branch review's words over the map and the run.
final class ReviewMapPresentationTests: XCTestCase {
    private typealias Pres = ReviewMapPresentation

    private func chapter(
        _ key: String,
        level: ReviewDangerLevel = .normal,
        paths: [String] = ["a/1"],
        lines: Int = 10,
        lane: String? = nil,
        target: Int64? = nil,
        jira: String? = nil,
        signals: [String: Int] = [:]
    ) -> ReviewMap.Chapter {
        ReviewMap.Chapter(key: key, title: key, level: level, core: false, paths: paths, changedLines: lines,
                          lane: lane, targetId: target, jiraKey: jira, signalsSummary: signals)
    }

    func testFileBadgeIsTheMostDangerousKnownSignalOnADangerousFileOnly() {
        let file = ReviewMap.File(path: "x.go", chapter: "dir:", level: .breaking,
                                  signals: ["security_path", "api_removed"], lane: nil, also: [])
        XCTAssertEqual(Pres.fileBadge(file), "API removed")
        let normal = ReviewMap.File(path: "y.go", chapter: "dir:", level: .normal, signals: ["ci"], lane: nil, also: [])
        XCTAssertNil(Pres.fileBadge(normal), "a normal file has no badge")
        let unknown = ReviewMap.File(path: "z.go", chapter: "dir:", level: .significant, signals: ["new_kind"], lane: nil, also: [])
        XCTAssertNil(Pres.fileBadge(unknown))
    }

    func testChapterHintAndSignalsLineFollowTheDangerOrder() {
        let c = chapter("lane:x", level: .breaking, signals: ["migration_edited": 1, "api_removed": 2, "unknown": 4])
        XCTAssertEqual(Pres.chapterHint(c), "public API removed · migration edited")
        XCTAssertEqual(Pres.signalsLine(c), "public API removed (2), migration edited (1)")
        XCTAssertEqual(Pres.chapterHint(chapter("dir:a")), "")
    }

    func testLaneCaption() {
        XCTAssertEqual(Pres.laneCaption(chapter("lane:tn/g7", lane: "tn/g7"), files: []), "tn/g7")
        XCTAssertEqual(Pres.laneCaption(chapter("lane:a", lane: "a", jira: "ACME-412"), files: []), "ACME-412")
        XCTAssertEqual(Pres.laneCaption(chapter("lane:a", lane: "a", target: 219, jira: "ACME-1"), files: []), "#219")
        XCTAssertEqual(Pres.laneCaption(chapter("dir:internal/digest"), files: []), "package · no lane")
        XCTAssertEqual(Pres.laneCaption(chapter("agent:1"), files: []), "by the agent")
        let shared = ReviewMap.File(path: "a/1", chapter: "lane:tn/g9", level: .normal, signals: [], lane: "tn/g9",
                                    also: ["tn/g7", "tn/g9"])
        XCTAssertEqual(Pres.laneCaption(chapter("lane:tn/g9", lane: "tn/g9"), files: [shared]), "tn/g9 also tn/g7")
    }

    func testNumbersAreGroupedWhateverTheLocale() {
        XCTAssertEqual(Pres.lines(1840), "1,840 lines")
        XCTAssertEqual(Pres.lines(1), "1 line")
        XCTAssertEqual(Pres.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(Pres.grouped(999), "999")
        XCTAssertEqual(Pres.counterLine(chapters: 11, files: 396), "11 chapters / 396 files left")
        XCTAssertEqual(Pres.counterLine(chapters: 1, files: 1), "1 chapter / 1 file left")
        XCTAssertEqual(Pres.canSkipDetail(chapter("collapsed", paths: ["a", "b"], lines: 9870)), "2 files · 9,870 lines")
    }

    func testRunLine() {
        XCTAssertEqual(Pres.runLine(nil, summary: .running, waitingFor: nil), .none)
        XCTAssertEqual(Pres.runLine(.running, summary: .running, waitingFor: nil), .describing)
        XCTAssertEqual(Pres.runLine(.waiting, summary: .waiting, waitingFor: "agent"),
                       .beingDescribedElsewhere("Being described by the agent's run"))
        XCTAssertEqual(Pres.text(Pres.runLine(.queued, summary: .running, waitingFor: nil)), "Queued — Retry runs after the current run")
        XCTAssertEqual(Pres.runLine(.cached, summary: .ok, waitingFor: nil), .described)
        XCTAssertEqual(Pres.runLine(.notStarted, summary: .ok, waitingFor: nil), .notDescribed)
        let failed = ChapterRunState.failed(text: "The overview of “x” did not finish in 3 min.", detail: "deadline")
        XCTAssertEqual(Pres.runLine(failed, summary: .running, waitingFor: nil),
                       .failed(text: "The overview of “x” did not finish in 3 min.", detail: "deadline"))
        XCTAssertEqual(Pres.runLine(failed, summary: .ok, waitingFor: nil),
                       .failed(text: "Not described — not covered by the summary", detail: "deadline"),
                       "once the summary is in, it does not cover the chapter")
    }

    func testProgressWhileRunning() throws {
        let keys = ["a", "b", "c", "d", "e"]
        let states: [String: ChapterRunState] = ["a": .ok, "b": .cached, "c": .running, "d": .running, "e": .queued]
        let card = try XCTUnwrap(Pres.progress(keys: keys, states: states, summary: .running, waiting: nil))
        XCTAssertEqual(card.title, "Describing chapters — 2 of 5 done")
        XCTAssertEqual(card.body, "Summary waits for 3 chapters (2 describing, 1 queued). Chapters fill in as they finish.")
        XCTAssertEqual(card.remaining, 0)
    }

    func testProgressWhileWaitingForAnotherRun() throws {
        let waiting = "The agent is describing this branch — chapters appear as it finishes them"
        let card = try XCTUnwrap(Pres.progress(keys: ["a", "b"], states: ["a": .cached, "b": .waiting], summary: .waiting,
                                               waiting: waiting))
        XCTAssertEqual(card.title, "The agent is describing this branch — chapters appear as it finishes them")
        XCTAssertEqual(card.body, "1 of 2 done.")
    }

    func testProgressWritingTheSummary() throws {
        let card = try XCTUnwrap(Pres.progress(keys: ["a"], states: ["a": .ok], summary: .running, waiting: nil))
        XCTAssertEqual(card.title, "Writing the summary")
        XCTAssertEqual(card.body, "The chapter is described.")
        XCTAssertTrue(card.running)
    }

    func testProgressAfterTheRunCountsFailedAndNotReached() throws {
        let failed = ChapterRunState.failed(text: "x", detail: nil)
        let states: [String: ChapterRunState] = ["a": .ok, "b": failed, "c": .notStarted, "d": .notStarted]
        let card = try XCTUnwrap(Pres.progress(keys: ["a", "b", "c", "d"], states: states, summary: .ok, waiting: nil))
        XCTAssertEqual(card.title, "Summary ready")
        XCTAssertEqual(card.body, "1 chapter failed, 2 were not reached · they are listed as not covered.")
        XCTAssertEqual(card.remaining, 2)
        XCTAssertFalse(card.running, "a settled card has no spinner")
        XCTAssertEqual(Pres.describeRemainingTitle(card.remaining), "Describe 2 remaining")
        let clean = try XCTUnwrap(Pres.progress(keys: ["a"], states: ["a": .cached], summary: .cached, waiting: nil))
        XCTAssertNil(clean.body)
        XCTAssertFalse(clean.running)
    }

    func testNotDescribedIsAFailedOrUnreachedChapter() {
        XCTAssertTrue(Pres.notDescribed(.failed(text: "x", detail: nil)))
        XCTAssertTrue(Pres.notDescribed(.notStarted))
        for state: ChapterRunState? in [nil, .pending, .running, .queued, .ok, .cached] {
            XCTAssertFalse(Pres.notDescribed(state), "\(String(describing: state))")
        }
    }

    func testNoCardBeforeARunOrOnASummaryFailure() {
        XCTAssertNil(Pres.progress(keys: ["a"], states: [:], summary: .pending, waiting: nil))
        XCTAssertNil(Pres.progress(keys: ["a"], states: ["a": .ok], summary: .failed(text: "s", detail: nil), waiting: nil))
    }

    func testNotCoveredLineVariants() {
        XCTAssertNil(Pres.notCoveredLine(failed: 0, notReached: 0))
        XCTAssertEqual(Pres.notCoveredLine(failed: 1, notReached: 0), "1 chapter failed · it is listed as not covered.")
        XCTAssertEqual(Pres.notCoveredLine(failed: 0, notReached: 3), "3 chapters were not reached · they are listed as not covered.")
        XCTAssertEqual(Pres.notCoveredLine(failed: 0, notReached: 1), "1 chapter was not reached · it is listed as not covered.")
    }

    func testSummaryFailedLine() {
        XCTAssertEqual(Pres.summaryFailedLine(described: 13, total: 13), "All 13 chapters are described — open Chapters to read them.")
        XCTAssertEqual(Pres.summaryFailedLine(described: 4, total: 13), "4 of 13 chapters are described — open Chapters to read them.")
    }
}
