# Search and knowledge

Watchtower has two kinds of search. The **Search** tab finds Slack messages by words. Knowledge search is an index of your Slack, mail, Jira, calendar, meetings, notes and chosen Confluence spaces, and it is what the assistant reads when you ask a question about your work.

## Why use it

You remember a thing was discussed, but not where. Ask the assistant "what did we decide about the payments rollout?" and it searches every source at once, then answers with links back to the original message, mail, issue or page. Use the **Search** tab when you want the exact Slack message.

## How it works

**The Search tab** matches your words against synced Slack messages. Every word you type must appear in the message, and the words `AND`, `OR`, `NOT` and `NEAR` are ignored. It shows at most 100 results, best match first.

**Knowledge search** is a separate full-text index that the daemon keeps up to date on every cycle, with no AI and no cost. It covers:

- Slack threads and channel days, Gmail and IMAP threads, Jira issues with their comments;
- calendar events, meeting transcripts and recaps, digest topics, ideas and decisions;
- the text files (`.md`, `.markdown`, `.txt`) of a workbench folder, visible only to that workbench's own sessions;
- the Confluence spaces you select (pages, blog posts, comments and the text of attachments).

Memory is not part of this index; the assistant reads it separately. A deleted source row leaves the index within one cycle, a deleted Slack message within a day.

**Confluence in search** uses your Jira sign-in. It is read-only: Watchtower never writes to Confluence from the index. Nothing is fetched until you select a space; after that each cycle loads a bounded amount (about 90 seconds of work), so a big space takes several cycles to arrive.

## Using it

**Find a Slack message.** Open **Search** in the sidebar and type. Each result shows its channel as a link; the `#channel` link opens that channel in Slack.

**Ask across everything.** Open **AI Chat** and ask in plain words. The steps show as "Searched knowledge: ..." so you can see what the assistant looked up. Coding agents in a Workbench and other tools you connect through the **MCP Server** setup use the same index.

**Add Confluence.**

1. Connect a Jira site in **Settings** → **Connections** → **Jira**.
2. In that site's **Confluence** section, press **Grant Confluence access** if it says Watchtower can't read Confluence yet, and approve in the browser.
3. Pick spaces; **Search spaces** filters a long list. Selecting a space starts its sync, and deselecting one removes its pages from the index.

**Turn it off.** **Settings** → **Features** has **Knowledge search** and **Confluence in search**. Both are on by default. Turned off, nothing new is indexed and the old index stays readable.

## When it's empty or wrong

- **"No results for ..."** in **Search**. Every word must match, so drop a word. Only Slack messages are searched here; mail and Jira are found through the chat.
- **The chat doesn't find something recent.** The index trails the sync by one daemon cycle. For Slack, results may say "NN% indexed" during a first big load.
- **"Confluence sync is turned off."** Press **Enable** in the Confluence section; it restarts the background sync.
- **"No Confluence spaces found on this site."** Your Atlassian account sees no spaces, or the grant does not cover Confluence. Press **Grant Confluence access** or sign in again.
- **A workbench file is missing.** Files that `.gitignore` excludes are not indexed, and other workbenches never see them.

## Related

- [Jira and Linear](jira-and-linear.md): the Jira data that feeds this index.

For developers: docs/features/knowledge-search.md, docs/features/confluence-knowledge-connector.md
