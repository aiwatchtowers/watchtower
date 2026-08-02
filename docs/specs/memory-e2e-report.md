# Secretary Memory — Phases 0–2 E2E Validation Report

> Ran on the work machine, live workspace `whitebit`, 2026-07-15/16. Task: `docs/specs/memory-e2e-validation-task.md`.
> Scope actually run: the last 7 days of the workspace (watermark manually advanced from the full 2020-backlog start to `now - 7d` before the first pass — see "Scope note" below).

## Scope note (deviation from the task's literal setup)

The task's setup step (`git checkout && ./watchtower memory consolidate --once` from a fresh `memory status`) assumes debt starts small. This workspace's sync backlog goes back to **2020-03-25** (451K+ total messages; see the pre-build audit), so a literal first pass would have to grind through ~5.5 years of mostly-dormant history before reaching anything current. Two full backlog passes were attempted and killed after ~30 minutes each having processed only ~1300 messages apiece with the pre-fix, one-call-per-channel extractor (see "Bug found" below) — at that rate, catching up to the present would have taken many hours. To keep the validation within a reasonable session, the watermark was manually advanced to `now - 7 days` before the first real pass. This means: **contract validation (section A) and quality review (section C) are grounded in 7 days of real data, not the full backlog**; the full-backlog catch-up behavior itself was not exercised end-to-end (only ~2700 messages of very old 2020 history were processed before the jump, confirming the mechanics work, not that a multi-year catch-up completes in practice).

## Bug found and fixed during this validation (blocking, now resolved)

**The first pass against real data failed 98/98 batches, 0 episodes.** Cause: the new cross-channel batching (`internal/memory/pipeline.go`, added earlier this session to fix a throughput problem — one AI call per channel window meant ~100 tiny calls per 2000-message chunk) built its prompt starting with a `"--- #channel (id) ---"` delimiter. `internal/ai/client.go` passes the generator's user message as a raw `"-p", userMessage` argv token (not stdin), and the `claude` CLI parsed the leading `--` as an unrecognized flag instead of `-p`'s value. No mocked-generator unit test could have caught this — it only surfaces against the real CLI subprocess. Fixed by opening the batch prompt with a non-dash line and switching the delimiter to `"=== #channel (id) ==="` (commit `8cb96d1`, prompt bumped to `memory.extract_episodes_batch` v2, regression-guarded by `TestBuildExtractPromptsNeverStartWithDash`). Confirmed fixed: the next pass extracted 67 episodes from 98/98 windows cleanly.

## Second issue found: watermark can fail to persist across a killed process, even after several full vault commits (open, NOT fixed — flagged for Phase 3)

While draining the 7-day backlog, a `consolidate --once` process was killed (background-task timeout, not a crash) partway through a run. **All 5 of that run's batches had already committed successfully to the git vault** (confirmed via `git log` in the vault — 5 `memory(extract)` commits plus a `memory(map)` commit, covering messages from 2026-07-10 14:19 through 2026-07-14 13:01), but `workspace.memory_last_extracted_ts` in the SQLite DB never advanced past its pre-run value. The next pass began **re-extracting the exact same message range** (verified byte-for-byte identical `period_from`/`period_to` on its first batch) and had already committed 8 duplicate episode nodes before this was caught and the pass was killed.

Recovery was manual: the watermark was set via direct SQL to the highest `period_to` already confirmed committed in the vault (`1784034099`, from `pipeline_steps` for the killed run). This is **not a code fix** — the underlying cause is unconfirmed. SQLite is in WAL mode with `synchronous=NORMAL`, which per SQLite's own documentation should survive an application-level kill (not just an OS crash), so the expected durability guarantee did not hold here for reasons not yet diagnosed. `SetMemoryWatermark` is called incrementally after each successful batch inside `runExtract`'s loop (not just once at the end), so this cannot be explained by "the kill happened before any watermark write" — multiple such writes should have already landed durably minutes before the kill.

