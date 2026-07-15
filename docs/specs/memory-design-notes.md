# Secretary Memory — Brainstorm Notes

> Status: draft brainstorm capture (2026-07-15). Not a spec — a first-pass record of the concept and decisions.

## Concept

A layer orthogonal to the raw data — **memory**, modeled on human memory: evictable, self-organizing, optimized for LLM reading. Not a source registry and not search over 2GB of messages, but a distillate the secretary can orient in within milliseconds and kilobytes of context.

First-iteration consumers: **Watchtower AI chats and MCP**. Triage/compose pipelines do not read memory in v1 (INBOX contracts untouched).

## Layers (human-memory analogy)

| Layer | Analog | What it is in WT |
|---|---|---|
| Raw stream | "the world" | `messages` and other sync tables; memory only references them (provenance) |
| Episodic | "what happened" | compressed episodes with participants, outcome, links to raw |
| Semantic | "what I know" | living entity pages + beliefs |
| Working | "what I'm thinking about now" | root world map (kilobytes, always injected); kin of existing `situations` |

### Two tiers: short-term and long-term

On top of the layers — a two-tier model (analog of complementary learning systems, hippocampus/cortex):

- **Short-term** — current operational state: what's in flight, what helps right now. Mobile, rebuilt every cycle, evicted aggressively and without ceremony (self-correcting through rebuild — needs no revision machinery). Small and hot → **injected wholesale** into every chat. Largely not a new store but a distilled page over what exists (situations, targets, day plan, running summaries) + fresh episodes.
- **Long-term** — knowledge about the company, processes, people; settled dogmas. Inert: changes only through consolidation, is not evicted but **revised** — the whole hysteresis/shaken/journal/dispute apparatus applies to it. Not injected — navigated. This is the new thing being built.

