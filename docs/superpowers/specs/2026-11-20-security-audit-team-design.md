# Security audit team — design

**Date:** 2026-11-20 (rev. 2: Cloudflare engine) · **Board:** #1115 · **Branch:** `feature/security-audit-team`

## 1. Intent

The owner wants to point the strongest available model (Mythos) at Watchtower's `main`
periodically and work through the findings. The owner starts a run; the skill asks which
kind (ask #779):

- **Full**: the whole of `origin/main`.
- **Range**: the code changed between two tags (default: the last audited tag → the
  newest tag), plus what that changed code now reaches.

The audit engine is Cloudflare's open-source
[`security-audit-skill`](https://github.com/cloudflare/security-audit-skill) (MIT), picked
by the owner on 2026-11-20 over our own hand-built team: it already has reconnaissance, a
deterministic coverage ledger, coverage-led hunter waves with coverage critics, an
independent fresh verifier per candidate, prior-run carry-over, `quick|standard|deep`
profiles, scoped runs over the diff between two refs, a JSON findings schema with node
validators, and domain companions (LLM, desktop/mobile/local IPC, data lifecycle, supply
chain…) that match Watchtower's surfaces.

What we build is the **Watchtower layer** around it:
1. a pinned, vendored copy of the engine;
2. Watchtower context the engine's reconnaissance and hunters read (surfaces, trust
   boundaries, inventory contracts, accepted risks);
3. the run policy Watchtower needs (read-only, nothing executed; outputs outside git);
4. a wrapper skill `/security-audit` (preflight, Full/Range question, model routing,
   run, import);
5. the owner's triage: one private claude.ai Artifact fed from the engine's
   `findings.json`, where the owner sets a status and a note per finding, and the next run
   reads those back.

Why outside git: the repository is public; an open vulnerability written into a spec, a
PR, a commit or a board comment is a disclosure.

## 2. Goals, non-goals, anti-goals

Goals
- Depth and few false positives — delivered by the engine's method (candidate gate,
  independent verifier, coverage critic).
- The owner's triage persists across runs: `accepted` and `false_positive` are not
  re-reported; a `fixed` finding that comes back is flagged as regressed.
- Coverage is visible — the engine's coverage ledger and its partial-coverage statement
  for Range runs show what was not looked at.

