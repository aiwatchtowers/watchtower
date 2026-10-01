---
type: bug
title: System-audio tap can go silent mid-recording without any signal
status: done
priority: high
tags: [transcription, meeting-recorder, audio-capture, desktop]
context: found while fixing docs/backlog/2026-09-30-whisper-hallucinates-subtitle-credits-over-the-last-half-of-a-meeting.md
created: 2026-10-01
---

On a real ~36 min recording the `rec_X.activity` sidecar shows the system
(remote) channel RMS dropping to exactly 0 at ~930 s and staying there until
the end. A few isolated blips appear later. The mic kept its normal
room-tone level throughout. The remote side of the meeting was not captured
from that point on, and nothing reported it. The transcript of the rest is
mic-only, labeled `[Я]`. Before the Whisper hallucination filter
(`WhisperHallucinationFilter`), the dropout at least showed up as subtitle-credit
garbage. Now that the filter removes that garbage, the gap is invisible unless
someone reads the sidecar.

Likely causes to check: an output-device switch (headphones), or the call
app changing process, which leaves the CoreAudio process tap reading
nothing. See `SystemAudioRecorder`.

Wanted:
- **Detect.** A sustained run of exact-zero system RMS (for example ≥ 60 s)
  after a period of non-zero system audio, while the mic stays above room
  tone. Real remote silence still carries codec noise, so an exact 0 is the
  signature. This is a pure check over `MicActivity.bins`, which are already
  loaded after Stop.
- **Surface.**
  - Live: a warning in `RecordingIndicatorView` so the owner can fix the
    output device during the call.
  - After Stop: a caption on the recording, "Remote audio stopped being
    captured at mm:ss".
- **Recover, if feasible.** Re-attach the tap on a default-output-device
  change.
- **Fail with a clear reason.** When a whole recording yields no speech
  because of this, the failure message should say so, instead of a bare
  "No speech recognized".

**Fixed (fix/system-audio-dropout) — detection and warning; recovery still open.**
`CallAudioWatch` (WatchtowerCore, pure, incremental) watches the system channel
in ~100 ms RMS steps. A *gap* is a stretch of at least 2 minutes below
`1e-4` RMS that starts right after the call was being heard: at least 30 s of
call audio in the preceding 5 minutes. It ends when the call is back: 2 s of unbroken call audio, or 5 s of it
within 10 s. A notification blip is shorter, so it does not end the gap.

The same detector drives three surfaces:
- **Live.** `MeetingRecorderCenter` feeds it the existing level stream and
  publishes `callAudioSilentSince`. The recording pill shows "No call audio"
  in orange with an explanatory tooltip, and one system notification goes
  out each time a gap opens, since the owner is usually looking at the call
  app. Both clear when call audio returns and on stop.
- **After the fact.** The recording detail reads the `rec_X.activity` sidecar
  off-main and shows "No call audio from 15:29 to the end — the transcript
  there may hold only your microphone". One or two gaps are listed; more are
  summarized.
- **No-speech failure.** A recording that yields no text now fails with
  "No speech recognized — no call audio was captured at all …" or
  "… call audio stopped at mm:ss and never came back …", instead of a bare
  "No speech recognized".

None of this ever fails a save. The message stays the bare one when there
is no sidecar.

**Calibration.** The detector was replayed over 33 real sidecars, offline and
not committed:
- The reported recording flags from 15:29 to the end.
- Room-only recordings, with no call or only system sounds, are not
  flagged.
- A few long quiet stretches inside real calls are flagged too. This is
  inherent: a dead tap and a silent call both write zeros. That is why the
  wording states a fact ("no call audio") and never a diagnosis.

**Accepted limits:**
- A recording whose call audio is missing from the very first second gets
  no gap. It cannot be told apart from a room-only meeting. Only the
  no-speech message names it.
- A complete IO stall that delivers no level pairs at all is not detected.
- The note disappears once retention sweeps the audio, because the sidecar
  is swept with it.

**Still open:** re-attaching the tap on a default-output-device change, so a
dropout recovers on its own. This needs CoreAudio work in
`SystemAudioRecorder` and real-hardware validation.

