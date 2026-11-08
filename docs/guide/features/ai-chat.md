# Chats

The **Chats** tab is the assistant you talk to about your work: it searches what Watchtower has synced, keeps long conversations organized, takes files, and returns documents. It can also propose changes, but only [you approve them](ai-chat-actions.md).

## Why use it

You ask "what did we decide about the payments rollout?" and get an answer drawn from Slack, mail, Jira, meetings and digests, with the sources one click away. Nothing is pre-loaded into the conversation, so a question about your schedule or a colleague works the same way: the assistant looks it up when you ask.

## How it works
<!-- learn
id: chat-ask-your-work
title: Ask about your work
text: Ask **Chats** a question and it searches Slack, mail, Jira and meetings, with **Sources** one click away.
area: assistant
level: basics
kind: feature
since: 0.24.0
action: chat:What did we decide this week, and where was it said?
done_when: chat.used
-->

<!-- learn
id: chat-provider-choice
title: Pick the provider for a chat
text: New chats use **Preferred + reserve · Auto**; pick **Only Claude** or **Only Codex** in the composer's pill to pin one.
replaces: [chat-pick-provider]
changed: New chats follow your preferred provider and move to the reserve at its limit.
area: assistant
level: next
kind: tip
since: 0.27.0
action: nav:chat
-->

<!-- learn
id: chat-web-search
title: Search the web from the chat
text: On Claude or Codex, ask about public docs, products or news; the pages show under **Web** in **Sources**.
area: assistant
level: next
kind: feature
since: 0.27.0
action: chat:What changed in the latest macOS release?
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

**The web.** On Claude and Codex the assistant can search the public web (documentation, products, news) and lists each page under **Web** in **Sources**. Your private data never goes into a search, and a link you give is never fetched; Codex sees only pages in its search index, so a very recent one can be missing. Ollama has no web search.

