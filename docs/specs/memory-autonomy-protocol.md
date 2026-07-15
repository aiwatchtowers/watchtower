# Memory feature — autonomous execution protocol

> Owner directive (2026-07-16): phases proceed autonomously, without owner interaction.
> This file defines how, and hosts the running decision journal the owner reviews at will.

## Operating rules

1. **Phase cycle** runs unattended: spec → implementation plan → agent-wave implementation (TDD) → adversarial review to convergence → fixes → push to `feature/secretary-memory` → CI kept green by a shepherd agent. No step waits for the owner.
2. **Judgment calls** are decided by conservative-default-per-spec and recorded below with rationale — never asked. The owner overrides asynchronously by editing/commenting; overrides are then implemented as ordinary work items.
3. **Inventory contracts** are never weakened silently. When a phase must CHANGE a contract, the change lands with an extended (never weakened) guard test and a `NEEDS-OWNER-REVIEW` entry below. Retroactive veto beats stalled work.
4. **Work-machine validation** is packaged as a task file in this branch (`memory-*-task.md`); the owner's only action is triggering it there. Results feed back via the branch.
5. **Merge to main** happens once, at full-feature completion, by the owner. Everything else merges into this integration branch.
6. Session death (usage limits, machine sleep) pauses autonomy; a single "продолжай" resumes it — all state lives in this branch.

## Decision journal

### 2026-07-15
- Access stats excluded from Phase 3 retention scoring (production counters are write-dead under read-only MCP; eviction must not depend on them until Phase 4 wires a writable path). Conservative default; revisit in Phase 4.
- PR #36 converted to draft: integration-branch mode per owner.

### 2026-07-16
- **NEEDS-OWNER-REVIEW (pre-existing, from work-machine session):** MEM-04 isolation granularity changed from per-channel to per-batch by the quiet-channel batching (`memory.extract_episodes_batch`); inventory updated there as "owner-approved". Recorded here for the audit trail.
- Watermark-persistence-after-kill investigation launched (top E2E blocker); fix lands with a contract-grade test when root cause confirmed.
- E2E-confirmed Phase 3 spec revisions to fold in: map.md two-tier design (56KB observed vs 2KB assumed at 447 entities); episode dedupe keyed on provenance-ref overlap, NOT title similarity (E2E's own duplicates had differing titles); entity-vocabulary broadening (1/447 back-links — hints don't overlap natural-key aliases) becomes an explicit Phase 3 goal rather than an open question.
