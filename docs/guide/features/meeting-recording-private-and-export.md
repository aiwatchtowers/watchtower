# Private recordings and transcript export

A private recording stays a transcript on your Mac: Watchtower never sends it to your AI provider. Any recording, private or not, can be copied or saved as a file. This page is for recordings made with [Meeting recording](meeting-recording.md).

## Why use it

Some calls should not reach an AI at all: a one-to-one, an interview, a legal or HR conversation. Mark the recording private and you still get the local transcript, speakers and audio, with no recap and no assistant reading it. Export takes any transcript out of the app, for a ticket, an email or subtitles.

## How it works

### What private changes
<!-- learn
id: recording-private
title: Keep a recording away from AI
text: Choose **Record Privately** in **Record**'s menu: the transcript stays on your Mac, never sent to AI.
area: meetings
level: next
kind: feature
since: next
action: nav:calendar
-->

A private recording is transcribed on your Mac like any other, and saved without a recap or chapters. Where an AI action would be, the recording shows **Private recording — not sent to AI**: no **Generate recap**, chapters, **Follow-up draft**, notes **Generate** or **Chat**.

The assistant never finds it either: chat search, knowledge search, ideas, Catch Up and Memory skip it. Linking it to a calendar event does not copy its text into the event's recap.

You can still read the transcript, name speakers, play the audio and write your own notes. An action item's **Target** button is off too: targets feed the briefing, the day plan and the chat.

### Turning private on or off later

Turning **Private** on asks for confirmation first. A recap or notes made before stay visible in the recording, but nothing reads them for the assistant any more. Ideas and memory already taken from the recording stay.

Turning it off brings the AI actions back. Nothing is generated on its own; press **Generate recap** when you want one.

### What private does not cover

A Workbench agent that can run shell commands can still read the database or the recordings folder directly. Your iPhone still receives the recording, encrypted for your own devices; the phone's chat uses the same tools, so it does not see it.

## Using it

### Make a recording private

- **Before it starts:** open **Record**'s menu (the arrow beside it) and choose **Record Privately**.
- **While it records or waits in the queue:** click the lock on its pill. A closed lock means private. Once the recording is being saved the lock can't be clicked: a private recording keeps a closed lock, a regular one shows none.
- **After a crash:** a recovered recording shows a lock on its pill too. A recording whose choice Watchtower can't tell (an older build's, or one whose start was never written down) comes back private; open its lock before **Transcribe** if it should get a recap.
- **After it is saved:** press **Private** in the recording's header.
- **Every time:** turn on **Record meetings privately by default** in **Settings → Meetings**. **Record**, Join's auto-record and iPhone recordings then start private.

A locked recording in the Meetings list and its header show a lock.

### Export a transcript
<!-- learn
id: recording-export
title: Save a transcript as a file
text: In a recording's header, **Export** copies the transcript or saves it as text, Markdown, subtitles or JSON.
area: meetings
level: next
kind: feature
since: next
action: nav:calendar
-->

Open the recording and choose from **Export** in its header:

- **Copy Transcript**: `[hh:mm:ss] Speaker: text` lines, onto the clipboard.
- **Save as Text…**: the same lines, in a `.txt` file.
- **Save as Markdown…**: the title, date and duration, then each utterance with its speaker and time.
- **Save as Subtitles (SRT)…**: numbered cues for a video player.
- **Save as JSON…**: the segments with times and speakers, for your own scripts.

Deleted utterances are never exported. A short line under the header confirms the copy or the saved file's name. Export runs on your Mac, so private recordings export too.

## When it's empty or wrong

- **Save as Subtitles (SRT)… is greyed out:** the recording has no timed utterances (an older recording). Use **Re-transcribe** under its transcript in the event, or export as text.
- **"Private recording — not sent to AI" where you expected a recap:** the recording is private. Turn **Private** off in its header, then press **Generate recap**.
- **The lock on a pill can't be clicked:** the recording is already being saved; once it's saved, change it with **Private** in the recording's header.
- **A recovered recording saved without a recap:** it came back private because its choice was unknown. Turn **Private** off in its header, then press **Generate recap**.

## Related

- [Meeting recording](meeting-recording.md)
- [Privacy](../concepts/privacy.md)

For developers: [docs/features/private-meetings.md](../../features/private-meetings.md)
