---
name: security-audit
description: Use when the owner wants a security audit of Watchtower — "security audit", "аудит безопасности", Full or Range between tags. Runs the vendored Cloudflare security-audit engine read-only over origin/main or a tag diff and imports findings into the private triage Artifact; nothing goes into git.
---

# Security audit

The Watchtower layer around Cloudflare's security-audit engine, vendored and pinned in
`engine/`. This skill does the preflight, asks Full or Range, pins a detached target
worktree, hands the engine Watchtower's context plus the owner's triage, runs the engine
read-only with one read-only agent for every delegated role, and imports the result into
one private claude.ai triage Artifact that the next run reads back.

Design: `docs/superpowers/specs/2026-11-20-security-audit-team-design.md`. Components this
skill uses (read them where a step says so, never copy them here):

| File | What it is |
|---|---|
| `engine/` | the vendored engine (`engine/SKILL.md` and its phase files); never edited |
| `watchtower-context.md` | run policy, principals, surfaces, inventory, accepted risks — handed to the engine |
| `import-rules.md` | `findings.json` → triage Artifact writes, rules 1–8 |
| `baseline-import.json` | legacy rows from the two earlier audits, for a new report |
| `report-page.html` | the triage Artifact page (published once, holds no data) |
| `.claude/agents/sec-audit-agent.md` | the read-only agent for both engine roles |
| `docs/security/surfaces.md` | surfaces and their `Paths:` pathspecs (Range mapping) |

## Never

- No finding text, fingerprint, title, PoC, fix hint or count from a run goes into git, a
  PR, a commit message, the Watchtower board, an ask, a target comment or any synced
  surface. Results live in the engine run dir and the private Artifact only.
- Nothing from the target is executed — not by the agents, not by this session. The
  session runs only: read-only `git` (`fetch`, `rev-parse`, `diff`, `log`, `tag`,
  `describe`, `ls-files`, `worktree add/remove/prune`), `shasum`, the engine's two node
  validators on run files, `tmutil`, and file operations under the directories below.
- Nothing is written into the target worktree or the repository.
- The Agent tool is never given a `model`.

## Paths

| Name | Path |
|---|---|
| `SKILL_DIR` | `$(git rev-parse --show-toplevel)/.claude/skills/security-audit` of the session's Watchtower checkout |
| `ENGINE` | `$SKILL_DIR/engine` |
| `REPO` | the Watchtower checkout (`git rev-parse --show-toplevel`); with `--target`, that repo |
| `OUT` | `~/security-audit-skill/` |
| run root | `$OUT/watchtower/` (real runs) or `$OUT/watchtower-test/` (`--test`) |
| run dir | `<run root>/run-<N>/` |
| aborted | `$OUT/watchtower-aborted/` |
| archive | `$OUT/watchtower-archive/` |
| `STATE` | `~/.config/watchtower/security-audit/` (`config.json` = `{"report_url":"…"}`, `lock`) |
| `CACHE` | `~/Library/Caches/watchtower-security-audit/` (target at `$CACHE/<run-id>/target`) |

Each Bash call is a fresh shell: every command that creates or writes anything under
`OUT`, `STATE` or `CACHE` starts with `umask 077;`. Directories are created 0700 and
files land 0600. The Write tool does not follow the shell umask, but its files land
inside 0700 directories, and the modes are re-applied at Cleanup.

## Start

1. **Say which model the agents use.** Read `printenv CLAUDE_CODE_SUBAGENT_MODEL`. Set →
   "Agents run on `<that value>`." Unset → "Agents run on the session's model
   (`<the model this session runs on>`)." The agents' model must be Opus or stronger:
   a Sonnet- or Haiku-class model → stop and tell the owner to start the session as
   `CLAUDE_CODE_SUBAGENT_MODEL=<model id> claude --model <main model>`. Unsure which
   class a value is → ask before continuing. Never write a model id into the repo.
