---
type: bug
title: System-audio tap can go silent mid-recording without any signal
status: open
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
