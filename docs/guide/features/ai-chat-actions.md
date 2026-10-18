# Writing and changing things from the AI Chat

The assistant in the [AI Chat](ai-chat.md) can do more than answer: it can create a task, comment on a Jira issue, send a Slack message, edit a Confluence page or draft an automation. Every one of these waits for your approval first.

## Why use it

"Tell #ops the deploy is done" or "move PROJ-123 to In Review" takes one sentence instead of a trip through three apps. You still see exactly what will happen before it does, and you can change the text.

## How it works

**A proposal, not an action.** A write tool never acts by itself. Calling it records a proposal and shows a card saying what it wants to do and why. **Approve** runs it once; **Reject** discards it.

A failed card offers **Retry**, and a done card links to what was created or changed. Proposals left from an interrupted reply gather at the bottom of the chat, and proposals from other places (reactions, automations, a workbench terminal) wait in the Inbox.

**What needs a click.** Anything that writes outside your Mac always waits for Approve, whatever the settings: every Jira tool, Slack send, Confluence edits. Two tools, `create_idea` and `remind_me`, run at once by default and just show what they did. **Settings → Profile → Assistant tools** lists every write tool with **Run without approval in:** checkboxes per place it is offered. External tools stay locked to Approve there.

**Where each tool works.** Slack send and `connect_jira_board` are for the main chat (Slack send also from a workbench terminal and automations). Confluence reading and editing work in the main chat and a target's chat. Draft-only chats (meeting, track, idea) offer no proposals at all.

## Using it

### Send a Slack message

1. Ask: "tell #ops the deploy is done", "reply in this thread: <link>", "DM Alice that I'll be late".
2. The assistant reads your writing style first (the one **Settings → Profile** builds from your own messages), then shows a card with the recipient ("To: #ops in Acme") and the text in an editable box.
3. Edit if you like ("Edited — Approve sends your version"), then **Approve & send**. The message goes out as you, from your Slack account.
4. If the channel exists in several workspaces, pick one in **Send from**; Approve stays off until you do.

Only channels and people Watchtower has synced can be addressed. **Retry** after a failure first checks whether the message reached Slack and posts only if it did not.

### Edit a Confluence page

1. Ask the assistant to read a page (by link, id or exact title) and change a passage or rewrite a section.
2. The card shows a word-by-word diff: removed words struck through, added words in green.
3. **Approve** saves it as a new version, "Edited via Watchtower". The page is written only if nobody changed it since the preview; otherwise the card fails with "the page was edited after the preview" and nothing is written. Ask for a fresh edit.

Everything the edit does not touch stays byte for byte as it was. A block whose formatting a chat edit cannot carry (an aligned paragraph, a table with column widths, a titled code block) is refused rather than flattened.

### Draft an automation

Describe the routine ("every weekday at 9, summarise the mail that needs a reply"). The assistant drafts a recipe, dry-runs it without writing anything and shows what it would have done. When you are happy it proposes **Save automation <name>**, with **Show the whole recipe**. Approving saves and confirms it.

A new recipe stays off until you turn it on in the Automations tab. See [Automations](automations.md).

### claude.ai connectors

On the Claude provider, the main chat can also use the connectors of your claude.ai account. Reading through one is a step in the reply. A write through one waits for your Approve like every other external tool; the one exception is a private Claude Docs doc the chat made itself.

1. Open **Settings → Profile → claude.ai tools**. The list fills in once a main chat on the Claude provider has started.
2. Turn **Connectors** off to stop them all, or switch one connector off.
3. For a connector shown **Not connected**, click **Connect on claude.ai** and connect it there.

A switch applies to the next reply: idle chats restart, and a reply already running keeps the tools it started with.

When the chat wants to write through a connector (send a mail, create an event, post a message), the reply shows an orange **Waiting for your approval** step and a card below it naming the connector and the tool, with the exact input it will send:

1. Read the input. You can edit it in the box; it must stay a JSON object ("Edited — Approve sends your version").
2. **Approve** sends it once, from the chat that asked. **Reject** cancels it and the chat says nothing was sent.
3. Answer within 15 minutes. After that the call is cancelled ("Cancelled — not approved in time"). **Stop** on the reply cancels it too ("Cancelled — chat stopped").

The card can be approved only while that reply is still running. Once the chat's session is gone the card says **Chat session ended** and nothing is sent; to send it, ask the chat again. These cards have no **Retry** and are not part of **Approve all**. They also wait in the Inbox while the reply runs. A card that says **Chat session ended — outcome unknown** and offers **Dismiss** stays on the Inbox badge until you click it: the call may or may not have reached the connector, so check there first. (The button appears once the chat starts again after the session that ran the call ended.)

## When it's empty or wrong

- **The send fails with "sign in again to grant send".** Your Slack workspace was connected before send existed. Click **Reconnect Slack** on the card, approve Slack's page in the browser, then **Retry**.
- **The assistant says it cannot edit Confluence.** The site needs **Allow editing** in **Settings → Connections → Jira → Confluence**. If Confluence sync is off, that section says "Confluence sync is turned off"; click its **Enable** button first.
- **An archived page.** It can be read but not edited; restore it in Confluence first.
- **A Confluence card says the edit "may have been saved".** The page moved one version but not to this edit. Ask the assistant to read the page again before trying again.
- **A connector card says "Chat session ended".** The chat stopped, quit or restarted before the call ran, so it was not sent. Ask again.
- **A connector card says "Chat session ended — outcome unknown".** The chat ended while the call was running. Check the connector to see whether it ran, then click **Dismiss** to take the card off the Inbox badge.
- **The chat says a connector is switched off or not connected.** Turn it on, or click **Connect on claude.ai**, in **Settings → Profile → claude.ai tools**, then ask again.
- **A chat offers no proposals.** You are in a draft-only chat. Use the main chat or the target's chat.

## Related

- [AI Chat](ai-chat.md)
- [Quick Connections](quick-connections.md): other tools the chat can read from
- [Automations](automations.md)

For developers: [docs/features/agent-actions.md](../../features/agent-actions.md), [docs/features/slack-send.md](../../features/slack-send.md), [docs/features/confluence-page-editing.md](../../features/confluence-page-editing.md)
