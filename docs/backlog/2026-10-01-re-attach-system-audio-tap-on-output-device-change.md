---
type: bug
title: Re-attach the system-audio tap when the output device changes mid-recording
status: open
priority: med
tags: [transcription, meeting-recorder, audio-capture, desktop, coreaudio]
context: split from docs/backlog/2026-10-01-system-audio-tap-dropout-is-silent.md (detection and warning shipped in PR #71)
created: 2026-10-01
---

A recording can lose the call partway through. The system-audio tap stops
delivering anything, typically after the default output device changes
(headphones plugged in or unplugged, a Bluetooth headset connecting) or after
the call app moves its audio to another process. Since PR #71 the owner is
warned while it happens: the recording pill says "No call audio", a
notification goes out, and the recording detail notes the gap. The capture
does not recover on its own, though. The owner has to notice the warning and
fix the output device by hand.

Wanted: `SystemAudioRecorder` listens for default-output-device changes (and,
if feasible, a process tap going quiet) and rebuilds the tap and aggregate
device on the fly, without restarting the recording. The `.caf` file and the
`rec_X.activity` sidecar keep going, with at most a short gap at the switch.

Constraints:
- No new TCC prompts. The tap is re-created with the same permission the
  recording already holds.
- Never fails the recording. If a rebuild fails, the recording keeps
  capturing the mic, and the existing warning stays up.
- The live↔batch transcription invariants are untouched. This is capture
  only.
- Needs validation on real hardware (switching headphones mid-call) before it
  ships. If the behaviour is uncertain, ship it dark behind a Settings
  toggle, following the house precedent.
