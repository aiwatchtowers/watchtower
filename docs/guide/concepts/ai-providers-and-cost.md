# AI providers, models and cost

Watchtower has no AI of its own and no API key to paste. It calls a provider you already use, and every AI feature goes through the one you pick in **Settings → System → AI**. This page covers the choices, what costs what, and where to watch usage.

## The three providers
<!-- learn
id: ai-pick-provider
title: Pick Claude, Codex or a local model
text: Choose the provider for every AI feature in **Settings → System → AI**; **Ollama / Local** keeps text on your Mac.
area: setup
level: next
kind: feature
since: 0.24.0
-->

| Provider | How it runs | Needs |
|---|---|---|
| **Claude** (default) | The Claude Code command-line tool | Installed and signed in |
| **Codex** | The Codex command-line tool | Installed and signed in |
| **Ollama / Local** | Any OpenAI-compatible server (Ollama, LM Studio, vLLM), at `http://localhost:11434` unless you change it | A running server and a chosen model |

Setup checks the Claude or Codex tool and keeps **Continue** off until it finds one ([Set up Watchtower](../start/setup.md)). When no provider is picked and only Codex is installed, setup picks Codex for you. If Watchtower cannot find the tool, set its path under **Settings → System → AI** (the field shows "auto-detect"), then press **Test Connection**. The main chat also has a provider and model pill for switching per chat. If your company's profile limits providers, the provider picker in **Settings → System → AI** lists only those; a configured provider it forbids shows "(not allowed)" there, and every AI call fails until you pick another.

## Light and strong models
<!-- learn
id: ai-own-models
title: Choose your own models
text: Type a model into **Light Model** or **Strong Model** in **Settings → System → AI**; **Default** clears it.
area: setup
level: power
kind: tip
since: 0.24.0
-->

Every AI call is routed to one of two tiers, and each provider has a model per tier.

- **Light** is the cheap, fast tier for bounded jobs: channel digest batches, rollups, people batches, memory extraction, mail and Jira digests, dictation cleanup, reaction commands and chat titles.
- **Strong** is for work where quality matters: briefings, day plans, recaps, tracks, idea consolidation and the chat.

Defaults:

- **Claude:** the aliases `haiku` (light) and `opus` (strong), which move to the newest model of each class without a Watchtower update.
- **Codex:** `gpt-5.6-luna` (light) and `gpt-5.6-sol` (strong), the models the Codex tool offers on a ChatGPT sign-in. A newer model such as `gpt-6-astra` needs an up-to-date Codex: run `codex update`, then type it into **Strong Model**.
- **Ollama / Local:** none, so pick a model; one model then serves both tiers.

Override either tier in **Light Model** and **Strong Model**, or press **Default** to clear it.

## What drives cost
<!-- learn
id: ai-mute-channel
title: Mute a noisy channel for AI
text: In **Statistics**, **Mute for AI** keeps a bot-heavy channel or person out of digests, tracks and the briefing.
area: setup
level: next
kind: tip
since: 0.24.0
action: nav:statistics
-->

- **Features, not tabs.** Slack Digests and Tracks are the heavy ones, every cycle. People Cards, Stream Digests, Ideas, Memory, Next Step and Knowledge search (its images and links) are medium. Briefing and Day Plan are light, once a day. Attention detection and subscription plan limits spend nothing. The badge is in **Settings → Features** ([Turning features on and off](features-on-and-off.md)).
- **Channels.** Digests are per channel, so a bot-heavy channel burns tokens. In **Statistics** you can **Mute for AI** a channel or a person; muted ones are skipped by digests, tracks and the briefing, but the chat, Catch Up and Memory can still read them.
- **Chat and Workbench.** They cost nothing until you send a message or start a session. One exception: in [Branch review](../features/workbench/diff-review.md), **Deep** mode makes a strong-model AI overview when a round opens and after each **Refresh** that finds new changes; **Quick** mode makes one only when you press **Make overview**.
- **A fresh connection.** The first month of history is processed by AI too. See [History backfill](history-backfill.md).
- **Parallelism.** **Settings → System → AI → Workers** (default 5; the **Workers** field under Sync is separate and not about AI) caps parallel AI calls.

On a local Ollama model nothing is billed, but speed and quality depend on the model you run.

## Where to see usage
<!-- learn
id: ai-usage-ledger
title: See what Watchtower spends on AI
text: Open **Usage → Watchtower** to see each AI job's calls, tokens and cost, so you know what to switch off.
area: setup
level: basics
kind: feature
since: 0.26.3
action: nav:usage
replaces: [ai-usage-by-day]
changed: Usage now shows every AI call by job, with cost, on the Watchtower tab.
-->

**Usage** has four tabs:

- **Plans**: Claude and Codex subscription limits, history and forecasts ([Plans and subscription limits](../features/plans.md)).
- **Watchtower**: what Watchtower itself spends on AI, for **Today**, **7 days** or **30 days**. A totals row shows calls, fresh input, cache, output and cost. Below it, a table lists each job (digests, briefing, ideas, memory, images, built-in automations and so on) with calls, tokens, output, cost and tokens per call. **Your automations** is a separate section with one row per automation of your own. **Chats and workbenches** shows one line each: your chats, and workbench sessions plus the helper calls Watchtower makes for workbenches. Workbench sessions count only for workbenches with analytics on; the tab names the ones left out.
- **Progress**: history of the background runs and their steps, without tokens.
- **Usage**: pick a day to see its run log, one entry per background run with status, duration, items and errors. It shows no tokens or money; **Open Watchtower tab** takes you there.

Reading the numbers:

- Cost is what the provider reports, which for Claude is the price at API rates even on a subscription, so it is not your bill. A figure with **≈** is an estimate from a price table, and **≥** means some calls have no price (Codex and local models), so the real total is higher; those calls still count in the token columns.
- A grey line under the totals names every gap: calls where the provider gave no usage (counted by length), calls with no price, and **Untagged** calls, which are listed with the command that made them.
- The tab starts counting from the first AI call after the update ("Recording starts with the next AI call"), keeps 90 days and refreshes every minute. Home shows today's total as **AI spend** (Watchtower, your automations and chats, without workbenches).
- A call that could not be written anywhere is missing from the tab; the cause (usually a full disk) leaves a line in `watchtower.log`.

For a terminal, `watchtower usage llm` prints the same numbers ([Command-line reference](../reference/cli.md)).

## Claude plan limits
<!-- learn: none -->

**Usage → Plans** shows Claude and Codex subscription limits separately, with history, forecasts and independent refresh. Claude's limits belong to the account, so chats and Claude Code draw from the same windows.

Both readers use existing sign-ins without AI model calls. The common **Subscription plan limits** feature switches them off together. Claude's system-notification switch stays separate; Codex adds information to Plans and the menu.

See [Plans and subscription limits](../features/plans.md) for window selection, menu counters, stale data and sign-in fixes.

## Related

- [How Watchtower works](how-watchtower-works.md)
- [Privacy](privacy.md): what is sent to the provider.
- [Troubleshooting](../troubleshooting/README.md)

For developers: [docs/features/llm-usage-ledger.md](../../features/llm-usage-ledger.md), [docs/features/model-provider-registry.md](../../features/model-provider-registry.md), [docs/features/claude-plan-limits.md](../../features/claude-plan-limits.md)
