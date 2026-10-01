import XCTest
@testable import WatchtowerCore

final class EmbeddedStreamReducerTests: XCTestCase {
    func testDeltasAccumulate() {
        var reducer = EmbeddedStreamReducer()
        XCTAssertEqual(reducer.apply(.text("Hel")), .text("Hel"))
        XCTAssertEqual(reducer.apply(.text("lo")), .text("Hello"))
    }

    func testTurnCompleteReplacesTheText() {
        var reducer = EmbeddedStreamReducer()
        _ = reducer.apply(.text("draft"))
        XCTAssertEqual(reducer.apply(.turnComplete("final answer")), .text("final answer"))
    }

    func testTextAfterTurnCompleteStartsOver() {
        var reducer = EmbeddedStreamReducer()
        _ = reducer.apply(.turnComplete("first turn"))
        XCTAssertEqual(reducer.apply(.text("second")), .text("second"))
        XCTAssertEqual(reducer.apply(.text(" turn")), .text("second turn"))
    }

    func testResetDropsThePreToolPreamble() {
        var reducer = EmbeddedStreamReducer()
        _ = reducer.apply(.text("Let me check first."))
        XCTAssertEqual(reducer.apply(.reset), .text(""))
        XCTAssertEqual(reducer.apply(.text("Here it is.")), .text("Here it is."))
    }

    func testSessionErrorAndDonePassThrough() {
        var reducer = EmbeddedStreamReducer()
        _ = reducer.apply(.text("kept"))
        XCTAssertEqual(reducer.apply(.sessionID("s1")), .sessionID("s1"))
        XCTAssertEqual(reducer.apply(.error("not logged in")), .failed("not logged in"))
        XCTAssertEqual(reducer.apply(.done), .none)
        XCTAssertEqual(reducer.text, "kept", "an error never touches the text")
    }

    func testCollectReturnsTheFinalText() async throws {
        let stream = AsyncThrowingStream<StreamEvent, Error> { c in
            for e: StreamEvent in [.text("pre"), .reset, .text("{\"a\":"), .text("1}"), .turnComplete("{\"a\":1}"), .done] {
                c.yield(e)
            }
            c.finish()
        }
        let text = try await AIStreamText.collect(stream)
        XCTAssertEqual(text, "{\"a\":1}")
    }

    func testCollectThrowsOnAnErrorEvent() async {
        let stream = AsyncThrowingStream<StreamEvent, Error> { c in
            c.yield(.text("partial"))
            c.yield(.error("boom"))
            c.finish()
        }
        do {
            _ = try await AIStreamText.collect(stream)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? AIStreamText.ProviderError, .init(message: "boom"))
        }
    }
}