Non-goals
- No automatic fixes; no per-PR gate (ask #779); no scheduled runs in v1.
- No changes to the engine's method. Watchtower-specific behaviour goes into the layer,
  never into the vendored files.

Anti-goals
- Finding text, PoC or fix hint in git, a PR, a commit message, the board or any synced
  surface.
- Anything executed against the target, live services, the owner's accounts or data.
- The vendored engine silently changing under us (it instructs agents — it is supply
  chain).

## 3. Constraints

- **Read-only, nothing executed** (owner decision, 2026-11-20). The engine allows
  sandboxed local execution; the Watchtower run policy forbids it: no builds, tests,
  processes or fixtures from the target. Under the engine's own rules a check that needs
  execution leaves the finding `needs_validation` with the blocker named, and `confirmed`
  requires an execution record — so in our runs findings land as `needs_validation`
  (source trace verified, not demonstrated) or `rejected`. The owner demonstrates during
  triage. The policy is stated in the run metadata (`execution_policy:
  "source-read-only"`) and in every delegated prompt through the Watchtower context.
- **Agents.** The engine delegates to two roles (`research`, `general`). Both map to one
  Watchtower agent, `.claude/agents/sec-audit-agent.md`, with `tools: Read, Grep, Glob`
  — no Bash, Write or Edit, so text inside the audited code cannot make any agent run or
  write anything. The parent (the session running the skill) is the only writer, as the
  engine already requires.
- **Model routing.** `sec-audit-agent` has no `model` field. Agents run on
  `CLAUDE_CODE_SUBAGENT_MODEL` when set, else on the session's model. Mythos agents under
  a Fable main thread: `CLAUDE_CODE_SUBAGENT_MODEL=<mythos model id> claude --model fable`.
  No model id is written into the repo. The skill states at start which model the agents
  will use. (Owner rule: never below Opus.)
- **Engine pinning.** The engine is vendored at
  `.claude/skills/security-audit-engine/` from commit
  `c1c8a8c1471069fb0e188eeaff69b8e8db6564a8`, with its `LICENSE` and a `VERSION` file
  (commit, date, upstream URL). Updating is a deliberate PR that diffs the new upstream
  against `VERSION` and is reviewed like code.
- **Node.** The engine's validators are node scripts. Node is not on the default PATH
  (nvm); the skill resolves `node` from PATH or the newest `~/.nvm/versions/node/*/bin/node`
  and stops at preflight if none.
- **Where things live.** Engine output: the engine's default
  `~/security-audit-skill/watchtower/run-<N>/` (outside git; the engine reads prior runs
  from there). Wrapper state: `~/.config/watchtower/security-audit/` (`config.json` with
  the report URL, `lock`). Audit target: a detached worktree of the pinned commit under
  `~/Library/Caches/watchtower-security-audit/<run-id>/`, removed after the run.
- Runs need the Agent, `Artifact` and `ArtifactData` tools, so they start from a
  top-level Claude Code session with claude.ai artifacts — not a subagent and not a
  Watchtower workbench session (its transcript shows in Workchat and can reach the phone).
  The local Claude Code transcript still holds the run — accepted residual on the owner's
  machine.

## 4. Approaches

| | Approach | Trade-off |
|---|---|---|
| A | Our own team: eight surface specialists + verifier + coverage, merge rules in a skill | Fully ours, but a younger method we would have to mature ourselves |
| **B (picked)** | Cloudflare engine + Watchtower layer | Proven method, less to write; more agent calls per run (cost on Mythos); node needed; a third-party skill to pin and review |
| C | Both side by side | Two reports, two baselines |

The owner picked B on 2026-11-20 (option 1 in the session).

## 5. Components

```
.claude/
  agents/sec-audit-agent.md            read-only agent for both engine roles
  skills/
    security-audit-engine/             vendored engine, untouched + VERSION
    security-audit/
      SKILL.md                         wrapper: preflight, Full/Range, run, import
      watchtower-context.md            context + run policy handed to the engine
      import-rules.md                  findings.json → triage rows (rules + examples)
      baseline-import.json             first-run baseline from the two old audits
      report-page.html                 Artifact page template (no data)
docs/security/surfaces.md              Watchtower surfaces: paths, boundaries, contracts
```

### 5.1 `watchtower-context.md`

What the engine's parent reads at setup and passes into reconnaissance and every hunter
and verifier prompt as source-visible context (it never replaces the engine's own
reasoning):
- **Run policy**: source-read-only; no execution of any kind; outputs only under the
  engine output dir; nothing written into the target.
- **Product and principals**: the owner, the owner's colleagues (message senders), web
  pages, the owner's own agents, a co-resident local process — and what each controls.
- **Surfaces** (from `docs/security/surfaces.md`): `llm-injection`, `local-endpoints`,
  `auth-secrets`, `crypto-sync`, `exec-sandbox`, `network-ssrf`, `data-lifecycle`,
  `supply-chain`, each with paths, entry points, sinks and the strongest existing control.
- **Inventory contracts** (`docs/inventory/`): load-bearing; a fix that weakens one is
  "needs owner decision".
- **Owner triage to honour** (generated per run, §6.2): fingerprints the owner marked
  `accepted` or `false_positive` with their notes — to be handled like the engine's prior
  `rejected` records (suppress the unchanged claim only, never coverage of the unit);
  fingerprints marked `fixed` — to be re-checked.

### 5.2 `docs/security/surfaces.md`

One section per surface: `Paths:` (pathspec globs), feature notes, inventory ids, entry
points, sinks, existing controls. Used by the context file and by the Range mapping
(which surfaces a tag diff touches, reported to the owner before the run).

## 6. A run (`/security-audit`)

### 6.1 Flow

0. **Preflight.** Agent, `Artifact`, `ArtifactData` tools present; `node` found; the
   engine's `VERSION` matches the vendored files (`git diff --quiet` on the engine dir).
   Report lookup: `config.json` → else `Artifact list` for "Security audit" (one: confirm;
   several: owner picks; none: new only on an explicit yes) → a URL that no longer opens
   stops the run. Lock: refuse while another run's pid is alive.
1. **Ask the kind** (`AskUserQuestion`): **Full** (profile `deep`) or **Range** (scoped
   run over `git diff <from>..<to>`, profile `standard`), with the proposed tag pair, the
   date of the last Full, and the engine's agent-invocation estimate; the owner may set
   an agent budget (the engine's `budget`). `/security-audit full|range <from>..<to>`
   skips the question.
2. **Pin.** `git fetch origin main --tags`; Full = `origin/main` SHA, Range = the `to`
   tag. Remove leftovers of dead runs under the cache dir, `git worktree prune`, then
   `git worktree add --detach` the target.
3. **Owner triage in.** `ArtifactData list findings` → write the per-run "owner triage"
   section of the context (§5.1) into the engine output dir (never into the repo). First
   run: `baseline-import.json` instead.
4. **Run the engine** in full audit mode on the target with `watchtower-context.md` +
   the triage section, `repo = watchtower`, the profile and scope from step 1, and every
   delegation through `sec-audit-agent`. The engine writes its run directory, validates
   `findings.json` and the coverage ledger with its node validators, and produces
   `REPORT.md`/`FINDINGS-DETAIL.md`/`NEEDS-VALIDATION.md`.
5. **Import** `findings.json` into the Artifact by `import-rules.md` (§7).
6. **Summary** in the terminal: counts by verdict and severity, regressed, coverage
   status (complete / partial with reasons), the report link, and the engine run dir.
   Nothing to the board.
7. **Cleanup**: remove the target worktree and its cache dir, release the lock. The
   engine run dir stays (it is the next run's prior evidence).

### 6.2 Failure paths

| What fails | What happens | Check |
|---|---|---|
| Artifact tools, node or the engine's integrity missing | Preflight stops with the reason; nothing created | Run with each one missing |
| Config lost | Report found through `Artifact list`; new report only on explicit yes | Delete config, run |
| Report URL dead / `ArtifactData` read fails | Stop before the engine runs (without triage the engine would re-report accepted risks) | Wrong URL in config |
| Engine stops early (budget, interruption, validator failure) | The engine marks the run `incomplete` itself; the wrapper imports whatever validated `findings.json` exists, labels the run "incomplete" in the report, and keeps the run dir | Run with a tiny budget |
| Import/publish fails | Engine run dir is intact; `/security-audit import <run-dir>` re-runs the import alone | Deny the publish prompt, then re-import |
| Two runs at once | Lock refuses the second | Start a second run |
| Owner edits while importing | Import writes only run-owned fields (§7) | Edit during import |

## 7. Triage Artifact

One private Artifact, URL in `config.json`. The page holds no findings; all data lives in
its `db` (`db` rules: read `view`, write `owner`; plus `user`).

Collections:
- `runs/<run-id>`: engine run dir name, kind, from/to, SHA, profile, budget,
  `run_status` (complete / incomplete + reason), coverage summary (units covered /
  deferred / out_of_scope), counts.
- `findings/<doc-id>` (doc id = first 16 hex of SHA-256 of the engine fingerprint):
  - run-owned: `fingerprint, verdict (needs_validation|rejected|confirmed), title,
    description, root_cause (or claimed_root_cause), trace[], evidence[], blockers[],
    validation_plan, remediation, severity, reason, first_seen_run, last_seen_run,
    run_state (new|still_open|regressed|not_refound|fixed)`;
  - owner-owned: `status (open|in_progress|fixed|accepted|false_positive), note`.

`import-rules.md` (deterministic, with worked examples): create a new fingerprint with
`set` and `status: open`; change an existing doc only with `update` naming run-owned
fields; `run_state` = `regressed` when the owner's status is `fixed` and the fingerprint
is back, `still_open` when it is open/in_progress, `not_refound` for an open finding the
run's coverage ledger marks its unit `covered` without re-finding it, and `fixed` only
when additionally its source changed since it was last seen; findings in units the run
did not cover are left untouched. Rows from `baseline-import.json` carry `legacy_id` and
no fingerprint; the engine's verifier sees them through the context, and a new finding
the engine links to one is shown with a **Matches an old audit item — check** badge until
the owner merges or splits it on the page (owner writes only).

Page (sketch):

```
┌ Security audit ───────────────────────── run 2026-11-20 · Range v0.28.3..v0.28.4 ▾ ┐
│  Needs validation 7  Rejected 12  Regressed 1   Coverage: partial (Range) · last Full: — │
│  [Severity ▾] [Status: open ▾] [Verdict ▾] [New only ☐]  search…                  │
├───────────────────────────────────────────────────────────────────────────────────┤
│ ● HIGH  NEW  needs_validation   <title>                                           │
│ ● MED   REGRESSED  needs_validation   <title>                                     │
├ Finding ──────────────────────────────────────────────────────────────────────────┤
│ Trace: entrypoint file:line → propagation … → sink file:line                      │
│ Root cause · Evidence · Blockers · Validation plan · Remediation                  │
│ Status [open ▾]   Note [_________________________]                                │
├ Rejected (12) ▸   Coverage ▸   Runs ▸                                             ┘
```
States: loading (10 s → "Could not load the audit data"), empty, non-owner read-only.
The full engine reports stay in the engine run dir; the page links to nothing local.

## 8. Left to the builder

- Exact text of `watchtower-context.md` and `surfaces.md`, drawn from the feature notes
  and inventory files.
- How the wrapper hands context and policy to the engine's parent without editing the
  engine (prepended instructions in the wrapper skill), as long as every delegated prompt
  receives them.
- Page design within the sketch (`artifact-design`).

## 9. Decisions

| Decision | Source |
|---|---|
| Periodic audit; report is a private Artifact outside git | Owner, chat + ask #776 |
| No per-PR gate; a run asks Full or Range between tags | Owner, ask #779 |
| Nothing executed during a run; owner demonstrates at triage | Owner, chat 2026-11-20 |
| No product code; the team is prompts, skills and a page | Owner, chat 2026-11-20 |
| Use Cloudflare's security-audit-skill as the engine, Watchtower layer around it | Owner, chat 2026-11-20 |
| Agents on Mythos via `CLAUDE_CODE_SUBAGENT_MODEL`, main thread on another model | Owner question, chat 2026-11-20 |
| Engine vendored and pinned to a commit; updates are reviewed PRs | Builder |
| Full = `deep` profile, Range = scoped `standard` | Builder |
| Both engine roles → one read-only `sec-audit-agent` | Builder (follows from read-only) |
| Owner's accepted/false_positive handed to the engine like prior `rejected` records | Builder |
| First run imports the two old audits as legacy rows | Builder |
| Nothing to the board; run from a non-workbench session | Builder |
