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

## When it's empty or wrong

- **The send fails with "sign in again to grant send".** Your Slack workspace was connected before send existed. Click **Reconnect Slack** on the card, approve Slack's page in the browser, then **Retry**.
- **The assistant says it cannot edit Confluence.** The site needs **Allow editing** in **Settings → Connections → Jira → Confluence**. If Confluence sync is off, that section says "Confluence sync is turned off"; click its **Enable** button first.
- **An archived page.** It can be read but not edited; restore it in Confluence first.
- **A Confluence card says the edit "may have been saved".** The page moved one version but not to this edit. Ask the assistant to read the page again before trying again.
- **A chat offers no proposals.** You are in a draft-only chat. Use the main chat or the target's chat.

## Related

- [AI Chat](ai-chat.md)
- [Quick Connections](quick-connections.md): other tools the chat can read from
- [Automations](automations.md)

For developers: [docs/features/agent-actions.md](../../features/agent-actions.md), [docs/features/slack-send.md](../../features/slack-send.md), [docs/features/confluence-page-editing.md](../../features/confluence-page-editing.md)
