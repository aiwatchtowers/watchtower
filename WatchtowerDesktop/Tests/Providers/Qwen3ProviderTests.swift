import XCTest
@testable import WatchtowerDesktop

final class Qwen3ProviderTests: XCTestCase {
    func testMetadata() throws {
        let p = Qwen3Provider()
        XCTAssertEqual(type(of: p).id, "qwen3")
        XCTAssertFalse(p.supportsLive)
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
}