2. **Plain terminal session only.** Say: "Run this from a plain Claude Code terminal
   session — not a Watchtower workbench session (its transcript reaches Workchat and the
   phone)." If the session has `mcp__watchtower-workbench__*` tools (connected or
   deferred), it is a workbench session — including a headless `claude -p` started
   from a workbench session's shell that inherited those tools; the rule below is the
   same there. In a workbench session only three invocations continue, with this
   warning: `--plan-only` (it produces no findings); `--test` together with `--target`
   (findings about an invented fixture repo, never Watchtower); and
   `import <run-dir> --test --report <url>` when `realpath <run-dir>` lies under
   `realpath ~/security-audit-skill/watchtower-test/` **and** the run was a `--target`
   run: its `run-metadata.json` has `watchtower_source_repo`, and
   `realpath "$(git -C <that repo> rev-parse --git-common-dir)"` differs from the same for
   the session's Watchtower checkout (a missing field, an unreadable repo or the same
   repository → stop; a `--test` run without `--target` holds real findings). Everything
   else stops here: a real `full`/`range`, `--test` without `--target` (it would audit
   real Watchtower), and every other `import`.
3. Speak the session's language to the owner; everything written to files stays English.

## Subcommands

| Invocation | Does |
|---|---|
| `/security-audit` | full flow; asks Full or Range |
| `/security-audit full` | Full over `origin/main`, no question |
| `/security-audit range <from>..<to>` | Range over the two tags, no question |
| `/security-audit import <engine-run-dir>` | import only (Preflight, then Import, Summary, Cleanup); for a run whose import failed or was denied |
| `--test --report <url>` | test mode: the fixture Artifact at `<url>`, run root `watchtower-test/`, `config.json` never read or written, the report page never published. `--test` without `--report` → refuse |
| `--target <repo path>` | audit that git repo instead of Watchtower (no fetch, its local tags and `HEAD`). Refused without `--test` |
| `--plan-only` | Preflight, the kind question, Pin and the Range mapping; print the plan and the estimate; then Cleanup. Stops before the engine — no run dir, no findings, no Artifact write |
| `--budget <n>` | the engine's `budget`: a strict maximum of agent invocations (positive integer) |

Flags combine with `full`, `range` and `import`
(`/security-audit import <run-dir> --test --report <url>`). For `import`, the run dir must
sit directly under the run root of the mode (`watchtower/`, or `watchtower-test/` with
`--test`); anything else → refuse.

When `AskUserQuestion` is not available (it is blocked in some sessions; load it with
ToolSearch `select:AskUserQuestion` if deferred) and the invocation leaves a question
open (the kind, a report to confirm), stop and tell the owner which argument to pass.

## Preflight

Spec §6.1 step 0 and §3. Run every check in this order; the first failure stops the
run with its reason, and nothing is created before the lock step.

1. **Agent tool.** The Agent tool is in this session's tools. Missing → stop: "run
   /security-audit from a top-level session". (`import` does not need it — skip.)
2. **Artifact tools.** ToolSearch `select:Artifact,ArtifactData`. Either missing → stop:
   "the claude.ai artifact tools are not available in this session".
3. **Node.** `command -v node`; else the newest
   `ls -d ~/.nvm/versions/node/v*/bin/node | sort -V | tail -1`. None → stop. Keep the
   absolute path as `NODE`; every validator call uses `"$NODE"`.
4. **Engine integrity** (the check from the plan's Task 1, verbatim; both sides sorted in
   the C locale):

   ```bash
   cd "$SKILL_DIR" && cd engine && sed -n '/^files:$/,$p' VERSION | tail -n +2 | shasum -a 256 -c --quiet
   ```
   must exit 0, and

   ```bash
   cd "$SKILL_DIR/engine" && LC_ALL=C comm -13 <(sed -n '/^files:$/,$p' VERSION | tail -n +2 | sed 's/^[0-9a-f]*  //' | LC_ALL=C sort) <(find . -type f ! -name VERSION | sed 's|^\./||' | LC_ALL=C sort)
   ```
   must print nothing. A failed checksum, a missing file or any unlisted file (a
   `.DS_Store` too) → stop naming the file(s). Never warn and continue.
