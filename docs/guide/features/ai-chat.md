# AI Chat

The **AI Chat** tab is the assistant you talk to about your work: it searches what Watchtower has synced, keeps long conversations organized, takes files, and returns documents. It can also propose changes, but only [you approve them](ai-chat-actions.md).

## Why use it

You ask "what did we decide about the payments rollout?" and get an answer drawn from Slack, mail, Jira, meetings and digests, with the sources one click away. Nothing is pre-loaded into the conversation, so a question about your schedule or a colleague works the same way: the assistant looks it up when you ask.

## How it works
<!-- learn
id: chat-ask-your-work
title: Ask about your work
text: Ask the **AI Chat** a question and it searches Slack, mail, Jira and meetings, with **Sources** one click away.
area: assistant
level: basics
kind: feature
since: 0.24.0
action: chat:What did we decide this week, and where was it said?
done_when: chat.used
-->

<!-- learn
id: chat-pick-provider
title: Pick the model for a chat
text: Use the pill in the composer to switch between Claude, Codex and Ollama and pick a model for the next reply.
area: assistant
level: next
kind: tip
since: 0.24.0
action: nav:chat
-->

<!-- learn
id: chat-ask-about-watchtower
title: Ask how Watchtower works
text: Ask the chat about any Watchtower feature: it answers from this guide and links the section and the screen.
area: assistant
level: basics
kind: tip
since: 0.24.0
action: chat:How do I make an automation that runs every Monday?
-->

**Where answers come from.** The assistant searches everything Watchtower synced and indexed (Slack, mail, Jira with comments, calendar, transcripts and recaps, digests, decisions, ideas). That search follows the Knowledge search feature switch. Each answer folds its steps into "Worked for 12s · 4 steps", and a line below it opens the **Sources** panel, grouped by Slack channel, Jira project, Confluence space, mail, meetings and other.

**Providers.** The pill in the composer picks Claude, Codex or Ollama and a model; **Auto** is the provider's configured strong model. Claude streams text live and shows steps. Codex and Ollama answer in the same chat but may show the reply all at once, may show no steps, and cannot read images or PDFs.

**Warm sessions.** Up to three conversations keep a live assistant process, for ten minutes of idle time, so the next reply starts fast. A fourth conversation waits for a free slot; a running reply is never cut off to make room.

**Memory.** When the Memory feature's **Chat surface** switch is on, the assistant starts each chat with a short map of what it remembers and can look things up. See [Memory](memory.md).

**Other assistant chats.** The same chat component appears in a target's **Assistant** tab, the track chat, an idea or decision, a recording's **Chat** tab, an automation's **Chat** in the Automations panel, and the setup assistant in Settings. They have no attachments, @-mentions or branches.

Only the main chat, the target chat and the automation editor can act, through proposals. The meeting, track, idea and setup chats are draft-only: they discuss and draft but never act. At most three replies across all of them run at once; a fourth shows **Queued**.

**Questions about Watchtower itself.** The assistant searches this guide (built into the app, so it matches your version) and links the section it used; if the guide has nothing on it, it says so. An answer can also link a screen, such as **Inbox**: the link opens that tab, and only screens shown in your sidebar become links.

