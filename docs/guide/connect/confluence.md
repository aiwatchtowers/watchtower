# Connect Confluence with the assistant

Press **Connect with Claude** (or Codex) on Confluence in **Connections → Jira** and the assistant connects a Jira site with Confluence on the same sign-in, through your company's Atlassian app. Watchtower then picks the spaces you work in, and the assistant adds any others you name. You sign in and approve. This page is the assistant's script: **Agent** steps are its own, **You** steps are yours.

## What you get

- The pages of the spaces you pick in knowledge search and the assistant's answers ([Search and knowledge](../features/search-and-knowledge.md)).
- Jira on the same site, with its boards ([Connect Jira with the assistant](jira.md)).

## Before you start

- Watchtower stays open on this Mac: Atlassian's sign-in returns to it on `127.0.0.1`.
- Your company's Atlassian app is on this Mac and has Confluence on: **Connections → Jira** offers **Connect with <company>'s Atlassian app**.
- **Confluence in search** is on in Watchtower's Features; without it nothing syncs.
- The site is not connected yet. For a Jira site already connected, use **Grant Confluence access** under its Confluence section instead.
- Your organization's policy allows Jira. A blocked Jira shows **Blocked by your organization** and the assistant cannot connect it.
- Atlassian's sign-in page is yours alone. The assistant reads only support.atlassian.com. It leaves any other page and stops.

## Steps

1. **Agent:** Call `connect_status`. If Jira is blocked by the organization, say so and stop. If a flow is running, wait for it with `connect_wait` or ask the customer whether to `connect_cancel` it. If the customer's site is already listed, tell them to use **Grant Confluence access** and stop.
2. **Agent:** Call `connect_start` with `with_confluence`. Watchtower opens Atlassian's authorization page in the default browser; it asks for Jira and Confluence together.
3. **You:** Sign in to Atlassian (2FA included), pick the company's site if the page asks, and press **Accept**.
4. **Check:** Call `connect_wait`; while it says `waiting`, call it again. On `connected`, go on; on `failed` or `timeout`, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong). Read the customer the Confluence line of the result: the spaces Watchtower picked, or why it picked none.
5. **Agent:** Call `choose` with kind `confluence_spaces` to list the site's spaces with the picked ones marked. Ask the customer whether to add any.
6. **Agent:** If they name more, call `choose` with kind `confluence_spaces` and `select` set to them. Then call `choose` with kind `jira_boards` and offer the boards, as on the Jira page.

## If something goes wrong

The assistant's panel always offers **Set up by hand**, which opens **Connections → Jira**.

- **Blocked by your organization** (`policy`). Your organization does not allow Jira. Ask your IT team.
- **"Another connection is already in progress."** (`busy`). Another Atlassian sign-in is running. Wait for it, or cancel it, then start again.
- **"Atlassian refused Confluence access — connecting Jira only; a second sign-in tab opens."** Your company's app or site does not allow Confluence. Approve the second tab to connect Jira alone.
- **"Jira connected; Confluence isn't enabled for this Atlassian app."** Your company's app has no Confluence. Ask whoever set it up to add the Confluence API.
- **"Turn on Confluence in search (Settings → Features) to sync your spaces."** Turn it on, then pick spaces in **Connections → Jira**.
- **"Confluence: no space you wrote in or viewed in the last 90 days."** Pick spaces with the assistant (step 5) or in **Connections → Jira**.
- **"no OAuth client configured: open your company's Watchtower link".** This Mac has no company Atlassian app. Open your company's link, or run the company setup.
- **The sign-in page was closed, or the wait ran out** (`timeout`). Nothing was connected. Start again.

```connect
service: jira
domains: support.atlassian.com
tools: connect_status, connect_start, connect_wait, connect_cancel, choose
options: with_confluence
```
