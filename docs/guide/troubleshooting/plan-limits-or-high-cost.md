# Plan limits and high cost

Claude runs out of quota sooner than expected, a warning says a limit will be hit, the chat says it is being rate-limited, or Watchtower's background AI uses more than you want.

## What you see

- A menu bar text `5h N% · 7d M%`, with a `⚠︎` prefix on a warning, and a notice that the 5-hour or weekly limit is projected to be hit.
- On **Usage → Claude plan**: "Sign in to Claude Code to see your plan limits.", "Your Claude Code sign-in expired — open Claude Code to refresh it." or "Couldn't update: …".
- In the chat: "The provider is rate-limiting requests. Try again in a moment."
- "Loading history paused — Claude plan limit" in the menu bar.

## Why

Your Claude plan limit belongs to your Claude account, so Watchtower's background jobs, the chat, Workbench sessions and your own Claude use all count against the same 5-hour and weekly windows. Slack Digests and Tracks run every sync cycle and are the heaviest; a bot-heavy channel multiplies the work, and a freshly connected source adds a month of history. Watchtower reads the plan numbers every 5 minutes read-only, and never refreshes Claude Code's sign-in itself.

## Fix

1. Open **Usage** and pick a day to see which pipeline made the calls, and **Progress** to see each run's tokens.
2. Switch off what you do not need in **Settings → Features**. The badges mark Heavy, Medium and Light. Turning off Slack Digests also leaves Tracks and People Cards with nothing to read, and Ideas with most of it.
3. In **Statistics**, **Mute for AI** on noisy channels or bots. Muted channels are skipped by digests, tracks and the briefing.
4. Lower the load per call: set **Light Model** and **Strong Model** in **Settings → System → AI**, or use Codex or a local Ollama model, which bills nothing.
5. Reduce parallel calls with **Workers** under **Settings → System → AI** (default 5).
6. **Sign-in expired:** use Claude Code once so it refreshes its sign-in; the numbers return within 5 minutes, or press **Refresh** on the tab.
7. **Rate limit in the chat:** wait a moment and press **Retry**.
8. Notifications about limits are the **Claude plan limits** switch in **Settings → Features → Notifications**.

## How to check

**Usage** shows fewer AI calls for the next day, and the 5-hour percentage grows slower. History backfill resumes by itself when no limit is projected to be hit.

## If it did not help

Codex and API-key accounts have no plan numbers. The model tiers and what costs what are on [AI providers, models and cost](../concepts/ai-providers-and-cost.md). A failing provider is [The Claude or Codex tool is not found or not signed in](ai-tool-not-found-or-not-signed-in.md).
