# Slice B real-data retrieval-compare report (Task 13)

> Date: 2026-07-21. Real-data verification of the Slice B unified retrieval mechanism (`docs/superpowers/specs/2026-07-20-memory-slice-b-unified-retrieval-design.md`), run against a safe, read-only snapshot of the live `whitebit` workspace (2,062 memory nodes at snapshot time, 465k messages). The snapshot and vault clone live at a session-scratch path outside the repo; never the live daemon's database. See methodology below for exactly how isolation was achieved.

## Verdict

**None of the three surfaces (recall / briefing / meeting-prep) clear the "not worse and demonstrably better on at least one dimension" bar on this real-data pass. All three flags stay dark. 13a/13b/13c are NOT executed in this slice.** This is a legitimate, plan-sanctioned outcome ("a surface can remain dark indefinitely... not a plan failure"), not a defect in Tasks 1–12's implementation — every task's own review already verified the code matches its spec. What this pass adds is real-world evidence about how the *mechanism* behaves against actual data, which surfaced two findings worth fixing before a future re-verification pass:

1. **Recall shows a real relevance regression risk on person-name queries**, not just harmless reordering (see below).
2. **Beliefs structurally never earn nonzero `importance_score` under Slice A's current `ComputeImportance` formula**, which makes briefing's (and meeting-prep's belief half) importance-based reranking inert on real data — a Slice A property, not a Slice B bug.
3. **Meeting-prep's short-term episode feature is architecturally dead on real data**: `RetrieveBySubject`'s "subjects" parameter is reused for both belief-subject lookup (entity IDs, correct) and short-tier alias lookup (`memory_provenance.sender_id`, which stores Slack user IDs / emails — a different ID space than entity IDs). Nothing in the current call chain resolves an entity to its Slack/email aliases before calling `ListShortTierEpisodesForAliases`, so it always returns empty on real subjects.

## Methodology

- **Isolation.** `WorkspaceDir()`/`DBPath()` are hard-derived from `$HOME` (`~/.local/share/watchtower/{workspace}/`), not independently configurable — the plan's runbook text ("build a scratch config with db_path/workspace_dir") doesn't match the actual code, which has no such keys. Real isolation was achieved by running the CLI binary (built from this branch, `go build -o /tmp/watchtower-sliceb-verify .`) with `HOME` overridden to a scratch sandbox directory whose `.local/share/watchtower/whitebit/{watchtower.db,memory}` are symlinks to the already-prepared snapshot DB and cloned vault, and a minimal `.config/watchtower/config.yaml` (`active_workspace: whitebit`, `memory.enabled: true`). This guarantees zero risk to the live workspace or the live daemon (confirmed running throughout, PID unrelated to this work — a separate process, separate DB file, separate config, no shared state).
- **Importance backfill.** The snapshot's `memory_nodes.importance_score` was `0.0` for all 2,062 nodes at snapshot time — the live production daemon has never run a `Reconcile`/`Rebuild` pass that includes Slice A's importance computation (PR #40 is still unmerged; the live daemon likely predates it). Ran `watchtower memory reindex` (this branch's `Rebuild`) against the isolated snapshot to populate real, derived importance scores from the vault's actual link graph / owner-edit history / engagement before evaluating Slice B's ranking — otherwise every comparison would trivially degenerate to "no difference" for the wrong reason (zero times anything is zero, not "equally good").
- **Recall:** ran `watchtower memory retrieve-compare --since 720h` (samples up to 30 real node titles as synthetic queries, per Task 11's documented limitation — no historical query log exists).
- **Briefing:** ran the same command across four different `--since` windows (168h, 720h, 2160h, 4320h) to get more than one data point, per the runbook's own suggestion.
- **Meeting-prep:** the same single `retrieve-compare` run covers all 13 real belief-subject entities found in the snapshot.
- Every comparison is read from `memory_retrieve_shadow` — the legacy selection was never touched (Task 7's `TestRetrieveCompare_LegacyTablesByteIdentical` already proves this structurally; this pass is additional confirmation on real, not synthetic, data).

## Recall (`memory_recall` / `RetrieveByQuery`)

**30 queries compared, 0 failed. `coverage_ok=true` for 24/30 (80%); mean `importance_score` across sampled top-N: legacy 2.06 → new 3.23.**

The mean-importance uplift is real, but the metric alone doesn't tell the whole story. Manually spot-checked (`watchtower memory open <id>`) two of the six `coverage_ok=false` cases — where the new ranking dropped a legacy top-hit entirely in favor of higher-importance nodes:

- **"Krystyna Vlasenko"**: the dropped legacy hit is a short episode *entirely* about her (title, story, and both participants are her and one colleague). The new top hit is a large multi-topic "Nova Card rollout" situation episode where she appears in exactly one bullet line among ~10 named contributors — a genuine keyword match (confirmed the term appears in the body), but far less central to a query specifically about her.
- **"Yevhenii Saienko"**: same pattern — the dropped hit is a 1:1 "Deputy CTO sync" meeting with just him and the owner; the new top hit is a 12-participant "Task sync" where he's one of many attendees.

Both are legitimate FTS matches (no hallucination), so this isn't a MEM-01-class defect. But it is a real, demonstrable **relevance regression risk for person-name queries**: importance accumulates on nodes with many links/engagement (large multi-person situation episodes, by construction, tend to accumulate more), and the new ranking can let that importance signal outweigh a highly specific, on-topic match. Whether this trade-off is acceptable is a product judgment call, not a coverage bug — but it means "new is not worse" is not established for recall on this evidence; it's a genuine trade-off with observed downside cases, not a strict improvement.

**Verdict: bar not met. `memory.retrieve.recall_compare` stays dark. 13a not executed.**

## Briefing (`gatherMemoryRevisions` / `RetrieveRevisions`)

**1 comparison per `--since` window, run across 4 windows (168h/720h/2160h/4320h). Every window: `intersection=5`, and `old_ids == new_ids` byte-identically, in the same order, every single time.**

Root cause confirmed by direct query: **all 15 belief nodes in this workspace have `importance_score = 0.0`**, even after the reindex that gave 305/623 episodes and 2/1367 entities nonzero scores. `ComputeImportance` sums incoming-link count + situation-origin bonus + owner-touch bonus + positive engagement — beliefs are terminal nodes that are rarely if ever linked *to* by other nodes, carry no `situation:` alias, and (in this workspace) show no owner-edit or engagement signal either. This is an emergent property of Slice A's importance formula as applied to belief nodes specifically, not a Slice B defect — but it means briefing's importance-weighted reranking is **structurally a no-op on real data today**: with every candidate's `Relevance × 0 importance = 0`, `RankByImportance`'s `sort.SliceStable` just preserves input order, which happens to already match `ListMemoryNodes`' encounter order the legacy path used.

**Verdict: bar not met (no evidence of improvement — the mechanism is provably inert for this node type on this data, not merely "no evidence yet"). `memory.retrieve.briefing_compare` stays dark. 13b not executed.**

## Meeting-prep (`gatherMemoryContext` / `RetrieveBySubject`)

**13 real belief-subject entities compared. `new_superset_ok=true` for all 13 (no belief silently dropped). `new_short_term_ids` is empty for all 13.**

The belief half shows `old_belief_ids == new_belief_ids` for every subject — every subject in this snapshot has only 1–2 real beliefs (well under the `maxAttendeeBeliefs=3` cap), so there's no room for reordering to ever manifest; this is a real, not a coincidental, ceiling given this workspace's actual belief density, not a bug.

The short-term half is the real finding: `gatherMemoryContext` (`internal/meeting/memory_context.go:118`) passes `node.ID` — the attendee's **entity ID** (`ent_...`) — as `RetrieveBySubject`'s `subjects` parameter, which is correct for the belief-subject lookup (`memory_nodes.subject` does store entity IDs) but is then reused verbatim for `ListShortTierEpisodesForAliases(subjects, ...)`, which filters `memory_provenance.sender_id IN (...)` — and `sender_id` stores Slack user IDs / email addresses (confirmed: 1,480/1,506 provenance rows have a real, nonempty `sender_id` like `U092Z4BL087`), never an entity ID. These are two disjoint ID spaces; nothing in the current call chain resolves an entity to its Slack/email aliases before this call, so the short-tier lookup can never match on real data, for any subject, regardless of how much real short-tier episode content exists (374 short-tier, non-tombstone episodes are available in this snapshot).

This is a genuine, real design gap — present since Task 6 first wrote `RetrieveBySubject`'s signature and inherited by Task 10's wiring exactly as specified — that only real-data verification against actual entity/alias data could surface; every task's own unit tests passed because their fixtures happened to construct subjects/aliases that coincide (a synthetic convenience, not a representative case).

**Verdict: bar not met — the belief half shows no regression but also no room to demonstrate improvement on this data's actual belief density; the short-term half (the surface's one genuinely NEW capability) is confirmed non-functional on real data due to the entity-ID/sender-ID mismatch. `memory.retrieve.meeting_prep_compare` stays dark. 13c not executed.**

## Recommendation for a future pass

Before re-attempting the evidence-gated switch for any of these three surfaces:

1. **Meeting-prep:** resolve each attendee's Slack/email aliases (already stored via `memory_aliases`/entity page frontmatter) and pass those — not the bare entity ID — into `ListShortTierEpisodesForAliases`, so the short-term feature can be evaluated at all.
2. **Briefing:** either accept that importance-weighted belief reranking is a no-op until beliefs earn a real importance signal (a possible `ComputeImportance` follow-up: reward beliefs by their subject entity's importance, or by revision frequency), or treat "no observed regression, no observed improvement" as sufficient grounds for a low-risk switch in a future slice — that is an owner product call, not a code defect.
3. **Recall:** the mean-importance uplift is real and positive in aggregate, but the person-name spot-check suggests a majority-vote or blended-score approach (e.g. requiring some FTS-relevance floor before importance can outweigh it) might avoid the specific-vs-broad trade-off observed — worth exploring in a follow-up before switching, given the observed downside cases are not edge cases (2 of 6 spot-checked, 20% overall `coverage_ok=false` rate).

None of these are blocking for Slice B's own completion — Tasks 1–12 are fully implemented, tested, and reviewed exactly to spec; the dark compare-mode infrastructure works correctly and safely (proven both structurally, in Task 7's guard test, and now empirically, on real data, with zero risk to the live workspace throughout this verification). What remains dark is a deliberate, evidence-based decision, not unfinished work.
