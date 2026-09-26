import Foundation

/// One timestamped segment of a transcribed window (seconds relative to the
/// window start). An empty array from the engine = no speech in the window.
struct TranscribedSegment: Equatable, Sendable {
    let text: String
    let startSec: Double
    let endSec: Double
}

/// Abstraction over the on-device STT engine so tests never load WhisperKit/CoreML.
protocol WhisperWindowEngine: Sendable {
    /// Language probabilities for one audio window (16 kHz mono Float32 samples).
    func detectLanguage(_ samples: [Float]) async throws -> [String: Float]
    /// Transcribe one window with the language forced. `prompt` is the previous
    /// speech window's text tail in the SAME language — whisper's long-form
    /// conditioning convention — and is nil when unavailable or disabled.
    /// Contract: the prompt is ADVISORY. A conformer must not let it turn
    /// decodable speech into an error or silence — the transcribers keep their
    /// carried context across a failed window on the strength of this (see
    /// `decodeWithPromptFallback`, which WhisperKitEngine routes through).
    func transcribeWindow(_ samples: [Float], language: String, prompt: String?) async throws -> [TranscribedSegment]
}

/// Windowed-transcription parameters. Ported from snoop (1 s overlap, langset
/// {ru, uk, en}, confidence threshold 0.6, margin 0.2 over the runner-up,
/// first-window fallback "ru"); the window default was raised 20 → 30 s after
/// a full-recording A/B showed the longer context recovering quiet-speaker
/// replies the 20 s windows dropped (2026-08-07), at the price of live chunks
/// arriving every 30 s instead of 20.
struct TranscriptionConfig: Equatable {
    var windowSec: Double = 30
    var overlapSec: Double = 1.0
    /// Snap window boundaries to the quietest point within ±boundarySnapSec
    /// of the nominal end (0 disables snapping — exact legacy boundaries).
    var boundarySnapSec: Double = 2.5
    var langset: [String] = ["ru", "uk", "en"]
    var langThreshold: Float = 0.6
    var margin: Float = 0.2
    var firstWindowDefault: String = "ru"
    var forcedLanguage: String?   // non-nil disables detection entirely
    /// Condition each window's decode on the previous window's text, whisper's
    /// long-form convention. Off (the default — a 2026-08-07 full-recording
    /// validation measured quality parity at ~1.4x decode cost, so it ships
    /// dark) = every window decodes blind, as before this existed. Exposed as
    /// a Settings → Meetings toggle. Honoured by the WhisperKit path only
    /// — Qwen3, Parakeet and Apple run their own windowing and ignore it.
    var contextPrompt: Bool = false
    /// Run the live (in-progress) transcription pass while recording. Off =
    /// capture only; the batch path transcribes from the file after Stop.
    var liveTranscription: Bool = true
    /// Speaker roles: diarization post-pass renders [Я]/[Speaker N] labels.
    var diarization: Bool = true
    /// Clustering threshold for the diarizer's speaker embeddings; lower splits
    /// more aggressively. FluidAudio's own default (0.7) under-splits compressed
    /// meeting audio, merging distinct people into one cluster.
    var diarizationThreshold: Float = 0.6
    /// Explicit engine model for factories that honor it — stamped by the
    /// dictation lane from its resolved `dictation.model` choice and consumed
    /// by `DictationCenter.dictationEngineFactory`. nil (the default, and
    /// always the meeting path) = the factory resolves the model from its own
    /// Settings keys; `fromDefaults` never sets this.
    var model: String?
    static let sampleRate = 16_000
}

/// One timestamped segment of the full recording (absolute seconds), carrying
/// the language of its parent window. Feeds the diarization post-pass.
struct TranscriptSegment: Equatable, Sendable {
    let text: String
    let startSec: Double
    let endSec: Double
    let language: String
}

/// Result of transcribing a full recording.
struct TranscriptionOutput: Equatable {
    let text: String                 // newline-joined non-empty window texts
    let langStats: [String: Int]     // windows per language (speech windows only)
    var segments: [TranscriptSegment] = [] // absolute-timestamped, for diarization
}

