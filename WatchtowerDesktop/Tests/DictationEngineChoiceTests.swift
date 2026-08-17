import Foundation
import Testing
@testable import WatchtowerDesktop

/// Truth table of `DictationEngineChoice` — the dictation-model picker's
/// settings resolution. Pure logic: `appleSupported` is a parameter here,
/// so no real `SpeechTranscriber`/OS gate is touched.
@Suite("DictationEngineChoice")
struct DictationEngineChoiceTests {
    /// A fresh, isolated defaults suite per test (the `isolatedDefaults`
    /// pattern from MeetingRecorderTestSupport, minus the XCTest unwrap).
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "DictationEngineChoiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - resolve

    @Test("Absent key defaults to Apple when supported")
    func absentKeyAppleSupported() {
        #expect(DictationEngineChoice.resolve(rawValue: nil, appleSupported: true) == .apple)
    }

    @Test("Absent key falls back to Whisper small when Apple unsupported")
    func absentKeyAppleUnsupported() {
        #expect(DictationEngineChoice.resolve(rawValue: nil, appleSupported: false)
            == .whisper(model: "small"))
    }

    @Test("Stored apple resolves to Apple when supported")
    func storedAppleSupported() {
        #expect(DictationEngineChoice.resolve(rawValue: "apple", appleSupported: true) == .apple)
    }

    @Test("Stored apple downgrades to Whisper small when unsupported")
    func storedAppleUnsupported() {
        // OS downgrade / synced prefs: the stored choice can no longer run here.
        #expect(DictationEngineChoice.resolve(rawValue: "apple", appleSupported: false)
            == .whisper(model: "small"))
    }

    @Test("Whisper small resolves regardless of Apple support",
          arguments: [true, false])
    func whisperSmall(appleSupported: Bool) {
        #expect(DictationEngineChoice.resolve(rawValue: "small", appleSupported: appleSupported)
            == .whisper(model: "small"))
    }

    @Test("Whisper turbo resolves to its model")
    func whisperTurbo() {
        #expect(DictationEngineChoice.resolve(rawValue: "large-v3-v20240930", appleSupported: true)
            == .whisper(model: "large-v3-v20240930"))
    }

    @Test("Whisper base resolves to its model")
    func whisperBase() {
        #expect(DictationEngineChoice.resolve(rawValue: "base", appleSupported: true)
            == .whisper(model: "base"))
    }

    @Test("Unknown raw value is treated as absent (Apple supported)")
    func unknownRawAppleSupported() {
        #expect(DictationEngineChoice.resolve(rawValue: "garbage", appleSupported: true) == .apple)
    }

    @Test("Unknown raw value is treated as absent (Apple unsupported)")
    func unknownRawAppleUnsupported() {
        #expect(DictationEngineChoice.resolve(rawValue: "garbage", appleSupported: false)
            == .whisper(model: "small"))
    }

    // MARK: - engineKey

    @Test("Engine keys are stable slot identifiers")
    func engineKeys() {
        #expect(DictationEngineChoice.apple.engineKey == "apple")
        #expect(DictationEngineChoice.whisper(model: "small").engineKey == "whisper|small")
        #expect(DictationEngineChoice.whisper(model: "large-v3-v20240930").engineKey
            == "whisper|large-v3-v20240930")
    }

    // MARK: - current

    @Test("current reads the stored key from the injected defaults")
    func currentReadsStoredKey() throws {
        let defaults = try makeDefaults()
        defaults.set("base", forKey: DictationEngineChoice.defaultsKey)
        #expect(DictationEngineChoice.current(defaults: defaults, appleSupported: true)
            == .whisper(model: "base"))
    }

    @Test("current with no stored key follows the absent-key default")
    func currentAbsentKey() throws {
        let defaults = try makeDefaults()
        #expect(DictationEngineChoice.current(defaults: defaults, appleSupported: true) == .apple)
        #expect(DictationEngineChoice.current(defaults: defaults, appleSupported: false)
            == .whisper(model: "small"))
    }

    @Test("current downgrades a stored apple on an unsupported system")
    func currentStoredAppleUnsupported() throws {
        let defaults = try makeDefaults()
        defaults.set("apple", forKey: DictationEngineChoice.defaultsKey)
        #expect(DictationEngineChoice.current(defaults: defaults, appleSupported: false)
            == .whisper(model: "small"))
    }
}
