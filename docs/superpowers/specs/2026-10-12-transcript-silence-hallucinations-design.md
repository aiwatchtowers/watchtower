# Transcripts that invent text over silence (board #554) — technical spec

Business spec: `2026-10-12-transcript-silence-hallucinations-business.md`. Plan:
`docs/superpowers/plans/2026-10-12-transcript-silence-hallucinations.md`. Read
`docs/features/meeting-transcriber.md` first (dual paths live↔batch, recap guard, warm engine slot).

Decisions and contracts only. Paths are under `WatchtowerDesktop/Sources/` unless stated.

## Defence layers

| Layer | Where | Covers |
|---|---|---|
| L1 VAD gate: a window with no speech is never decoded | shared window loops | Whisper, Qwen3 |
| L2 segment-outside-speech drop | shared, after decode | Whisper (has segment timestamps) |
| L3 Whisper confidence drop | `WhisperKitEngine` | Whisper |
| L4 no prompt across silence | `ContextPromptState` | Whisper with `contextPrompt` on |
| L5 non-speech muted before a whole-buffer engine | Parakeet, Apple transcribers | Parakeet, Apple |
| existing phrase filter | `WhisperHallucinationFilter` | now applied to every provider's text |

## D1. Speech detection contract

- `protocol SpeechDetector: Sendable { func speechRanges(in samples: [Float]) async throws -> [Range<Int>] }`
  (`Services/Transcription/SpeechDetector.swift`). Ranges are sample offsets relative to `samples`, sorted,
  non-overlapping, already padded. Stateless across calls: the same samples always give the same ranges — this is
  what keeps live↔batch equivalent (both paths call it on identical window samples).
