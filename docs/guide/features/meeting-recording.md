# Meeting recording

Watchtower records a meeting on your Mac, transcribes it on-device, and writes a recap with action items you can turn into targets. It captures your microphone and the call's audio together, with no virtual audio device. It needs macOS 14.4 or later.

## Why use it

You finish a call and the decisions are already written down: a summary, chapters, action items, and a follow-up draft in your own voice. You can also ask the assistant "what exactly did we decide about the rollout?" and it searches the transcript.

## How it works

### Capture

**Record** captures the microphone and the system audio (the other participants). The first time, macOS asks for two permissions: microphone, and system audio recording. While you record, a pill at the bottom right of the window shows the elapsed time and **Stop**, whatever tab you are on.

After **Stop**, the recording joins a queue, and each queued recording gets its own pill: "Transcribing 2/5", "Identifying speakers…", "Summarizing…".

You can start a new recording while an old one is processing. Only one transcription runs at a time, so the new one keeps capturing and its live panel reads "Waiting for previous transcription… live transcript will catch up."

If the call goes quiet, you get a warning. When nothing has come from the call for over 2 minutes after it was heard, the pill shows **No call audio** in orange and a notification fires. It usually means the output device changed.

The recording's detail later notes the gap, such as "No call audio from 15:29 to the end".

When headphones or AirPods connect or disconnect, the capture reattaches to the new device about a second later. Turn this off with **Follow audio device changes** in **Settings → Meetings**.

### Transcription is local

Audio never leaves your Mac. Only the transcript text goes to your AI provider, for the recap.

Pick the **Engine** in **Settings → Meetings**. Only engines available on your Mac are listed:

- **WhisperKit (Whisper)**, the default, with the **Large v3 Turbo (recommended)** model, and **Qwen3-ASR** transcribe while you record, as long as **Live transcription** (on by default) is on.
- **Parakeet v3 (NVIDIA)** and **Apple Speech (macOS 26+)** transcribe after **Stop** and show no live text meanwhile.

The model downloads once. With the **Meetings** goal chosen at setup, it downloads in the background after the first sync, or after 10 minutes, whichever comes first. Otherwise it downloads at your first recording or dictation, and a pill shows progress with **Retry** if the connection drops.

**Preload model before meetings** (on by default) loads the model about 5 minutes before a calendar meeting starts, so **Record** starts at once.

### What a recording produces

After the transcript is saved, the recap and chapters are generated on their own. A transcript under 200 characters is saved without them. Speaker labels are `[Я]` for you, from the microphone channel, and `[Speaker 1…N]` for others, with on-device speaker separation.

Each recording has four tabs:

- **Recap**: a summary, then chapters with decisions, action items and open questions. **Target** turns an action item into a target. **Follow-up draft** writes a message in your voice; it is shown to copy and is never sent.
- **Notes**: **Generate** writes publishable meeting notes. Edit them in place (they autosave), then **Copy**.
- **Transcript**: utterances with speaker and time. Click a speaker label to hear samples and name them.
- **Chat**: talk to the assistant about this meeting.

## Using it

1. Click **Record** on an event (10 minutes before it starts, through its end) or in the list header for a meeting without an event.
2. Click **Stop** in the pill when it ends.
3. Open the meeting. The recap appears when the pills clear.
4. For a recording with no event, use **Link to event…** in its header.

Audio files are deleted after 30 days (**Delete audio after N days** in **Settings → Meetings**; 0 keeps them). Transcripts and recaps stay.

**Delete** removes the recording, its transcript, notes, chat and audio after confirmation. The event's recap stays with the event.

### Naming voices

Watchtower learns recurring voices and names speakers automatically. Voice data stays on your Mac.

When a voice is unknown, a notification says "N voices to label". Open the **Voices** window from the menu bar icon with **Voices to label (N)**, **Review voices** or **Train voices**.

- **Queue**: one card per unknown voice, with short clips. Pick a name, then **Confirm**. **Don't know** keeps "Speaker N", **Several people** marks a mixed voice, **Skip** leaves it for later. Nothing is saved until you confirm.
- **Review**: the list of known voices, spot-checks of recent automatic labels (**Correct** or **Wrong**), and **Export…** / **Import…** of a password-protected `.wtvoices` file. It holds only voice numbers, never audio or text.
- **Train**: label many meetings at once; similar voices are grouped into one card.

An imported voice only suggests a name until you confirm it. Turn the whole feature off with **Voice recognition** in **Settings → Meetings**; **Notify about unknown voices** only mutes the notification.

## When it's empty or wrong

- **No Record button:** the event is more than 10 minutes away or over, or the Mac is below macOS 14.4.
- **"No speech recognized":** the note says whether call audio was missing. Check the output device.
- **Only your voice in the transcript:** call audio was not captured. The **No call audio** warning fires during the call so you can fix it.
- **Different people share one "Speaker N":** lower **Diarization threshold** (0.3 to 0.9) in **Settings → Meetings**.
- **Transcription or recap failed:** the audio is kept. Use **Retry** on the failed pill, **Re-transcribe** under the transcript, or **Generate recap** on the Recap tab.
- **The app quit mid-recording:** at the next launch the pill offers **Transcribe recovered recording**; dismiss it to skip.
- **"Speaker names were updated — regenerate the recap?":** names changed after the recap was made. Nothing regenerates on its own; click **Regenerate**.

Recording or transcript failing? See [Recording or transcript problems](../troubleshooting/recording-or-transcript-problems.md).

## Related

- [Calendar and meeting prep](calendar-and-meeting-prep.md)
- [Voice dictation](voice-dictation.md) shares the same transcription engine slot.

For developers: [docs/features/meeting-transcriber.md](../../features/meeting-transcriber.md)
