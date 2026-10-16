# AI providers, models and cost

Watchtower has no AI of its own and no API key to paste. It calls a provider you already use, and every AI feature goes through the one you pick in **Settings → System → AI**. This page covers the choices, what costs what, and where to watch usage.

## The three providers

| Provider | How it runs | Needs |
|---|---|---|
| **Claude** (default) | The Claude Code command-line tool | Installed and signed in |
| **Codex** | The Codex command-line tool | Installed and signed in |
| **Ollama / Local** | Any OpenAI-compatible server (Ollama, LM Studio, vLLM), at `http://localhost:11434` unless you change it | A running server and a chosen model |

Setup checks the Claude or Codex tool and keeps **Continue** off until it finds one ([Set up Watchtower](../start/setup.md)). If Watchtower cannot find the tool, set its path under **Settings → System → AI** (the field shows "auto-detect"), then press **Test Connection**. The main AI Chat also has a provider and model pill for switching per chat.

## Light and strong models

Every AI call is routed to one of two tiers, and each provider has a model per tier.

- **Light** is the cheap, fast tier for bounded jobs: channel digest batches, rollups, people batches, memory extraction, mail and Jira digests, dictation cleanup, reaction commands and chat titles.
- **Strong** is for work where quality matters: briefings, day plans, recaps, tracks, idea consolidation and the chat.

Defaults:

- **Claude:** the aliases `haiku` (light) and `opus` (strong), which move to the newest model of each class without a Watchtower update.
- **Codex:** `gpt-6-luna` (light) and `gpt-6-astra` (strong).
- **Ollama / Local:** none, so pick a model; one model then serves both tiers.

Override either tier in **Light Model** and **Strong Model**, or press **Default** to clear it.

## What drives cost

- **Features, not tabs.** Slack Digests and Tracks are the heavy ones, every cycle. People Cards, Stream Digests, Ideas, Memory and Next Step are medium. Briefing and Day Plan are light, once a day. Attention detection, Knowledge search and Claude plan limits spend nothing. The badge is in **Settings → Features** ([Turning features on and off](features-on-and-off.md)).
- **Channels.** Digests are per channel, so a bot-heavy channel burns tokens. In **Statistics** you can **Mute for AI** a channel or a person; muted ones are skipped by digests, tracks and the briefing, but the chat, Catch Up and Memory can still read them.
- **Chat and Workbench.** They cost nothing until you send a message or start a session.
- **A fresh connection.** The first month of history is processed by AI too. See [History backfill](history-backfill.md).
- **Parallelism.** **Settings → System → AI → Workers** (default 5; the **Workers** field under Sync is separate and not about AI) caps parallel AI calls.

On a local Ollama model nothing is billed, but speed and quality depend on the model you run.

## Where to see usage

**Usage** has three tabs:

- **Usage**: pick a day. It shows AI calls, input tokens (including cache), uncached input and output tokens, then each request with its pipeline, model and call count. It shows tokens, not money. A day with no AI calls shows nothing; pick another day.
- **Progress**: history of the background runs, with each run's steps, tokens and duration. Runs that made no AI call are not listed, except a failed Memory run.
- **Claude plan**: your Claude account's limits, below.

## Claude plan limits

This tab shows how much of your Claude plan is used: the 5-hour window, the weekly window and per-model weekly limits, each with a projection of when it would be hit at the current pace. The limits belong to the Claude account, so Claude chats and Claude Code count too.

Watchtower reads the numbers every 5 minutes with Claude Code's existing sign-in, read-only.

It never refreshes that sign-in, so if Claude Code's token has expired the tab shows the last numbers marked stale until you use Claude Code again. The source is an undocumented endpoint and can change. Codex and API-key accounts have no plan numbers.

- The menu bar shows `5h N% · 7d M%`; a `⚠︎` prefix marks a warning. **Show in the menu bar** on this tab hides it.
- Notifications fire once per limit per window, when the 5-hour or weekly limit is projected to be hit before it resets, and when any limit reaches 90%. The switch is **Claude plan limits** in **Settings → Features → Notifications**.
- **Refresh** polls once now.
- When a limit is projected to be hit, history backfill pauses ("Loading history paused — Claude plan limit"). Nothing else is held back.
- The feature is **Claude plan limits** in Settings → Features; off stops the polling.

## Related

- [How Watchtower works](how-watchtower-works.md)
- [Privacy](privacy.md): what is sent to the provider.
- [Troubleshooting](../troubleshooting/README.md)

For developers: [docs/features/model-provider-registry.md](../../features/model-provider-registry.md), [docs/features/claude-plan-limits.md](../../features/claude-plan-limits.md)