5. **Report lookup.**
   - `--test`: the report is `--report <url>`; `config.json` is not touched.
   - Otherwise read `$STATE/config.json`. Present → its `report_url`.
   - Absent → `Artifact` `action: "list"` (`scope: "mine"`, `limit: 200`, follow
     `page_token`) and keep the artifacts whose title is exactly `Security audit`:
     - exactly one → ask the owner to confirm it is the audit report; on yes write
       `config.json` (`umask 077`); on no, treat as none;
     - several → for each, `ArtifactData list runs` and show its newest run row
       (`started_at` date, `kind`); the owner picks one; write `config.json`;
     - none → ask "No previous audit report found — start a new report?"; only an
       explicit yes continues, with no URL yet (Import publishes the page); anything
       else stops. `--plan-only` never creates one.
   - A URL in hand must open: `Artifact` `action: "read"` succeeds and says the owner is
     a writer, and `ArtifactData list runs` succeeds. Otherwise → stop before the engine
     (without the owner's triage the engine would re-report accepted risks). Never fall
     back to a new report when a configured URL fails.
6. **Lock** `$STATE/lock`, content `<pid> <RFC3339 start>`, where `<pid>` is this
   session's Claude Code process (`$PPID` of the Bash tool's shell; confirm with
   `ps -p "$PPID" -o comm=` that it is the claude process, else walk up with
   `ps -o ppid= -p …`).
   - No lock → create it atomically: `umask 077; mkdir -p "$STATE" && chmod 700 "$STATE"
     && (set -o noclobber; printf '%s %s\n' "$pid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE/lock")`.
   - Lock held by another live process (`kill -0 <pid>` succeeds and `ps -p <pid> -o comm=`
     is a claude process) → refuse: "another security audit is running (pid …, since …)".
   - Lock held by a dead pid, by a pid now running something else, or by this same
     session (an interrupted earlier run) → replace it and say so: "Replaced a stale lock
     left by pid … (started …)."
   From here on, every stop runs Cleanup.
7. **Directories.** `umask 077; mkdir -p ~/security-audit-skill/{watchtower,watchtower-test,watchtower-aborted,watchtower-archive} "$CACHE"`
   then `chmod 700` each of them, `$OUT` and `$CACHE`. Time Machine: if
   `tmutil isexcluded ~/security-audit-skill` does not say `[Excluded]`, run
   `tmutil addexclusion ~/security-audit-skill` (an "already excluded" answer is fine;
   any other failure → tell the owner and continue).
8. **Aborted runs.** For every `run-*` dir under `watchtower/` and `watchtower-test/`: it
   is valid only if `findings.json` and `coverage-ledger.json` exist, `"$NODE"
   "$ENGINE/validate-findings.cjs" <dir>/findings.json` and `"$NODE"
   "$ENGINE/validate-coverage-ledger.cjs" <dir>/coverage-ledger.json` both exit 0, and
   `run-metadata.json` has `run_status` `complete` or `incomplete`. Anything else is moved
   to `watchtower-aborted/<root>-run-<N>-<UTC timestamp>` (`<root>` = `watchtower` or
   `watchtower-test`) and named to the owner. A validated `incomplete` run stays: it is
   engine history.
