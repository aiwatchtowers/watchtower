import XCTest
import Speech
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// How many words each transcription engine invents over stretches with no
/// speech (board #554, spec D6). Local only — CI never sets the gate:
///
///     scripts/transcribe-bench-fetch.sh
///     WATCHTOWER_TX_BENCH=1 make test-swift FILTER=TranscriptionHallucinationBenchTests
///
/// Clips: FLEURS speech A → 60 s of filler → speech B for every filler kind ×
/// language, speech then 3 min of filler per filler kind, and every utterance
/// alone for WER. Each registered provider runs batch, and live (0.5 s pieces)
/// where it supports it; a provider whose model is not cached is skipped.
/// Results go to `bench-<date>.json` in `WATCHTOWER_TX_BENCH_OUT` (a directory;
/// default the temp dir) and a summary table to the log.
///
/// Other env: `WATCHTOWER_TX_BENCH_PROVIDERS` (comma-separated ids, default
/// all), `WATCHTOWER_TX_BENCH_PATHS` (`batch`, `live` or both, the default),
/// `WATCHTOWER_TX_BENCH_LANGUAGES` (subset of en,ru,uk — splits a long run),
/// `WATCHTOWER_TX_BENCH_DOWNLOAD=1` (let providers download missing
/// models), `WATCHTOWER_BENCH_CACHE` (corpus root, as for the fetch script).
final class TranscriptionHallucinationBenchTests: XCTestCase {
    private static let languages = ["en", "ru", "uk"]
    private static let liveFeedSec = 0.5
    /// Engines whose output segments carry real decode timestamps. Qwen3's
    /// segments span whole windows and Parakeet/Apple return none, so for
    /// them only `insertedWords` measures text over filler.
    private static let timedSegmentProviders: Set<String> = [WhisperKitProvider.id]

    func testBench() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WATCHTOWER_TX_BENCH"] == "1", "bench only: set WATCHTOWER_TX_BENCH=1")
        let corpus = try loadCorpus(env: env)
        let clips = Self.buildClips(corpus: corpus)
        let wanted = env["WATCHTOWER_TX_BENCH_PROVIDERS"].map { Set($0.split(separator: ",").map(String.init)) }
        let paths = Set((env["WATCHTOWER_TX_BENCH_PATHS"] ?? "batch,live").split(separator: ",").map(String.init))
        let allowDownload = env["WATCHTOWER_TX_BENCH_DOWNLOAD"] == "1"
        let onlyLanguages = env["WATCHTOWER_TX_BENCH_LANGUAGES"].map { Set($0.split(separator: ",").map(String.init)) }

        var results: [ClipResult] = []
        var skipped: [String: String] = [:]
        for provider in TranscriptionProviderRegistry.all {
            let id = type(of: provider).id
            if let wanted, !wanted.contains(id) { continue }
            let model = provider.models[0].id
            if case let .unavailable(reason) = provider.availability() {
                skipped[id] = reason
                continue
            }
            if !allowDownload, let missing = Self.missingModel(providerID: id, model: model) {
                skipped[id] = missing
                continue
            }
            var languages = await Self.benchLanguages(provider: provider, model: model)
            if let onlyLanguages { languages.formIntersection(onlyLanguages) }
            guard !languages.isEmpty else {
                skipped[id] = "no bench language available"
                continue
            }
            let transcriber: Transcriber
            do {
                transcriber = try await provider.makeTranscriber(model: model) { _ in }
            } catch {
                skipped[id] = "load failed: \(error.localizedDescription)"
                continue
            }
            let runnable = clips.filter { languages.contains($0.language) }
            print("[bench] \(id) \(model): \(runnable.count) clips, languages \(languages.sorted())")
            for clip in runnable {
                if paths.contains("batch") {
                    results.append(await run(clip, provider: id, model: model, path: "batch", transcriber: transcriber))
                }
                if provider.supportsLive, paths.contains("live") {
                    results.append(await run(clip, provider: id, model: model, path: "live", transcriber: transcriber))
                }
            }
        }
        for (id, reason) in skipped.sorted(by: { $0.key < $1.key }) {
            print("[bench] skipped \(id): \(reason)")
        }

