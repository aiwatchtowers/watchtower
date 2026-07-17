# Secretary Memory Phase 5 — Universal Substrate: Design Spec

> Date: 2026-07-16. Status: direction CONFIRMED by the owner (2026-07-16); implementation in its **own integration branch** (`feature/memory-phase5`, cut from `main` after PR #36 ships) — merged to main only as a whole, same discipline as phases 0–4.
> Background: `docs/specs/memory-roadmap.md`, the owner's brainstorm (2026-07-16: "все наши сущности внутренние должны проходить через базу знаний, плюс все внешние — письма, сообщения, ивенты календаря, таски из внешних систем, мои диалоги внутри системы"), `docs/specs/memory-autonomy-protocol.md` decision journal, `docs/specs/memory-data-audit.md` (the evidence that killed "memory on top of digests").

## Concept

Memory stops being one feature among pipelines and becomes the system's **semantic bus**: every source flows through it, every product surface renders from it. The three-layer split is load-bearing and non-negotiable:

1. **Raw layer (unchanged):** `messages`, `gmail_messages`, calendar events, Jira issues stay in relational tables as the source of record. MEM-01 validates provenance *against* raw — memory can never absorb the thing it verifies itself with.
2. **Semantic layer (the substrate):** episodes / entities / beliefs in the vault. After Phase 5 this is the ONLY distillation layer — nothing else reads raw with an LLM.
3. **Operational layer (mirrored, not absorbed):** inbox items, situations, targets, tracks, day plans remain relational UI state machines (INBOX/DASH contracts untouched); each object is *mirrored and linked* in memory (the `situation:<id>` alias pattern generalized).

"Everything passes through memory" = every input becomes episodes/entities with validated provenance, and every internal entity is represented and linked — **not** stored — in the vault.

## Sub-phases

### 5A — Universal ingestion (all external sources + all internal dialogs)

Generalize what Slack and situation-chats already have:

- **Provenance-resolver registry** (the enabling refactor, first step): each source registers a ref scheme + validator — `slack` (`channel_id ts`, exists today), `chat:` (Phase 4), `mail:<message_id>`, `cal:<event_id>`, `jira:<issue_key>@<change_ts>`. MEM-01 generalizes from hardcoded cases to the registry; the evidence grammar and episode `## Provenance` sections accept any registered scheme. One interface, one test contract per resolver.
- **Gmail**: thread → episode (a thread IS a story arc: participants, question, resolution); senders → person entities with email aliases (identity stitching is free via the alias table). Cheap-tier extractor over `gmail_messages` mirroring the Slack one (debt watermark, batching, same MEM-04 discipline).
- **Calendar**: past events → episodes (participants, topic, link to meeting recap artifacts where they exist); recurring series → entities. Mechanical where possible (event metadata is structured); LLM only for the recap-style narrative if recaps don't already provide it.
- **Jira**: status transitions → episodes; projects/epics → entities (natural-key aliases already seeded). **Precondition: the Jira sync is repaired first** (dead since 2026-04-24 — audit finding; fixing it is outside this phase's scope but gates this source).
- **Internal dialogs, generalized**: Phase 4's situation-chat ingest extends to target/track/onboarding chats; the "remember this" command (Phase-6 backlog) lands here — with universal ingestion it is the same mechanism (owner statement → owner-rank evidence / entity note, code-minted rank, MEM-09 unchanged).

Each source ships separately: own extractor, own watermark, own dark flag (`memory.sources.{gmail,calendar,jira,chats}`), own validation section appended to the living validation task.

### 5B — Renders over memory (the inversion)

The legacy distillation stack becomes views over episodes, one consumer at a time, each dark-launched against legacy output on live data before switching:

1. **Channel digests** consume the window's episodes as input (raw only for coverage gaps). Validated episode provenance kills the hallucinated `key_messages` class for free. Compare-mode first: both pipelines run, a diff report lands in the branch.
2. **people_cards ← person entity pages** (the `refs.people_card` link inverts).
3. **Channel running_summary ← the channel entity's `## Current`**.
4. **Decisions → a structured facet of episode outcomes**; the legacy table becomes a view/compat shim.

After 5A, renders are cross-source by construction — a day's digest sees mail and meetings, which the legacy stack never could. Every step carries its own inventory-contract update (DIGEST/CATCHUP guards reviewed per step, never weakened silently — NEEDS-OWNER-REVIEW journal entries where semantics shift).

### 5C — Internal entities linked through memory

- targets/tracks get entity mirrors + open-loops links (the design notes' original plan); conversions (situation → target) are recorded as episode outcomes.
- Day plan reads open loops from memory; meeting prep reads the attendees' entity pages and beliefs.
- The secretary's beliefs now range over the whole working universe — mail, calendar, tasks, dialogs — not just Slack.

### 5D — Interaction ingest (the learning loop; owner addition 2026-07-16)

The owner's interactions with entities become memory input — "это и будет наше дообучение":

- **Signal source (already collected relationally):** `inbox_feedback` (👍/👎 + reasons), `user_interactions`, `decision_reads`, situation status transitions (`resolved_reason`, dismissals, snoozes), conversions (situation → target/track), vault owner-edits (already owner-rank), and the Desktop-side access trail (the Phase-3 access stats finally gain their writable consumers — UI interactions land via GRDB and are live, unlike the read-only MCP path).
- **New evidence rank `owner-action`** — between `observed` and `owner`: authentically the owner, but non-propositional and ambiguous (a dismissal has many readings), so it weighs less than the owner's words. Minted ONLY by code from real interaction rows (`act:<table>:<id>` scheme in the resolver registry) — MEM-09 extends: the model can mint neither `owner` nor `owner-action`.
- **Mechanical first, semantic second:** (1) episode mirrors gain outcome annotations ("owner dismissed", "converted to target #N"); (2) entities gain engagement aggregates (engage/dismiss rates — the retention-importance input Phase 3 stubbed); (3) only on top of that does the ordinary belief pass form **preference beliefs** ("the owner does not care about X-alerts"), subject to the same hysteresis/shaken/dispute machinery — so everything "learned" is explainable, contestable, and visible in the revision journal. No weight updates, no fine-tuning in the ML sense: evidence accumulation with provenance.
- **Boundary preserved:** `inbox_learned_rules` ("how to react" in triage) stays its own system; memory learns "what I know about the owner"; rules may reference memory, never merge with it — one learning loop per concern.

## Non-Goals

- Absorbing raw tables or operational state into the vault (see Concept).
- Removing legacy pipelines before their render replacements win the dark-launch comparison.
- Embeddings; multi-workspace; vault sync (still Phase 6 candidates).

## Contract candidates

- **MEM-12 (resolver registry):** every provenance scheme written to the vault has a registered validator; an unregistered scheme is rejected at write time (MEM-01 generalization).
- **MEM-13 (render fidelity):** a render consumer switched from legacy must cite only episode provenance (no invented refs) — per-consumer guard extending the MEM-01 family.
- **MEM-14 (mirror, don't absorb):** memory never becomes the write path for operational tables (MEM-05 generalized beyond inbox to targets/tracks/day plans).
- **MEM-15 (action rank is code-minted):** `owner-action` evidence comes only from real interaction rows via the registry; the model can mint neither owner nor owner-action rank (MEM-09 extension).

## Rollout

- Branch: `feature/memory-phase5` off `main` after PR #36 merges (owner: implement in a separate branch). Same autonomy protocol, same review-panel-to-convergence cycle per sub-phase, PR kept draft until the whole phase validates.
- Order: resolver registry → 5A gmail → 5A calendar → 5A chats-generalization → (jira when sync fixed) → 5D interaction ingest (mechanical parts can land alongside 5A; preference beliefs after) → 5B digest compare-mode → 5B switches one by one → 5C. Each step independently shippable dark.
- Validation: per-source sections appended to a Phase-5 validation task; the 5B digest switch additionally requires the live compare report (quality ≥ legacy on the owner's hand-review).

## Estimated size

Roughly phases 3+4 combined: registry + three extractors + chat generalization (~3–4K LOC), render inversions (~2–3K LOC, heavy on tests/compat), mirrors + open loops (~1K). Multiple review cycles; several weeks of pipeline wall-clock at the current cadence.
