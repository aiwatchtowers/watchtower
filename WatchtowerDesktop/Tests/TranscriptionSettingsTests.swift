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

    @Test("The struct defaults pin the shipped configuration")
    func structDefaults() throws {
        let config = TranscriptionConfig()
        // 30 s windows: raised from 20 after the 2026-08-07 full-recording A/B
        // (longer context recovers quiet-speaker replies). Conditioning dark.
        #expect(config.windowSec == 30)
        #expect(config.contextPrompt == false)
    }

    @Test("Absent context prompt keeps the dark default")
    func contextPromptDefault() throws {
        let config = TranscriptionConfig.fromDefaults(try makeSuite())
        #expect(config.contextPrompt == false)
    }

    @Test("Reads the context prompt override")
    func contextPromptOverride() throws {
        let defaults = try makeSuite()
        defaults.set(true, forKey: "transcription.contextPrompt")
        let config = TranscriptionConfig.fromDefaults(defaults)
        #expect(config.contextPrompt)
    }

    @Test("Empty langset falls back to default")
    func emptyLangsetFallsBack() throws {
        let defaults = try makeSuite()
        defaults.set("  , ,", forKey: "transcription.langset")
        let config = TranscriptionConfig.fromDefaults(defaults)
        #expect(config.langset == ["ru", "uk", "en"])
    }
}

@Suite("Dictation model picker")
struct DictationModelPickerTests {
    @Test("Apple row is offered only when the Apple session is supported")
    func appleRowGatedBySupport() throws {
        let supported = DictationEngineChoice.pickerOptions(appleSupported: true)
        #expect(supported.first == DictationEngineChoice.PickerOption(
            id: "apple", label: "Apple (realtime)"))

        let unsupported = DictationEngineChoice.pickerOptions(appleSupported: false)
        #expect(!unsupported.contains { $0.id == "apple" })
    }

    @Test("The whisper trio is always present, in order")
    func whisperTrioAlwaysPresent() throws {
        for appleSupported in [true, false] {
            let whisper = DictationEngineChoice.pickerOptions(appleSupported: appleSupported)
                .filter { $0.id != "apple" }
            #expect(whisper == [
                DictationEngineChoice.PickerOption(id: "large-v3-v20240930", label: "Whisper large-v3 turbo"),
                DictationEngineChoice.PickerOption(id: "small", label: "Whisper small (fast)"),
                DictationEngineChoice.PickerOption(id: "base", label: "Whisper base (fastest)")
            ])
        }
    }

    @Test("Absent storage resolves to the default selection, never empty")
    func absentStorageShowsResolvedDefault() throws {
        #expect(DictationEngineChoice.resolve(rawValue: nil, appleSupported: true).storedRawValue == "apple")
        #expect(DictationEngineChoice.resolve(rawValue: nil, appleSupported: false).storedRawValue == "small")
        // @AppStorage's empty-string default takes the same path as absent.
        #expect(DictationEngineChoice.resolve(rawValue: "", appleSupported: true).storedRawValue == "apple")
    }

    @Test("A stored whisper model round-trips through the proxy")
    func storedModelRoundTrips() throws {
        #expect(DictationEngineChoice.resolve(rawValue: "base", appleSupported: true).storedRawValue == "base")
        #expect(DictationEngineChoice.resolve(rawValue: "base", appleSupported: false).storedRawValue == "base")
    }

    @Test("Every picker option's id resolves back to itself when supported")
    func optionIDsAreStableRawValues() throws {
        for option in DictationEngineChoice.pickerOptions(appleSupported: true) {
            #expect(DictationEngineChoice.resolve(
                rawValue: option.id, appleSupported: true).storedRawValue == option.id)
        }
    }
}
