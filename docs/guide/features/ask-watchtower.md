# Ask Watchtower

**Ask Watchtower** is a small panel, opened with ⌘/ from anywhere, that answers "how do I do this in Watchtower?" from this guide. It is for questions about the app, not about your work; for that, use [AI Chat](ai-chat.md).

## Why use it

You wonder why the Briefings tab is empty, or where the Claude sign-in lives. Press ⌘/, type the question, and get a short answer with the screen names the app uses, plus a link to the guide section it came from. You never leave the screen you were on.

## How it works

**Instant matches.** While you type, the panel lists matching guide sections (**Guide**) and screens (**Go to**) without calling any AI. The guide is read once per launch from the copy built into the app.

**The answer.** **Ask** sends your question to the assistant with the few best-matching guide sections. It uses the light model of your configured provider and runs with no tools at all, so it cannot read any of your data: no messages, mail, meetings or targets. If the guide doesn't cover the question, it says so and suggests AI Chat.

**Nothing is kept.** The conversation lives only while the panel is open. Closing it ends the conversation and stores nothing. No long-term memory (the **Memory** tab) is read.

**Screen links.** An answer can link to a screen. The link opens only screens that are visible in the sidebar right now; a hidden one shows as plain text. The main AI Chat answers app questions from the same guide and can use the same links.

## Using it

1. Press ⌘/, or choose **Ask Watchtower…** in the Help menu. In a code editor (the Files pane, a diff review, the automation editor) ⌘/ comments out the line instead; use the Help menu there.
2. Type a question. Press Return on the **Ask** row to ask it, or pick a **Guide** row to open that section in your browser.
3. Pick a **Go to** row, or press ⌘Return, to open that screen.
4. Type a follow-up in the answer view. **Open in AI Chat** repeats your first question there when you need your own data.
5. Press Esc to close.

**Watchtower User Guide** in the Help menu opens the guide's front page.

## When it's empty or wrong

**"The guide couldn't load"**: the screens still match, but answers have no guide sections and the assistant says the guide doesn't cover it. Open the panel again to retry.

**A wrong or missing answer**: the guide on your Mac is the one built with your version, so a newer feature may be missing. Ask in AI Chat, or open the section from the **Guide** rows.

**No answer at all**: the panel needs your AI provider like any chat; see [The Claude or Codex tool is not found or not signed in](../troubleshooting/ai-tool-not-found-or-not-signed-in.md).

## Related

- [AI Chat](ai-chat.md)
- [AI providers, models and cost](../concepts/ai-providers-and-cost.md)

For developers: [docs/features/ask-watchtower.md](../../features/ask-watchtower.md)