Key tier decisions:
- **One node space, tier is a node attribute**, not two stores with different schemas: content flows upward (episode in flight → closed → facts into a page → dogma), and the transition must not create duplicates. Stability is a number inside the node; the longer it lives and the more often it's confirmed, the more evidence a flip requires (dogma inertia = free hysteresis).
- **Inertia is asymmetric**: a dogma is hard to move with observational noise, but a direct contradiction (owner's word, a clearly refuting episode) instantly puts it into shaken, bypassing accumulation. Inertia protects against flapping, not against falsification — otherwise silently stale dogmas (a reorg, a changed process) become a source of confident nonsense.
- **Consolidation = the bridge between tiers**: moving short-term into long-term is its core job ("sleep transfers hippocampus → cortex").

**Consolidation = sleep**: a periodic daemon phase. Fresh episodes → fact extraction → merge/dedup/conflict resolution → rewriting entity pages → updating the root map.

**Eviction ≠ deletion**: retention score `importance × recency × access_count`; accessing a node reinforces it (reads from chat/MCP "warm it up"). A cold episode collapses into one line of its parent rollup, provenance links to raw are kept — "I remember something happened, I can pull up the thread."

## Data structure

Not a vector database and not a fact table, but a **tree of linked markdown nodes** with stable IDs and explicit links. The LLM doesn't search — it *navigates*: root map (~2KB) → entity node → episode → raw messages if needed. Plus FTS5 over the nodes as "keyword recall." No vector infrastructure; SQLite is already there.

Scale: 2GB of raw over ~2 months → the semantic layer under aggressive distillation is single-digit to tens of MB, hierarchy depth 3–4 levels.

## Node types

1. **Episode** — a time-bounded story (participants, outcome, links). Immutable once closed; the past is not rewritten, only compressed on eviction.
2. **Entity** — a living page for a project/person/system/process. The only type consolidation rewrites wholesale. Sections: what it is, current state, settled facts (prose with provenance markers), relations, open loops (links to targets/situations — a separate "prospective memory" type is not built in v1).
3. **Rollup** — a time aggregate (week/month) that evicted details degrade into.
4. **Belief** — an inference, not a fact. The "observed vs inferred" axis is kept strict: a fact lives in an entity page (provenance = a message), a belief is a separate node (provenance = reasoning over evidence). Attributes: confidence, evidence for/against, revision history ("I used to think X, revised after episode Y").

## Belief revision mechanics

Three pure models were considered: silent self-revision (trust doesn't scale: invisible mind-changes, silent error propagation, flapping), asking the owner (quiz-machine secretary, the owner often doesn't know either, revision blocks), and a "shaken" buffer (honest, but with no exit it degenerates into mush). The resulting hybrid:

- **Self-revision by default + hysteresis**: a contradiction first shakes (`shaken`); a flip requires an accumulated preponderance of evidence, notably more than creating the belief took. Flapping is dead.
- **A revision journal instead of questions**: notable mind-changes go as a line into the morning briefing, with reasons. Transparency without interruption; the surface (briefings) already exists.
- **Lazy questions in context**: the secretary doesn't ping on every doubt, but when the topic comes up in Discuss it drops the doubt as a remark. An unanswered question blocks nothing (the belief lives in shaken).
- **An arguing secretary — proactively through the inbox**: a serious dispute ("you said X, I see the opposite") is a `watchtower`-detector trigger item → the usual triage pipeline → a situation on the dashboard with evidence links. The secretary's doubts compete for attention on equal footing: minor stuff — ambient, a dispute — actionable; caps and 👎 feedback protect against graphomania for free. The owner's response in the card (feedback/Discuss) = resolution of the memory conflict.
- **Evidence ranks with decay**: what the owner said in AI chats > what was observed in Slack/Gmail > what consolidation inferred. A belief with owner rank cannot be silently flipped by observations — only shaken and raised to the journal/inbox (analog of `user_rule` protection from implicit overwrite). Owner rank decays over time: fresh words are near-absolute, half-year-old ones are just strong evidence. If the owner insists in a dispute → re-pinned with fresh owner rank, but decay keeps working.

One-line rule: **never ask before a revision; always show after, when the change is notable.**

## Memory inputs (by descending trust)

1. The owner's direct words in AI chats (Discuss etc.) — top rank.
2. Observations from synced sources (Slack, Gmail, Jira, Calendar).
3. Consolidation's inferences.

## Access

One interface for both consumers: `memory_map` (root), `memory_open(node_id)`, `memory_recall(query)` — MCP tools next to `list_people`/`list_targets`; chat uses the same tools agentically, plus auto-injection of working memory (map + relevant beliefs) into the system context.

## Node addressing

Wiki model (alternatives surveyed: content addressing, git vault, hierarchical paths, natural-language addressing, natural keys, addressless embeddings — under the requirement "links survive merge/rename" most converge to "stable handle + mutable naming layer"):

- Canonical ID is stable, with a type prefix: `ent_*`, `ep_*`, `bel_*`, `sum_*` (type visible in a link before dereferencing).
- Slugs are aliases (a many-to-one table); a rename adds an alias, old ones live on as redirects.
- Links in text look like `[[ent_7f3a|billing-migration]]` — readable for the LLM without dereferencing, stable for the resolver; a stale label is refreshed by consolidation when it rewrites the page.
- Merge = tombstone with a redirect, O(1); links are rewritten lazily by consolidation; redirect chains are collapsed during rewrites (path compression).
- Split = a disambiguation node; incoming links are resolved by consolidation from context, lazily.
- `memory_open` accepts ID/alias/tombstone, follows redirects, returns the canonical node with its current ID (external consumers self-heal).
- **Natural keys as aliases**: external IDs (`C0123`, `PROJX`, email) are rows in the same alias table → cross-source identity stitching = two aliases on one node, no separate mechanism needed.
- Option: content hash as the ID of immutable episodes (free dedup) — deferred, not required.

## Change journal and reflection

- **The journal is an append-only log of all mutations** of all nodes (not just beliefs): `(ts, node_id, op: create/update/merge/tombstone/promote-tier/evict/revise, diff/summary, cause: consolidation run | chat turn | owner edit, evidence)`. Cause is mandatory — every mutation answers "why." This is the trust audit and the raw material for debugging.
- **Reflection is second-order consolidation**: a periodic phase reads the journal over a window. It catches: flapping (→ raise the node's hysteresis — self-tuning), unstable zones ("memory about X rewritten 5 times" — a briefing signal), overheated/dead areas, anomalous runs. Outputs: briefing lines, meta-observations as ordinary belief nodes, parameter tweaks. Metacognition over its own log.

## Storage: files + git primary, SQLite as index

The node design converged with an Obsidian vault (markdown + wiki links + aliases in frontmatter) — use that:

- **Primary storage is a folder of markdown files under git**: node text, frontmatter (ID, type, tier, aliases), history. A consolidation git commit = a transaction with a structured "why" message → **the change journal = git log for free**, reflection reads diffs.
- **SQLite is a rebuildable index**: FTS, mechanics metadata (confidence, retention, access_count), counters. Rule: text and history live in files, numeric and derived state in the index; the index can be dropped and rebuilt with no loss.
- **Owner's manual edits** (in Obsidian or any editor) are a top-rank input: the daemon sees the diff via git and takes it as "the boss said so." A memory-training channel with none of our UI.
- **Obsidian is compatibility, not a dependency**: WT never requires it and never calls its API; the vault simply opens nicely in Obsidian (graph view, backlinks, mobile — for free).
- Known costs: watcher/index rebuild as a subsystem; read reinforcement is only visible from chat/MCP (not from Obsidian); care with concurrent writes by the daemon and Obsidian Sync.

**Self-sufficiency principle: assume no external tools on the machine.** Everything needed is built in; external tools only improve the experience:
- git → **go-git** (pure Go, no system binary; same move as `modernc.org/sqlite`). The vault is an ordinary compatible git repo; system git/remotes are a power-user option. Manual edits are detected by diffing the working tree against HEAD on a consolidation run; the daemon makes the "owner edit" checkpoint commit itself (owner rank) — the user never needs to know git.
- Watcher → none in v1: vault ↔ index reconciliation at the start of each run (mtime/hashes against HEAD). fsnotify (pure Go) if it ever needs to be livelier.
- FTS → FTS5 inside the already-used `modernc.org/sqlite`.
- Plan B (if go-git doesn't work out): journal.jsonl + vault snapshots — the worst option (no diffs, no git compatibility), emergency exit only.

## Consolidation scheduling and economics

**"Night" is a metaphor, not a mechanism.** Consolidation work is API calls, not local compute; the machine only needs to be on. Instead of a nightly cron — **micro-dreams**:

- The daemon phase fires **on debt, not on the clock**: debt = unprocessed input since the last run (its own watermark). Debt > threshold → bite off a capped chunk (analog of `MaxTriageMessages`), digest it, commit, yield.
- **Chunk = transaction = git commit** with an advanced watermark. An interruption (sleep, shutdown) loses at most one uncommitted chunk — it just gets digested again. The requirement is idempotence and resumability, not time of day.
- Machine was off → on power-up the large debt is caught up as a series of chunks (like sync catches up Slack). Lag is harmless: the short-term tier lives on situations/targets (updated by daytime pipelines), the long-term tier is inert by design.
- One concession to "night": heavy rare work (full page rewrites, reflection) preferentially scheduled for "on AC power + user idle" (pmset/IOKit) — an optimization against competing for rate limits, not correctness.

**Economics** (owner's rate: 2GB/2mo ≈ 33MB/day of raw DB ≈ 3–6M tokens/day of text):

1. **The strong model never reads raw.** Funnel: raw → cheap tier (haiku class) squeezes out episodes (10–20:1 compression) → strong tier (sonnet class) reads only the distillate for facts/beliefs/pages → reflection reads only the journal.
2. **Don't pay twice**: existing pipelines (triage, digests, running summaries, situations) already run the raw stream through the cheap tier — consolidation feeds on their output as episode seeds and dives into raw only selectively. The first (expensive) funnel pass is already paid for by WT's current budget; the increment = strong tier over ~100–300K tokens of distillate per day → **on the order of tens of cents to a dollar a day**.
   > **Correction from the live-data audit (2026-07-15, `memory-data-audit.md`)**: the scale estimates are off by 1–2 orders of magnitude (raw text ~50K tokens/day, fresh distillate ~25–45K tokens/day), so diving into raw is cheap even for the strong tier. Measure the economics **by output, not input**: for the live pipelines output (~660K tokens/day) dwarfs all input costs in any pricing model, and consolidation's core work — rewriting pages — is generation. And the budget currency is the CLI subscription's rate limits (WT runs without an API key); API dollars are only a sanity check.
3. **Deltas by default, rewrites on schedule**: a chunk appends deltas to nodes; a full page rewrite happens when N deltas accumulate or staggered (each entity ~once a week, spread out); the root map is re-rendered from pages (cheap). Per-run caps + accounting in `pipeline_runs`.

## Boundaries against existing systems (do not merge!)

- **`inbox_learned_rules`** — "how to react"; memory — "what I know." Rules may reference nodes, live separately.
- **Channel memory (running summary)** — volatile "what's happening in the channel" for digests; an entity page is the stable "what this is." Different lifecycles.
- **`people_cards`** — remain their own base; "person" entity nodes reference the people_card, don't duplicate it.
- **`situations`/`targets`** — working memory and open loops; nodes reference them, don't absorb them.

## Open questions

- The "notability" threshold for mind-changes in the briefing journal (confidence × entity importance?).
- Whether a fifth node type "prospective memory" is needed after trialing open loops on targets.
- Exact coupling of consolidation to existing pipeline output (which of digests/situations/summaries work as episode seeds, what's missing).
- Watcher/SQLite-index rebuild mechanics from the vault; behavior on daemon ↔ manual-edit conflict.

Settled during the brainstorm: addressing (wiki model, see section), cross-source identity stitching (natural keys as aliases), storage (vault+git primary, SQLite index), journal+reflection (see section).

## MVP slice (first iteration)

1. Node tables + FTS5, types: episode / entity / rollup / belief.
2. A consolidation phase in the daemon: episodes from chats → facts/beliefs → pages → map.
3. MCP: `memory_map` / `memory_open` / `memory_recall`.
4. Working-memory injection + agentic access in Discuss chat; the owner's words from chat are written to memory with owner rank.
5. Revision journal in the briefing; dispute situations via the `watchtower` detector.
