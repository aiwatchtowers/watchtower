import XCTest
@testable import WatchtowerDesktop

/// Metadata/availability-only: `SpeechAnalyzer`/`SpeechTranscriber` need on-device
/// system models, so no test here triggers a real transcribe/prefetch call (mirrors
/// how ParakeetProviderTests only smoke-tests when a model is already cached).
final class AppleProviderTests: XCTestCase {
    func testAvailabilityMatchesOS() {
        let p = AppleProvider()
        if #available(macOS 26, *) {
            XCTAssertEqual(p.availability(), .available)
        } else {
            if case .unavailable = p.availability() {} else { XCTFail("must be unavailable < 26") }
        }
    }

    func testMetadata() {
        let p = AppleProvider()
        XCTAssertEqual(AppleProvider.id, "apple")
        XCTAssertFalse(p.supportsLive)
        XCTAssertEqual(p.models.map(\.id), ["system"])
    }

    func testUkrainianNotSupported() {
        // uk is intentionally excluded — the product core needs it, Apple lacks it.
        let langs = AppleProvider().supportedLanguages(model: "system")
        XCTAssertNotNil(langs)
        XCTAssertFalse(langs?.contains("uk") ?? true)
    }

    func testSupportedLanguagesCoversRuAndEn() {
        // The one workspace shape this provider is meant for (design doc §1): ru/en-only.
        let langs = AppleProvider().supportedLanguages(model: "system")
        XCTAssertTrue(langs?.isSuperset(of: ["ru", "en"]) ?? false)
    }

    func testRegistered() {
        XCTAssertTrue(TranscriptionProviderRegistry.all.contains { type(of: $0).id == "apple" })
    }
}