extension TranscriptionConfig {
    /// Builds a config from the `transcription.*` UserDefaults keys backing the
    /// Settings "Transcription" section. Any key that is absent keeps the struct
    /// default, so an untouched install behaves exactly like `TranscriptionConfig()`.
    /// The model name is NOT read here — it is a separate key consumed by the
    /// engine factory. `defaults` is injectable so tests use an isolated suite.
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> TranscriptionConfig {
        var config = TranscriptionConfig()

        if let raw = defaults.string(forKey: "transcription.langset") {
            let parsed = raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !parsed.isEmpty { config.langset = parsed }
        }
        if defaults.object(forKey: "transcription.windowSec") != nil {
            let value = defaults.double(forKey: "transcription.windowSec")
            if value > 0 { config.windowSec = value }
        }
        if defaults.object(forKey: "transcription.boundarySnapSec") != nil {
            let value = defaults.double(forKey: "transcription.boundarySnapSec")
            if value >= 0 { config.boundarySnapSec = value }
        }
        if defaults.object(forKey: "transcription.langThreshold") != nil {
            config.langThreshold = Float(defaults.double(forKey: "transcription.langThreshold"))
        }
        if defaults.object(forKey: "transcription.margin") != nil {
            config.margin = Float(defaults.double(forKey: "transcription.margin"))
        }
        if defaults.object(forKey: "transcription.contextPrompt") != nil {
            config.contextPrompt = defaults.bool(forKey: "transcription.contextPrompt")
        }
        if defaults.object(forKey: "transcription.liveTranscription") != nil {
            config.liveTranscription = defaults.bool(forKey: "transcription.liveTranscription")
        }
        if defaults.object(forKey: "transcription.diarization") != nil {
            config.diarization = defaults.bool(forKey: "transcription.diarization")
        }
        if defaults.object(forKey: "transcription.diarizationThreshold") != nil {
            let value = Float(defaults.double(forKey: "transcription.diarizationThreshold"))
            if value >= 0.3 && value <= 0.9 { config.diarizationThreshold = value }
        }
        let force = (defaults.string(forKey: "transcription.forceLang") ?? "")
            .trimmingCharacters(in: .whitespaces)
        config.forcedLanguage = force.isEmpty ? nil : force

        return config
    }
}

/// Trims engine segments, drops empty ones, and lifts the survivors to
/// absolute timestamps. nil = the window produced no speech. Shared by
/// WindowedTranscriber (batch) and StreamingTranscriber (live) so their
/// text/segment shapes cannot drift.
func liftWindowSegments(
    _ raw: [TranscribedSegment],
    windowStart: Int,
    language: String
) -> (windowText: String, segments: [TranscriptSegment])? {
    let windowStartSec = Double(windowStart) / Double(TranscriptionConfig.sampleRate)
    let cleaned = raw
        .map {
            TranscribedSegment(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                               startSec: $0.startSec, endSec: $0.endSec)
        }
        .filter { !$0.text.isEmpty }
    guard !cleaned.isEmpty else { return nil }
    let lifted = cleaned.map {
        TranscriptSegment(text: $0.text,
                          startSec: windowStartSec + $0.startSec,
                          endSec: windowStartSec + $0.endSec,
                          language: language)
    }
    return (cleaned.map(\.text).joined(separator: " "), lifted)
}

/// Prompt for the next window: the previous speech window's tail, passed
/// only while the language sticks — a language flip drops the context so
/// e.g. a ru prompt never conditions an en window. Shared by
/// WindowedTranscriber (batch) and StreamingTranscriber (live) so their
/// conditioning cannot drift.
///
/// The 200-char cap is deliberately conservative rather than a technical
/// limit: the prompt seeds `currentTokens` toward WhisperKit's 223-token
/// decode budget for the window, so every char of context is bought from the
/// window's own output allowance. WhisperKit additionally suffix-trims the
/// encoded prompt to 111 tokens — for Cyrillic (multiple tokens per char)
/// that token trim can bind before this char cap; either way the FRESHEST
/// tail survives, since both trims take a suffix.
///
/// Known deviation: with the default `overlapSec` 1.0 the tail's final ~second
/// describes audio the NEXT window re-decodes, so the prompt slightly pre-empts
/// what the model is about to hear. A 48-window full-recording validation
/// (2026-08-07) showed no observable harm from this; accepted as-is, with a
/// timestamp-based trim of the overlapped tail as the future fix if evidence
/// ever points here.
func contextPromptTail(
    prevText: String?,
    prevLang: String?,
    language: String,
    config: TranscriptionConfig
) -> String? {
    guard config.contextPrompt,
          let prevText, !prevText.isEmpty,
          prevLang == language
    else { return nil }
    return String(prevText.suffix(200))
}

/// The rolling conditioning context: the previous speech window's text plus the
/// silent-window streak that expires it. One shared state machine so batch and
/// live cannot drift on WHEN context is dropped (`contextPromptTail` decides
/// whether it is USED for a given window).
struct ContextPromptState {
    /// Consecutive silent windows that expire the context. Bounds the
    /// prompt+retry tax over a long pause and stops minutes-old context from
    /// conditioning speech it has nothing to do with; language stickiness is
    /// separate and deliberately unbounded.
    static let silenceLimit = 3

    private(set) var text: String?
    private var silentStreak = 0

