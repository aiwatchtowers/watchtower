import XCTest
@testable import WatchtowerCore

/// The streamed overview, pinned by the Go golden `cmd/testdata/review-overview-stream.jsonl`
/// (copied byte for byte into `Fixtures/review-overview-stream.jsonl`).
final class ReviewOverviewStreamTests: XCTestCase {
    private func golden() throws -> Data {
        try ReviewMapTests.fixture("review-overview-stream.jsonl")
    }

    /// A compact, comparable form of an event.
    private func label(_ event: ReviewStreamEvent) -> String {
        switch event {
        case .map(let map): "map:\(map.chapters.count)"
        case .mapFailed: "mapFailed"
        case .waiting(let by): "waiting:\(by)"
        case .tick: "tick"
        case .chapter(let c): "chapter:\(c.key):\(c.state)"
        case let .summary(ok, _): "summary:\(ok)"
        case .final(let env): "final:\(env.ok)"
        case .finalUnreadable: "finalUnreadable"
        }
    }

    func testGoldenInOneRead() throws {
        var decoder = ReviewOverviewStreamDecoder()
        let events = decoder.feed(try golden())
        XCTAssertEqual(events.map(label), [
            "map:7",
            "chapter:dir:api:ok",
            "chapter:lane:ABC-1-login:ok",
            "chapter:dir::ok",
            "chapter:dir:internal/db/migrations:ok",
            "chapter:agent:1:ok",
            "chapter:lane:task-b:failed(text: \"The AI answer for “Payments lane” could not be read.\", detail: nil)",
            "summary:true",
            "final:true"
        ])
        guard case .chapter(let described) = events[1] else { return XCTFail("not a chapter") }
        XCTAssertEqual(described.what, "about dir:api")
        XCTAssertEqual(described.risks, [ReviewOverview.Risk(path: "api/api.go", level: .low, why: "check dir:api")])
        XCTAssertNil(described.error)
        guard case .chapter(let failed) = events[6] else { return XCTFail("not a chapter") }
        XCTAssertEqual(failed.error?.errorClass, "parse")
        guard case let .final(env) = events[8] else { return XCTFail("not the envelope") }
        XCTAssertEqual(env.incomplete, ["lane:task-b"])
        XCTAssertEqual(env.overview?.incomplete, ["lane:task-b"])
        XCTAssertEqual(env.overview?.chapters.map(\.key), [
            "dir:api", "lane:ABC-1-login", "dir:", "dir:internal/db/migrations", "agent:1", "lane:task-b", "collapsed"
        ])
        XCTAssertEqual(env.overview?.coverage.map(\.source), [.lane, .lane])
    }

    func testGoldenAcrossSplitReads() throws {
        let data = try golden()
        let whole: [String] = {
            var d = ReviewOverviewStreamDecoder()
            return d.feed(data).map(label)
        }()
        for size in [1, 7, 64, 333] {
            var decoder = ReviewOverviewStreamDecoder()
            var events: [String] = []
            var offset = 0
            while offset < data.count {
                let end = min(offset + size, data.count)
                events += decoder.feed(data.subdata(in: offset..<end)).map(label)
                offset = end
            }
            XCTAssertEqual(events, whole, "chunk size \(size)")
        }
    }

