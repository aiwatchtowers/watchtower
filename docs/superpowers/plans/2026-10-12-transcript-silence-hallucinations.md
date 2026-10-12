# Transcripts that invent text over silence (board #554) — plan

Spec: `docs/superpowers/specs/2026-10-12-transcript-silence-hallucinations-design.md` (decisions D1–D6 are
binding; quote them, do not re-decide). Branch `feature/554-silence-hallucinations`, one PR.

All tasks are Swift and run in **one lane, in order** (one ML-stack build at a time). Inner loop per task:
`make test-swift FILTER=<classes>` and `make lint-diff`; Core logic goes to WatchtowerCore + `Tests/Core`.
Never weaken `StreamingTranscriberTests`/`WindowedTranscriberTests` equivalence assertions; update expected
values only where D4 changes them, and say so in the commit.

## Task 1 — Corpus and bench, "before" numbers (board #555)

Depends on: none.

- `scripts/transcribe-bench-fetch.sh`: fetches LibriSpeech test-clean (en) and Common Voice (ru, uk) samples,
  ~10 utterances each with references, into `~/Library/Caches/watchtower-bench/`; prints licences; idempotent.
- `Tests/Support/SyntheticAudio.swift`: generators per D6 (zeros, white/pink noise at given dBFS, hum, fade to
  dither), deterministic (seeded RNG), 16 kHz mono Float32; `compose([Piece])` returning samples + a timeline of
  `(kind: speech|filler, range, reference?)`.
- `Tests/TranscriptionHallucinationBenchTests.swift`: env-gated (`WATCHTOWER_TX_BENCH=1`, cache present), runs
  each available provider batch + live (live = feed the composed samples in 0.5 s pieces into the provider's
  live session), writes `bench-<date>.json` (per clip: provider, path, words in filler, WER on speech).
- Word counting and WER as pure helpers in WatchtowerCore (`TranscriptBenchMetrics`): normalise case and
  punctuation; WER = word-level Levenshtein / reference words.

Tests that must pass (unit, not env-gated): generators — zeros are exact zeros, noise RMS within ±1 dB of the
target, same seed → same samples; `compose` timeline offsets exact; metrics — WER 0 on identical text,
1 substitution in 4 words = 0.25, empty hypothesis = 1.0, punctuation/case ignored; words-in-filler counts only
words whose segment midpoint lies in a filler range (±0.5 s tolerance).

Done: the bench runs locally, "before" numbers posted as a comment on #555 (counts per provider/path/filler, WER).

## Task 2 — VAD gate L1 + L2 (board #556)

Depends on: Task 1.

- `SpeechDetector` protocol, `SileroSpeechDetector`, `EnergySpeechDetector` (Core), `SpeechGate` decisions
  (Core) per D1/D2; `TranscriptionConfig.speechGate` + `fromDefaults` key; dictation stamps it false.
- Gate wired into `WindowedTranscriber` and `StreamingTranscriber` through one shared helper; WhisperKit
  transcriber creates the detector lazily; VAD model added to `AppState.prefetchDiarizerModels`.
- Tune the D1 thresholds on the corpus; record the numbers in a comment next to the constants.

Tests: silent window (fake detector → no ranges) is never passed to `detectLanguage` or `transcribeWindow`, fires
progress, does not count or stick; speech window with a segment entirely in a VAD gap → dropped; segment
overlapping 0.25 s → kept; segment 1 s long overlapping 0.35 s (35 %) → kept; zero-length segment inside a range
→ kept, outside → dropped; window with 0.2 s of speech → silent; detector throws → energy fallback used, window
decoded; all-silent recording with no engine errors → empty output, no throw; all windows failing → still throws;
batch and live give identical output with the gate on (existing equivalence test extended with a fake detector);
`speechGate` false → detector never called; `fromDefaults` reads the key, absent → true; Energy detector:
zeros → [], −30 dBFS tone → one padded range, −60 dBFS noise → [].

## Task 3 — Whisper confidence L3 (board #557)

Depends on: Task 2.

- `WhisperSegmentConfidence.shouldDrop(noSpeechProb:avgLogprob:compressionRatio:)` (Core) per D3; explicit
  `DecodingOptions` values; engine drops before mapping; per-reason count logging.
- Tune the `avgLogprob` cut-off on the corpus: no reference phrase may be lost.

Tests: (0.7, −1.2, 1.5) → drop; (0.7, −0.5, 1.5) → keep; (0.2, −1.2, 1.5) → keep; (0.1, −0.3, 2.6) → drop;
(0.1, −1.7, 1.5) → drop; boundary values exactly at the thresholds → keep; a test that `DecodingOptions` built by
the engine's options factory carries the four pinned values (factor the options into a testable function).

## Task 4 — No prompt across silence L4 (board #558)

Depends on: Task 2.

- `ContextPromptState.silenceLimit` = 1; update the doc comments that cite 3; update the prompt-sequence
  expectations in the equivalence tests.

Tests: speech → one silent window → speech: the third window's prompt is nil (batch and live); speech → failed
window → speech: prompt survives (unchanged asymmetry); language flip still drops the prompt.

## Task 5 — Every provider, control run, docs, owner check (board #559)

Depends on: Tasks 2–4.

- `Qwen3Windower`: L1 through the shared helper (no L2); phrase filter on its window text.
- `ParakeetTranscriber`, `AppleTranscriber`: L5 muting per D5; phrase filter on their text; if the bench shows
  words over zeros, switch that engine to per-range decoding (D5) and record why.
- Run the bench, post "after" numbers on #559; done criteria 1–2 of #554 must hold.
- Update `docs/features/meeting-transcriber.md` (the layers, the kill-switch key, the bench) and
  `docs/app-guide.md` if anything user-visible changed.
- File the owner's manual check (`ask_owner`, kind check): a recording with a ≥ 1 min pause, live and after Stop,
  with Whisper and one other engine.

Tests: Qwen3 silent window never decoded; Qwen3 live == batch with the gate; muting helper — samples outside
padded ranges are exactly 0, inside unchanged, empty ranges → all zeros; phrase filter applied to Parakeet/Apple
text (fake engine returns "Продолжение следует..." → empty output).

## Gate before the PR

`make test`, `make test-swift`, `make lint-all`; then `local-review`/`debate-review` on the PR diff.