**Providers.** Choose **Preferred + reserve · Auto** or **Only** a provider. See [limits, pins and recovery](../concepts/ai-providers-and-cost.md#a-reserve-provider-for-quota-limits).

**Warm sessions.** Up to three conversations keep a live assistant for ten idle minutes, so replies start fast; a fourth waits, and no running reply is cut off.

**Memory.** When the Memory feature's **Chat surface** switch is on, the assistant starts each chat with a short map of what it remembers and can look things up. See [Memory](memory.md).

**Other assistant chats.** The same chat, steps included, appears in a target's **Assistant** tab, the track chat, an idea or decision, a recording's **Chat** tab, an automation's **Chat** and the setup assistant in Settings, without attachments, @-mentions or branches. Only the main chat, the target chat and the automation editor can act, through proposals; the others are draft-only. At most three replies across all of them run at once; a fourth shows **Queued**.

**Questions about Watchtower itself.** The assistant searches this guide (built in, so it matches your version), links the section it used, and says so when the guide has nothing. An answer can also link a screen, such as **Inbox**: the link opens that tab, and only screens shown in your sidebar become links.

Messages sent from the ⌘/ panel also tell the assistant your tab and item; that note is never stored.

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
text: Press ⌘K in **Chats** to search the text of every message you and the assistant wrote.
area: assistant
level: next
kind: shortcut
since: 0.24.0
action: hotkey:search-chats
-->

<!-- learn
id: chat-codex-images
title: Show Codex an image
text: On Codex, attach a screenshot or photo to a message and ask about it; PDFs still need Claude.
area: assistant
level: next
kind: tip
since: 0.27.0
action: nav:chat
-->

1. Open **Chats**. A start page offers a composer, starter prompts, and your pinned and recent chats; the list on the left is [the Chats panel](#the-chats-panel). If you left a chat less than two hours ago, the tab reopens it instead. A chat with a reply running, or an unsent draft or file, always reopens.
2. Type and press Enter (Shift+Enter adds a line). **Stop** (Esc) keeps what was written and offers **Continue**. **Edit** your message or **Regenerate** a reply on hover; every version is kept.
3. Type `@` to point at a person, Slack channel, Jira issue, target or track. Type `/` at the start to load one of your enabled skills.
4. Attach files with the paperclip, drag and drop, or ⌘V: images (PNG, JPEG, GIF, WebP) up to 5 MB, PDFs up to 32 MB, text-like files up to 256 KB, 30 MB per message. Anything else is refused with the reason. Files are stored privately and deleted with their chat.
5. ⌘V attaches copied files, screenshots, images or PDFs; other images become PNGs, shrunk if over 5 MB. A text paste of 10,000 characters or more, up to 256 KB, offers **Attach as File** (⌘Z puts the text back) or **Keep as Text**.
6. **New chat** is ⌘N (the **+** in the panel header); ⌘K searches the text of every message. Right-click a chat to rename, pin, move to a project, archive or delete. A title comes after the first reply; one you set is kept.

### The Chats panel
<!-- learn
id: chat-panel-read-state
title: See which chats have new answers
text: In **Chats**, a bold title and filled dot mark an unread answer; hover a chat and ✕ deletes it, with Undo.
area: assistant
level: next
kind: tip
since: 0.26.0
action: nav:chat
-->

Each chat has a dot and two lines: its title and the start of the last answer with its age (in **All chats**, a project chat's line starts with the project name). The dot is orange for a proposal waiting for your approval, a pulsing accent while the answer is written, a filled accent with a bold title for an unread answer, and a grey ring once read. A chat is read once opened or when its answer finishes on screen.

Chats are grouped as **PINNED**, **RECENT** (the last 7 days) and **▸ N older**, folded until you open it (remembered). The chat on screen stays visible under the header.

The header reads **All chats ⌄**, or **‹ 📁 Project ⌄** inside a project, with **+** for a new chat; its menu switches projects (see [Chat projects](ai-chat-projects.md)). **⌘[** goes back to All chats.

Hover a chat and press **✕** to delete it at once; **Undo** (⌘Z) stays for 5 seconds. An answering or waiting chat has no ✕; **Delete…** in the right-click menu asks first. Click the panel, then **↑/↓** move, **Return** opens, **⌘⌫** deletes and **⌘1–⌘9** open the first nine chats (they and ⌘[ need the panel shown).

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

Press **⌘/** (**Help** → **Ask Watchtower…**) on any tab to open the same chat as a panel over it. It continues the conversation selected in the **Chats** tab; messages show in both places. **New** starts a fresh conversation, and **Open in Chats** switches to the tab on this conversation.

**Esc** stops a running answer; a second **Esc** closes the panel. In the **Chats** tab, **⌘/** puts the cursor in the message box; in a Workbench **Files** editor it still toggles a comment.

### Artifacts

Documents, tables, drafts, events, code and HTML pages open in the artifact panel beside the chat, where you edit, comment, export or present them. On the Claude provider you can ask for a page, deck or doc on claude.ai instead. See [Artifacts in Chats](ai-chat-artifacts.md).

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
since: 0.25.0
action: nav:chat
-->

Select a passage of a finished answer right in the chat, then click **Ask about this** next to it. The passage joins the quotes above the message box and the cursor moves there, so you type your follow-up. Quotes go out together with your next message, each with an optional comment.

A selection can run across the paragraphs, headings and lists of an answer, up to the next code block or table. A table is selected whole, with tabs between cells, and ⌘C copies it as plain text. Your own messages can be copied, not quoted.

### Question cards

When your request can be read two ways, the assistant asks with a card of one to four questions. Pick an option, or write your own in the **Other…** field, then **Send answers**. A card can be answered on the latest reply only.

## When it's empty or wrong

- **A reply fails.** Your message stays. After a started-turn limit, **Review actions** opens saved actions; send a new message after checking. Other errors may offer **Retry**.
- **Answers miss recent items.** The assistant sees only synced data. Check **Connections**, or see [Search and knowledge](search-and-knowledge.md).
- **An attachment is refused.** It is over the size cap, or the provider can't read that type (Codex: no PDFs; Ollama: no images or PDFs); the reason shows under the field.
- **A project edit seems ignored.** A reply being written finishes first; the change applies from the next message.

Provider not signed in? See [The Claude or Codex tool is not found or not signed in](../troubleshooting/ai-tool-not-found-or-not-signed-in.md).

## Related

- [Writing, Slack send, Confluence and automations from the chat](ai-chat-actions.md)
- [Artifacts in Chats](ai-chat-artifacts.md)
- [Chat projects](ai-chat-projects.md)
- [Memory](memory.md)
- [Quick Connections](quick-connections.md)

For developers: [docs/features/chat-redesign.md](../../features/chat-redesign.md), [docs/features/embedded-chat.md](../../features/embedded-chat.md)
