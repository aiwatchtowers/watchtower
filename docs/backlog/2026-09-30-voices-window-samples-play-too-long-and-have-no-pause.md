---
type: bug
title: Voices window samples play too long and have no pause
status: done
priority: med
tags: [voice-registry, desktop, audio, ux, transcription]
context: docs/chat-projects-vision — backlog collection session, item 6 (owner screenshot of the Voices → Queue tab)
created: 2026-09-30
---

In the "Who spoke" Voices window (Queue tab, `VoicesWindowView` + `ClipPlayer`)
the per-cluster samples are hard to use:

1. **A sample plays far too long.** The owner reports having to sit through
   minutes of audio ("I'm not going to listen for 9 minutes"). In the research
   POC the samples were a few seconds each and that was very convenient.
   By design a clip should be `clipMinSec` 4 … `clipMaxSec` 10 s
   (`VoiceRegistryPolicy`, `ClusterFeatures.compute`) and `ClipPlayer.tick`
   should stop at `span.end` — so either the stop does not fire (timer/tick,
   or the player being replaced/leaked across cards), or some path plays the
   whole segment/recording. Reproduce and check which.
2. **Only Play, no Pause/Stop.** The button is a static "▶ 0:00". It should
   toggle play ⇄ pause (or stop) for the clip that is playing, show which clip
   is playing, and clicking another clip should switch to it.
3. **The three samples of a card are near-duplicates.** In the screenshot the
   clips of one card start at 0:00 / 0:10 / 0:20 (or 8:40 / 8:50 / 9:40) and all
   three show the *same* full-utterance text, truncated. They look like
   consecutive 10 s slices of one long diarized segment, not three distinct
   moments. Better: pick clips from different segments spread across the
   meeting, and show only the words spoken inside that clip (word/segment
   timestamps) rather than the whole utterance.

Suggested target: 3 clips of ~3–6 s each, from different parts of the
meeting, each with its own text, and a play/pause toggle. Keep the spec's
"no clip files written, play straight from the .caf" rule.

Screenshot note: it also contains real colleague names/emails — do not copy
them into fixtures.

> Original note: «когда ты мне делал было пиздато то, что семплики были по несколько сек и было очень удобно. Ну я же ебал 9 мин слушать. Плюс плей/пауз должен быть. Щас тока плей» (with screenshot)

**Fixed (fix/voices-followups):** (1) The playback itself was never long:
the stored clips of a real recording are 5–10 s and `ClipPlayer` seeks and
stops correctly on the AAC `.caf` (probed with `AVAudioPlayer` directly). The
"9 minutes" was the button label — "▶ 9:40" is the clip's *start* in the
meeting, which reads as a duration. The button now shows the clip's length
("▶ 6 s") and the start moves to a separate "at 9:40" caption;
`VoiceRegistryPolicy.clipMaxSec` drops 10 → 6 s. (2) `ClipPlayer` is
`@Observable` with `toggle(url:span:)`/`isPlaying(url:span:)`: the playing
clip's button turns into "■ Stop", clicking another clip switches to it —
Queue, Train and Review alike. (3) The near-duplicates were the diarizer's
10 s chunk slices of one long turn, each taken as its own "segment", and
every clip showed the whole merged utterance. `ClusterFeatures` now joins
same-speaker segments ≤ 0.5 s apart into speech runs, picks the longest runs
whose starts lie ≥ 60 s apart (topping up from nearer runs when too few are),
and lists them in time order; `ClipTranscript` (WatchtowerCore) shows only
the words whose proportional position falls inside the clip, "…"-marked where
the cut lands mid-utterance (utterances carry no word timestamps). Clip spans
are computed at save time, so recordings saved before this keep their old
spans (the new length label and clip text apply to them too). Still no clip
files written.