        let url = try write(BenchReport(date: Date(), skipped: skipped, clips: results), env: env)
        print(Self.summary(results))
        print("[bench] wrote \(url.path)")
        XCTAssertFalse(results.isEmpty, "no provider ran — every one was skipped")
    }

    // MARK: - Corpus and clips

    private struct Utterance {
        let language: String
        let samples: [Float]
        let reference: String
    }

    private struct Clip {
        let id: String
        let language: String
        /// nil for speech-only clips.
        let filler: String?
        let layout: String
        let composition: SyntheticAudio.Composition
    }

    private func loadCorpus(env: [String: String]) throws -> [String: [Utterance]] {
        let root = env["WATCHTOWER_BENCH_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("watchtower-bench")
        let fleurs = root.appendingPathComponent("fleurs")
        let refs = fleurs.appendingPathComponent("references.tsv")
        guard FileManager.default.fileExists(atPath: refs.path) else {
            throw XCTSkip("no corpus at \(refs.path) — run scripts/transcribe-bench-fetch.sh")
        }
        var corpus: [String: [Utterance]] = [:]
        for line in try String(contentsOf: refs, encoding: .utf8).split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard fields.count == 3 else { continue }
            let url = fleurs.appendingPathComponent(fields[0]).appendingPathComponent(fields[1])
            let samples = try AudioFileDecoder.decodePCM16k(url: url)
            corpus[fields[0], default: []].append(Utterance(language: fields[0], samples: samples, reference: fields[2]))
        }
        for language in Self.languages where (corpus[language]?.count ?? 0) < 2 {
            throw XCTSkip("corpus has fewer than 2 \(language) utterances — rerun the fetch script")
        }
        return corpus
    }

    /// Filler kinds per spec D6, each with a fixed seed.
    private static let fillers: [(name: String, make: @Sendable (Double) -> [Float])] = [
        ("zeros", { SyntheticAudio.zeros(seconds: $0) }),
        ("white-60", { SyntheticAudio.whiteNoise(seconds: $0, dBFS: -60, seed: 1) }),
        ("white-45", { SyntheticAudio.whiteNoise(seconds: $0, dBFS: -45, seed: 2) }),
        ("pink-60", { SyntheticAudio.pinkNoise(seconds: $0, dBFS: -60, seed: 3) }),
        ("pink-45", { SyntheticAudio.pinkNoise(seconds: $0, dBFS: -45, seed: 4) }),
        ("hum-40", { SyntheticAudio.hum(seconds: $0, dBFS: -40) }),
        ("fade-90", { SyntheticAudio.fadeToDither(seconds: $0, seed: 5) })
    ]

    private static func buildClips(corpus: [String: [Utterance]]) -> [Clip] {
        var clips: [Clip] = []
        for (index, filler) in fillers.enumerated() {
            let fillerSamples = filler.make(60)
            for language in languages {
                let pool = corpus[language] ?? []
                let speechA = pool[(2 * index) % pool.count]
                let speechB = pool[(2 * index + 1) % pool.count]
                clips.append(Clip(
                    id: "\(language)-\(filler.name)-sandwich", language: language, filler: filler.name, layout: "sandwich",
                    composition: SyntheticAudio.compose([
                        .speech(speechA.samples, reference: speechA.reference),
                        .filler(fillerSamples),
                        .speech(speechB.samples, reference: speechB.reference)
                    ])
                ))
            }
        }
        for (index, filler) in fillers.enumerated() {
            let language = languages[index % languages.count]
            let pool = corpus[language] ?? []
            let speech = pool[index % pool.count]
            clips.append(Clip(
                id: "\(language)-\(filler.name)-tail", language: language, filler: filler.name, layout: "tail",
                composition: SyntheticAudio.compose([.speech(speech.samples, reference: speech.reference),
                                                     .filler(filler.make(180))])
            ))
        }
        for language in languages {
            for (index, utterance) in (corpus[language] ?? []).enumerated() {
                clips.append(Clip(
                    id: "\(language)-speech-\(index)", language: language, filler: nil, layout: "speech",
                    composition: SyntheticAudio.compose([.speech(utterance.samples, reference: utterance.reference)])
                ))
            }
        }
        return clips
    }

    // MARK: - Providers

    /// nil when the provider's model is on disk (or the provider keeps no
    /// files we can check); otherwise why the provider is skipped. Paths
    /// mirror each library's default cache location.
    private static func missingModel(providerID: String, model: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path: String
        switch providerID {
        case "whisperkit":
            path = "Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-\(model)"
        case "parakeet":
            path = "Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
        case "qwen3":
            // MLX aborts the whole process without its Metal library, and
            // SwiftPM never builds one: it must be copied into the test
            // bundle by hand, as a SwiftPM resource bundle so codesign
            // accepts it (see `make app`'s build-app.sh for the build step).
            // Codesign reshapes a flat bundle into Contents/Resources, so
            // look it up the way MLX does — through the bundle's resources.
            let mlxBundle = Bundle(for: Self.self).resourceURL?.appendingPathComponent("mlx-swift_Cmlx.bundle")
            guard mlxBundle.flatMap(Bundle.init(url:))?.url(forResource: "default", withExtension: "metallib") != nil else {
                return "no default.metallib in \(mlxBundle?.path ?? "the test bundle's resources")"
            }
            path = "Library/Caches/qwen3-speech/models/aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        default:
            return nil
        }
        let url = home.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? nil : "model not cached (\(path))"
    }

    /// Bench languages the provider declares; for Apple only the locales
    /// whose assets are already installed (no download from the bench).
    private static func benchLanguages(provider: any TranscriptionProvider, model: String) async -> Set<String> {
        var languages = Set(Self.languages)
        if let supported = provider.supportedLanguages(model: model) {
            languages.formIntersection(supported)
        }
        guard type(of: provider).id == AppleProvider.id else { return languages }
        guard #available(macOS 26, *) else { return [] }
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        return languages.filter { language in
            AppleLocaleCatalog.localeByLanguage[language].map { installed.contains($0) } ?? false
        }
    }

    private func run(
        _ clip: Clip,
        provider: String,
        model: String,
        path: String,
        transcriber: Transcriber
    ) async -> ClipResult {
        var config = TranscriptionConfig()
        // Apple decodes one locale per session, picked from the langset.
        if provider == AppleProvider.id { config.langset = [clip.language] }
        let samples = clip.composition.samples
        let started = Date()
        let output: TranscriptionOutput
        do {
            if path == "live" {
                guard let session = transcriber.makeLiveSession(config: config) else {
                    return ClipResult(clip: clip, provider: provider, model: model, path: path,
                                      error: "no live session")
                }
                output = try await session.run(samples: Self.pieces(of: samples)) { _ in }
            } else {
                output = try await transcriber.transcribe(samples, config: config) { _, _ in }
            }
        } catch {
            return ClipResult(clip: clip, provider: provider, model: model, path: path,
                              error: error.localizedDescription)
        }
        let result = ClipResult(clip: clip, provider: provider, model: model, path: path, output: output,
                                decodeSec: Date().timeIntervalSince(started))
        print("[bench] \(provider) \(path) \(clip.id): filler words \(result.wordsInFiller.map(String.init) ?? "-")"
            + " inserted \(result.insertedWords) WER \(String(format: "%.3f", result.wer))")
        return result
    }

    /// The live recorder's shape: the clip as a stream of 0.5 s pieces.
    private static func pieces(of samples: [Float]) -> AsyncStream<[Float]> {
        let step = Int(liveFeedSec * Double(TranscriptionConfig.sampleRate))
        return AsyncStream { continuation in
            for start in stride(from: 0, to: samples.count, by: step) {
                continuation.yield(Array(samples[start..<min(start + step, samples.count)]))
            }
            continuation.finish()
        }
    }

    // MARK: - Report

    private struct BenchReport: Encodable {
        let date: Date
        let skipped: [String: String]
        let clips: [ClipResult]
    }

    private struct ClipResult: Encodable {
        let provider: String
        let model: String
        let path: String
        let clip: String
        let language: String
        let filler: String?
        let layout: String
        let durationSec: Double
        let referenceWords: Int
        /// Words of the segments whose midpoint lies in filler; nil unless the
        /// engine's segments carry decode timestamps (`timedSegmentProviders`).
        let wordsInFiller: Int?
        /// Hypothesis words the alignment against the speech reference can
        /// only explain as insertions — comparable across every engine.
        let insertedWords: Int
        let wer: Double
        /// Text of the timed segments centred in filler (untrimmed ranges).
        let fillerText: String
        let text: String
        /// The engine's segments as returned (Whisper: decode timestamps).
        let segments: [TimedText]
        let decodeSec: Double
        let error: String?

        init(
            clip: Clip,
            provider: String,
            model: String,
            path: String,
            output: TranscriptionOutput = TranscriptionOutput(text: "", langStats: [:]),
            decodeSec: Double = 0,
            error: String? = nil
        ) {
            let reference = clip.composition.reference
            let fillers = clip.composition.fillerSeconds
            let segments = output.segments.map {
                TranscriptBenchMetrics.Segment(text: $0.text, startSec: $0.startSec, endSec: $0.endSec)
            }
            self.provider = provider
            self.model = model
            self.path = path
            self.clip = clip.id
            language = clip.language
            filler = clip.filler
            layout = clip.layout
            durationSec = Double(clip.composition.samples.count) / Double(SyntheticAudio.sampleRate)
            referenceWords = TranscriptBenchMetrics.words(reference).count
            let timed = TranscriptionHallucinationBenchTests.timedSegmentProviders.contains(provider)
            wordsInFiller = timed ? TranscriptBenchMetrics.wordsInFiller(segments: segments, fillers: fillers) : nil
            insertedWords = TranscriptBenchMetrics.insertedWords(reference: reference, hypothesis: output.text)
            wer = TranscriptBenchMetrics.wordErrorRate(reference: reference, hypothesis: output.text)
            let centredInFiller = segments.filter { segment in
                let mid = (segment.startSec + segment.endSec) / 2
                return fillers.contains { $0.contains(mid) }
            }
            fillerText = timed ? centredInFiller.map(\.text).joined(separator: " ") : ""
            text = output.text
            self.segments = segments.map { TimedText(text: $0.text, start: $0.startSec, end: $0.endSec) }
            self.decodeSec = decodeSec
            self.error = error
        }
    }

    private struct TimedText: Encodable {
        let text: String
        let start: Double
        let end: Double
    }

    private func write(_ report: BenchReport, env: [String: String]) throws -> URL {
        let dir = env["WATCHTOWER_TX_BENCH_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: report.date)
        let url = dir.appendingPathComponent("bench-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url)
        return url
    }

    /// Per provider × path: words over filler per filler kind (segment
    /// midpoint / alignment insertions, summed over the filler clips) and
    /// speech-only WER per language (edits over reference words).
    private static func summary(_ results: [ClipResult]) -> String {
        var lines = ["[bench] summary — filler cells: wordsInFiller/insertedWords; WER on speech-only clips"]
        let groups = Dictionary(grouping: results.filter { $0.error == nil }) { "\($0.provider) \($0.path)" }
        for key in groups.keys.sorted() {
            let rows = groups[key] ?? []
            let fillerCells = fillers.map(\.name).map { kind -> String in
                let hits = rows.filter { $0.filler == kind }
                let inFiller = hits.compactMap(\.wordsInFiller)
                let inFillerText = inFiller.count == hits.count ? String(inFiller.reduce(0, +)) : "-"
                return "\(kind) \(inFillerText)/\(hits.map(\.insertedWords).reduce(0, +))"
            }
            let werCells = languages.compactMap { language -> String? in
                let speech = rows.filter { $0.layout == "speech" && $0.language == language }
                let words = speech.map(\.referenceWords).reduce(0, +)
                guard words > 0 else { return nil }
                let edits = speech.map { $0.wer * Double($0.referenceWords) }.reduce(0, +)
                return "\(language) \(String(format: "%.3f", edits / Double(words)))"
            }
            lines.append("[bench] \(key): \(fillerCells.joined(separator: ", ")) | WER \(werCells.joined(separator: ", "))")
        }
        let failed = results.filter { $0.error != nil }
        if !failed.isEmpty {
            lines.append("[bench] \(failed.count) clip runs failed: "
                + Set(failed.map { "\($0.provider) \($0.path): \($0.error ?? "")" }).sorted().joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}
