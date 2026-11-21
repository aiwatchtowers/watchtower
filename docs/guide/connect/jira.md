# Connect Jira with the assistant

Press **Connect with Claude** (or Codex) in **Connections → Jira** and the assistant connects a Jira site through your company's Atlassian app, then picks the boards to sync with you. You sign in and approve. This page is the assistant's script: **Agent** steps are its own, **You** steps are yours.

## What you get

- The boards you pick in **Project Map**, **Releases**, **Blockers** and **Workload**, and in the briefing and the assistant's answers ([Jira](../features/jira-and-linear.md)).
- Confluence on the same sign-in, if you want it: [Connect Confluence with the assistant](confluence.md).

## Before you start

- Watchtower stays open on this Mac: Atlassian's sign-in returns to it on `127.0.0.1`.
- Your company's Atlassian app is on this Mac: **Connections → Jira** offers **Connect with <company>'s Atlassian app**. Without one, open your company's Watchtower link, set it up with [Set up your company's Atlassian app with the assistant](company-atlassian.md), or connect by hand with an API token.
- You can sign in to Atlassian with an account that reaches the company's site.
- Your organization's policy allows Jira. A blocked Jira shows **Blocked by your organization** and the assistant cannot connect it.
- Atlassian's sign-in page is yours alone. The assistant reads only support.atlassian.com. It leaves any other page and stops.

## Steps

1. **Agent:** Call `connect_status`. If Jira is blocked by the organization, say so and stop. If a flow is running, wait for it with `connect_wait` or ask the customer whether to `connect_cancel` it. Ask the customer which site to add (like `acme.atlassian.net`) and whether to add Confluence too; for Confluence, follow the Confluence page instead.
2. **Agent:** Call `connect_start`, with `site` set to the customer's site when they named one. Watchtower opens Atlassian's authorization page in the default browser.
3. **You:** Sign in to Atlassian (2FA included), pick the company's site if the page asks, and press **Accept**.
4. **Check:** Call `connect_wait`; while it says `waiting`, call it again. If the account reaches several sites, Watchtower asks which one: call `set_fields` with `site` set to the customer's pick, then `connect_wait` again. On `connected`, go on; on `failed` or `timeout`, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong).
5. **Agent:** Call `choose` with kind `jira_boards` to list the site's boards. Ask the customer which ones to sync; only picked boards sync.
6. **Agent:** Call `choose` with kind `jira_boards` and `select` set to the picked boards. Then call `connect_status` to confirm the site and tell the customer the first sync has started.

## If something goes wrong

The assistant's panel always offers **Set up by hand**, which opens **Connections → Jira**.

- **Blocked by your organization** (`policy`). Your organization does not allow Jira. Ask your IT team.
- **"Another connection is already in progress."** (`busy`). Another Jira sign-in is running. Wait for it, or cancel it, then start again.
- **"no OAuth client configured: open your company's Watchtower link, or set WATCHTOWER_JIRA_CLIENT_ID for development".** This Mac has no company Atlassian app. Open your company's link, run the company setup, or use **Connect with an API token** by hand.
- **"this Atlassian sign-in does not reach the company's site".** You signed in with an account outside the company's site. Sign in with your company account and start again.
- **"Watchtower's shared Atlassian app is retired".** Connect through your company's app or with an API token.
- **The sign-in page was closed, or the wait ran out** (`timeout`). Nothing was connected. Start again.
- **The board list is empty.** The site has no board you can see. Pick boards later under **Boards** in **Connections → Jira** (**Fetch Boards**).
- **"Connect failed" with a message.** The assistant reads you the message. Try again, or use **Set up by hand**.

```connect
service: jira
domains: support.atlassian.com
tools: connect_status, connect_start, connect_wait, connect_cancel, choose, set_fields
options: site
```