9. **Retention.**
   - In `watchtower/`, the newest Full is the highest `<N>` whose `run-metadata.json` has
     `watchtower_kind: "full"`. Every run dir with a lower `<N>` is archived: create
     `watchtower-archive/run-<N>/`, copy into it whichever of `REPORT.md`,
     `FINDINGS-DETAIL.md`, `NEEDS-VALIDATION.md`, `findings.json`, `run-metadata.json`
     exist, then delete the run dir. No Full yet → nothing is archived.
   - Delete `watchtower-archive/` entries whose run started more than 180 days ago
     (`watchtower_started_at` in their `run-metadata.json`; the dir's mtime when absent).
   - Delete `watchtower-aborted/` and `watchtower-test/` entries whose mtime is more than
     7 days old (`find … -mindepth 1 -maxdepth 1 -mtime +7`).
   The engine never reads `watchtower-aborted/`, `watchtower-archive/` or (for a real run)
   `watchtower-test/`.

## Kind question

First refresh the refs: `git -C "$REPO" fetch origin main --tags` (Watchtower; with
`--target`, no fetch — its local tags and `HEAD` only). Then, unless the invocation is
`full`, `range <from>..<to>` or `import` (`import` skips this section and Pin), one
`AskUserQuestion` with the options **Full** and **Range**, showing:

- **Last audited tag → newest tag** (the proposed Range). Newest tag:
  `git -C "$REPO" describe --tags --abbrev=0 origin/main` (`HEAD` for `--target`). Last
  audited tag, from the report's newest run row by `started_at`: a Range row → its `to`;
  a Full row → `git -C "$REPO" describe --tags --abbrev=0 <its sha>`. No run rows (or a
  new report) → the tag before the newest (`describe --tags --abbrev=0 <newest>^`). When
  the last audited tag already is the newest tag, say there is nothing new since the
  last audit and propose Full.
- **Last Full**: `started_at` date of the newest `kind: "full"` row, else "never".
- **Surfaces the Range touches** (the Range mapping below), each with its changed-file
  count.
- **The estimate** (below) for each option.
- **Budget**: the owner may set one (`--budget` already given → show it).

Full = profile `deep` over the whole target. Range = a scoped `standard` run over
`git diff <from>..<to>`.

### Range checks and mapping

- Each tag must match `^[A-Za-z0-9._/+-]+$` and resolve with
  `git -C "$REPO" rev-parse --verify --quiet "refs/tags/<tag>^{commit}"`; `<from>` must
  be an ancestor of `<to>` (`git merge-base --is-ancestor`). Otherwise stop and ask for a
  valid pair. An empty `git diff --name-only <from>..<to>` → stop: nothing changed.
- **Mapping** (Watchtower only; with `--target` say "no surfaces map for this repo"):
  read `docs/security/surfaces.md` from the session's checkout. For each `## <surface>`
  section, its pathspecs are the lines of the fenced block after `Paths:`. Pass them
  unchanged, each quoted, to git — they are git pathspecs (`*` crosses `/`), never
  shell globs or fnmatch:

  ```bash
  git -C "$REPO" diff --name-only <from>..<to> -- '<pathspec 1>' '<pathspec 2>' …
  ```
  A surface is touched when that prints at least one file. Files no surface matches are
  listed as "outside the mapped surfaces" — they are still in scope.

### Estimate

A pre-reconnaissance estimate in the terms of the engine's "Cost budget" section
(`engine/SKILL.md`): 4 reconnaissance agents; hunters ≈ one per expected coverage unit
(Full: every surface in `surfaces.md` × its applicable attack classes, split per
subsystem; Range: the touched surfaces only); critics — one post-wave critic per wave plus
one final-clean critic; verifiers — 2 per expected candidate for `deep`, 1 for
`standard` (when unsure, the engine's 30% reserve). Give it as a range and say it is
refined by the engine after reconnaissance. With a budget, say whether it can fund the
engine's minimum (4 reconnaissance + the critic reserve + at least 1 verifier); one
that cannot makes the engine end `incomplete` with no audit pass.

## Pin

1. The refs were fetched at the start of the Kind question (`--target`: none).
2. The commit: Full → `git rev-parse origin/main` (`--target`: `HEAD`); Range → the
   `<to>` tag's commit. Keep it as `SHA`.
3. Run id: `run-<N>`, `<N>` = 1 + the highest `<N>` found under the mode's run root,
   under `watchtower-archive/` (real runs) and among `watchtower-aborted/<root>-run-<N>-*`
   (1 when none). The cache entry is `$CACHE/<root>-run-<N>/`.
4. Leftovers: for every entry under `$CACHE` (no other run is alive — the lock is
   held): `git -C "$REPO" worktree remove --force <entry>/target` when git still lists
   it, then `rm -rf <entry>`. Then `git -C "$REPO" worktree prune`.
5. `umask 077; mkdir -p "$CACHE/<root>-run-<N>"` and
   `git -C "$REPO" worktree add --detach "$CACHE/<root>-run-<N>/target" "$SHA"`. Record
   `started_at` (UTC, now).

`--plan-only` stops here: print the kind, profile, `SHA`, the Range pair and mapping (or
"Full"), the number of in-scope files, the budget, the prior runs the engine would read,
the number of disputed rejections, and the estimate; then run Cleanup. Nothing is
written to the Artifact and no run dir is created.

## Owner triage in

1. Read every `findings` doc (`ArtifactData list findings`, every page). A failed read →
   stop before the engine. A new report (no URL yet) or an empty `findings` collection
   → use `baseline-import.json` as the legacy rows and leave the other lists empty.
2. Build the lists:
   - **Suppress unless the code changed**: docs with a `fingerprint` and owner `status`
     `accepted` or `false_positive`.
   - **Re-check**: docs with a `fingerprint` and `status: "fixed"`.
   - **Disputed rejections**: docs with `verdict: "rejected"` and `status` `open` or
     `in_progress`.
   - **Legacy items**: `legacy-*` docs without `merged_into` (or the baseline rows).
3. Create the run dir `<run root>/run-<N>/` (`umask 077; mkdir`, then `chmod 700`) and
   write in it:
   - `watchtower-context.md` = the repository's `watchtower-context.md`, with its
     placeholder `## Owner triage` section replaced by the four lists. One line per doc:
     `fingerprint` (or `legacy_id`), owner `status`, `title`, the distinct `trace[].file`
     (legacy: `files`), the engine's `reason` for disputed ones, and the owner's `note`.
     Under the disputed list state: "The owner's list wins over the engine's history:
     re-validate each with a fresh verifier; never carry it as a prior `rejected` record,
     never suppress it."
   - `watchtower-disputed.json` = the disputed fingerprints with the owner's notes
     (import rule 6 reads this list back).
   The repository's `watchtower-context.md` is never modified.

## Run the engine

Read `$ENGINE/SKILL.md` and follow its **full audit mode** with every phase file it names
(`RECONNAISSANCE.md`, `HUNTING.md`, `ATTACK-CLASSES.md`, the selected companions,
`VALIDATION-AND-REPORTING.md`), this session as the parent. The Watchtower run policy in
`watchtower-context.md` overrides every place where the engine allows execution. Settings
and overrides:

- **Setup values.** Skill directory = `$ENGINE`. Target = `$CACHE/<root>-run-<N>/target`.
  Repo name = `watchtower`. Run id = `run-<N>` (`run_id` in `run-metadata.json`). Output directory = the run dir created above (already
  exists, empty but for the two wrapper files). Source ref = `SHA`, clean.
- **`run-metadata.json`** as the engine requires, with `execution_policy:
  "source-read-only"` (replacing the engine's default string), `profile` (`deep` | `standard`),
  `scope_paths` (Full: `[]` for the whole target; Range: `git diff --name-only
  --diff-filter=d <from>..<to>`, with the scope stated as the diff between the two refs),
  `budget` (`--budget`/the answer, else `null`), and the prior-run paths below. Wrapper
  bookkeeping fields: `watchtower_kind` (`full`|`range`), `watchtower_from`,
  `watchtower_to` (`null` for Full), `watchtower_started_at`, `watchtower_source_repo`
  (`REPO`), `watchtower_test` (bool).
- **Prior runs** are exactly the valid run dirs under the same run root other than this
  one — never `watchtower-aborted/`, `watchtower-archive/`, or (for a real run)
  `watchtower-test/`.
- **Range** is a scoped run: seed units only for in-scope surfaces, everything else
  `out_of_scope`; traces may follow into unchanged code that the changed code reaches.
  The report presents it as partial coverage.
- **Delegation.** Every engine delegation — `research` and `general` alike — is an Agent
  call with `subagent_type: "sec-audit-agent"`, `name` = the agent id, and no `model`.
  Agent ids carry a role prefix and match `^[a-z0-9][a-z0-9_-]{0,63}$`:
  `recon-<n>` (reconnaissance), `hunter-<wave>-<n>`, `critic-<wave>` /
  `critic-final`, `verifier-<n>` (candidate validation and record verification alike;
  every one fresh). Import rule 6 recognises a verifier check only by `verifier-`.
- **Every delegated prompt starts with the full text of the run dir's
  `watchtower-context.md`**, then a `---` line, then the engine's role prompt.
- **Nothing is executed.** No agent and not this session runs a build, test, script,
  process, fixture or package install from the target. Every check is a source check
  (`method: "source"`, `artifact: null`); a check that would need execution leaves the
  finding `needs_validation` with the blocker named. No promotion into `artifacts/`
  happens. The parent writes only under the run dir.
- **Owner triage.** `accepted`/`false_positive` fingerprints are handled like prior
  `rejected` records: the unchanged claim is suppressed, its unit is still covered, and
  a changed source behind it makes the claim live again. `fixed` fingerprints are
  re-checked, never suppressed. **Disputed rejections**: each is seeded as a current
  `planned` ledger unit linked to its fingerprint (the unit it sat in last, else one
  derived from its trace; `prior_status: "prior_rejected_claim_changed"`, bookkeeping
  field `watchtower_disputed: true`), is never carried as a prior `rejected` record —
  even when its source is unchanged and the engine's own history says rejected — and
  goes with the owner's note to a fresh `verifier-` agent, which becomes the unit's
  owner and moves it to `candidate`. It ends in `findings.json` with a fresh verdict.
- **Validators** run as `"$NODE" "$ENGINE/validate-findings.cjs" <run dir>/findings.json`
  and `"$NODE" "$ENGINE/validate-coverage-ledger.cjs" <run dir>/coverage-ledger.json`,
  whenever the engine says to.
- **Terminal states** are the engine's two. A run that ends `incomplete` before any
  record or unit exists still writes `findings.json` and `coverage-ledger.json` as `[]`
  (both validators accept an empty array), so it imports as an incomplete run instead of
  being moved to `watchtower-aborted/`.

## Import

Follow `import-rules.md` rules 1–8 for the run dir, with the report URL from Preflight:

- Kind, `from`, `to` and `started_at` come from the `watchtower_*` fields of
  `run-metadata.json`; the disputed list from `watchtower-disputed.json`.
- Rule 4's `git diff` runs in `watchtower_source_repo` (the target worktree may be gone).
- Batches of at most 50 writes; updates carry `if_version`; a version conflict →
  re-read, recompute, resend (rule 8). New engine-`rejected` records are created
  `status: "false_positive"` (rule 2).
- **No report yet** (the owner said yes to a new one; never with `--test`): load the
  `artifact-capabilities` skill, then publish `$SKILL_DIR/report-page.html` with
  `icon: "shield"` and
  `capabilities: {"db": {"rules": [{"path": "runs", "read": "view", "write": "owner"}, {"path": "findings", "read": "view", "write": "owner"}]}, "user": {}}`.
  Write the returned URL to `config.json` (`umask 077`) before the first data write.
  Later runs never republish the page.
- An import or publish that fails or is denied leaves the run dir intact; say:
  "`/security-audit import <run dir>` re-runs the import." Then Cleanup.

## Summary

In the terminal only (nothing to the board): counts by verdict and severity (rule 7's
`counts`), regressed, new, `disputed_not_revalidated` (the fingerprints, with "your
dispute was not re-checked; it stays on the next run's list" — and why, when the ledger
had no role-prefixed ids), coverage status (complete; or partial with the reasons:
Range scope, `run_status: "incomplete"` and its `incomplete_reason`, the
`coverage` counts of deferred / out_of_scope / blocked units), the report link, and the
engine run dir. No finding titles or text.

## Cleanup

Runs at the end of every path after the lock was taken (success, stop, failure,
`--plan-only`):

1. When Pin created a worktree: `git -C "$REPO" worktree remove --force "$CACHE/<root>-run-<N>/target"`, then
   `rm -rf "$CACHE/<root>-run-<N>"` and `git -C "$REPO" worktree prune`.
2. Re-apply modes: `find ~/security-audit-skill ~/.config/watchtower/security-audit -type d -exec chmod 700 {} +`
   and `… -type f -exec chmod 600 {} +`.
3. Release the lock: delete `$STATE/lock` only when it still holds this session's pid.

The engine run dir stays: it is the next run's prior evidence. `git status` of the
Watchtower checkout must still be clean of anything this run made.

## Updating the engine

The vendored engine instructs agents, so an update is supply chain and is reviewed like
code. Only this procedure produces `engine/VERSION`:

1. `tmp=$(mktemp -d)`; `git clone https://github.com/cloudflare/security-audit-skill "$tmp/src"`;
   `git -C "$tmp/src" checkout <new commit>`.
2. Read the upstream diff before copying:
   `git -C "$tmp/src" diff <pinned commit>..<new commit> -- skills/security-audit LICENSE`.
   Check what this skill and `import-rules.md` depend on: the setup values and
   `run-metadata.json` fields, the agent id regex, the ledger fields and `prior_status`
   values, the prior-run rules, the budget rules, the `findings.json` schema and the
   validator invocations. Adjust this skill or `import-rules.md` in the same PR.
3. Replace the contents of `engine/` with `"$tmp/src"/skills/security-audit/*` and
   `"$tmp/src"/LICENSE` — nothing else (no `.git`); files upstream removed are removed
   here.
4. Write `engine/VERSION`: `upstream: https://github.com/cloudflare/security-audit-skill`,
   `commit: <new commit>`, `date: <its commit date, ISO 8601>`, `files:`, then the
   manifest generated from the clone's copies — one `shasum -a 256` line
   (`<sha256>  <path relative to engine/>`) per copied file, sorted by path with
   `LC_ALL=C sort`.
5. Run both Preflight integrity commands → exit 0, no output.
6. On a branch, `git add -f .claude/skills/security-audit/engine` (`.claude/` is
   gitignored), commit `chore(security-audit): update engine to <short commit>`, and open
   a PR whose body lists the changed engine files with the old and new commit; it goes
   through `local-review` → `debate-review` like any code change. `rm -rf "$tmp"`.

The engine stays nested under this skill so Claude Code never registers its own
`name: security-audit` as a second skill.
