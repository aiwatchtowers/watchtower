import Foundation
@preconcurrency import AVFoundation
import Speech

/// Adapts Apple's native `Speech` framework (`SpeechAnalyzer` + `SpeechTranscriber`,
/// introduced macOS 26 "Tahoe" / WWDC25 session 277) to the pluggable
/// `TranscriptionProvider` contract. Batch-only: `SpeechTranscriber` is a
/// one-locale-per-session engine with no public "detect language for this window" hook,
/// so it cannot drive the per-window sticky ru/uk/en language switching
/// `WindowedTranscriber`/`StreamingTranscriber` do — wiring it into the live path would
/// silently regress language handling. See
/// docs/superpowers/specs/2026-07-15-apple-speechanalyzer-engine-design.md.
///
/// Ukrainian (`uk`) is verified ABSENT from `SpeechTranscriber.supportedLocales` (design
/// doc §2.2, re-confirmed against the macOS 26.5 SDK's Speech.swiftinterface at
/// implementation time) — this provider is an opt-in choice for ru/en-only workspaces on
/// macOS 26+, never a WhisperKit replacement for the project's default {ru, uk, en} mix.
struct AppleProvider: TranscriptionProvider {
    static var id: String { "apple" }
    var displayName: String { "Apple Speech (macOS 26+)" }
    var models: [TranscriptionModelOption] { [.init(id: "system", label: "System model")] }
    var supportsLive: Bool { false }

    func availability() -> ProviderAvailability {
        if #available(macOS 26, *) { return .available }
        return .unavailable(reason: "Requires macOS 26")
    }

    /// Base language codes covered by `SpeechTranscriber.supportedLocales` (verified
    /// list, see `AppleLocaleCatalog`). Hard-coded rather than queried at runtime so this
    /// method works on the macOS 14 floor too — `supportedLocales` itself is
    /// `@available(macOS 26, *)`-only. "uk" (Ukrainian) is deliberately absent: Apple
    /// does not ship a Ukrainian model for `SpeechTranscriber`.
    func supportedLanguages(model: String) -> Set<String>? {
        Set(AppleLocaleCatalog.localeByLanguage.keys)
    }

    func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26, *) else { return }
        let transcriber = SpeechTranscriber(locale: AppleLocaleCatalog.defaultLocale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            // Nothing to install: locale's assets are already on-device.
            progress(1.0)
            return
        }
        progress(0.0)
        try await request.downloadAndInstall()
        progress(1.0)
    }

    func makeTranscriber(model: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber {
        guard #available(macOS 26, *) else {
            throw NSError(domain: "AppleProvider", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Requires macOS 26"])
        }
        return AppleTranscriber()
    }
}

/// One representative full locale per base language code `SpeechTranscriber` supports
/// (verified against Apple's WWDC25 "Bring advanced speech-to-text to your app" session
/// and the macOS 26.5 SDK's `Speech.swiftinterface`). `SpeechTranscriber` is constructed
/// with a concrete `Locale` (e.g. "ru-RU"), not a bare language code, so
/// `TranscriptionConfig.langset` (bare codes like "ru") needs mapping to one.
enum AppleLocaleCatalog {
    static let localeByLanguage: [String: String] = [
        "ar": "ar-SA", "da": "da-DK", "de": "de-DE", "en": "en-US", "es": "es-ES",
        "fi": "fi-FI", "fr": "fr-FR", "he": "he-IL", "it": "it-IT", "ja": "ja-JP",
        "ko": "ko-KR", "ms": "ms-MY", "nb": "nb-NO", "nl": "nl-NL", "pt": "pt-BR",
        "ru": "ru-RU", "sv": "sv-SE", "th": "th-TH", "tr": "tr-TR", "vi": "vi-VN",
        "yue": "yue-CN", "zh": "zh-CN"
    ]
    static let defaultLocale = Locale(identifier: "en-US")

    /// Picks the first language in `langset` Apple actually supports. Unlike
    /// WhisperKit's per-window detection, this is decided ONCE up front —
    /// `SpeechTranscriber` needs exactly one locale for the whole session.
    static func resolveLocale(langset: [String]) -> Locale {
        for code in langset {
            if let id = localeByLanguage[code] { return Locale(identifier: id) }
        }
        return defaultLocale
    }

