import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// "Where is it used?"'s searches (ruling R45): one per workbench, a newer
/// one or a cancel silences the older, the locations capped.
@MainActor
final class CodeQuestionUsageSearchesTests: XCTestCase {
    private final class Handle: CodeSearchCancelling {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    private struct Started {
        let options: CodeSearchOptions
        let handle: Handle
        let onMatch: @MainActor (CodeSearchMatch) -> Void
        let onDone: @MainActor (CodeSearchRun.Outcome) -> Void
    }

    private var started: [Started] = []

    private func makeSearches() -> CodeQuestionUsageSearches {
        CodeQuestionUsageSearches { [unowned self] _, options, onMatch, onDone in
            let handle = Handle()
            started.append(Started(options: options, handle: handle, onMatch: onMatch, onDone: onDone))
            return handle
        }
    }

    private func match(_ line: Int) -> CodeSearchMatch {
        CodeSearchMatch(path: "a.go", line: line, col: 1, text: "load()", textCol: 1, before: [], after: [])
    }

    private let folder = URL(fileURLWithPath: "/tmp/acme")

    func testASearchReportsItsLocationsOnce() throws {
        let searches = makeSearches()
        var results: [CodeQuestionUsages?] = []
        searches.start(name: "load", folder: folder, workbenchID: 1) { results.append($0) }
        let run = try XCTUnwrap(started.first)
        XCTAssertEqual(run.options.query, "load")
        XCTAssertTrue(run.options.word)
        XCTAssertTrue(run.options.caseSensitive)
        XCTAssertTrue(searches.isRunning(1))
        run.onMatch(match(3))
        run.onDone(.finished(CodeSearchDone(files: 1, matches: 1, truncated: false)))
        run.onDone(.finished(CodeSearchDone(files: 1, matches: 1, truncated: false)))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first??.locations.map(\.line), [3])
        XCTAssertFalse(searches.isRunning(1))
    }

    func testANewerSearchOrACancelSilencesTheOlder() throws {
        let searches = makeSearches()
        var results: [String?] = []
        searches.start(name: "old", folder: folder, workbenchID: 1) { results.append($0?.name) }
        searches.start(name: "new", folder: folder, workbenchID: 1) { results.append($0?.name) }
        XCTAssertTrue(started[0].handle.cancelled, "the older search is killed")
        started[0].onDone(.finished(CodeSearchDone(files: 0, matches: 0, truncated: false)))
        XCTAssertEqual(results, [])
        searches.start(name: "other", folder: folder, workbenchID: 2) { results.append($0?.name) }
        searches.cancelAll()
        XCTAssertTrue(started[1].handle.cancelled)
        XCTAssertTrue(started[2].handle.cancelled)
        started[1].onDone(.failed("killed"))
        XCTAssertEqual(results, [], "nothing after a cancel")
    }

    func testAFailedSearchReportsNil() throws {
        let searches = makeSearches()
        var results: [CodeQuestionUsages?] = []
        searches.start(name: "load", folder: folder, workbenchID: 1) { results.append($0) }
        started[0].onDone(.failed("no index"))
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0])
    }

    /// The locations stop at the cap; the result says it was cut.
    func testLocationsAreCapped() throws {
        let searches = makeSearches()
        var result: CodeQuestionUsages?
        searches.start(name: "load", folder: folder, workbenchID: 1) { result = $0 }
        for line in 1...(CodeQuestionUsages.limit + 5) { started[0].onMatch(match(line)) }
        started[0].onDone(.finished(CodeSearchDone(files: 1, matches: 35, truncated: false)))
        XCTAssertEqual(result?.locations.count, CodeQuestionUsages.limit)
        XCTAssertEqual(result?.truncated, true)
    }
}
