import Foundation
import Testing
@testable import WatchtowerDesktop

@Suite("TranscriptionConfig.fromDefaults")
struct TranscriptionSettingsTests {
    /// Isolated UserDefaults suite so tests never touch `.standard`.
    private func makeSuite() -> UserDefaults {
        let name = "transcription-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test("Empty suite yields struct defaults")
    func emptyDefaults() {
        let config = TranscriptionConfig.fromDefaults(makeSuite())
        #expect(config == TranscriptionConfig())
    }

    @Test("Reads overrides from the suite")
    func readsOverrides() {
        let defaults = makeSuite()
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
    func forcedLanguage() {
        let defaults = makeSuite()
        defaults.set("uk", forKey: "transcription.forceLang")
        let config = TranscriptionConfig.fromDefaults(defaults)
        #expect(config.forcedLanguage == "uk")
    }

    @Test("Blank force language stays nil")
    func blankForceLanguageIsNil() {
        let defaults = makeSuite()
        defaults.set("   ", forKey: "transcription.forceLang")
        let config = TranscriptionConfig.fromDefaults(defaults)
        #expect(config.forcedLanguage == nil)
    }

    @Test("Empty langset falls back to default")
    func emptyLangsetFallsBack() {
        let defaults = makeSuite()
        defaults.set("  , ,", forKey: "transcription.langset")
        let config = TranscriptionConfig.fromDefaults(defaults)
        #expect(config.langset == ["ru", "uk", "en"])
    }
}
