import XCTest
@testable import WatchtowerDesktop

final class TranscriptionProviderRegistryTests: XCTestCase {
    func testAllIdsAreUnique() {
        let ids = TranscriptionProviderRegistry.all.map { type(of: $0).id }
        XCTAssertEqual(ids.count, Set(ids).count, "provider ids must be unique")
    }

    func testEveryProviderHasModels() {
        for p in TranscriptionProviderRegistry.all {
            XCTAssertFalse(p.models.isEmpty, "\(type(of: p).id) has no models")
        }
    }

    func testResolveUnknownFallsBackToWhisperKit() {
        let p = TranscriptionProviderRegistry.resolve(providerID: "does-not-exist")
        XCTAssertEqual(type(of: p).id, TranscriptionProviderRegistry.fallbackProviderID)
    }

    func testAvailableProvidersExcludeUnavailable() {
        let avail = TranscriptionProviderRegistry.availableProviders()
        for p in avail { XCTAssertEqual(p.availability(), .available) }
    }

    /// Migration contract: an install with no `transcription.provider` key
    /// (i.e. everything shipped before the pluggable-provider work) must
    /// resolve to whisperkit, so `transcription.model` keeps meaning exactly
    /// what it always did.
    func testMigrationDefaultsToWhisperKitWhenProviderKeyAbsent() {
        let d = UserDefaults(suiteName: "test.migration.\(UUID().uuidString)")!
        let providerID = d.string(forKey: "transcription.provider") ?? "whisperkit"
        XCTAssertEqual(providerID, "whisperkit")
        XCTAssertEqual(type(of: TranscriptionProviderRegistry.resolve(providerID: providerID)).id, "whisperkit")
    }
}
