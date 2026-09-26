import XCTest
@testable import WatchtowerDesktop

final class Qwen3ProviderTests: XCTestCase {
    func testMetadata() throws {
        let p = Qwen3Provider()
        XCTAssertEqual(type(of: p).id, "qwen3")
        XCTAssertTrue(p.supportsLive)
        if Qwen3Provider.isAppleSilicon {
            XCTAssertEqual(p.availability(), .available)
        } else {
            XCTAssertEqual(p.availability(), .unavailable(reason: "Requires Apple Silicon"))
        }
        let langs = p.supportedLanguages(model: "Qwen3-ASR-0.6B")
        XCTAssertNotNil(langs)
        XCTAssertTrue(try XCTUnwrap(langs).isSuperset(of: ["ru", "uk", "en"]))
    }

    func testRegistered() {
        XCTAssertTrue(TranscriptionProviderRegistry.all.contains { type(of: $0).id == "qwen3" })
    }

    /// The live session must forward to the SAME windower loop the batch path
    /// uses: chunks arrive per window and the returned output matches them.
    func testLiveSessionForwardsToWindower() async throws {
        var c = TranscriptionConfig()
        c.windowSec = 2.0
        c.overlapSec = 0.2
        c.boundarySnapSec = 0.25
        var n = 0
        let session = Qwen3LiveSession(windower: Qwen3Windower(config: c) { _ in
            n += 1
            return "w\(n)"
        })
        let samples = [Float](repeating: 0.01, count: 5 * 16_000)
        let stream = AsyncStream<[Float]> { cont in
            cont.yield(samples)
            cont.finish()
        }
        final class ChunkBox: @unchecked Sendable { var chunks: [StreamChunk] = [] }
        let box = ChunkBox()
        let out = try await session.run(samples: stream) { box.chunks.append($0) }
        XCTAssertGreaterThan(box.chunks.count, 1)
        XCTAssertEqual(out.text, box.chunks.map(\.text).joined(separator: "\n"))
        XCTAssertEqual(box.chunks.map(\.index), Array(1...box.chunks.count))
    }
}