- Production: `SileroSpeechDetector` wraps FluidAudio `VadManager` + `segmentSpeech(_:config:)`. Pinned defaults
  (tuned in Task 1/2 by the corpus, then fixed as constants with the measured numbers in a comment):
  `VadConfig.defaultThreshold` 0.5 (FluidAudio's 0.85 is tuned for ASR chunking and drops quiet speech),
  `minSpeechDuration` 0.25 s, `minSilenceDuration` 0.5 s, `speechPadding` 0.3 s.
- Fallback when the VAD model cannot load or throws: `EnergySpeechDetector` (pure, WatchtowerCore) — 20 ms frames,
  speech = frame RMS above −50 dBFS, same min-speech / padding rules. Never "no gate": a failed VAD must not
  silently restore the hallucinating path. The fallback is logged once per recording (counts only).
- Model provisioning: the VAD model is fetched with the diarizer models in `AppState.prefetchDiarizerModels`
  (`TranscriptionModelProvisioner` extras); a missing model at transcribe time downloads on first use like the
  diarizer does. One detector instance per recording, created next to the transcriber (not a new engine slot).
- Kill switch: hidden UserDefaults key `transcription.speechGate` (absent = on), read by
  `TranscriptionConfig.fromDefaults` into `speechGate: Bool = true`. No Settings UI (business spec decision 1).

## D2. The window gate (L1 + L2) — `Services/Transcription/SpeechGate.swift`

Pure decision logic in WatchtowerCore (`SpeechGate`), the async glue next to `liftWindowSegments`:

- `isSilent(ranges)` ⇔ total speech in the window < `minWindowSpeechSec` 0.3 s.
- A silent window: no language detection, no decode, `promptState.recordSilence()`, progress fires, not counted in
  `langStats`, language does not stick — exactly the existing empty-decode semantics, only cheaper.
- A speech window decodes as today (whole window, unchanged boundaries — `WindowPlanner` is not touched). After
  decode, a segment is kept iff its `[startSec, endSec]` overlaps the speech ranges by ≥ 0.2 s **or** by ≥ 30 % of
  its own duration (Whisper timestamps drift; the generous rule protects real speech — business decision 2). A
  zero-length segment is kept iff its start lies inside a range.
- Order: VAD → (language) → decode → L3 (inside the engine) → phrase filter → L2 → `liftWindowSegments`.
- A detector error on one window: fall back to `EnergySpeechDetector` for that window; never skip the window.
- Shared by `WindowedTranscriber`, `StreamingTranscriber` and `Qwen3Windower` through one helper so the three
  loops cannot drift (same rule as `liftWindowSegments`/`contextPromptTail`). Qwen3 has no segment timestamps:
  L1 only, its window text stays whole.
- The dictation lane is out of scope: it builds its config through the same providers, so the dictation config
  stamps `speechGate = false` (the way it already stamps `model`) and keeps today's behaviour. The detector is
  created lazily by the `Transcriber` on the first `transcribe`/`makeLiveSession` call whose config has
  `speechGate` true (the config only arrives there), and reused for the transcriber's lifetime.

## D3. Whisper confidence (L3) — `WhisperKitEngine`

- `DecodingOptions` set explicitly: `temperatureFallbackCount` 5, `compressionRatioThreshold` 2.4,
  `logProbThreshold` −1.0, `noSpeechThreshold` 0.6 (WhisperKit's own values, now pinned so an upgrade cannot
  move them), `chunkingStrategy` stays nil (our windows are already ≤ 30 s).
- Per segment, after decode: drop iff `(noSpeechProb > 0.6 && avgLogprob < −1.0)` or `compressionRatio > 2.4`
  or `avgLogprob < −1.6`. The last cut-off is tuned on the corpus (Task 3) and must not drop any reference phrase.
  The rule is a pure function in WatchtowerCore (`WhisperSegmentConfidence`) taking three Floats — testable
  without WhisperKit.
- `TranscribedSegment` does not grow: the engine filters before mapping.
- Log line per window that dropped anything: counts by reason (`vad`, `outside_speech`, `confidence`, `phrase`)
  and dropped char count. Never text.

## D4. Prompt across silence (L4)

`ContextPromptState.silenceLimit` 3 → 1: one silent window expires the context. With L1 a silent window is a
VAD verdict, not a decode result. `decodeWithPromptFallback` is unchanged. The live↔batch equivalence tests that
pin the prompt sequence are updated to the new limit — not relaxed (same assertions, new expected sequence).

## D5. Whole-buffer engines (L5) — Parakeet, Apple

Both hand the full buffer to the engine. Before that: run the detector over the full recording in 30 s chunks
(VAD cost is negligible), and replace every sample outside the padded speech ranges with 0. If the corpus shows
the engine still emits words over zeros (Task 5 measures), switch that engine to decoding each speech range
separately and joining the texts. The phrase filter then runs on the engine's text. Their `langStats`/segments
behaviour is unchanged.

## D6. Corpus and bench (Task 1)

- Repo holds **no recordings**. Synthetic signals are generated in code (`Tests/Support/SyntheticAudio.swift`):
  digital zeros; white and pink noise at −60/−45 dBFS; 50 Hz hum + harmonics at −40 dBFS; speech followed by a
  fade to −90 dBFS dither (the "system audio went quiet" case).
- Speech comes from open datasets with licences that allow it, fetched by `scripts/transcribe-bench-fetch.sh`
  into `~/Library/Caches/watchtower-bench/` (never into the repo): Google FLEURS test split (CC BY 4.0, public on
  Hugging Face, no sign-in) for en, ru and uk, ~10 utterances each, reference transcripts kept with them. The script prints
  the licence lines; a missing cache makes the bench skip, never fail.
- Clips: `speech A → 60 s filler → speech B` for each filler × language, plus "speech then 3 min of filler",
  plus speech-only clips for WER.
- Bench: env-gated XCTest `TranscriptionHallucinationBenchTests` (skips unless `WATCHTOWER_TX_BENCH=1`), runs
  every available provider in batch and (where `supportsLive`) live, writes JSON to the scratch dir:
  words inside filler stretches (by the known timeline ± 0.5 s), WER on speech vs reference. Run locally only;
  CI never runs it. "Before" numbers go on board #555, "after" numbers on #559.
- Owner's own recordings are never used by the bench (owner ruling, ask #172); the manual check is #559's ask.

## Invariants (guard tests must keep holding)

- `StreamingTranscriberTests.testMatchesBatchOnSameSamples` and the Windowed/Streaming equivalence family keep
  their assertions; new fakes include a fake `SpeechDetector`.
- Total engine failure still throws (a silent-by-VAD window is not an engine error and not a failure).
- `WindowPlanner` boundaries unchanged.

## Non-goals

Per-channel (mic vs system) detection — the transcriber sees a mono mix. UI marking of doubtful text.
Speaker-level changes. Dictation.

## Implementation notes (2026-10-12, measured on the bench corpus)

Deviations accepted during implementation; the constants carry the numbers in their comments.

- D1 energy fallback: the level is adaptive — max(−70 dBFS, the window's quietest tenth of frames + 10 dB).
  Half the FLEURS utterances sit at −60…−66 dBFS RMS, so a fixed −50 dBFS floor skipped 14 speech windows,
  and a fixed floor of any value opens steady −45 dBFS noise and −40 dBFS hum.
- D1 Silero: minimum speech 0.3 s (not 0.25) — FluidAudio asserts padding ≤ minimum speech; padding stays 0.3 s.
  A detector error switches the rest of that recording to the fallback (no per-window retry); the next recording
  tries the model again.
- D2 L2 rule unchanged (≥ 0.2 s or ≥ 30 %): it dropped no real segment on the corpus. Two short-segment
  tightenings were evaluated and rejected — "≤ 3 words need ≥ 50 % overlap" dropped a real phrase whose start
  Whisper stretched 16 s into the pause; "drop a short segment ending outside speech" is fitted to a tiny sample and
  would drop short real replies whose end Whisper stretches to the window edge.
- D3: the logprob judged is the segment's own text-token mean (WhisperKit's segment `avgLogprob` is per decode pass).
  The −1.6 cut-off stays: a real sentence at 0 dB SNR scored −1.48, so −1.2 lost speech. WhisperKit 0.18 never
  computes `noSpeechProb`, so the first rule is dormant.
- D5: no engine wrote over zeros on the corpus, so Parakeet and Apple keep whole-buffer decoding (muted); a
  recording with no detected speech is not decoded. The kill switch also covers the new phrase-filter uses.
- Known leftovers after all layers: short phrases at speech edges («Звучить.», «Играет музыка.», «Спасибо.»,
  «Дякую.») — reported, not filtered.