**This should block or at least inform Phase 3**: the documented v1 limitation ("a crash between vault commit and watermark write can produce near-duplicate episode nodes... at most one uncommitted chunk") is **more severe in practice than documented** — an entire run's worth of committed batches (not just the one in flight) can apparently lose their watermark advance together. Recommend before Phase 3: reproduce this deliberately (kill at controlled points across multiple runs) to isolate whether it's a WAL-checkpoint interaction, a connection-pooling artifact, or something else, and consider writing the watermark and the vault commit hash together in one place that can be reconciled on startup (e.g., stamp the vault's last commit SHA next to the watermark, and on daemon start verify they're consistent, self-healing forward if the vault is ahead of the recorded watermark by re-deriving it from `git log`).

## A. Contract health

| Check | Result |
|---|---|
| refs_rejected rate | **1 rejected out of thousands of refs across ~4 clean runs** (runs 16305: 0/many, 16314: 0/many, plus 1 earlier in a partial run) — near-zero, matching the pre-build audit's prediction for honest, copy-don't-invent extractor output. MEM-01 held: 3 spot-checked provenance refs all resolved to the exact real message, content matching the episode's Story verbatim (down to dollar figures). |
| malformed count | 0 across all clean runs on real data. (Malformed handling itself was separately unit-tested via the injected cross-channel-refs and one-bad-channel-in-a-batch scenarios — both correctly fail the whole batch, see the code-review fixes from earlier this session.) |
| quarantine on untouched vault | **0**, as expected. Deliberately re-tested (F4): injected an unknown frontmatter key into one entity file → `quarantined=1`, file kept on disk, existing index row preserved, pipeline continued; reverted → next pass clean (`quarantined=0`). |
| watermark monotonicity | **Violated in practice once** — see "Second issue found" above. Never moved *backwards*, but failed to move *forward* despite confirmed committed work, after a killed process. Manually corrected mid-validation. |
| debt strictly decreases | True on every pass that wasn't the duplicate-generating one (which was killed after 1 batch once the duplication was noticed). Final state: **debt = 0**. |
| concurrency (flock) | **Confirmed clean.** A second `consolidate --once` launched while one was mid-run refused instantly with `"memory consolidation: another memory run is in progress"`, exit code 1, no artifacts. Lock releases correctly even when the holding process is killed (verified twice). |
| idempotency at debt=0 | **Confirmed.** A pass at debt=0 produced all-zero stats (`0 episodes from 0/0 windows`) and zero new vault commits (85 commits before and after), in 4.6 seconds. |
| owner-edit round-trip (MEM-03) | **Confirmed.** Hand-edited one entity's `## What` line; the next pass committed a separate `memory(owner-edit): manual changes` commit *before* its map re-render, and the edit survived verbatim in the file afterward. |
| reindex | **Confirmed.** Node count unchanged (831 before and after `memory reindex`). |

## B. Cost & runtime

