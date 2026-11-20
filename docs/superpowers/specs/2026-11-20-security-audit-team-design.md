# Security audit team — design

**Date:** 2026-11-20 · **Board:** #1115 · **Branch:** `feature/security-audit-team`

## 1. Intent

The owner wants a standing security team of Claude Code agents that can be pointed at
`main` by the strongest available model (Mythos when the session runs on it). The owner
starts a run; the skill asks which kind (ask #779):

- **Full**: a whole-codebase sweep of `origin/main`.
- **Range**: the code changed between two tags (default: the last audited tag → the
  newest tag), plus whatever that changed code now reaches.

Both write to one private claude.ai Artifact **outside git** that the owner works
through: every finding gets a status and a note, and the next run reads those statuses
back. There is no per-PR gate (the owner declined it in ask #779): `local-review` and
`debate-review` stay as they are.

Why outside git: the repository is public. An open, unfixed vulnerability written into a
spec, a PR body, a commit or a board comment is a disclosure. The team's *tooling* (agent
prompts, skill, surface map) is ordinary repo content; its *findings* never are.

## 2. Goals, non-goals, anti-goals

Goals
- Depth over breadth: each finding is an exploit chain (attacker input → path → sink →
  consequence) a reviewer can check, not "this looks risky".
- Few false positives: an independent verifier tries to refute every finding before the
  owner sees it.
- Memory between audits: accepted risks and false positives are not re-reported; a
  previously fixed issue that comes back is flagged as a regression.
- Coverage is visible: the report names the code no specialist looked at.

Non-goals
- No automatic fixes. A run produces a report; fixes are separate work
  the owner starts.
- No scheduled/unattended runs in v1 (Mythos availability and cost make this the owner's
  button). A `/schedule` routine can come later.
- No dynamic testing against live services, the owner's real accounts or real data.

Anti-goals (a failure even if it "works")
- A finding text, PoC or fix hint lands in git, a PR body/comment, a commit message, the
  Watchtower board or any synced surface (phone slices).
- The report is a wall of plausible-sounding "might be" items the owner has to refute
  by hand.
- An agent runs an exploit or a write against anything outside a throwaway sandbox.

## 3. Constraints

- Agents live in `.claude/agents/*.md`. Their frontmatter `model` only accepts
  sonnet/opus/haiku/fable, so **security agents omit `model`** and inherit the session's
  model: run the session on Mythos and the whole team runs on Mythos. The skill never
  passes `model` to the Agent tool. (Owner rule: subagents are never below Opus — a
  session started for an audit must itself be Opus or stronger; the skill checks nothing
  here, it states it in its first line.)
- Read-only is enforced by the tool list, not only by the prompt: the eight specialists
  and `sec-coverage` get `tools: Read, Grep, Glob` — no Bash, so injection text inside
  the audited code cannot make them run anything. Only `sec-verifier` has Bash, and its
  limit is enforced by a hook, not by its prompt: the agent's frontmatter declares a
  `PreToolUse` hook on Bash (`.claude/skills/security-audit/verifier-bash-guard.sh`)
  that denies every command except an allow-list — `git -C <scratch> <read verb>`,
  `git worktree add|remove` under the audit scratch root, and
  `.claude/skills/security-audit/sandboxed-go-test.sh <scratch copy> <pkg> <name>` —
  and denies any command containing `;`, `&&`, `||`, `|`, `$(`, backticks, redirection
  or a path outside the scratch root. The same hook covers `Write`/`Edit`: the verifier
  may only create or change `*_test.go` files inside its scratch copy. A denied call is
  reported in the verifier's output.
- The test the verifier writes is itself steered by untrusted code, so it runs in an OS
  sandbox, not on trust: `sandboxed-go-test.sh` runs `go test -run <name>` under
  `sandbox-exec` with a profile that denies all network, denies writes outside the
  scratch copy, the Go build cache and a per-run temp dir, and denies reads of the
  owner's secrets and data (`~/.config/watchtower`, `~/Library/Application
  Support/Watchtower`, `~/.claude`, `~/.ssh`, the keychains). Child processes inherit the
  sandbox. If `sandbox-exec` is missing or the profile fails to load, the script refuses
  to run the test (the finding stays `plausible`). The hook and the sandbox profile have
  their own tests: allowed and denied command samples including injection-shaped ones,
  and a test that tries network, an outside write and a secret read under the sandbox
  and expects all three to fail.
- Runs need the Agent tool and the `Artifact`/`ArtifactData` tools, so they start from a
  top-level Claude Code session with claude.ai artifacts available, not from a subagent.
- Run from a plain terminal session, not a Watchtower workbench session: a workbench
  session's transcript is shown in Workchat and can be sent to the phone on request
  (`session_chat`). The skill's first line says so. The local Claude Code transcript
  under `~/.claude/projects` still holds the agents' reports — an accepted residual on
  the owner's own machine.
- Existing baselines to respect on the first run: `docs/security-audit-2026-07-31.md`
  §8 (accepted risks) and `docs/review/2026-07-05-audit-security.md`. They are imported
  as the initial "accepted / fixed" set, so the first audit does not re-report them.
- `docs/inventory/` contracts are load-bearing. A finding whose fix would weaken a
  contract or a guard test is marked **needs owner decision**, never "just fix it".
- The existing review stack (`local-review`, `debate-review`, `release-audit`) is not
  changed.

## 4. Approaches

| | Approach | Trade-off |
|---|---|---|
| **A (picked)** | Specialists per attack surface + a refuting verifier + a coverage agent; Artifact with a triage database | Deepest on Watchtower's real risk (cross-module chains such as Slack text → LLM → tool write); most expensive run; the surface map needs upkeep |
| B | Slice the code by module, one generic security checklist per slice | Even coverage, but misses chains that cross modules — exactly the dominant risk here |
| C | Grow `release-audit`'s security lens | Cheap, but delta-only: code older than the range is never audited |

The owner picked A (2026-11-20). The coverage agent covers A's weak spot (code that
belongs to no surface) without paying for B.

## 5. Components (all in the repo)

```
.claude/
  agents/
    sec-llm-injection.md     sec-local-endpoints.md   sec-auth-secrets.md
    sec-crypto-sync.md       sec-exec-sandbox.md      sec-network-ssrf.md
    sec-data-lifecycle.md    sec-supply-chain.md
    sec-verifier.md          sec-coverage.md
  skills/
    security-audit/
      SKILL.md               # orchestrator: asks full | range, then runs
      finding-format.md      # the one finding schema every agent emits
      report-page.html       # the Artifact page template (no data in it)
docs/security/
  surfaces.md                # surface → paths/packages → agent; entry points and sinks
```

### 5.1 Surfaces (one agent each)

Each agent file carries: the surface's threat model (who the attacker is, what they
control), the entry points and sinks with real paths, the Watchtower invariants that
already defend it (with their inventory ids), the known-accepted risks to skip, and the
finding format. The table is the seed; `docs/security/surfaces.md` holds the paths.

| Agent | Attacker controls | Looks for (examples) | Anchors |
|---|---|---|---|
| `sec-llm-injection` | Text in Slack, mail, Confluence, Jira/Linear, web pages, image text, transcripts | Untrusted content reaching a tool call, a write (`Registry.Propose`/`Approve`, `send_slack_message`, `edit_confluence_page`), automation `agent()`/`mcp()`, memory, the system prompt; trust-order bypass; fence breaks | AGENT-*, AUTO-*, READ-01..02, CHAT-02/03/05 |
| `sec-local-endpoints` | Another local user/process, a web page in the browser, a crafted link | `LocalPreviewServer`, session host sockets, `chat.sock`, MCP stdio servers, OAuth loopback ports, URL schemes (`watchtower-nav://`, `wtpreview:`), WebViews (`SandboxedHTMLView`, Monaco), `NSWorkspace` opens | CHAT-05, html-artifacts threat model |
| `sec-auth-secrets` | A log reader, a co-resident process, a malicious OAuth redirect | OAuth state/PKCE, code exchange order, token files 0600, secrets in argv/env/logs/temp files, client secrets, refresh races, auth state silently downgraded to ok | FILES-01, OWNER-01, §8 accepted list |
| `sec-crypto-sync` | The network, the relay, iCloud, a stolen phone | SQLCipher key handling, mobile E2E envelopes/keybox/pairing code, relay client, Go hub, live link, signature checks, nonce reuse, downgrade, replay | mobile POC invariants, relay-client contracts |
| `sec-exec-sandbox` | Recipe author, repo content in a workbench folder, branch/file names | goja sandbox escapes and limits, `shell()`/`session()`, child process env scrubbing, argv injection (leading `-`), PTY/session host, git commands on untrusted repos, path traversal in worktree/cleanup/preview | AUTO-*, PROJ-*, POLICY-* |
| `sec-network-ssrf` | URLs in messages and pages | `webfetch`/`linkrule` gates, redirects, DNS rebinding, ports, connect-time checks, TLS config, response size/time caps | EXT-03/04, KB-* |
| `sec-data-lifecycle` | A revoked account, a former colleague, MDM policy | Purge/deletion completeness, private meetings leaking into prompts, cross-account scoping, bulk-read caps, policy bypass, Limited Use exposure | PURGE-*, SRCDEL-*, MEETPRIV-*, POLICY-*, READ-* |
| `sec-supply-chain` | A dependency, a CI action, a download mirror | CI workflows (pinning, `pull_request_target`, secrets), install/build scripts, dependency pins, model downloads, signing/entitlements/hardened runtime, the leak check itself | — |

New features land in a surface by editing `surfaces.md`; an agent reads its surface's
paths from there at run time, so a path change does not mean editing ten agent files.

### 5.2 Finding format (`finding-format.md`)

Every specialist emits a JSON list; each finding:

```
fingerprint   "<surface>:<class>:<file>:<symbol>"   — stable across line drift
surface, class (e.g. ssrf, prompt-to-write, argv-injection, path-traversal, secret-leak)
title         one line
severity      critical | high | medium | low   (agent's claim; verifier recalibrates)
attacker      who, with what access
chain         ordered steps, each with file:line and a quote of the code
preconditions what must be true (settings, account type, policy)
impact        what the attacker gets
poc           how to show it (a test sketch or an input), never run against live services
fix           the smallest fix that holds; "needs owner decision" when it touches a contract
confidence    confirmed-by-reading | plausible
inventory     contract ids touched, if any
```

A finding without a chain whose every step quotes code is dropped by the skill before
verification.

## 6. A run (`/security-audit`)

### 6.1 Flow

0. **Preflight.** The session has the Agent, `Artifact` and `ArtifactData` tools
   (loaded through ToolSearch if deferred); if any is missing the run stops with that
   message before anything else — it never falls through to the first-run branch. Then
   **find the report Artifact**: the URL in
   `~/.config/watchtower/security-audit/config.json`; if the file is missing, the skill
   lists the owner's artifacts (`Artifact list`) for ones titled "Security audit". One
   found → it asks the owner to confirm it and rewrites the config. Several found → it
   lists them with each one's last run (sha, date, finding count from its `runs`
   collection) and the owner picks one; it never picks by itself. None found → it asks
   the owner "no previous audit found — start a new report?" and only a yes takes the
   first-run branch. A config URL that no longer opens stops the run (failure table).
   **Ask the kind.** One `AskUserQuestion`: **Full** (whole `origin/main`) or **Range**
   (between tags). For Range the skill proposes the last audited tag → the newest tag
   (`git tag --sort=creatordate`); with no audited tag yet, the tag before the newest →
   the newest. The owner can name another pair. The question also shows when the last
   Full ran, because Range never revisits untouched code. `/security-audit full` and
   `/security-audit range <from>..<to>` skip the question.
