import XCTest
@testable import WatchtowerDesktop

final class WhisperKitProviderTests: XCTestCase {
    func testMetadata() {
        let p = WhisperKitProvider()
        XCTAssertEqual(type(of: p).id, "whisperkit")
        XCTAssertTrue(p.supportsLive)
        XCTAssertEqual(p.availability(), .available)
        XCTAssertEqual(p.models.first?.id, "large-v3-v20240930", "turbo must be the default (first) model")
        XCTAssertNil(p.supportedLanguages(model: "large-v3-v20240930"), "Whisper is not language-restricted")
    }

    func testRegisteredAsWhisperKit() {
        XCTAssertTrue(TranscriptionProviderRegistry.all.contains { type(of: $0).id == "whisperkit" })
        XCTAssertTrue(TranscriptionProviderRegistry.resolve(providerID: "whisperkit") is WhisperKitProvider,
                      "stub must be gone, real WhisperKitProvider must be registered")
    }
}
