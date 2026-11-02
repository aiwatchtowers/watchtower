# Plan limits and high cost

Claude or Codex runs out of subscription quota sooner than expected, a forecast says a limit will be hit, the chat is rate-limited, or Watchtower's background AI uses more than you want.

## What you see

- Provider-labelled counters in the menu bar, with a `⚠︎` prefix on a fresh warning. The popup keeps source errors and retry actions visible.
- On **Usage → Plans**: a source error, **Collecting data…**, or **Forecast needs an update**. Claude can also send its existing system notifications.
- In the chat: "The provider is rate-limiting requests. Try again in a moment."

## Why

Each subscription has its own account-wide allowances. Watchtower's background jobs, chats, Workbench sessions and your own use draw from the provider's windows; Claude and Codex percentages are never added together. Watchtower reads each source independently every five minutes, with a longer retry delay after errors, and never refreshes Claude Code's sign-in itself.

## Fix

1. Open **Usage → Watchtower** and pick **7 days**. The table lists each job by cost (by tokens where no cost is known), so the biggest is first; **Your automations** and **Chats and workbenches** are below it.
2. Switch off what you do not need in **Settings → Features**. The badges mark Heavy, Medium and Light. Turning off Slack Digests also leaves Tracks and People Cards with nothing to read, and Ideas with most of it.
3. In **Statistics**, **Mute for AI** on noisy channels or bots. Muted channels are skipped by digests, tracks and the briefing.
4. Lower the load per call: set **Light Model** and **Strong Model** in **Settings → System → AI**, or use Codex or a local Ollama model, which bills nothing.
5. Reduce parallel calls with **Workers** under **Settings → System → AI** (default 5).
6. **Sign-in expired:** use Claude Code once so it refreshes its sign-in; the numbers return within 5 minutes, or press **Refresh** on the tab.
7. **Rate limit in the chat:** wait a moment and press **Retry**.
8. Notifications about limits are the **Claude plan limits** switch in **Settings → Features → Notifications**.

For Codex source errors, open the installed Codex tool, sign in with your ChatGPT subscription, update it if needed, then press **Retry** on its card. An API key alone has no subscription quota to read. If only the forecast is missing, follow [Plans and subscription limits](../features/plans.md): it may need fifteen minutes of history, a fresh snapshot or account confirmation.

## How to check

**Usage → Watchtower** shows fewer calls and tokens for the jobs you switched off on the next day, and the 5-hour percentage grows slower. History backfill runs on at its own pace; the plan limit never pauses it.

## If it did not help

Subscription limits and API call costs are separate measurements. The model tiers and what costs what are on [AI providers, models and cost](../concepts/ai-providers-and-cost.md). A failing provider is [The Claude or Codex tool is not found or not signed in](ai-tool-not-found-or-not-signed-in.md).