Messages sent from the panel (**⌘/**) also tell the assistant which tab you are on, what status line an empty tab shows and which item is selected. That note goes to your AI provider but is never stored, so the history shows only what you typed.

## Using it
<!-- learn
id: chat-mentions-and-skills
title: Point the chat with @ and /
text: Type `@` to name a person, channel, issue or target, or `/` at the start to load one of your skills.
area: assistant
level: next
kind: tip
since: 0.24.0
action: nav:chat
-->

<!-- learn
id: chat-attach-files
title: Attach files and screenshots
text: Drop a file on the chat or press ⌘V on a screenshot, and the assistant reads it with your question.
area: assistant
level: basics
kind: feature
since: 0.24.0
action: nav:chat
-->

<!-- learn
id: chat-search-chats
title: Find an old conversation
text: Press ⌘K in **AI Chat** to search the text of every message you and the assistant wrote.
area: assistant
level: next
kind: shortcut
since: 0.24.0
action: hotkey:search-chats
-->

1. Open **AI Chat**. A start page offers a composer, starter prompts, and your pinned and recent chats. If you left a chat less than two hours ago, the tab reopens it instead. A chat with a reply running, or an unsent draft or file, always reopens.
2. Type and press Enter (Shift+Enter adds a line). **Stop** (Esc) keeps what was written and offers **Continue**. Hover your message to **Edit**; hover a reply to **Regenerate**. Every version is kept, switch with the arrows.
3. Type `@` to point at a person, Slack channel, Jira issue, target or track. Type `/` at the start to load one of your enabled skills.
4. Attach files with the paperclip, drag and drop, or ⌘V. Images (PNG, JPEG, GIF, WebP) up to 5 MB, PDFs up to 32 MB, text-like files up to 256 KB. One message's files together stay under 30 MB. Anything else, or a folder, is refused with the file's name and the reason. Files are stored privately in the workspace and deleted with their chat.
5. ⌘V attaches files copied in Finder, a screenshot or copied image, and copied PDF data. A PNG, JPEG, GIF or WebP goes as is; any other image becomes a PNG, shrunk if it is over 5 MB. Copied text pastes as text, even when the copy also carries a picture of it. Only a bare link or blank text beside an image yields to the image, as with a browser's **Copy Image**. A paste of 10,000 characters or more, up to 256 KB, offers **Attach as File** (it becomes `Pasted text.txt`; ⌘Z puts the text back) or **Keep as Text**. Longer text just pastes.
6. **New chat** is ⌘N; ⌘K searches the text of every message. Right-click a chat to rename, pin, move to a project, archive or delete. A title is written after the first reply, and one you set is never replaced.

### Asking from any tab
<!-- learn
id: chat-ask-from-any-tab
title: Ask from any tab
text: Press ⌘/ on any tab to open the chat as a panel over it; it knows which tab you are on.
area: assistant
level: basics
kind: shortcut
since: 0.24.0
action: hotkey:help
-->

Press **⌘/** (**Help** → **Ask Watchtower…**) on any tab to open the same chat as a panel over it. It continues the conversation the **AI Chat** tab has selected, so what you say there shows up here and the other way round. **New** starts a fresh conversation, and **Open in AI Chat** switches to the tab on this conversation.

**Esc** stops a running answer; a second **Esc** closes the panel, and while one streams you can't send another message. In the **AI Chat** tab, **⌘/** puts the cursor in the message box; in a Workbench **Files** editor it still toggles a comment.

**Watchtower User Guide** in the **Help** menu opens this guide's front page.

### Artifacts

Documents, tables, drafts, events, code and HTML pages open in the artifact panel beside the chat, where you edit, comment, export or present them. On the Claude provider a page, deck or doc is published to your claude.ai account instead. See [Artifacts in the AI Chat](ai-chat-artifacts.md).

### Ask about a passage
<!-- learn
id: chat-quote-passage
title: Ask about one passage
text: Select part of an answer and click **Ask about this**: it joins your next message as a quote.
area: assistant
level: next
kind: tip
since: 0.24.0
action: nav:chat
-->

<!-- learn
id: chat-copy-table
title: Copy a table from an answer
text: Select across paragraphs or a whole table in an answer and ⌘C copies it as plain text, tabs between cells.
area: assistant
level: power
kind: tip
since: next
action: nav:chat
-->

Select a passage of a finished answer right in the chat, then click **Ask about this** next to it. The passage joins the quotes above the message box and the cursor moves there, so you type your follow-up. Quotes go out together with your next message, each with an optional comment.

A selection can run across the paragraphs, headings and lists of an answer, up to the next code block or table. A table is selected whole, across cells and rows, with tabs between cells; one inside a list or quote, cell by cell. ⌘C and the right-click menu copy it as plain text. Your own messages can be copied, not quoted. The chats inside other tabs offer selection and copy only.

### Projects
<!-- learn
id: chat-projects
title: Group chats in a project
text: Click **+** next to PROJECTS to give a set of chats shared instructions, files and pinned sources.
area: assistant
level: power
kind: feature
since: 0.24.0
action: nav:chat
-->

A project groups chats that share context: instructions given in every chat, files, and pinned sources (Jira projects, Slack channels, Confluence spaces, targets, tracks, people). Pinned channels, projects and spaces rank first in the project's knowledge search.

Use **+** next to PROJECTS, then **New chat in this project**. An edit reaches every chat in the project on its next message. Deleting a project deletes its files and keeps its chats.

### Question cards

When your request can be read two ways, the assistant asks with a card of one to four questions. Pick an option, or write your own in the **Other…** field, then **Send answers**. A card can be answered on the latest reply only.

## When it's empty or wrong

- **A reply fails.** The card shows the provider's own reason and **Retry**; your message is never lost. A sign-in error names the command for that provider.
- **Answers miss recent items.** The assistant sees only what has synced. Check the source's status in Settings, or see [Search and knowledge](search-and-knowledge.md).
- **An attachment is refused.** It is over the size cap, or the provider cannot read that type (Codex and Ollama take no images or PDFs).
- **A project edit seems ignored.** A reply being written finishes first; the change applies from the next message.

Provider not signed in? See [The Claude or Codex tool is not found or not signed in](../troubleshooting/ai-tool-not-found-or-not-signed-in.md).

## Related

- [Writing, Slack send, Confluence and automations from the chat](ai-chat-actions.md)
- [Artifacts in the AI Chat](ai-chat-artifacts.md)
- [Memory](memory.md)
- [Quick Connections](quick-connections.md)

For developers: [docs/features/chat-redesign.md](../../features/chat-redesign.md), [docs/features/embedded-chat.md](../../features/embedded-chat.md)
