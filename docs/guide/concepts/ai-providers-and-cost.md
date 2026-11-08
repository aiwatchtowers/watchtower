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

Setup checks the Claude or Codex tool and keeps **Continue** off until it finds one ([Set up Watchtower](../start/setup.md)). When no provider is picked and only Codex is installed, setup picks Codex for you. If Watchtower cannot find the tool, set its path under **Settings → System → AI** (the field shows "Auto-detect"), then press **Test connection**. The main chat also has a provider and model pill for switching per chat. If your company's profile limits providers, the provider picker in **Settings → System → AI** lists only those; a configured provider it forbids shows "(not allowed)" there, and every AI call fails until you pick another.

## Light and strong models
<!-- learn
id: ai-models-per-provider
title: Keep models for each provider
text: Set **Light model** and **Strong model** in **Settings → System → AI**; each provider keeps its choices.
replaces: [ai-own-models]
changed: Switching providers restores their saved models.
area: setup
level: power
kind: tip
since: 0.26.5
-->

Every AI call is routed to one of two tiers, and each provider has a model per tier.

- **Light** is the cheap, fast tier for bounded jobs: channel digest batches, rollups, people batches, memory extraction, mail and Jira digests, dictation cleanup, reaction commands and chat titles.
- **Strong** is for work where quality matters: briefings, day plans, recaps, tracks, idea consolidation and the chat.

Defaults:

- **Claude:** the aliases `haiku` (light) and `opus` (strong), which move to the newest model of each class without a Watchtower update.
- **Codex:** `gpt-5.6-luna` (light) and `gpt-5.6-sol` (strong), the models the Codex tool offers on a ChatGPT sign-in. A newer model such as `gpt-6-astra` needs an up-to-date Codex: run `codex update`, then type it into **Strong model**.
- **Ollama / Local:** none, so pick a model; one model then serves both tiers.

Override either tier in **Light model** and **Strong model**, or press **Provider default** to clear it.

Each provider keeps its own model choices. Switching providers restores its saved choices; a provider without saved choices starts with **Provider default**.

## A reserve provider for quota limits
<!-- learn
id: ai-reserve-provider-settings
title: Keep working when your AI plan runs out
text: Turn on **Use reserve when limits are reached** in **Settings → System → AI** to switch to Codex or Claude.
replaces: [ai-reserve-provider]
changed: The reserve is set up in Settings now, and chats and automations can use it too.
area: setup
level: power
kind: tip
since: next
action: hotkey:settings
-->

If you have both Claude Code and Codex, the other one can stand in when your plan's quota runs out. In **Settings → System → AI**, choose your **Preferred provider**, check the other provider's models and CLI path under **Reserve provider**, then turn on **Use reserve when limits are reached** and save. The switch starts off; installing or testing the other CLI never turns it on.

**Check connection** checks the installed CLI without sending an AI prompt. **Not verified** means sign-in cannot safely be confirmed from metadata; **Test connection** sends one short request with that provider's strong model and account, possibly using paid quota. It tests your unsaved model and path without testing the light model or switching to the reserve.

**Saved provider limits → Check again** only reads local quota metadata and is limited to once a minute. A reset time passing does not prove recovery; a waiting safe request must succeed. Saving shows **Applying provider settings** until the background service confirms the saved configuration; it takes the change without a restart, and tasks already running and Workbench sessions carry on; **Retry** after an apply failure checks the latest saved settings.

You can also enable the reserve in Terminal:

```
watchtower config set ai.fallback.provider codex
watchtower config set ai.fallback.enabled true
```

Use `claude` as the provider when Codex is your main one. Background summaries and your automations' AI steps switch only on a confirmed quota error, with the reserve's own **Light model** and **Strong model**. When both are out of quota, supported unfinished AI steps wait for a later sync; source syncing continues. A provider your company's profile forbids is never used as the reserve. Workbench sessions keep their own agent.

New chats use **Preferred + reserve · Auto**. **Only Claude**, **Only Codex**, **Only Ollama** or an explicit model pins the chat; old chats keep their pins until you explicitly choose **Preferred + reserve · Auto model**. **Current provider** shows who actually answers and its model. Codex reads the images you attach to a message, with that message only (attach one again to ask about it later), but not PDFs or a project's images and PDFs; Ollama reads none of them, so with Ollama the paperclip picks text files only and a line under the chat says what it can't do. They start fresh on every reply and re-read the text files you sent earlier, newest first, up to 256 KB; an older file past that is named instead of read, so attach it again. A reserve missing a required tool or attachment is refused before startup.

The reserve is chosen before a new turn starts. A quota failure after work starts keeps the partial reply and offers **Review actions**, which opens saved actions without sending, approving or repeating anything. Check those actions, choose a provider if needed, then send a new message.

A healthy reserve stays with the chat after the preferred provider recovers. **Use Claude** or **Use Codex** switches back between turns and keeps your draft. If that reserve later reaches its own limit, the next new turn can use the recovered compatible preferred provider. Availability refreshes when you enter a chat, return to the app or finish a turn; the app never sends a paid test prompt just to check recovery.

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
- **Watchtower**: what Watchtower, your automations and your chats spend on AI, for **Today**, **7 days** or **30 days**. A totals row shows calls, fresh input, cache, output and cost for Watchtower, your automations and chats together, the same total Home shows; workbenches are not in it. Below it, **Watchtower collecting and processing** lists each job (digests, briefing, ideas, memory, images, built-in automations and so on) with calls, tokens, output, cost and tokens per call, and its own tokens and cost next to the title. **Your automations** is a separate section with one row per automation of your own. Tokens everywhere on the tab count fresh input, cache and output together, so the rows add up to their section's title. **Chats and workbenches** shows one line each: your chats, and workbench sessions plus the helper calls Watchtower makes for workbenches. Workbench sessions count only for workbenches with analytics on; the tab names the ones left out.
- **Progress**: history of the background runs and their steps, without tokens.
- **Usage**: pick a day to see its run log, one entry per background run with status, duration, items and errors. It shows no tokens or money; **Open Watchtower tab** takes you there.

Reading the numbers:

- Cost is what the provider reports, which for Claude is the price at API rates even on a subscription, so it is not your bill. A figure with **≈** is an estimate from a price table, and **≥** means some calls have no price (Codex and local models), so the real total is higher; those calls still count in the token columns.
- A grey line under the totals names every gap in them: calls where the provider gave no usage (counted by length), calls with no price, and **Untagged** calls, which a Watchtower job lists with the command that made it.
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
