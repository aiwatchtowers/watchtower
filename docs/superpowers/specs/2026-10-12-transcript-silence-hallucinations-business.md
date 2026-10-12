# Transcripts that invent text over silence (board #554) — business spec

**For:** the owner. One page. The tech spec is `2026-10-12-transcript-silence-hallucinations-design.md`.

## The problem

When a recording goes quiet — a pause, an empty room, the other side muted, the call audio gone silent — the
transcript fills the gap with text nobody said: podcast-style phrases, random sentences, subtitle credits. It is
a known habit of Whisper (it was trained on subtitles and fills silence with what subtitles usually say), and two
things in our pipeline make it worse: every 30-second window goes to the model even when it holds no speech at
all, and the previous window's text is fed in as a hint for up to three silent windows, so the model "continues"
the conversation into the silence. Our current filter only removes a fixed list of known phrases, so anything new
slips through. One invented sentence is enough to make the whole transcript untrustworthy.

## What changes

- **Silence is never transcribed.** A small voice detector (Silero VAD, already shipped inside a library we use;
  about 2 MB, downloaded once with the other models) checks each piece of audio first. A piece with no speech is
  not sent to the transcription model at all — it reads as silence, as it is.
- **Text outside speech is dropped.** When a window holds a little speech and a long pause, any text the model
  places in the pause is removed.
- **Low-confidence text is dropped.** Whisper reports how sure it is about each sentence and whether it thinks
  there was speech; sentences it is unsure about over likely-silence, and looping repeats, are removed.
- **No hint across a pause.** The previous window's text is no longer passed into a window after a silent one.
- **Every engine, live and after Stop.** The same protection covers Whisper, Qwen3, Parakeet and Apple, and both
  the live transcript during the meeting and the final one after Stop.
- Invented text is **removed, not marked**. Logs keep counts only, never the text (as today).

## What you will see

Pauses in a meeting transcript stay empty. Real speech reads as before — if anything slightly faster, since
silent stretches are skipped. Nothing new in Settings.

## Decisions (with my recommendation)

1. **Switch.** Recommended: always on, no Settings toggle; a hidden setting exists only to switch it off if a
   problem shows up in the field. Alternative: a visible toggle in Settings → Meetings.
2. **What wins on a borderline case** (a very quiet, distant voice the detector is unsure about). Recommended:
   keep the speech — the detector and the confidence filter are tuned so that no real phrase in the test set is
   lost, even if that lets a rare invented word through. Alternative: stricter, risking a lost quiet reply.

## Out of scope

- Fixing what is said while people talk (wrong words in real speech) — this is only about silence.
- Separate detection for your microphone and the call audio: the transcriber hears them already mixed into one
  track, so the detector works on the mix.
- Marking doubtful text in the UI instead of removing it.

## How we know it is done

1. A test set built from generated audio (digital silence, room-like noise, hum, call audio fading out) and
   licensed open speech recordings: "speech → a minute of silence or noise → speech". No word lands in a silent
   stretch, for every engine, live and after Stop. Numbers before and after go on the board.
2. On the speech parts no real phrase is lost: the word error rate is no worse than before.
3. You check one of your own recordings with a long pause (an ask at the end): nothing invented.
