import XCTest
@testable import WatchtowerDesktop

final class TranscriptionProviderTests: XCTestCase {
    func testModelOptionIsIdentifiableById() {
        let a = TranscriptionModelOption(id: "large-v3-v20240930", label: "Large v3 Turbo")
        XCTAssertEqual(a.id, "large-v3-v20240930")
    }

    func testAvailabilityEquatable() {
        XCTAssertEqual(ProviderAvailability.available, .available)
        XCTAssertNotEqual(ProviderAvailability.available, .unavailable(reason: "x"))
    }

    // A minimal fake proves the protocols are usable end-to-end without any model.
    func testFakeProviderConformsAndTranscribes() async throws {
        let provider: TranscriptionProvider = FakeProvider()
        XCTAssertEqual(type(of: provider).id, "fake")
        let t = try await provider.makeTranscriber(model: "m") { _ in }
        let out = try await t.transcribe([0, 0, 0], config: TranscriptionConfig()) { _, _ in }
        XCTAssertEqual(out.text, "hello")
        XCTAssertNil(t.makeLiveSession(config: TranscriptionConfig()))
    }
}

private struct FakeProvider: TranscriptionProvider {
    static var id: String { "fake" }
    var displayName: String { "Fake" }
    var models: [TranscriptionModelOption] { [.init(id: "m", label: "M")] }
    var supportsLive: Bool { false }
    func availability() -> ProviderAvailability { .available }
    func supportedLanguages(model: String) -> Set<String>? { nil }
    func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func makeTranscriber(model: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber {
        FakeTranscriber()
    }
}

private struct FakeTranscriber: Transcriber {
    func transcribe(
        _ samples: [Float],
        config: TranscriptionConfig,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> TranscriptionOutput {
        TranscriptionOutput(text: "hello", langStats: [:])
    }
    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? { nil }
}