1. **Pin the commit.** `git fetch origin main`; record the SHA. Create a detached,
   read-only worktree at that SHA under the scratchpad (`git worktree add --detach`),
   so the audit never touches the owner's checkouts and every agent reads the same tree.
2. **Load the baseline.** Read the triage database of the audit Artifact (§7) with
   `ArtifactData list`: every finding's fingerprint and status. On the very first run
   there is no Artifact: import §8 of `docs/security-audit-2026-07-31.md` and the
   2026-07-05 audit as baseline rows. These rows have no agent fingerprint; they carry
   the old id (`D-1`, `S-3`…), the text and the paths, with status `fixed`, `accepted`
   or — for a leftover the old audit left open — `open`. A mixed item is split into one
   row per part. (Builder's call, see §10.)
3. **Changed-since list.** `git diff --name-only <last audited SHA>..<SHA>`; the last SHA
   comes from the previous run row. Agents audit their whole surface but start with these
   files. On the first run there is no previous SHA: the list is empty and agents audit
   the whole surface with no starting order.
4. **Fan out** the eight specialists and `sec-coverage` in one parallel batch. Each gets:
   the worktree path, its slice of `surfaces.md`, the changed-since list for its paths,
   and the baseline rows for its surface (fingerprint + status + the owner's note), with
   the rule: skip `accepted` and `false_positive`; re-check every `fixed` one and report
   it as a regression if it is back.
5. **Verify.** The skill drops malformed findings, dedupes by fingerprint (keeps the
   highest severity, records every surface that found it), then hands them to
   `sec-verifier` in batches of ≤ 10 (several verifiers in parallel). Verdicts:
   `confirmed`, `plausible` (could not refute, could not prove), `refuted` (with the
   reason). Refuted findings go to the report's collapsed "Refuted" list, not away — the
   owner can overturn a refutation.
6. **Match against the baseline.** An exact fingerprint match is a match. A finding
   without one goes to the verifier together with the baseline rows of its surface, and
   the verifier says whether it is the same issue as one of them (same weakness, the code
   moved or was renamed, or an imported text-only row). A model-confirmed match takes
   over the old row's status and note and the row gets the new fingerprint as an alias,
   so a refactor does not turn an accepted risk into "fixed + new". Because a wrong match
   would hide a real issue under an old `accepted`/`false_positive`, such a row gets
   `match: model` and the report shows it at the top with a **Matched by model — check**
   badge and the old and new text side by side; the owner presses **Same issue** (badge
   goes) or **Different issue** (the alias is dropped, the finding becomes a new row with
   status `open`). Until the owner confirms, the finding counts in the severity totals as
   if open. (Builder's call, see §10.)
   Then **classify:** `new`, `still open` (fingerprint open in the
   baseline), `regressed` (was `fixed`), `fixed` (was open, not found again, and its file
   changed since; if the file did not change, it stays `still open` and is flagged
   "not re-found" — a missed finding is not a fix).
7. **Publish** (§7) and print a short terminal summary: counts per severity and per
   class, the Artifact link, coverage gaps. Nothing is written to the board (it syncs to
   the phone): no titles, no paths, no counts. (Builder's call, see §10.)
8. **Clean up** the audit worktree.

### 6.2 `sec-coverage`

Inputs: `git ls-files` of the worktree (Go, Swift, scripts, workflows), `surfaces.md`.
Output: the files and packages no surface claims, ranked by risk signals it can see
cheaply (`os/exec`, `net/http`, `net.Listen`, `sql` string building, `NSWorkspace`,
`WKWebView`, file writes under user-controlled paths, `unsafe`, cgo). It does not
audit; it reports gaps, and the report suggests which surface should claim them.

### 6.3 Severity

- **critical**: remote attacker (a message, a mail, a web page) gets code execution, a
  write in the owner's name without approval, or the owner's secrets.
- **high**: same impact but needs a local foothold or an unusual setting; or a
  cross-account data leak; or a policy/purge bypass.
- **medium**: information leak to the local machine (logs, temp files), DoS of the
  daemon, defence-in-depth gap on a path with another guard.
- **low**: hardening.
The verifier may change severity with a reason; any finding touching an inventory
contract is never below high (same rule as `release-audit`).

### 6.4 `sec-verifier`

Persona: tries to prove each finding wrong. For every step of the chain it re-reads the
code and checks for a guard the finder missed (a validator upstream, a policy check, a
sandbox, a type that cannot carry the value). It may write a throwaway Go test
**in its own scratch worktree** to demonstrate a finding (never in the audit worktree,
never committed, deleted at the end) and runs it only through `sandboxed-go-test.sh`
(§3: no network, no writes outside the copy, no reads of the owner's secrets) — no live
accounts, no `make` targets.
v1 runs Go tests only: a Swift test in a fresh worktree needs a cold `.build` (minutes,
~5 GB), so Swift findings are confirmed by reading or stay `plausible`. (Builder's call, see §10.)
A demonstrated finding is `confirmed` with the test's output quoted.

### 6.5 Failure paths

| What fails | What happens | Test (how the skill is checked) |
|---|---|---|
| A specialist returns nothing or garbage | Marked `failed` in the run row; its surface shows "not audited this run" in the report; the run still publishes | Dry run with one agent prompt forced to return invalid JSON |
| A specialist hangs | The skill does not poll; agents run in one foreground batch. If the session is interrupted, nothing is published and the worktree is removed by the next run's step 1 (it removes stale `security-audit-*` worktrees first) | Manual: interrupt mid-run, re-run, see the stale worktree gone |
| `Artifact`/`ArtifactData` tools missing in the session | Preflight (step 0) stops the run with "artifact tools are not available in this session"; nothing is created or imported | Run in a session without claude.ai artifacts |
| `config.json` lost (new machine, cleaned `~/.config`) | Preflight looks the report up with `Artifact list` and asks the owner to confirm it; a new report is created only on the owner's explicit yes — never silently | Delete the config, run, see the existing report found |
| `ArtifactData` read fails (offline, Artifact deleted) | The run stops before fan-out with that message — auditing without the baseline would re-report everything | Run with a wrong Artifact URL in the local config |
| Publish fails | The report and findings JSON are already saved under `~/.config/watchtower/security-audit/runs/<date>-<sha>/` (0600, outside git); the skill prints that path and how to re-publish | Run with publishing denied |
| Two runs at once | A lock file `~/.config/watchtower/security-audit/lock` (pid + start time); a second run refuses while the pid is alive | Start a second run during the first |
| The owner edits a status while a run publishes | Runs never overwrite owner fields (`status`, `note`); they write their own fields only (`last_seen_run`, verdict, chain). Race-free by field ownership | Covered by the db rule design in §7 |

## 7. The report Artifact

One private Artifact for all audits, its URL kept in
`~/.config/watchtower/security-audit/config.json` (outside the repo). Each run
republishes the page from `report-page.html` and writes data with `ArtifactData`;
the page holds no findings in its HTML — everything comes from its database, so
republishing never loses triage.

Capabilities: `db` (rules: read `view`, write `owner` on every path — the Artifact stays
private and only the owner writes) and `user` (to show the owner's controls only to the
owner).

Collections:
- `runs/<run-id>`: sha, started/finished, model note, per-surface status
  (`ok`/`failed`), counts, coverage gaps.
- `findings/<fingerprint-hash>`: the finding fields from §5.2 plus `verdict`,
  `verifier_note`, `first_seen_run`, `last_seen_run`, `run_state`
  (`new|still_open|regressed|fixed|not_refound`) — written by runs;
  `status` (`open|in_progress|fixed|accepted|false_positive`) and `note` — written by
  the owner from the page, never by a run (a new finding is created with `status: open`
  once); `match` (`exact|model|owner_confirmed`) and `aliases` (earlier fingerprints) —
  written by runs, except that **Same issue** / **Different issue** (§6.1 step 6) is the
  owner's.

Page (sketch):

```
┌ Security audit ─────────────────────────────── run 2026-11-20 · 3e63da8 ▾ ┐
│  Critical 1   High 4   Medium 9   Low 6     Regressed 1   Not audited: —   │
│  Kind: Range v0.41.0..v0.42.0 · last Full: 2026-11-20                      │
│  [Surface ▾] [Severity ▾] [Status: open ▾] [New only ☐]   search…          │
├ Matched by model — check (1) ──────────────────────────────────────────────┤
│ ◆ was: S-1 "client secrets extractable"   now: auth-secrets:secret-leak …  │
│   [Same issue]  [Different issue]                                          │
├────────────────────────────────────────────────────────────────────────────┤
│ ● CRIT  NEW  llm-injection · prompt-to-write                               │
│   Slack text reaches send_slack_message without approval via …             │
│ ● HIGH  REGRESSED  local-endpoints · auth-bypass                           │
│   Preview server accepts …                                                 │
│ …                                                                          │
├ Finding ───────────────────────────────────────────────────────────────────┤
│ Chain  1 internal/…:120  "…"   2 internal/…:88  "…"   3 …                  │
│ Impact · Preconditions · PoC · Fix · Verifier: confirmed (test output)     │
│ Status [open ▾]   Note [______________________________]                    │
├ Coverage gaps (3) ▸   Refuted (7) ▸   Runs history ▸                       ┘
```

States: loading (10 s timer, then "could not load the audit data" with the reason),
empty (no runs yet), a viewer who is not the owner (read-only, controls hidden).
The page is a claude.ai Artifact, not a Desktop screen, so the Desktop style guide does
not apply; the sketch above is its mockup and the first publish in the plan's last task
is shown to the owner before the plan is closed.

## 8. How Range differs from Full

The flow in §6.1 is the same; these steps change:

- **Pin**: the worktree is at the `to` tag, not `origin/main`.
- **Which specialists**: changed paths (`git diff --name-only <from>..<to>`) are mapped
  to surfaces through `surfaces.md`; only matched specialists run. `sec-llm-injection`
  also runs when prompts, tool registries or automation code changed;
  `sec-supply-chain` when workflows, scripts or dependency files changed. `sec-coverage`
  runs over the changed files only.
- **What they read**: the range diff and the merged PR list, told to audit the changed
  code and what it now reaches (a new caller of an old sink counts), not the whole
  surface. Range is therefore shallower than Full by design: an old hole in code the
  range did not touch is found only by a Full run. It complements Full, it does not
  replace it; the kind question and the report header show when Full last ran.
- **Classification**: a surface that did not run this time keeps its findings as they
  were — nothing is marked `fixed` or `not_refound` there. Its strip in the report says
  "not in this run's scope", not "failed".
- **Run row** records the kind and the range; "last audited tag" for the next Range
  proposal is the `to` tag of the newest Range run, or the newest tag at or before the
  newest Full run's SHA.

## 9. Left to the builder

- Exact wording of each agent's threat model, drawn from the feature notes listed in
  `surfaces.md` — the agent files are the main work and should be written per surface by
  someone who reads that surface's notes and inventory files.
- Batch sizes and how many verifiers run in parallel.
- The fingerprint hash function (any stable hash of the fingerprint string).
- The page's visual design within the sketch, following `artifact-design`.

## 10. Decisions

| Decision | Source |
|---|---|
| Approach A: surface specialists + verifier + coverage | Owner, chat 2026-11-20 |
| Periodic audit; report is a private Artifact outside git | Owner, chat + ask #776 |
| No per-PR gate; a run asks Full or Range between tags | Owner, ask #779 |
| Agents omit `model` and inherit the session's (Mythos) | Builder (platform constraint) |
| First run imports the two old audits as text-only baseline rows; mixed items split; old leftovers `open` | Builder |
| Baseline match after a refactor is proposed by the verifier, marked `match: model`, confirmed by the owner on the page | Builder (owner confirms each match) |
| Range audits changed code and what it reaches, not whole surfaces | Builder (follows from ask #779) |
| Verifier runs Go tests only in v1; Swift findings confirmed by reading | Builder |
| Nothing written to the board; run from a non-workbench session | Builder |
| Specialists have no Bash; the verifier's Bash/Write/Edit are limited by a PreToolUse allow-list hook and its tests run under `sandbox-exec` (no network, no outside writes, no secret reads) | Builder |

None open. Any Builder row the owner rejects in review changes only its own section.
