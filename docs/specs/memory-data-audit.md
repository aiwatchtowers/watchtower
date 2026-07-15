# Real-data audit for secretary memory

> Date: 2026-07-15. DB: work machine, workspace `whitebit`, 1.6 GB file.
> Method: read-only SELECTs only (`sqlite3 -readonly`). No raw message text was copied into this report — aggregates and anonymized observations only.
> Task: `docs/specs/memory-data-audit-task.md`; context: `docs/specs/memory-design-notes.md`.

**Token estimation method.** From `length(text)` (characters) and `length(cast(text as blob))` (UTF-8 bytes) the text splits into Cyrillic (2 bytes/char) and Latin: `cyr = bytes − chars`, `lat = 2·chars − bytes`; tokens ≈ `cyr/2.2 + lat/4.0`. Rough (±30%), but an order of magnitude more accurate than "DB bytes ÷ 4".

---

## 1. Volume and rate

**Main correction: the doc's estimate of "3–6M tokens/day of text" is ~50–60× too high.** It was derived from DB file growth (33 MB/day), but 98%+ of that growth is not text:

| DB component (1.6 GB) | Size | Share |
|---|---|---|
| `messages.raw_json` (full history) | 886 MB | 55% |
| rest of the `messages` table (keys, permalink, ts…) | ~486 MB | 30% |
| `messages.text` — **all text of all history** | 23.5 MB | **1.4%** |
| message FTS index | ~42 MB | 2.6% |
| `messages` B-tree indexes | ~55 MB | 3.4% |
| distillate (`digests` + `digest_topics`) | ~36 MB | 2.2% |
| `people_cards` | 22 MB | 1.4% |

Other facts:

- 451K messages total; history reaches back to 2020 (sync pulled the backlog), the active period is ~2 months.
- Last 30 days: **124.4K messages, 5.03M chars / 6.36M bytes of text ≈ 1.5M tokens/month ≈ 50K tokens/day** on average; peak weekdays 60–90K, weekends 5–15K.
- **73% of messages (90.7K of 124.4K) have empty `text`** — bot notifications with content in attachments/blocks (`raw_json`; 178 MB over 30 days). Human text (`is_bot=0`): 28.8K messages, 3.05M chars (~60% of the text stream, ≈30K tokens/day).
- No Gmail tables in the DB — mail is not synced, excluded from estimates.
- Jira: 1165 issues across 2 projects, but **sync has been dead since 2026-04-24** — 0 updates in 30 days.

## 2. Stream coverage by distillate

### What is covered

Messages of the last 30 days against channel digest windows (`period_from..period_to` of their channel):

| Slice | Total | Inside a digest window |
|---|---|---|
| Messages with text | 33.7K | **~40%** (13.9K) |
| …by text characters | 5.03M | **~35%** (1.59M) |
| private channels (chars) | 4.43M | 35% |
| public (chars) | 287K | 9% |
| group_dm (chars) | 55K | 33% |
| **DM (chars)** | 255K | **0%** |
| Empty-text (bots) | 90.7K | ~2% |

