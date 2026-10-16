# Voice dictation

Dictation turns speech into text in the places where you would otherwise type: a chat message, a new idea, a recording's notes. It runs on your Mac. **Quick Capture** goes further and saves a spoken idea without opening the app window.

## Why use it

You are mid-thought and typing would slow you down. Press a key, say it, and a cleaned-up idea lands in your Ideas list. Or dictate your question to the assistant instead of typing it.

## How it works

### Where the mic button appears

A mic button sits next to three kinds of fields: every assistant chat input (including the setup assistants), the new-idea sheet, and a recording's **Notes** tab.

In a chat input, your words land exactly as transcribed. In the idea sheet and **Notes**, a light AI pass removes filler words and false starts, and shapes the text for where it goes (a title and body for an idea). A **Cleaned** chip with **Raw** shows for 5 seconds so you can swap back to what you actually said.

If you dictate into a field that already has text, the new text is added after it.

### Engines and the first download

**Settings › Meetings › Dictation model** picks the engine, separately from the meeting engine: **Apple (realtime)** on macOS 26 and later (the default there, nothing to download), or **Whisper large-v3 turbo**, **Whisper small (fast)** or **Whisper base (fastest)**. On older macOS the default is Whisper small.

A Whisper model downloads at the first dictation. The mic is already listening meanwhile, so nothing you say is lost, and the capsule reads "Downloading model… N%".

A failed download ends the dictation with the reason, and **Retry** on the pill continues it.

Text appears live as you speak. The engine then stays loaded for 15 minutes, so a burst of dictations starts fast.

### Silence and meetings

If nothing is said for 2 minutes, the dictation pauses itself. A paused dictation stops and delivers its text after 5 more minutes.

A meeting recording takes priority. While one is capturing or processing, the mic buttons are disabled with the tooltip "A meeting recording is in progress", and what you had said so far is delivered first. Only one field can dictate at a time ("Another field is dictating").

## Using it

1. Click the mic button, or press **⌃⌥D** anywhere for Quick Capture.
2. Speak. The pause and resume buttons give you a break (in Quick Capture they read **Pause** and **Resume**).
3. Click **Stop** to insert the text. **Esc** cancels and discards it.

### Quick Capture

Press **⌃⌥D** in any app, or choose **New Voice Idea** in the menu bar icon's menu. A small window opens and listens at once.

1. Speak.
2. Click **Stop**, review the cleaned text, then click **Save**. It becomes an active idea in the Ideas list. **Discard** or closing the window drops it.
3. After "Saved ✓" the window closes by itself after 2 seconds, or click **Open Ideas**.

If cleanup fails, **Save as idea** keeps what was transcribed as it is.

## When it's empty or wrong

- **Mic button greyed out:** a meeting recording is running, or another field is dictating. The tooltip says which.
- **Nothing happened after you stopped:** you said nothing, or only silence. The field stays as it was, with no error. In Quick Capture you see "Nothing was dictated."
- **A small error under an idea or note:** the cleanup step failed. With a live engine your raw text is already in the field. Nothing you said is thrown away.
- **"Dictation is busy elsewhere — try again in a moment."** Quick Capture found the mic in use. Close it and retry.
- **⌃⌥D does nothing:** choose **New Voice Idea** in the menu bar icon's menu, which opens the same window.

## Related

- [Meeting recording](meeting-recording.md) uses the same on-device engines.

For developers: [docs/features/voice-dictation.md](../../features/voice-dictation.md)