    /// Dictation-lane locale resolution (realtime-dictation spec §2:
    /// "forceLang when set, else Locale.current") — used ONLY by the
    /// dictation session factory; the batch `AppleTranscriber` path keeps its
    /// langset resolution above. A supported `forced` language (mapped
    /// through `localeByLanguage`) wins; otherwise the user's `current`
    /// locale when Apple supports its language; else the en-US default.
    /// A forced language Apple does not support (e.g. "uk") deliberately
    /// falls through to current-or-default rather than erroring — the same
    /// degrade-to-a-working-engine shape as `DictationEngineChoice.resolve`.
    static func resolveDictationLocale(forced: String?, current: Locale = .current) -> Locale {
        if let forced, let id = localeByLanguage[forced] {
            return Locale(identifier: id)
        }
        if let code = current.language.languageCode?.identifier, localeByLanguage[code] != nil {
            return current
        }
        return defaultLocale
    }
}

/// Runs the real macOS 26 `SpeechAnalyzer` batch flow: build one `SpeechTranscriber`
/// module for the resolved locale, feed the whole recording as a single `AnalyzerInput`,
/// and collect only `isFinal` results (never volatile/draft text) into one transcript —
/// mirroring the "only save finalized text" rule from the live-transcription design
/// (docs/superpowers/specs/2026-07-14-live-transcription-design.md).
/// `@unchecked Sendable` is sound here: one instance is created per recording and its
/// `transcribe` is awaited once from a single detached task, never shared concurrently
/// (same single-use invariant as `WhisperKitEngine`).
final class AppleTranscriber: Transcriber, @unchecked Sendable {
    func transcribe(
        _ samples: [Float],
        config: TranscriptionConfig,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> TranscriptionOutput {
        guard #available(macOS 26, *) else {
            throw NSError(domain: "AppleProvider", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Requires macOS 26"])
        }
        progress(0, 1)

        let locale = AppleLocaleCatalog.resolveLocale(langset: config.langset)
        let transcriberModule = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriberModule])

        let sourceBuffer = try Self.makePCMBuffer(samples: samples)
        let inputBuffer = await Self.converted(sourceBuffer, forModules: [transcriberModule])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: inputBuffer))
        continuation.finish()

        // Collect finalized results concurrently with feeding input: `results` is a
        // live AsyncSequence that must be consumed while (not after) the analyzer runs.
        let collector = Task<String, Error> {
            var text = ""
            for try await result in transcriberModule.results where result.isFinal {
                let piece = String(result.text.characters)
                guard !piece.isEmpty else { continue }
                text += text.isEmpty ? piece : " " + piece
            }
            return text
        }

        _ = try await analyzer.analyzeSequence(stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let finalText = try await collector.value

        progress(1, 1)
        // langStats has different semantics from WhisperKit's per-window counters (one
        // fixed locale for the whole session, not windows-per-language) — synthesize a
        // single-entry stat so downstream UI still has something to label, tagged with
        // the resolved locale's language code.
        let stats: [String: Int] = finalText.isEmpty ? [:] : [locale.identifier(.bcp47): 1]
        return TranscriptionOutput(text: finalText, langStats: stats)
    }

    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? { nil }

    /// 16 kHz mono Float32 buffer straight from the recorder's samples — the format
    /// every WhisperKit/Parakeet path already uses (`TranscriptionConfig.sampleRate`).
    /// Internal (not private) so `AppleDictationSession` reuses it per mic chunk.
    static func makePCMBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(TranscriptionConfig.sampleRate),
                                         channels: 1, interleaved: false) else {
            throw NSError(domain: "AppleProvider", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not construct 16 kHz PCM format"])
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw NSError(domain: "AppleProvider", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate PCM buffer"])
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return } // empty input → nothing to copy
            channel.update(from: base, count: samples.count)
        }
        return buffer
    }

    /// `SpeechAnalyzer` dictates its own preferred audio format (rarely our 16 kHz mono
    /// Float32), so the buffer is resampled via `AVAudioConverter` before being handed to
    /// the analyzer (design doc §7.4). Falls back to the original buffer if Apple reports
    /// no preferred format or conversion setup fails — the analyzer will then surface its
    /// own format error rather than us silently dropping audio.
    /// Internal (not private) so `AppleDictationSession` reuses it per mic chunk.
    @available(macOS 26, *)
    static func converted(_ buffer: AVAudioPCMBuffer,
                          forModules modules: [any SpeechModule]) async -> AVAudioPCMBuffer {
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules, considering: buffer.format)
        else { return buffer }

        let sameFormat = targetFormat.sampleRate == buffer.format.sampleRate
            && targetFormat.channelCount == buffer.format.channelCount
            && targetFormat.commonFormat == buffer.format.commonFormat
        if sameFormat { return buffer }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return buffer
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1_024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return buffer
        }

        var suppliedInput = false
        var conversionError: NSError?
        _ = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return conversionError == nil ? outBuffer : buffer
    }
}
