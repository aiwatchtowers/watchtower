import Foundation
import Testing
@testable import WatchtowerDesktop

@Suite("TranscriptionConfig.fromDefaults")
struct TranscriptionSettingsTests {
    /// Isolated UserDefaults suite so tests never touch `.standard`.
    private func makeSuite() throws -> UserDefaults {
        let name = "transcription-tests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test("Empty suite yields struct defaults")
    func emptyDefaults() throws {
        let config = TranscriptionConfig.fromDefaults(try makeSuite())
        #expect(config == TranscriptionConfig())
    }

    @Test("Reads overrides from the suite")
    func readsOverrides() throws {
        let defaults = try makeSuite()
        defaults.set("ru,en", forKey: "transcription.langset")
        defaults.set(15.0, forKey: "transcription.windowSec")
        defaults.set(0.7, forKey: "transcription.langThreshold")
        defaults.set(0.1, forKey: "transcription.margin")

        let config = TranscriptionConfig.fromDefaults(defaults)
        #expect(config.langset == ["ru", "en"])
        #expect(config.windowSec == 15.0)
        #expect(config.langThreshold == 0.7)
        #expect(config.margin == 0.1)
        #expect(config.forcedLanguage == nil)
    }

    @Test("Non-empty force language disables detection")
    func forcedLanguage() throws {
        let defaults = try makeSuite()
        defaults.set("uk", forKey: "transcription.forceLang")
        let config = TranscriptionConfig.fromDefaults(defaults)
        #expect(config.forcedLanguage == "uk")
    }

    @Test("Blank force language stays nil")
    func blankForceLanguageIsNil() throws {
        let defaults = try makeSuite()
        defaults.set("   ", forKey: "transcription.forceLang")
        let config = TranscriptionConfig.fromDefaults(defaults)
        #expect(config.forcedLanguage == nil)
    }

    @Test("Absent diarization threshold keeps the default")
    func diarizationThresholdDefault() throws {
        let config = TranscriptionConfig.fromDefaults(try makeSuite())
        #expect(config.diarizationThreshold == 0.6)
    }

    @Test("Reads the diarization threshold override")
    func diarizationThresholdOverride() throws {
        let defaults = try makeSuite()
        defaults.set(0.55, forKey: "transcription.diarizationThreshold")
        let config = TranscriptionConfig.fromDefaults(defaults)
        #expect(config.diarizationThreshold == 0.55)
    }

    @Test("Out-of-range diarization threshold falls back to the default")
    func diarizationThresholdOutOfRange() throws {
        let defaults = try makeSuite()
        defaults.set(1.5, forKey: "transcription.diarizationThreshold")
        let config = TranscriptionConfig.fromDefaults(defaults)
        #expect(config.diarizationThreshold == 0.6)
    }

    @Test("Empty langset falls back to default")
    func emptyLangsetFallsBack() throws {
        let defaults = try makeSuite()
        defaults.set("  , ,", forKey: "transcription.langset")
        let config = TranscriptionConfig.fromDefaults(defaults)
        #expect(config.langset == ["ru", "uk", "en"])
    }
}
