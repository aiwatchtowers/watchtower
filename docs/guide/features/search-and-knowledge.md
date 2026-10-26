# Search and knowledge

Knowledge search is an index of your Slack, mail, Jira, Linear, calendar, meetings, notes and chosen Confluence spaces, and it is what the assistant reads when you ask a question about your work. There is no search screen of its own: you search by asking.

## Why use it

You remember a thing was discussed, but not where. Ask the assistant "what did we decide about the payments rollout?" and it searches every source at once, then answers with links back to the original message, mail, issue or page.

## How it works

**Knowledge search** is a full-text index that the daemon keeps up to date on every cycle. The index itself uses no AI; images and links do (below). It covers:

- the pages of this user guide, from the app itself (the assistant's help answers use them);
- Slack threads and channel days, Gmail and IMAP threads, Jira and Linear issues with their comments;
- calendar events, meeting transcripts and recaps, digest topics, ideas and decisions;
- artifacts from your AI chats that you added with **Add to Knowledge** (see [Artifacts in Chats](ai-chat-artifacts.md));
- the text files (`.md`, `.markdown`, `.txt`) of a workbench folder, visible only to that workbench's own sessions;
- the Confluence spaces you select (pages, blog posts, comments and the text of attachments).

Memory is not part of this index; the assistant reads it separately. A deleted source row leaves the index within one cycle, a Slack message deleted today within a sync cycle or two, an older one when the day-by-day check reaches its day (see [Privacy](../concepts/privacy.md#when-something-is-deleted-at-the-source)).

### Images and links
<!-- learn
id: knowledge-images
title: Find a screenshot by what it shows
text: Images in Slack, mail, Confluence and your chats get an AI description, so search finds them by their content.
area: assistant
level: next
kind: feature
since: 0.25.0
requires: feature:knowledge-search
-->

<!-- learn
id: knowledge-links
title: Search inside shared links
text: Public links posted in Slack and Confluence are opened and summarized, so a question finds the page behind them.
area: assistant
level: power
kind: feature
since: 0.25.0
requires: feature:knowledge-search
-->

**Images.** New images in Slack messages, Confluence pages and attachments, mail, and the images you attach in **Chats** or to a workbench target get an AI description: what it shows, the text on it, and keys like `PROJ-123`. It joins the message, page or mail as a section labelled "Image (AI description of an attached image)", so a screenshot is found by what it shows, and a key on it links the thread to that issue. Tiny images, tracking pixels and repeated mail logos are skipped. Chat images feed Ideas & Decisions; target images reach the agent with the target.

**Links.** New links in Slack and Confluence are opened and summarized: "Link (AI summary of a fetched public page)". Never opened: links in mail, links whose address carries a token, key or signature or reads like `/reset`, `/invite` or `/login`, addresses on your Mac or local network, Slack, Atlassian, Linear, Gmail and Google Calendar links (already synced), Google Docs and Drive links, and addresses with a port other than the usual web ones. Login pages are not summarized.

Only images and links that arrive while Knowledge search is on are processed, never older ones. Images need Claude or Codex as the provider (with Ollama they wait); near your Claude plan limit the work pauses.

- Opening a link fetches the page from your Mac like a browser visit: the site sees your Mac's address and the time, and a tracking link can tell its author the link was opened.
- Text read off a screenshot is stored and searchable as it is, passwords and tokens included.
- Links to your own company: the domains of the work addresses you connected (Gmail, mail, Jira, Linear; not public mail like gmail.com) and their subdomains are never opened. Hosts listed under `knowledge.link_fetch_deny_hosts` in `config.yaml` are never opened either.

**Confluence in search** uses your Jira sign-in. It is read-only: Watchtower never writes to Confluence from the index. Nothing is fetched until you select a space; after that each cycle loads a bounded amount (about 90 seconds of work), so a big space takes several cycles to arrive.

## Using it
<!-- learn
id: search-ask-chat-for-message
title: Find the exact Slack message
text: Ask **Chats** with every word you remember; the answer links straight to the message in Slack.
area: assistant
level: basics
kind: feature
since: next
replaces: [search-slack-message]
action: nav:chat
-->

<!-- learn
id: knowledge-confluence-spaces
title: Add Confluence to search
text: Pick Confluence spaces under **Connections → Jira** and the assistant reads their pages too.
area: assistant
level: next
kind: feature
since: 0.24.0
action: connect:confluence
done_when: confluence.connected
-->

**Ask across everything.** Open **Chats**, or press **⌘/**, and ask in plain words. The steps show as "Searched knowledge: ..." so you can see what the assistant looked up. Coding agents in a Workbench and other tools you connect through the **MCP Server** setup use the same index.

**Add Confluence.** When you add a Jira site, **Also connect Confluence** is ticked: the same sign-in grants Confluence, and **Choose Boards** selects up to five spaces you wrote in or viewed in the last 90 days and names them. Nothing is selected while **Confluence in search** is off. To change them, or to add Confluence to a site connected without it:

1. Open **Connections** in the sidebar, then **Jira**.
2. In that site's **Confluence** section, press **Grant Confluence access** if it says Watchtower can't read Confluence yet, and approve in the browser.
3. Pick spaces; **Search spaces** filters a long list. Selecting a space starts its sync, and deselecting one removes its pages from the index.

**Turn it off.** **Settings** → **Features** has **Knowledge search** and **Confluence in search**. Both are on by default. Turned off, nothing new is indexed or described and the old index stays readable. Turned back on, the index catches up, but images and links from the time it was off are never described. The guide is the exception: it stays indexed with **Knowledge search** off, so help keeps working.

## When it's empty or wrong

- **The chat doesn't find something recent.** The index trails the sync by one daemon cycle. For Slack, results may say "NN% indexed" during a first big load.
- **"Confluence sync is turned off."** Press **Enable** in the Confluence section; it restarts the background sync.
- **"No Confluence spaces found on this site."** Your Atlassian account sees no spaces, or the grant does not cover Confluence. Press **Grant Confluence access** or sign in again.
- **A screenshot or link isn't found.** It is processed in the next cycle or two. With Ollama images wait, near the plan limit both pause, and anything from before Knowledge search was on is never processed.
- **A workbench file is missing.** Files that `.gitignore` excludes are not indexed, and other workbenches never see them.

## Related

- [Jira and Linear](jira-and-linear.md): the Jira and Linear data that feeds this index.

For developers: [docs/features/knowledge-search.md](../../features/knowledge-search.md), [docs/features/confluence-knowledge-connector.md](../../features/confluence-knowledge-connector.md)