- The ~40% coverage is stable across each of the 30 days — not a watermark lag but structural: digest windows are short (tens of seconds to a couple of hours, typically ~30 min per sync run) and are not generated for every channel/window.
- By channel: of 308 channels active in the month, digests have ever seen 157; channels "known to digests" hold 85% of the characters. Complete holes: **all 102 DM channels** (5% of text), 23 private (139K chars), 5 public.
- No mutes (`channel_settings` is empty) — the holes are not explained by muting.
- `period_summaries` — 0 rows (the pipeline doesn't run). Catchup (99 themes/30d) references digests/inbox — second-order distillate, doesn't cover raw.
- Inbox/situations: 1370 inbox items in 30d → 563 unique messages reached situations; 100 situations created (the feature has only existed since 2026-07-07).

### Distillate volume

Daily volume of **new** distillate (characters, typical weekday):

| Source | chars/day |
|---|---|
| digest summaries (new) | ~12K |
| digest topics (title+summary+decisions+actions) | ~45K |
| situations (after 07-07) | 15–50K |
| briefing | ~10K |
| catchup (episodic) | ~20K |
| **Total new** | **~80–130K chars ≈ 25–45K tokens/day** |

Nuance: 82% of the `digests` table "volume" (1.62M of 1.98M chars over 30d) is `running_summary` — the cumulative channel state re-copied into every digest. Counting it repeatedly yields ~100K+ tokens/day — which is presumably how the doc's 100–300K estimate was born. The actual strong-tier input (new distillate) is **25–45K tokens/day**, 3–7× below the estimate.

Naive "compression" of digests relative to the raw they cover is ≈1:1 or worse (1.59M covered chars → ~1.7M chars of digest output including topics): the existing distillate is **not 10–20:1 compression but a restatement** with repeated state.

Actual API spend over 30 days (`pipeline_runs`, all statuses) — three numbers with different roles:

| Metric | 30 days | ~/day | Meaning |
|---|---|---|---|
| uncached input (`input_tokens`) | 1.9M | 64K | lower bound of *new* content read by models (new content in agentic sessions often lands as cache_creation and doesn't show here) |
| cache input (read+write combined) | 22.4M | 750K | repeated context reads by agentic loops; read costs 0.1× regular input, write 1.25×; **not separated** in the DB |
| output | 19.9M | 664K | generation (reasoning + result); **the main cost driver**: ~$100/mo at haiku prices, ~$300/mo at sonnet — orders of magnitude above all input |

The "first (cheap) pass" is indeed already paid for: ≥64K/day of new-content input + ~660K/day of output. By pipeline (full input): digests 4.6M, inbox 4.6M, tracks 6.2M, people 7.7M, briefing 0.9M. Cross-checked against the Desktop Usage screen for 07-14: the DB gives 1.24M in / 57.3K uncached / 872K out vs 1.3M / 67.7K / 890K on the screen — the gap is explained by the day boundary (started_at in UTC, the screen uses local days).

Token-field semantics (`internal/ai/client.go`): `input_tokens` = uncached input only; `total_api_tokens` = input + cache_read + cache_creation (present only in `pipeline_runs`/`pipeline_steps` — `digests` rows have no full input); `cost_usd` is computed nowhere (always 0).

Important, on the economics' currency: Watchtower calls the `claude`/`codex` CLIs on a subscription — marginal token price is $0, the real budget is the **subscription's rate limits** (which weigh consumption roughly like API prices: cache reads are much cheaper). API dollars are a sanity check, not a real bill.

## 3. Fitness of the distillate as episode seeds

13 samples across different days reviewed by hand: 7 random digest topics, 4 situations, 2 catchup themes.

### Digest topics — half a seed

Consistently present: time frame (the digest window), participants (names in text + a `situations` JSON inside the topic with user_id and roles), the gist of the episode (title+summary read as a coherent story).

Systematically missing:

1. **Outcome/resolution.** Narrow windows → a topic is a snapshot of a story's middle: "no further updates in the window", action items forever `open`. The same story's continuation in the next window is **not linked** to the previous one — consolidation itself would have to stitch an episode out of 3–5 windows.
2. **Provenance — effectively absent.** `key_messages` is filled in 42% of topics, and the links are **hallucinated**: of 2173 ts links over 30 days exactly **12 (0.6%) resolve to a real message** by exact match, 12% with a ±60s tolerance. The model generates plausible ts (a telltale artifact — the "year shift": month-day match, epoch from the previous year). `decisions[].message_ts` is a mix of a real ts, a "17:44" time, or garbage. Channel_id is recoverable via the parent digest; message-level links do not exist.
3. Minor: occasional generation artifacts (CJK glyphs in the middle of Russian text), unresolved `U0…` ids instead of names.

### Situations — ready-made episodes

The audit's best find. Every situation has: a title, summary, why_matters, **actor-based chronology** ("who → did/claimed what → what refuted it"), a status lifecycle (open/done/stale/converted + resolved_reason), and **impeccable provenance**: 1337 of 1337 inbox references over 30 days resolve to real messages (channel_id+ts, written by the detector, not an LLM; permalink included). This is exactly the episode schema from the design notes.

Limitations: they only cover the trigger stream + the top of the stream scan (563 messages of 124K per month); history starts 2026-07-07; open situations by definition have no outcome yet.

### Catchup themes

refs point to digests/inbox items (not to messages) — usable as provenance only transitively and only through the inbox branch.

## 4. Entity vocabulary (first-wave `ent_*` candidates)

| Entity | Over 30 days |
|---|---|
| People who wrote at least once | 489 |
| — with ≥5 messages | 270 |
| — with ≥20 | 155 |
| — with ≥100 | 65 |
| people_cards already exist | 391 |
| Channels with text | 294 (157 private, 102 dm, 23 gdm, 12 public) |
| — with ≥20 messages | 163 |
| Jira projects | 2 (sync dead) |
| Tracks (threads) total | 880 |
| Targets | 27 |

First-wave scale: **hundreds of nodes, not thousands** (~150–300 people + ~160 channels + projects/systems/processes). A semantic tier of single-digit MB is confirmed; staggered rewriting of hundreds of pages is clearly feasible.

---

## Verdict on the "don't pay twice" bet

**Partially confirmed — and, in the important sense, turned out unnecessary.**

Confirmed:
- The first pass is indeed paid for (per month: ≥1.9M uncached input + 22.4M cache input + 19.9M output across pipelines) and its output exists.
- The distillate volume is affordable for the strong tier: 25–45K tokens/day of input — cents per day. Consolidation economics closes with margin.
- Situations are ready-made episode seeds with perfect provenance; take them as-is.

Refuted:
- **Digest topics are unusable as the main seed corpus without rework**: no outcome (narrow windows, no story stitching across windows) and no message-level provenance (99.4% of links hallucinated). "Dive into raw selectively via distillate links" is impossible on current digests — the links are broken.
- Coverage is full of holes: 60–65% of text outside digest windows, DMs at 0%, period_summaries dead. Memory feeding only on the output would inherit these holes.

The key correction that changes the decision frame:
- **The problem the bet protected against does not exist.** Real text raw is ~50K tokens/day (not 3–6M). Reading the **entire** daily text costs: ~$0.05–0.1/day on the cheap tier, ~$0.2–0.5/day on the strong tier (input). The "economics ×N" of dropping the bet is a multiple of a negligible base.

Therefore: "don't pay twice" is not a load-bearing wall but an optimization. The funnel design needs no rework, but there is also no reason to cling to digests as the only input.

## Consequences for the MVP slice

1. **v1 episodes = situations.** Take them wholesale (title/summary/chronology/status/provenance). They already are "episodes per our schema" with no rework.
2. **Our own cheap episode extractor over raw text** instead of trying to fix digest-window stitching: 50K tokens/day of raw reads on a haiku-class model for pennies, closes the DM hole and the 60% of uncovered stream, and yields honest provenance links (ts taken from data, not generation). Cheaper and more reliable than reconstructing episodes from fragmented windows with broken links.
3. **Digests are background context, not a source of links.** A channel's running_summary is useful as "what this channel is right now" when rewriting entity pages; never use key_messages/decisions.message_ts (hallucinations). A separate (non-blocking for memory) task — fix key_messages generation: feed real ts into the prompt and validate on write, otherwise drop the field.
4. **The bot stream (73% of messages, content in raw_json) is out of memory v1.** These are alerts/CI/integrations; if ever needed — a deterministic parser, not an LLM.
5. **Fix the Jira sync before** counting Jira as a memory input (dead since April); there is no Gmail input at all.
6. Correct the design-notes estimates: raw ~50K tok/day (not 3–6M); distillate ~25–45K tok/day (not 100–300K); entity vocabulary — hundreds of nodes; the "10–20:1 compression" of existing digests is not observed (≈1:1 due to state repetition).
7. **Measure consolidation economics by output, not input**: live data shows pipeline output (664K/day) is orders of magnitude more expensive than input in any pricing model, and consolidation's core work is page rewriting, i.e. generation. The "tens of cents to a dollar a day" estimate in the design notes, computed from distillate input, understates the main line item. And the budget currency is the CLI subscription's rate limits, not dollars.
8. For consolidation caps and accounting: weighted accounting `uncached×1 + cache×~0.1..1.25 + output×(output price)`; in the current schema cache_read and cache_creation are merged into `total_api_tokens` — when adding the consolidation phase, write them separately. `cost_usd` is never populated; AI chats log tokens nowhere — if consolidation also feeds on chats, accounting must be added.
