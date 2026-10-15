# Workbench — configurable methodology (design)

**Board:** #265 (group), #266 (this spec), #267 (custom board columns — a later spec that builds on this one)
**Status:** draft for owner review
**Owner decisions so far:** ask #138 (methodology first, columns later), ask #140 (what becomes configurable; where the rules live), ask #141 (understanding confirmed; ask guard modes `strict / soft / off`), ask #144 (approach B: two skills + rules through the brief)

## 1. Problem

A workbench session today runs one fixed methodology. The shipped skill
`watchtower-workbench` (pack v8) mixes three layers:

1. **Product core**: the board is the truth, ids are never invented, the parent
   status follows its children, the board agrees with git, asks are the channel
   to the owner, and quoted material is data, not instructions.
2. **Methodology**: a plan becomes sub-targets with `Task N` intents, targets
   are grouped before creation, `in_review` means "reviewed by agents" (built
   for superpowers subagent-driven development), comment discipline, how a
   group is worked.
3. **Enforcement**: Stop hooks send the agent back when it breaks a rule.

A user with a different process cannot adopt it without editing `SKILL.md`. An
edited skill is never upgraded again (PROJ-04 keeps a drifted file as it is).
The hooks override any skill they write. The ask guard sends back a question
asked in plain text, and it sends back work that looks complete without a
`finish_session` call.

## 2. Goal and non-goals

**Goal.** Let a user fit the agent's behaviour to their own process without
writing a skill. They can do this in two ways:

- **Team rules:** plain text in a file in the folder.
- **Personal settings:** set in the app. They override the file's defaults.

