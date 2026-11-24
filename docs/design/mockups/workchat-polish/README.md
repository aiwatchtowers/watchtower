# Workchat polish — design draft

Mockup: open [`index.html`](index.html) in a browser (`open docs/design/mockups/workchat-polish/index.html`).

v2 after owner feedback ("too colourful"): no fills, pills or coloured boxes; colour only on text, muted, like IDE syntax highlighting.

Five items from the owner (conversation, 2026-11-24):

1. **Turn steps** — collapsed by default to one line (current step + its time); expanded without the card fill, a thin left rule, finished steps grey, only the running one bright. `0:00` becomes `<1s`, bare tool names (`SendMessage`) get a human label. The expanded/collapsed choice is remembered per pane.
2. **Highlighting in the agent's text** — IDE-syntax style: muted text colour only, no fills, pills or bold (owner, v2). Deterministic, plain text only (code spans and links untouched): `#N` target/PR refs (click opens), commit hashes (click copies), file paths (click opens the code viewer), commands.
3. **"Agent finished" event** — a quiet row (glyph tinted by status, no badge fill or pills) instead of the raw `<task-notification>` dump: status badge, agent name, one meta line (tools · tokens · duration); expanded shows the result only, with Open output and Details (ids) behind buttons; Claude Code's boilerplate note is never shown. Failed agents get a red badge; background commands a smaller, quieter card.
4. **Paste from the clipboard** — ⌘V takes a screenshot (preview chip), Finder-copied files (file chips) and long text (token); the paperclip menu gains "Paste from clipboard", labelled by what the clipboard holds.
6. **Line stuck in "pending"** — root cause: `TerminalCenter.ownerInput` marks `promptDrafts` on every non-Return key (Backspace included) and only a submitting Return clears it, so erasing the prompt text never releases the held line. Fix: read the prompt line off the terminal screen; when it is empty the line goes. When text really is there, a grey caption under the bubble says so, shows it, and offers "Clear and send" (Ctrl+U, then the line) / "Send together" / Cancel. Failure paths: session closed while held → "Not sent", text back in the field; screen unreadable → today's behaviour plus "Clear and send".

Open question for the owner: which clipboard content failed to paste in item 4 (screenshot, Finder file, text)?

Next step after approval: spec with DesignShotCatalog shots per state, then plan.
