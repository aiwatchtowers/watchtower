# Search and knowledge

Watchtower has two kinds of search. The **Search** tab finds Slack messages by words and shows matching pages of this guide above them. Knowledge search is an index of your Slack, mail, Jira, Linear, calendar, meetings, notes and chosen Confluence spaces, and it is what the assistant reads when you ask a question about your work.

## Why use it

You remember a thing was discussed, but not where. Ask the assistant "what did we decide about the payments rollout?" and it searches every source at once, then answers with links back to the original message, mail, issue or page. Use the **Search** tab when you want the exact Slack message or the guide page.

## How it works

**The Search tab** matches your words against synced Slack messages and, in a **Help** block on top, against the user guide (up to three pages, one row each with the section heading). Every word you type must appear in the message, and the words `AND`, `OR`, `NOT` and `NEAR` are ignored. It shows at most 100 results, best match first.

**Knowledge search** is a separate full-text index that the daemon keeps up to date on every cycle, with no AI and no cost. It covers:

- the pages of this user guide, from the app itself (the Help block in **Search** and the assistant's help answers use them);
- Slack threads and channel days, Gmail and IMAP threads, Jira and Linear issues with their comments;
- calendar events, meeting transcripts and recaps, digest topics, ideas and decisions;
- the text files (`.md`, `.markdown`, `.txt`) of a workbench folder, visible only to that workbench's own sessions;
- the Confluence spaces you select (pages, blog posts, comments and the text of attachments).

Memory is not part of this index; the assistant reads it separately. A deleted source row leaves the index within one cycle, a Slack message deleted today within a sync cycle or two, an older one when the day-by-day check reaches its day (see [Privacy](../concepts/privacy.md#when-something-is-deleted-at-the-source)).

**Confluence in search** uses your Jira sign-in. It is read-only: Watchtower never writes to Confluence from the index. Nothing is fetched until you select a space; after that each cycle loads a bounded amount (about 90 seconds of work), so a big space takes several cycles to arrive.

## Using it

**Find a Slack message.** Open **Search** in the sidebar and type. Each result shows its channel as a link; the `#channel` link opens that channel in Slack. A guide row opens that section on GitHub, and **Ask in chat** opens the **⌘/** panel with your query in the message box (an unsent draft there is kept and the query is added below it).

**Ask across everything.** Open **AI Chat** and ask in plain words. The steps show as "Searched knowledge: ..." so you can see what the assistant looked up. Coding agents in a Workbench and other tools you connect through the **MCP Server** setup use the same index.

**Add Confluence.** When you add a Jira site, **Also connect Confluence** is ticked: the same sign-in grants Confluence, and **Choose Boards** selects up to five spaces you wrote in or viewed in the last 90 days and names them. Nothing is selected while **Confluence in search** is off. To change them, or to add Confluence to a site connected without it:

1. Open **Settings** → **Connections** → **Jira**.
2. In that site's **Confluence** section, press **Grant Confluence access** if it says Watchtower can't read Confluence yet, and approve in the browser.
3. Pick spaces; **Search spaces** filters a long list. Selecting a space starts its sync, and deselecting one removes its pages from the index.

**Turn it off.** **Settings** → **Features** has **Knowledge search** and **Confluence in search**. Both are on by default. Turned off, nothing new is indexed and the old index stays readable. The guide is the exception: it stays indexed with **Knowledge search** off, so help keeps working.

## When it's empty or wrong

- **"No results for ..."** in **Search**. Every word must match, so drop a word. Only Slack messages and guide pages are searched here; mail and Jira are found through the chat.
- **The chat doesn't find something recent.** The index trails the sync by one daemon cycle. For Slack, results may say "NN% indexed" during a first big load.
- **"Confluence sync is turned off."** Press **Enable** in the Confluence section; it restarts the background sync.
- **"No Confluence spaces found on this site."** Your Atlassian account sees no spaces, or the grant does not cover Confluence. Press **Grant Confluence access** or sign in again.
- **A workbench file is missing.** Files that `.gitignore` excludes are not indexed, and other workbenches never see them.

## Related

- [Jira and Linear](jira-and-linear.md): the Jira and Linear data that feeds this index.

For developers: [docs/features/knowledge-search.md](../../features/knowledge-search.md), [docs/features/confluence-knowledge-connector.md](../../features/confluence-knowledge-connector.md)
