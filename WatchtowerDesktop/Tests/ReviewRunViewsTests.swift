import SwiftUI
import ViewInspector
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// Board #1025, Task 12: a failed chapter or summary shows its one sentence;
/// the provider's own text only after **Provider's message** is opened.
@MainActor
final class ReviewRunViewsTests: XCTestCase {
    private var fixtures: [ReviewFixture] = []

    override func tearDown() {
        fixtures.forEach { $0.cleanUp() }
        fixtures = []
        super.tearDown()
    }

    private let sentence = "The AI provider failed on “cmd”."
    private let detail = "HTTP 529 overloaded_error"

    private static let files: [ReviewFixture.File] = [.init(path: "cmd/x.go"), .init(path: "pkg/y.go")]

    /// A Deep round of `cmd` and `pkg` whose streamed run ends with `lines`.
    private func fixture(phase: String, lines: [String]) throws -> ReviewFixture {
        let f = try ReviewFixture(files: Self.files, mode: "deep", phase: phase, stream: lines)
        fixtures.append(f)
        f.openNow()
        let deadline = Date().addingTimeInterval(5)
        while f.model.overview == .loading || f.model.overview == .idle, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return f
    }

    private var envelope: String {
        #"{"ok":true,"overview":{"summary":"","coverage":[],"risk":[],"chapters":[],"incomplete":[]}}"#
    }

    func testFailedChapterShowsItsSentenceAndFoldsTheProvidersText() throws {
        let failed = #"{"event":"chapter","key":"dir:cmd","state":"failed","#
            + #""error":{"class":"provider","text":"\#(sentence)","detail":"\#(detail)"}}"#
        let f = try fixture(phase: "chapters", lines: [failed, envelope])
        guard case .ready(let map) = f.model.map, let chapter = map.chapters.first(where: { $0.key == "dir:cmd" }) else {
            return XCTFail("the map did not load")
        }
        XCTAssertEqual(f.model.chapterStates["dir:cmd"], .failed(text: sentence, detail: detail))
        let header = try ReviewChapterHeader(model: f.model, chapter: chapter, map: map).inspect()
        XCTAssertNoThrow(try header.find(text: sentence))
        XCTAssertThrowsError(try header.find(text: detail), "the provider's text is folded by default")
        XCTAssertNoThrow(try header.find(button: "Retry"))
    }

    func testFailedSummaryShowsItsSentenceAndFoldsTheProvidersText() throws {
        let summary = #"{"event":"summary","state":"failed","#
            + #""error":{"class":"timeout","text":"The summary did not finish in 2 min.","detail":"\#(detail)"}}"#
        let ok = #"{"event":"chapter","key":"dir:cmd","state":"ok","what":"Flags.","risks":[]}"#
        let ok2 = #"{"event":"chapter","key":"dir:pkg","state":"ok","what":"Locks.","risks":[]}"#
        let f = try fixture(phase: "meaning", lines: [ok, ok2, summary, envelope])
        let view = try ReviewOverviewView(model: f.model).inspect()
        XCTAssertNoThrow(try view.find(text: "The summary did not finish in 2 min."))
        XCTAssertNoThrow(try view.find(text: "All 2 chapters are described — open Chapters to read them."))
        XCTAssertThrowsError(try view.find(text: detail), "the provider's text is folded by default")
        XCTAssertNoThrow(try view.find(button: "Retry"))
    }

    func testProvidersTextShowsOnlyOnceTheDisclosureIsOpened() throws {
        var open = false
        let expanded = Binding(get: { open }, set: { open = $0 })
        let folded = ReviewFailureNotice(text: sentence, detail: detail, retry: {}, expanded: expanded)
        XCTAssertNoThrow(try folded.inspect().find(text: sentence))
        XCTAssertThrowsError(try folded.inspect().find(text: detail))
        try folded.inspect().find(button: "Provider's message").tap()
        XCTAssertTrue(open)
        let opened = ReviewFailureNotice(text: sentence, detail: detail, retry: {}, expanded: expanded)
        XCTAssertNoThrow(try opened.inspect().find(text: detail))
    }

    func testANoticeWithoutDetailHasNoDisclosure() throws {
        let notice = ReviewFailureNotice(text: sentence, detail: nil) {}
        XCTAssertThrowsError(try notice.inspect().find(button: "Provider's message"))
    }

    /// A later round's Since view lists part of the map: the counter and Next
    /// see only the listed chapters.
    func testCounterAndNextSeeOnlyTheChaptersInView() {
        func chapter(_ key: String, _ paths: [String]) -> ReviewMap.Chapter {
            ReviewMap.Chapter(key: key, title: key, level: .breaking, core: false, paths: paths, changedLines: 1,
                              lane: nil, targetId: nil, jiraKey: nil, signalsSummary: [:])
        }
        func file(_ path: String, _ key: String) -> ReviewMap.File {
            ReviewMap.File(path: path, chapter: key, level: .breaking, signals: [], lane: nil, also: [])
        }
        let map = ReviewMap(
            chapters: [chapter("hidden", ["h.go"]), chapter("shown", ["s.go", "h2.go"])],
            files: [file("h.go", "hidden"), file("s.go", "shown"), file("h2.go", "shown")]
        )
        let visible = ReviewChapterListView.visible(map, chapters: ["shown"], paths: ["s.go"])
        XCTAssertEqual(visible.chapters.map(\.key), ["shown"])
        XCTAssertEqual(visible.files.map(\.path), ["s.go"])
        XCTAssertEqual(ReviewChapterList.next(map: visible) { _ in false }, "shown", "never the hidden chapter")
    }
}
