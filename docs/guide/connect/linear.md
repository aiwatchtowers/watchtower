# Connect Linear with the assistant

Press **Connect with Claude** (or Codex) in **Connections → Linear** and the assistant connects a Linear workspace, by your sign-in or by a personal API key, then picks the teams to sync with you. This page is the assistant's script: **Agent** steps are its own, **You** steps are yours, **You only** steps are the customer's alone.

## What you get

- The issues of the teams you pick in **Blockers** and the weekly digest, and an assistant that reads and changes them after your Approve ([Linear](../features/linear.md)).
- Several workspaces: run it once per workspace.

## Before you start

- Watchtower stays open on this Mac: Linear's sign-in returns to it on `127.0.0.1`.
- You can sign in to the Linear workspace. Where the workspace asks for app approvals, the sign-in waits until an admin approves Watchtower.
- An API key acts with your own Linear permissions and never expires; delete it in Linear to revoke it.
- Your organization's policy allows Linear. A blocked Linear shows **Blocked by your organization** and the assistant cannot connect it.
- The assistant works only on linear.app, and never on a page that shows a key. It leaves any other page and stops.

## Steps

Pick one path after step 1: sign in (steps 2–4) or an API key (steps 5–7). Then pick teams (steps 8–9).

1. **Agent:** Call `connect_status`. If Linear is blocked by the organization, say so and stop. If a flow is running, wait for it with `connect_wait` or ask the customer whether to `connect_cancel` it. Ask the customer whether to sign in (the default) or use a personal API key.
2. **Agent:** Call `connect_start` with `oauth`. Watchtower opens Linear's authorization page in the default browser.
3. **You:** Sign in to Linear if it asks, pick the workspace and approve Watchtower's access.
4. **Check:** Call `connect_wait`; while it says `waiting`, call it again. On `connected`, go to step 8; on `failed` or `timeout`, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong).
5. **Agent:** On linear.app, open the account's security page (Linear's account menu, then **Security & access**) and stop there, before any key is made. Call `request_secret` with kind `linear_api_key`.
6. **You only:** Create a personal API key, copy it into the card, leave Linear's page, then press **Send**.
7. **Check:** `request_secret` returns the result once Watchtower has checked the key. On success, go on; on a failure, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong).
8. **Agent:** Call `choose` with kind `linear_teams` to list the workspace's teams. Ask the customer which ones to sync. An empty list means the first sync has not finished: tell the customer to pick teams under **Teams** in **Connections → Linear** after it, and stop.
9. **Agent:** Call `choose` with kind `linear_teams` and `select` set to the picked teams. Then call `connect_status` to confirm the workspace.

## If something goes wrong

The assistant's panel always offers **Set up by hand**, which opens **Connections → Linear**.

- **Blocked by your organization** (`policy`). Your organization does not allow Linear. Ask your IT team.
- **"Another connection is already in progress."** (`busy`). Another Linear sign-in is running. Wait for it, or cancel it, then start again.
- **"Another Linear change is still running — try again in a moment."** A team change is still running. Pick the teams again a moment later.
- **The sign-in waits for an admin.** Your workspace asks for app approvals. Ask a Linear admin to approve Watchtower, then start again.
- **"Paste a Linear API key."** The card was sent empty. Run the API key path again.
- **"Connect failed" with a message.** The key or the sign-in was refused. The assistant reads you the message; make a new key or sign in again.
- **"Couldn't load teams" with a message.** Pick teams later under **Teams** in **Connections → Linear**.
- **The sign-in page was closed, the card was cancelled, or the wait ran out** (`timeout`). Nothing was connected. Start again.

```connect
service: linear
domains: linear.app
tools: connect_status, connect_start, connect_wait, connect_cancel, choose, request_secret
secrets: linear_api_key
options: oauth
```