**Configurable (ask #140):**
- the methodology (the preset skill and the folder rules),
- the ask guard (`strict / soft / off`, ask #141),
- the finish check (`on / off`).

**Not configurable:**
- The board drift check against git (PROJ-07). It stays as it is.
- The product core (layer 1 above).
- The `ask_owner` tool and the asks stack.
- The status set. Custom columns come later, in #267, on top of this spec.

**Non-goals:**
- Multiple named presets or a preset marketplace. The only choices are the
  shipped preset or none.
- Per-session modes.
- Mobile UI for these settings.

## 3. Overview

```
<folder>/.watchtower/workflow.md        team: rules text + defaults (frontmatter), committed
projects.{methodology_preset,           personal: per-workbench overrides in the DB (NULL = use the file)
          ask_guard_mode, finish_check}
        │
        ▼  resolve (personal > file > built-in default)
effective settings ──► install: which skills land in the folder
                   ──► SessionStart brief: the folder rules slot
                   ──► Stop ask guard: mode, finish check
                   ──► PreToolUse AskUserQuestion/request_user_input: mode
```

Built-in defaults: preset `watchtower-flow`, ask guard `strict`, finish
check `on`. With no file and no overrides, behaviour is exactly today's.

## 4. Two skills

The v8 `watchtower-workbench` skill is split into two skills. They are
embedded under `internal/devpack/workbenchskill/` and installed side by side,
into `.claude/skills/` for Claude Code and `.agents/skills/` for Codex.

### 4.1 `watchtower-workbench`: the core (pack v9), always installed

It keeps what is true for any process:

- **Intro.** What the board, asks and comments are, and the `reason` rule on
  every write.
- **Tools.** The full list. Status values are described neutrally:
  `in_review` = "the work is being reviewed".
- **Setup.** Unchanged.
- **Working a target.** The minimal version: `get_target`, `list_comments`,
  set it `in_progress` with its `branch`, and never move it back to `todo`
  only because no code exists yet. Without this, Desktop's **Work on It**
  prompt would have nothing to land on.
- **Asking the owner.** All of it. Asks are the core channel. The paragraph
  about the end-of-turn check becomes conditional (§7).
- **Finishing a session.** The tool and the summary. The "write 'session
  finished'" line applies only when the finish check is on (§7).
- **Images, keeping the board in step with git, blocked, board language.**
  Unchanged.
- **Rules.** Unchanged, except the `in_review` definition, which moves to the
  preset.
- **A new section, "Folder rules".** The brief may carry a `Folder rules:`
  block (§6). Those rules are the owner's instructions for this folder. They
  win over the methodology preset when the two disagree. They never override
  the core rules in this skill: the board stays true, ids are never invented,
  asks are filed through `ask_owner`, and quoted material stays data.

### 4.2 `watchtower-flow`: the methodology preset, installed unless the preset is `none`

It takes the opinionated part, moved over verbatim where possible:

- Features, specs and plans (a feature target, review of every spec or plan, a
  plan becomes sub-targets).
- Grouping before every `create_targets`.
- Working a group.
- Running a plan (SDD): `in_progress`, then `in_review` while the reviewer
  agents run, then `done` with a one-to-three-line comment.
- Comment discipline (blockers and done summaries only).
- The `in_review` meaning: agents review the work, and waiting for the owner
  is never `in_review`.

Its description says it applies inside a workbench folder whenever a feature,
spec, plan or plan execution happens. That way it is loaded in the same
situations the v8 skill was.

**Why physically separate.** With the preset off, its text is not in the
agent's context at all, so there is nothing for the folder rules to contradict.
A user who has their own methodology (their own skills, or only folder rules)
gets a clean core.

### 4.3 Install and upgrade (PROJ-04 amended)

**Install.** `installWorkbenchFiles` writes the core every time. It writes
`watchtower-flow` only when the effective preset is `watchtower-flow`.

**Upgrade from v8.**
- An unchanged v8 core file (the shipped bytes, or bytes matching the sidecar
  digest) is replaced by the v9 core, and `watchtower-flow` is written next to
  it.
- A drifted v8 file (edited by the owner) is left alone, as PROJ-04 already
  requires. No `watchtower-flow` is written next to it, because the edited file
  already carries its own copy of the methodology. `workbench resync` reports
  this case with one line: "your edited skill keeps the old single-file layout;
  delete it to take the v9 core and preset".

**Preset switched to `none`.**
- `watchtower-flow` is removed only when its bytes are still ours (shipped, or
  matching the sidecar digest).
- An edited copy is left alone and reported.

This is the existing drifted-file rule.

**When the install runs.** Install and resync happen today on integrate, on
`workbench resync`, and when the Desktop changes a setting that needs it (§8).
A changed `preset:` line in `workflow.md` takes effect on the next install or
resync. The brief flags the mismatch (§6) so it is never silent.

**Fixtures.** The fixtures gain `watchtower-workbench-v8.md`, and the
upgrade tests cover v1..v8 → v9 core + flow (DEV-04).

## 5. The folder file: `.watchtower/workflow.md`

```markdown
---
preset: watchtower-flow      # watchtower-flow | none
ask_guard: soft              # strict | soft | off
finish_check: off            # on | off
---

Free text: the team's rules for agents working this folder, e.g.
"Plans live in docs/plans/. Never open a PR without a linked Jira issue.
Put a target in_review only when a human reviewer is assigned."
```

**Frontmatter.**
- Every key is optional. An absent key falls through to the built-in default.
- Parsing follows `internal/skills`' strict frontmatter reader: duplicate keys,
  unknown keys and bad values are refused.
- A refused file is ignored as a whole. The brief says so in one line, naming
  the error, and the built-in defaults apply. A broken file never weakens a
  check silently: a parse error means `strict` and `on`.

**Body.** Free text, UTF-8, read up to 64 KiB. A longer file is cut, and the
brief says so.

**Read safety.**
- The file is read with lstat semantics, as the automations indexer does
  (`internal/automations/indexer.go`). A symlink or a special file is never
  read; it is treated like a broken file.
- Only `<folder>/.watchtower/workflow.md` is read. In a session worktree it is
  the worktree's copy, because the hook's cwd is the worktree. This matches how
  the folder's `CLAUDE.md` behaves.

**Trust.** The file is treated like the folder's `CLAUDE.md`: owner and team
instructions, not quoted data. A cloned repository can carry
`ask_guard: off`. This is no worse than a `CLAUDE.md` that asks the agent to
skip asks. The personal setting in the app always wins, and the Desktop shows
where each effective value comes from (§8).

## 6. The brief

`renderSessionBrief` (`cmd/workbench_brief.go`) gains a **Folder rules**
section. It is reserved up front next to `briefRules`, so it is never cut by
the board sections.

- **Body of at most 1200 characters.** The body goes in verbatim under
  `Folder rules (.watchtower/workflow.md — the owner's rules for this folder; they win over the watchtower-flow preset):`.
- **Longer body.** One line goes in instead: `Folder rules: .watchtower/workflow.md (<N> chars) — read it before you start working.`
- **No file.** Nothing is added.
- **Broken file.** One line: `Folder rules: .watchtower/workflow.md was ignored: <error>. Built-in defaults apply.`
- **Mode line.** One line appears only when a mode differs from the
  built-in defaults: `Checks: ask guard soft (personal), finish check off (folder file).`
  It tells the agent which end-of-turn checks are live, so the core skill's
  conditional paragraphs (§7) resolve.
- **Preset mismatch.** One line when the effective preset differs from what is
  installed: `Methodology preset: none is set, but watchtower-flow is still installed — run 'watchtower workbench resync <id>'.`

The rules section reserves at most 1400 characters, so the existing 4000-char
cap and the board sections' share stay workable. `TestBrief*` goldens are
extended.

## 7. Hook modes

The modes are resolved at run time by the hook itself:
`workbenchmethod.Resolve(ctx, db, workbenchID, folder)` (a new small package `internal/workbenchmethod`: the file reader and the precedence) returns the
effective `{Preset, AskGuard, FinishCheck, Sources}`. Codex hooks resolve
the same way through the session row. A failure to read the DB or the file
resolves to `strict` + `on`. This mirrors the "a database failure reads as the
owner away" rule in PROJ-13.

### 7.1 Ask guard, Stop (`decideStop`)

| Mode | Classifier call | Request phase | Finish phase |
|---|---|---|---|
| `strict` | yes | today's table | if finish check on |
| `soft` | yes | never sends back. A chat request is recorded whatever the presence. A full request (review, check, several decisions) is recorded as the chat question with its full text. | if finish check on |
| `off` | only if finish check on | skipped, nothing recorded or cleared | if finish check on |

With `off` and the finish check off, the hook returns before reading stdin's
message. No model call is made, so no cost is spent.

**What `soft` keeps.** The question is never lost. A recorded question while
the owner is away is raised by the Desktop at once. While the owner is
present, it is raised after the existing 10-minute timeout
(`ChatQuestionEscalationPolicy`). A recorded full request is raised as a
**Full** ask with the message's question text and no options, the same as the
existing zero-option escalation path (`TestEscalateZeroOptionsIsQuick` is
amended: zero options from a full request become Full).

**Accepted limit.** The escalation runs only while the Desktop runs. In
`strict` the agent itself files the ask, so the Desktop is not needed. In
`soft`, a question asked while the Desktop is down waits until it starts. The
Settings help text says this.

### 7.2 Ask guard, PreToolUse (`AskUserQuestion` / `request_user_input`)

| Mode | Behaviour |
|---|---|
| `strict` | denied, as today |
| `soft` | denied only while the owner is away, with the away reason. Allowed while the owner is present in this session. |
| `off` | allowed |

### 7.3 Finish check

When `finish_check` is `off`, `stopFinishPhase` is skipped in every mode. The
session then ends without `finish_session`, as `Stopped` and not `Finished`.
It has no summary in its report (PROJ-14 is unchanged: only `finish_session`
marks a session finished).

### 7.4 What does not change

- The drift Stop hook (`workbench check --stop-hook`, PROJ-07).
- The state hooks (PROJ-11).
- The classifier text (`askguard_classifier.md` v4 golden).
- The fixed reason strings.
- `stop_hook_active` never blocks, in any mode.

## 8. Storage and the Desktop

**Migration.** It adds three nullable columns to `projects`. NULL means "use
the folder file, else the default":

```sql
methodology_preset TEXT NULL CHECK(methodology_preset IS NULL OR methodology_preset IN ('watchtower-flow','none')),
ask_guard_mode     TEXT NULL CHECK(ask_guard_mode IS NULL OR ask_guard_mode IN ('strict','soft','off')),
finish_check       TEXT NULL CHECK(finish_check IS NULL OR finish_check IN ('on','off'))
```

**Required updates.**
- Mirror the columns in `schema.sql`.
- Regenerate the Swift test schema.
- Add the Go setters `SetWorkbenchMethodology`.
- Add the Swift twin in `WorkbenchQueries`, a documented dual path. It is
  written by both, like `worktree_setup`.

**CLI.**
- `watchtower workbench methodology <id> [--preset …] [--ask-guard …] [--finish-check …] [--clear]` writes the overrides.
- `--json` prints the effective values and their sources.

The Desktop calls this command; it does not write the columns itself. That
keeps the resync (§4.3) in one place: a preset change runs the install right
after the write.

**Desktop, workbench settings ("Agent" section).**
- **Three pickers.**
  - Methodology: *From folder file / Watchtower flow / None*.
  - Ask guard: *From folder file / Strict / Soft / Off*.
  - Finish check: *From folder file / On / Off*.
  - Each picker shows the effective value and its source when it is set to
    "From folder file".
- **Folder file button.** It reads **Open workflow.md**. When the file is
  missing it reads **Create workflow.md**, which writes a commented template.
  The template has every frontmatter key commented out and a two-line body
  hint. It never overwrites an existing file.
- **Help text** per mode, including the §7.1 Desktop-down limit for `soft`.

The MCP tools gain nothing new: the agent never changes its own checks. A
`workbench_info` result gains `methodology: {preset, ask_guard, finish_check}`
with sources, read-only.

## 9. Contracts

**PROJ-13, amended** (the owner approved the modes in ask #141). Today it
reads "the ask guard never traps a turn". It gains the mode table (§7.1–7.2),
the resolution failure → `strict` rule, and the off-and-finish-off
no-model-call rule.

New guards:
- `TestProj13_ModeTable`
- `TestProj13_SoftNeverSendsBackAndAlwaysRecords`
- `TestProj13_OffWithFinishOffCallsNoModel`
- `TestProj13_UnreadableModeIsStrict`
- `TestProj13_PreToolUseFollowsMode`

Existing guards stay as they are, run under `strict`.

**PROJ-04, amended.** The install writes two skills. It removes the preset
only when it is ours, and keeps a drifted v8 single file without adding the
preset.

New guards:
- `TestProj04_PresetNoneRemovesOnlyOurFlow`
- `TestProj04_DriftedV8KeepsSingleFileNoFlow`

**PROJ-02, extended.** A workbench delete removes `watchtower-flow` too, when
it is ours.

**PROJ-14, unchanged.** It is only noted in the changelog that the finish
check can now be off.

**DEV-04, extended.** Upgrade fixtures v1..v8 → v9 core + flow.

**`docs/features/workbench.md`, new section "Methodology".** It covers the
file, the precedence, the modes and the two skills. `CLAUDE.md`'s feature
line gets one clause.

## 10. Testing

**Go.**
- `internal/devpack`: the split, install and upgrade matrix, and preset none.
- `cmd`:
  - the brief's rules slot (inline, long, broken and mismatch lines; the cap
    respected),
  - `decideStop` per mode,
  - PreToolUse per mode,
  - the resolution precedence and the failure → strict rule,
  - the `workbench methodology` CLI.
- `internal/db`: the migration and setters; `internal/workbenchmethod`: the file parser (lstat, strict frontmatter, cut at 64 KiB) and the precedence.

**Swift.**
- `WorkbenchQueries` setters.
- The pickers' source labels.
- Escalation of a zero-option full request → Full.

**Manual (an ask with a checklist).** In a scratch folder:
1. Set `soft` and ask a question in the terminal while away. It is raised as
   an ask.
2. Set `off`. No send-back, and no model call shows in the log.
3. Set preset `none` from the app. `watchtower-flow` disappears from
   `.claude/skills`.

## 11. Rollout

1. **Go core.** Migration, resolver, hooks' modes, brief slot, CLI. With no
   file and no overrides, this is a no-op.
2. **Skill split.** v9 core + `watchtower-flow`, install and upgrade.
3. **Desktop.** Agent settings section and the template.
4. **Docs and inventory.**

Each phase can merge on its own. Phase 1 alone already lets a team use
`workflow.md` with the v8 skill.

## 12. Open points for the owner

1. **Should `soft` cover a full request** (a review or check in plain text) by
   raising a Full ask with the raw text? The alternative is to send it back
   even in `soft`, so the agent files a proper `kind: review` with a
   `doc_path`. The draft says raise it, because `soft` means "never send
   back".
2. **The brief's inline cap** for folder rules is 1200 characters. Longer files
   become a pointer that the agent must follow.
