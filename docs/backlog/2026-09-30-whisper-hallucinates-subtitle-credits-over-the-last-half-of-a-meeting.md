---
type: bug
title: Whisper hallucinates subtitle credits over the last half of a meeting
status: done
priority: high
tags: [transcription, whisperkit, hallucination, meeting-recorder, diarization]
context: docs/chat-projects-vision — backlog collection session, item 4; checked against the owner's latest recording (a ~36 min Russian meeting, 2026-09-30)
created: 2026-09-30
---

The latest meeting transcript is fine for its first ~17 minutes and then turns
mostly into the classic Whisper YouTube-subtitle hallucinations, repeated over
and over:

- «Продолжение следует...» (dozens of times per segment)
- «Субтитры сделал DimaTorzok»
- «Спасибо за субтитры Алексею Дубровскому!»
- stray «Спасибо.» / «Да.»

From ~1033 s to the end (2191 s) almost every segment is dominated by these
phrases, with only a few short real utterances in between. Several segments are
90–120 s long, i.e. whole windows decoded into the loop. Many of these lines are
attributed to `[Я]` (mic-dominant), some to `Speaker N`. The recap/notes built
from this text inherit the garbage.

Setup at the time (Desktop defaults): engine `whisperkit`, model `large-v3`
(not the turbo `large-v3-v20240930` default), `windowSec` 30,
`transcription.contextPrompt` not set (= off, so this is not the prompt-carry
pathology), language auto (`lang_stats` = all ru).

Hypotheses to check:
- the remote side's audio dropped out mid-meeting (system audio tap lost after
  an output-device switch / headphones, or the call app changed process), so
  the windows held only quiet mic room tone — Whisper fills near-silence with
  these credits; that would also explain the `[Я]` attribution. Check the
  recording's `rec_X.activity` sidecar (system RMS over time) for that range;
- WhisperKit's no-speech / logprob / compression-ratio thresholds are not
  catching it (`TranscriptionEngine.swift` notes only rely on WhisperKit's own
  compressionRatio/logProb fallback). A repetitive «Продолжение следует...» x30
  should fail a compression-ratio check — verify the options are actually set;
- the real audio is there, but the non-turbo `large-v3` is more prone to it.

Fix ideas:
- skip/blank windows below a speech-energy floor (VAD) before decoding;
- a post-decode filter: drop segments made of known hallucination phrases
  (ru/uk/en subtitle-credit list) and collapse n-gram repetition loops;
- tighten `noSpeechThreshold` / `compressionRatioThreshold` / `logProbThreshold`;
- a regression fixture: a silent / room-tone window must decode to nothing.

> Original note: «Субтитры сделал DimaTorzok Субтитры сделал DimaTorzok - в транскрайбе. Посмотри последний мит транскрайб - там в конце полная ебаторика»

**Fixed (fix/whisper-credits-hallucination):** The first hypothesis held.
The recording's `rec_X.activity` sidecar shows the system-audio RMS dropping
to exactly 0 at ~930 s and staying there (a few isolated blips) until the end,
while the mic kept its usual room-tone level. The remote side was no longer
captured, so Whisper was decoding near-silence and filling it with subtitle
boilerplate. That also explains the `[Я]` attribution, since only the mic
carried signal.

- `WhisperHallucinationFilter` (WatchtowerCore, pure) runs on every WhisperKit
  segment inside `WhisperKitEngine.decode` (`[TranscribedSegment].withoutHallucinations()`).
  The live and batch paths therefore get the same output, and the
  `StreamingTranscriber` equivalence pins are untouched. It removes:
  - the subtitle-credit forms («Субтитры сделал/создавал …», «Спасибо за
    субтитры …», «Редактор субтитров … Корректор …», "Subtitles by …");
  - the ellipsis form of «Продолжение следует…» and its uk/en equivalents,
    anywhere in a segment;
  - whole-sentence sign-offs («Спасибо за просмотр», «Дякую за перегляд»,
    "Thanks for watching" …);
  - runs of 3 or more identical sentences, collapsed to one.

  A segment left with no letters is dropped, so an all-credit window reads as
  silence.
- Checked offline against the five most recent real transcripts. Every
  credit and continuation loop is gone (35 + 10 + 9 occurrences in the
  reported meeting). No other words were removed apart from one collapsed
  "Ну, да." ×4 loop.
- Default on, with no toggle: the filter only removes text, and only these
  fixed forms. It needs no audio validation. The decoding thresholds were left
  unchanged, since tuning them would need real-audio validation.

**Not fixed here (follow-up):** why the system-audio tap went silent
mid-meeting. Likely an output-device switch or the call app changing
process. The capture neither reports this nor recovers from it. Existing
transcripts are not rewritten.