    /// A speech window refreshes the context and ends the streak.
    mutating func recordSpeech(_ windowText: String) {
        text = windowText
        silentStreak = 0
    }

    /// A silent window keeps the context until the streak reaches the limit.
    /// A FAILED window records neither: an error surfacing from the engine
    /// means the window yielded no usable speech even without the prompt (see
    /// `decodeWithPromptFallback`), so the carried context is not implicated
    /// and survives — an error streak therefore never expires it, a documented
    /// asymmetry with silence.
    mutating func recordSilence() {
        silentStreak += 1
        if silentStreak >= Self.silenceLimit { text = nil }
    }
}

/// Encodes a conditioning prompt the way WhisperKit's own CLI does: trimmed,
/// behind a leading space, with special tokens filtered out (the decoder
/// prepends `<|startofprev|>` itself). nil — never an empty array — when there
/// is nothing to condition on, since an empty `promptTokens` would still cost
/// the prefill cache while conditioning on nothing. The tokenizer is injected
/// so this stays pure and testable without loading a model.
func whisperPromptTokens(
    _ text: String?,
    specialTokenBegin: Int,
    encode: (String) -> [Int]
) -> [Int]? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    let tokens = encode(" " + trimmed).filter { $0 < specialTokenBegin }
    return tokens.isEmpty ? nil : tokens
}

/// Decodes one window, retrying ONCE without the prompt when a prompted decode
/// comes back empty or throws. Takes the decode step as a closure so the retry
/// rule is testable without loading a model.
///
/// A prompted decode can collapse to an immediate end-of-text on audio that
/// decodes fine clean, and a poisoned prompt must never cascade — the prompt is
/// advisory, so an empty-or-failed prompted window retries once without it.
/// Genuine silence stays silent (a SUCCESSFUL prompted decode whose clean retry
/// is also empty), but a prompted THROW is only absorbed when the clean retry
/// actually produced speech: an empty clean retry after a throw rethrows the
/// original error, so an engine failure can never masquerade as silence and
/// `lastEngineError` keeps its "total failure throws" guarantee. An error
/// reaching the transcriber therefore always means the window yielded no
/// usable speech even without the prompt (the clean retry failed, was empty
/// after a throw, or the run was cancelled — a cancelled run discards its
/// output) — which is why a failed window keeps its carried context.
///
/// Cost: WhisperKit skips its prefill KV cache for any prompted window (an
/// upstream `TextDecoder` limitation, flagged as unfinished in its own source)
/// and every prompt token costs a decoder pass. The retry doubles the decode
/// on any prompted window that comes back empty — a collapse OR genuine
/// silence, indistinguishable here, so each pause after speech pays it up to
/// `ContextPromptState.silenceLimit` times before expiry kicks in. Once the
/// task is cancelled nothing is retried — the engine-slot residency bound is
/// one window.
///
/// NOT covered here: the repetition-loop pathology, where a prompt sends the
/// decoder into a repeating phrase and produces plenty of "speech". WhisperKit's
/// own compressionRatio/logProb temperature fallback is the active mitigation.
func decodeWithPromptFallback(
    promptTokens: [Int]?,
    decode: ([Int]?) async throws -> [TranscribedSegment]
) async throws -> [TranscribedSegment] {
    guard promptTokens != nil else { return try await decode(nil) }

    do {
        let segments = try await decode(promptTokens)
        guard !containsSpeech(segments), !Task.isCancelled else { return segments }
        return try await decode(nil)
    } catch {
        guard !Task.isCancelled else { throw error }
        let retried = try await decode(nil)
        guard containsSpeech(retried) else { throw error }
        return retried
    }
}

/// Whether a decode produced anything usable, under the same trimming rule
/// `liftWindowSegments` applies downstream.
private func containsSpeech(_ segments: [TranscribedSegment]) -> Bool {
    segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Detection with sticky fallback, shared by WindowedTranscriber (batch) and
/// StreamingTranscriber (live) so their language selection cannot drift. A
/// detection error is treated as low confidence (fallback), never fatal.
/// Only called when `config.forcedLanguage == nil`.
func resolveWindowLanguage(
    for window: [Float],
    previous: String?,
    config: TranscriptionConfig,
    engine: WhisperWindowEngine
) async -> String {
    let fallback = previous ?? config.firstWindowDefault
    guard let probs = try? await engine.detectLanguage(window) else {
        return fallback
    }
    let restricted = probs
        .filter { config.langset.contains($0.key) }
        .sorted { $0.value > $1.value }
    guard let best = restricted.first else { return fallback }
    let runnerUp = restricted.dropFirst().first?.value ?? 0
    if best.value >= config.langThreshold && (best.value - runnerUp) >= config.margin {
        return best.key
    }
    return fallback
}