Two clean, fully-committed extraction runs on real data (the two that weren't interrupted):

| Run | Episodes | Windows/batches | Messages | Input (uncached) | Output | Total API tokens | Wall clock |
|---|---|---|---|---|---|---|---|
| 16305 | 67 | 98 windows → 5 batches | 2000 | 45 | 76,390 | 127,740 | 741s (12m21s) |
| 16314 | 51 | 69 windows → 5 batches | 1085 | 36 | 53,963 | 79,340 | 488s (8m8s) |
| **Total** | **118** | **167 → 10 batches** | **3085** | **81** | **130,353** | **207,080** | **1229s (20m29s)** |

**Batching's actual throughput win** (the reason this whole batching detour happened): the *pre-fix, per-channel* extractor made one AI call per channel window — a killed diagnostic pass processed only **1287 messages in 46 calls over ~31 minutes** (~40 msg/min). The *post-fix, batched* extractor processes messages at roughly **150–160 msg/min** (3085 messages / ~20.5 min, 10 AI calls instead of ~167) — **roughly a 4x wall-clock improvement and a ~17x reduction in AI call count** for the same content, because batches of up to 20 quiet channels/DMs share one call.

**Steady-state extrapolation**: the pre-build audit estimated raw text at ~50K tokens/day. This run's real ratio (3085 messages → 207,080 total API tokens, 130,353 output tokens) scales to roughly **207K–280K total API tokens/day and ~130K–175K output tokens/day** at the workspace's actual weekday-heavy traffic (~4,100 msg/day average per the pre-build audit). Per that audit's own framing, output tokens are the real cost driver in any pricing model, and the budget currency is the CLI subscription's rate limits, not API dollars — this is consistent with "cents to a dollar a day" being the right order of magnitude, now with actual measured numbers instead of estimates.

**Wall-clock for a full day's volume**: ~20.5 minutes of AI-call time for 3085 messages extrapolates to roughly **27 minutes/day** of consolidation wall-clock at the workspace's real daily message volume — comfortably small for a background daemon phase running in small chunks throughout the day (matches the "micro-dreams" design intent).

## C. Quality (hand review)

**10 random extracted episodes** (not situation-ingested), graded good / usable / garbage:

- 8 **good**: clear title, real story, honest outcome (including partial/ambiguous ones stated as such, e.g. "Partial - fix released but asymmetric behavior noted"), participants correctly attributed. Example (anonymized detail, real structure): *"WebSocket notification duplication on account transfer"* — correctly captured a multi-person diagnosis-then-partial-fix arc across 3 messages spanning several days, with an honestly stated caveat instead of a false "resolved."
- 2 **usable**: one had an empty Outcome (correctly — `outcome: null` for a genuinely still-open investigation, not a bug), one was slightly rambling but still captured the actual decision made.
- 0 garbage.
- **3 spot-checked provenance refs, 3/3 resolved to the exact real message**, content matching the episode's Story verbatim (a Cloudflare invoice episode's two dollar figures matched the source message exactly).

**5 situation-ingested episodes**: uniformly excellent — this reconfirms the pre-build audit's strongest finding. Example: a DDoS-incident situation captured a precise chronology-by-actor ("artem.deriapa — primary alert... → Kateryna Shulika — 2.37M requests blocked... → Denys Molchanov — closed as 'no action required' without assigning a DRI or RCA"), with a clear, honestly-stated governance gap (no DRI/RCA) as the actual "outcome." Faithful mirrors of the source situations, not lossy compressions.

