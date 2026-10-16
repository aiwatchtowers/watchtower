# AI Chat

The **Chat** tab is the assistant you talk to about your work: it searches what Watchtower has synced, keeps long conversations organized, takes files, and returns documents. It can also propose changes, but only [you approve them](ai-chat-actions.md).

## Why use it

You ask "what did we decide about the payments rollout?" and get an answer drawn from Slack, mail, Jira, meetings and digests, with the sources one click away. Nothing is pre-loaded into the conversation, so a question about your schedule or a colleague works the same way: the assistant looks it up when you ask.

## How it works

**Where answers come from.** The assistant searches everything Watchtower synced and indexed (Slack, mail, Jira with comments, calendar, transcripts and recaps, digests, decisions, ideas). That search follows the Knowledge search feature switch. Each answer folds its steps into "Worked for 12s · 4 steps", and a line below it opens the **Sources** panel, grouped by Slack channel, Jira project, Confluence space, mail, meetings and other.

**Providers.** The pill in the composer picks Claude, Codex or Ollama and a model; **Auto** is the provider's configured strong model. Claude streams text live and shows steps. Codex and Ollama answer in the same chat but may show the reply all at once, may show no steps, and cannot read images or PDFs.

**Warm sessions.** Up to three conversations keep a live assistant process, for ten minutes of idle time, so the next reply starts fast. A fourth conversation waits for a free slot; a running reply is never cut off to make room.

**Memory.** When the Memory feature's **Chat surface** switch is on, the assistant starts each chat with a short map of what it remembers and can look things up. See [Memory](memory.md).

**Other assistant chats.** The same chat component appears in a target's **Discuss** tab, the track chat, an idea or decision, a recording's **Chat** tab, an automation's **Change in words**, and the setup assistant in Settings. They have no attachments, @-mentions or branches. Only the main chat, the target chat and the automation editor can act, through proposals. The meeting, track, idea and setup chats are draft-only: they discuss and draft but never act. At most three replies across all of them run at once; a fourth shows **Queued**.

## Using it

1. Open **Chat**. A start page offers a composer, starter prompts, and your pinned and recent chats. If you left a chat less than two hours ago, the tab reopens it instead. A chat with a reply running, or an unsent draft or file, always reopens.
2. Type and press Enter (Shift+Enter adds a line). **Stop** (Esc) keeps what was written and offers **Continue**. Hover your message to **Edit**; hover a reply to **Regenerate**. Every version is kept, switch with the arrows.
3. Type `@` to point at a person, Slack channel, Jira issue, target or track. Type `/` at the start to load one of your enabled skills.
4. Attach files with the paperclip, drag and drop, or paste. Images (PNG, JPEG, GIF, WebP) up to 5 MB, PDFs up to 32 MB, text-like files up to 256 KB. One message's files together stay under 30 MB. Anything else is refused with the reason. Files are stored privately in the workspace and deleted with their chat.
5. **New chat** is ⌘N; ⌘K searches the text of every message. Right-click a chat to rename, pin, move to a project, archive or delete. A title is written after the first reply, and one you set is never replaced.

### Artifacts

A document, table, email or Slack draft, event or code opens in the artifact panel instead of the chat. Each change is a new version; you can edit it, copy it, or export it as .md, .csv or .txt. Select a passage and choose **Comment** to leave a note. Notes stay drafts until you click **Send N comments**, which sends them together; the assistant answers with a new version. Drafts are never sent by Watchtower: an email opens in Gmail compose, a Slack draft is copied with its channel opened, an event opens Google Calendar's new-event page.

### Quote in reply

Hover a finished answer and choose **Quote in reply** to pick the exact passage you mean. Quotes collect above the message box and go out together with your next message.

### Projects

A project groups chats that share context: instructions given in every chat, files, and pinned sources (Jira projects, Slack channels, Confluence spaces, targets, tracks, people). Pinned channels, projects and spaces rank first in the project's knowledge search. Use **+** next to PROJECTS, then **New chat in this project**. An edit reaches every chat in the project on its next message. Deleting a project deletes its files and keeps its chats.

### Question cards

When your request can be read two ways, the assistant asks with a card of one to four questions. Pick an option, or write your own under **Other**, then **Send answers**. A card can be answered on the latest reply only.

## When it's empty or wrong

- **A reply fails.** The card shows the provider's own reason and **Retry**; your message is never lost. A sign-in error names the command for that provider.
- **Answers miss recent items.** The assistant sees only what has synced. Check the source's status in Settings, or see [Search and knowledge](search-and-knowledge.md).
- **An attachment is refused.** It is over the size cap, or the provider cannot read that type (Codex and Ollama take no images or PDFs).
- **A project edit seems ignored.** A reply being written finishes first; the change applies from the next message.

## Related

- [Writing, Slack send, Confluence and automations from the chat](ai-chat-actions.md)
- [Memory](memory.md)
- [Quick Connections](quick-connections.md)

For developers: docs/features/chat-redesign.md, docs/features/embedded-chat.md
