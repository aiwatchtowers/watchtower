# Recording or transcript problems

**Record** does nothing, the pill shows a failure, the transcript holds only your voice, or no recap appears.

## What you see

- An error under the pill: "Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone." or "System audio recording was denied. Enable it in System Settings → Privacy & Security → Screen & System Audio Recording."
- "Meeting recording requires macOS 14.4 or newer."
- An orange **No call audio** during the call, or a note "No call audio from 15:29 to the end".
- A failed pill with the message "No speech recognized", and **Retry** and **Dismiss**.
- A failed pill with "The recording file was not finalized — the audio is kept for recovery." or "The recording file is not finalized — its audio could not be read. The file is kept for recovery."
- A recording with a transcript but no recap.
- A model download pill with **Retry**.
- A pill reading "Waiting for the recording to stop" while another meeting records.

## Why

Recording needs two macOS permissions, microphone and system audio, and macOS 14.4 or newer. The call's audio is lost when the output device changes mid-call. Transcription runs on your Mac with a speech model that downloads once; the recap is written by your AI provider afterwards.

## Fix

1. **Permission denied:** open the System Settings page named in the message, switch Watchtower on, then start the recording again.
2. **No call audio:** check which output device the call uses. Keep **Follow audio device changes** on in **Settings → Meetings** so the capture follows headphones. Audio already lost cannot be recovered; the transcript will hold only your side.
3. **"No speech recognized":** the note says whether call audio was missing. Fix the device, then press **Retry** on the pill. The audio is kept.
4. **"The recording file was not finalized":** the audio was captured, but the file was not closed properly, so Watchtower cannot read it and **Retry** fails the same way. The audio file stays on your Mac until the audio cleanup, so it can still be rescued by hand. New recordings are not affected.
5. **Model download failed:** press **Retry** on the download pill once the network is back. A model already downloaded needs no network.
6. **"Waiting for the recording to stop":** nothing is wrong. That recording has to be transcribed from its audio, and transcription waits until the recording in progress stops. It then starts on its own.
7. **No recap:** open the recording and use **Generate recap** on the **Recap** tab, or **Retry recap** under the transcript. A transcript under 200 characters gets no recap by design.
8. **Wrong transcript:** **Re-transcribe** under the transcript runs it again while the audio file exists. Audio is deleted after 30 days (**Delete audio after N days** in **Settings → Meetings**).
9. **The app quit mid-recording:** at the next launch press **Transcribe recovered recording** on the pill.
10. **Can't find an old recording:** recordings open only from the **Calendar** tab, and the list loads the newest 200. Without a connected calendar the tab is hidden; see [Calendar events are missing](calendar-events-missing.md).
11. A recap error that names the Claude or Codex tool: [The Claude or Codex tool is not found or not signed in](ai-tool-not-found-or-not-signed-in.md).

## How to check

The pill clears and the recording opens with a transcript and a recap. For the permission, a new test recording shows both voices.

## If it did not help

Two speakers merged into one "Speaker N", or the wrong names, are voice-naming issues on [Meeting recording](../features/meeting-recording.md). A busy transcription queue holds new jobs: "Waiting for previous transcription…" clears on its own.