    func testTruncatedLastLineIsHeldNotDecoded() throws {
        var decoder = ReviewOverviewStreamDecoder()
        let events = decoder.feed(Data(#"{"event":"tick"}"# .utf8) + Data("\n".utf8) + Data(#"{"ok":true,"overv"#.utf8))
        XCTAssertEqual(events.map(label), ["tick"])
        // The rest of the line arrives: one envelope, nothing more.
        let rest = decoder.feed(Data(#"iew":{"summary":"s"}}"#.utf8) + Data("\n".utf8))
        XCTAssertEqual(rest.map(label), ["final:true"])
    }

    func testTruncatedLineNeverCompletedYieldsNothing() {
        var decoder = ReviewOverviewStreamDecoder()
        XCTAssertTrue(decoder.feed(Data(#"{"event":"chapter","key":"dir:a","sta"#.utf8)).isEmpty)
        XCTAssertTrue(decoder.feed(Data()).isEmpty)
    }

    func testTickAndUnknownLinesAreLife() {
        var decoder = ReviewOverviewStreamDecoder()
        let lines = [
            #"{"event":"tick"}"#,
            #"{"event":"progress","n":3}"#,
            "not json",
            #"{"event":"chapter","state":"ok"}"#
        ]
        let events = decoder.feed(Data((lines.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(events.map(label), ["tick", "tick", "tick", "tick"])
    }

    /// A recognised but malformed chapter line is a failure the owner sees, never a tick.
    func testMalformedChapterLinesFail() {
        var decoder = ReviewOverviewStreamDecoder()
        let generic = ReviewOverviewStreamDecoder.chapterFailedText
        let lines = [
            #"{"event":"chapter","key":"dir:a","state":"failed"}"#,
            #"{"event":"chapter","key":"dir:b","state":"failed","error":"not an object"}"#,
            #"{"event":"chapter","key":"dir:c","state":"thinking"}"#,
            #"{"event":"chapter","key":"dir:d"}"#,
            #"{"event":"chapter","key":"dir:e","state":"ok","what":"w","risks":[{"path":"a","level":"dire","why":"y"}]}"#,
            #"{"event":"chapter","key":"dir:f","state":"cached","what":7}"#
        ]
        let events = decoder.feed(Data((lines.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(events.count, lines.count)
        for (event, key) in zip(events, ["dir:a", "dir:b", "dir:c", "dir:d", "dir:e", "dir:f"]) {
            guard case .chapter(let chapter) = event else { return XCTFail("\(key): not a chapter") }
            XCTAssertEqual(chapter.key, key)
            XCTAssertEqual(chapter.state, .failed(text: generic, detail: nil), key)
            XCTAssertEqual(chapter.error, ReviewRunError(errorClass: "parse", text: generic), key)
            XCTAssertNil(chapter.what, key)
            XCTAssertEqual(chapter.risks, [], key)
        }
    }

    func testEmptyDescriptionReadsAsNil() {
        var decoder = ReviewOverviewStreamDecoder()
        let events = decoder.feed(Data((#"{"event":"chapter","key":"dir:a","state":"ok","what":"","risks":null}"# + "\n").utf8))
        guard case .chapter(let chapter) = events.first else { return XCTFail("not a chapter") }
        XCTAssertEqual(chapter.state, .ok)
        XCTAssertNil(chapter.what)
        XCTAssertEqual(chapter.risks, [])
    }

    func testUnreadableMapAndEnvelopeAreFailures() {
        var decoder = ReviewOverviewStreamDecoder()
        let lines = [
            #"{"event":"map","map":{"chapters":[{"key":"k"}]}}"#,
            #"{"event":"map"}"#,
            #"{"ok":true,"overview":{"summary":"s","risk":[{"path":"a","level":"dire","why":"y"}]}}"#
        ]
        let events = decoder.feed(Data((lines.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(events.map(label), ["mapFailed", "mapFailed", "finalUnreadable"])
    }

    func testMalformedSummaryFails() {
        var decoder = ReviewOverviewStreamDecoder()
        let lines = [
            #"{"event":"summary","state":"failed"}"#,
            #"{"event":"summary","state":"thinking"}"#
        ]
        let events = decoder.feed(Data((lines.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(events.map(label), ["summary:false", "summary:false"])
        for event in events {
            guard case let .summary(_, error) = event else { return XCTFail("not the summary") }
            XCTAssertEqual(error, ReviewRunError(errorClass: "parse", text: ReviewOverviewStreamDecoder.summaryFailedText))
        }
    }

    func testWaitingCachedNotStartedAndFailedSummary() {
        var decoder = ReviewOverviewStreamDecoder()
        let lines = [
            #"{"event":"waiting","by":"agent"}"#,
            #"{"event":"chapter","key":"dir:a","state":"cached","what":"w","risks":[]}"#,
            #"{"event":"chapter","key":"dir:b","state":"not_started"}"#,
            #"{"event":"chapter","key":"dir:c","state":"failed","#
                + #""error":{"class":"provider","text":"The AI provider failed on “c”.","detail":"HTTP 529"}}"#,
            #"{"event":"summary","state":"failed","error":{"class":"timeout","text":"The overview of the summary did not finish in 2 min."}}"#
        ]
        let events = decoder.feed(Data((lines.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(events.map(label), [
            "waiting:agent",
            "chapter:dir:a:cached",
            "chapter:dir:b:notStarted",
            "chapter:dir:c:failed(text: \"The AI provider failed on “c”.\", detail: Optional(\"HTTP 529\"))",
            "summary:false"
        ])
        guard case let .summary(_, error) = events[4] else { return XCTFail("not the summary") }
        XCTAssertEqual(error, ReviewRunError(errorClass: "timeout", text: "The overview of the summary did not finish in 2 min."))
    }

    func testFailedEnvelope() {
        var decoder = ReviewOverviewStreamDecoder()
        let events = decoder.feed(Data((#"{"ok":false,"error":"Branch review is describing this branch now.","error_class":"busy"}"# + "\n").utf8))
        guard case let .final(env) = events.first else { return XCTFail("not the envelope") }
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.errorClass, "busy")
    }
}
