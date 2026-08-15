import Foundation
@preconcurrency import AVFoundation
import Speech

/// Volatile/final accumulation behind the Apple streaming lane, pure (no
/// Speech.framework types) so it is unit-testable: finalized pieces
/// accumulate space-joined, a volatile piece only ever REPLACES the tail.
/// The analyzer internals around it are deliberately not unit-tested (no
/// Speech mocking) — this struct plus the DictationCenter wiring are the
/// coverage (realtime-dictation plan, Task 3).
struct AppleDictationAccumulator {
    private(set) var finalized: String = ""
    private(set) var volatileTail: String = ""

    /// The full display string so far: finalized prefix + current volatile
    /// tail — what `DictationTranscribing.onUpdate` full-replaces into the
    /// field.
    var display: String {
        if finalized.isEmpty { return volatileTail }
        if volatileTail.isEmpty { return finalized }
        return finalized + " " + volatileTail
    }

    /// Empty text is ignored for BOTH flags: an empty volatile piece must not
    /// wipe the tail the user is watching, and an empty final piece has
    /// nothing to accumulate.
    mutating func accept(text: String, isFinal: Bool) {
        guard !text.isEmpty else { return }
        if isFinal {
            finalized += finalized.isEmpty ? text : " " + text
            volatileTail = ""
        } else {
            volatileTail = text
        }
    }
}

/// macOS 26+ native streaming dictation over `SpeechAnalyzer` /
/// `SpeechTranscriber` — `AppleTranscriber`'s batch flow inverted: input
/// arrives incrementally from the mic stream while results (INCLUDING
/// volatile ones) are consumed concurrently through the accumulator, firing
/// `onUpdate` with the full display string on every accepted change. The
/// returned string is the finalized text after
/// `finalizeAndFinishThroughEndOfInput()` — single-pass, that return IS the
/// raw transcript.
///
/// `Sendable` is sound: the only stored state is the immutable locale; each
/// `run` builds its whole analyzer world locally.
final class AppleDictationSession: DictationTranscribing, Sendable {
    /// OS availability gate, mirroring `AppleProvider.availability()` —
    /// consulted by `DictationEngineChoice` resolution and the Settings
    /// picker.
    static var isSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    private let locale: Locale

    init(locale: Locale) {
        self.locale = locale
    }

    func run(samples: AsyncStream<[Float]>,
             onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        guard #available(macOS 26, *) else {
            throw NSError(domain: "AppleDictationSession", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Requires macOS 26"])
        }
        return try await stream(samples: samples, onUpdate: onUpdate)
    }

    @available(macOS 26, *)
    private func stream(samples: AsyncStream<[Float]>,
                        onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        // `.progressiveTranscription`, not the batch flow's `.transcription`:
        // only the progressive preset reports `.volatileResults`, and without
        // volatile results nothing streams — the lane would degrade to
        // final-only lumps, defeating its purpose (spec §2: "volatile results
        // replace the tail").
        let transcriberModule = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        // Asset install first — the `AppleProvider.prefetch` flow (a nil
        // request means the locale's assets are already on-device).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriberModule]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriberModule])

        // Results are consumed concurrently with the input feed — `results`
        // is a live AsyncSequence that must be read while (not after) the
        // analyzer runs. Every accepted change hops to the MainActor with
        // the full display string.
        let collector = Task<String, Error> {
            var accumulator = AppleDictationAccumulator()
            for try await result in transcriberModule.results {
                let before = accumulator.display
                accumulator.accept(text: String(result.text.characters), isFinal: result.isFinal)
                let display = accumulator.display
                if display != before {
                    await onUpdate(display)
                }
            }
            return accumulator.finalized
        }

        // The analyzer consumes its input stream on its own task while the
        // loop below feeds mic chunks in as they arrive.
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzeTask = Task { _ = try await analyzer.analyzeSequence(inputStream) }

        // Per-chunk conversion rides the promoted batch helpers verbatim
        // (`makePCMBuffer` + `converted`): a fresh target-format query and
        // AVAudioConverter per chunk. Correctness-first choice — reusing one
        // converter across chunks would mean duplicating or refactoring the
        // shared helper, and the format query is cheap next to a decode.
        do {
            for await chunk in samples where !chunk.isEmpty {
                let buffer = try AppleTranscriber.makePCMBuffer(samples: chunk)
                let input = await AppleTranscriber.converted(buffer, forModules: [transcriberModule])
                inputContinuation.yield(AnalyzerInput(buffer: input))
            }
        } catch {
            inputContinuation.finish()
            analyzeTask.cancel()
            collector.cancel()
            throw error
        }

        // The mic stream ended (stop/cancel): close the input, let the
        // analyzer drain it, finalize the volatile tail through end of
        // input, then return what was finalized.
        inputContinuation.finish()
        do {
            try await analyzeTask.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }
}