**10 seeded entity pages**: all mechanically correct (right people/channels resolved from Slack IDs, Jira keys, people_card refs) but **almost all have an empty `## What` section** — this is the documented v1 design (mechanical seeding is a skeleton; a real "What" only appears when the entity already has rich content in the *existing* `people_cards` table, e.g. "Показывает систематический подход к диагностике проблем..." for one well-covered person vs. "Insufficient data for analysis this period" — literally the People Pipeline's own low-signal message — for most others). **Missing entity**: no dedicated concept/topic entities exist at all in v1 beyond people/channels/Jira-project natural keys — see the `## Links` finding below.

**`## Links` back-link coverage — a real gap**: out of 447 seeded entities, **only 1** (`CEX`, a Jira-project-key entity) ever received an episode back-link. The extractor's `entity_hints` (free-text labels like "HSM", "phishing", "gzip compression", dozens of distinct hints logged as "unresolved" on nearly every batch) almost never match an existing alias, because v1's alias table only covers Slack user IDs, Slack channel IDs, and Jira project keys — not the free-text concepts the extractor actually names. The hint-resolution mechanism works correctly (nothing invented, unresolvable hints dropped per design) but is **structurally starved of anything to resolve against** for concept-level entities. This is worth a Phase 3 decision: either seed a broader entity vocabulary (topics/systems/processes, not just natural-key people/channels/projects) or accept that back-links stay sparse until full LLM-authored entity pages exist.

**`map.md`**: reads as a genuinely usable table of contents — People/Channels/Projects sections with one-line excerpts (drawing on existing `people_cards` content where available), a clean "Recent open episodes" list with real, relevant titles. **But it is 56 KB**, not the design notes' target "~2 KB, always injected wholesale." At 447 entities the mechanical one-line-per-entity render has already blown past the "inject into every chat" budget by roughly 28x — this is a direct, negative answer to the map-size-discipline question below.

**3 `memory_recall` queries**: "HSM" and "staging maildev" both surfaced exactly the right, relevant episodes (including two near-duplicate maildev episodes from separate extraction windows — expected v1 behavior, dedup is explicitly Phase 3). "prod deploy failed" (a more generic phrase) returned no matches — FTS keyword recall is literal, not semantic; a paraphrased query can miss content that's actually there.

## D. Phase 3 knob inputs

- **Episodes per entity per week / rewrite trigger**: cannot be measured meaningfully yet — only 1 entity ever accumulated any links (see above), so the draft's "N deltas accumulate" trigger (default 5) has no real data to validate against until entity vocabulary broadens.
- **Duplicate episodes observed**: yes, but **all 8 known duplicates in this vault are an artifact of this validation's own killed/re-run incident**, not organic retry-overlap. Titles were not identical between the original and duplicate (a title-based dedup heuristic would miss this pair) — dedup will need to key off provenance ref overlap, not title similarity.
- **Episode age/volume distribution**: 384 episodes from 7 days of real traffic → roughly **55 episodes/day** at this workspace's activity level. The design's 45-day eviction window would hold roughly 2,475 episodes before the oldest start evicting — very manageable at this rate.
- **Total vault size / map-size discipline**: **8.3 MB total** (1.7 MB entities, 1.5 MB episodes, 56 KB map) after 7 days on this ~70-person workspace. Extrapolating to a full month: roughly **35 MB** — squarely inside the pre-build audit's "single-digit to tens of MB" prediction. **The map itself, however, is NOT viable at ~2 KB** — see above; this is the one figure in the design notes that needs a hard revision, not just a footnote.

## Verdicts

1. **Does it hold up?** — **Mostly yes, with one real open risk.** Provenance (MEM-01), quarantine (F4), concurrency (flock), idempotency, and owner-edit isolation (MEM-03) all held exactly as designed under real load. The watermark-persistence gap on a killed process is a genuine, reproduced issue that risks silent duplicate extraction in production if the daemon phase is ever interrupted mid-run (crash, OOM, machine sleep) — **this needs root-causing before Phase 3**, not just noting.
2. **Is the output any good?** — **Yes.** Situations are excellent, unmodified. Raw-text episodes are good-to-usable with honest outcomes and verified provenance. The weak points are structural, not quality-of-generation: seeded entity pages are empty skeletons in practice (by v1 design), back-link coverage is nearly nonexistent because the hint vocabulary and the alias vocabulary don't overlap, and `map.md` is far larger than the design's stated budget.
3. **What are Phase 3's knobs?** — Partially answered. Vault size and episode-volume numbers are solid and match the pre-build audit's predictions well. Rewrite-trigger and dedup-threshold numbers can't be validated yet (too few links accumulated); duplicate-detection needs to be provenance-based, not title-based, given what this validation itself produced. The map-size assumption needs revising now, not deferring.

## Should block Phase 3

- **Watermark-persistence-after-kill (open, root cause unknown).** Reproduce deliberately, diagnose, and fix before relying on the daemon phase running unattended — a killed/crashed run should never risk silent duplicate extraction of already-vaulted content.
- **`map.md`'s size assumption is wrong** (56 KB observed vs. ~2 KB assumed) at only 447 entities — the "inject wholesale into every chat" design needs either a real compression pass or a two-tier map (hot summary + full index) before Phase 3 builds working-memory injection on top of it.
- **Entity vocabulary is too narrow for the back-link mechanism to do anything** — 1/447 entities linked. Worth a product decision (broaden seeding vs. accept sparse links until Phase 4's full page rewrites) rather than silently shipping a mostly-inert feature.

Non-blocking, worth tracking: FTS recall is literal-keyword only (a known, accepted trade-off, not a regression); duplicate-episode dedup should be provenance-keyed, not title-keyed, whenever Phase 3 builds it.
