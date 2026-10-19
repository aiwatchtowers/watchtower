# Automation editor: write what the owner asked, show what it will do

Date: 2026-10-20. Board: #769 (assistant fidelity), #770 (workbench scope at creation).

## Why

The owner asked the automation editor chat for "a Release button for the watchtower
workbench: use the release skill, always check the docs, ship public, corp and the
mobile app". The assistant:

- could not see the workbench's `/release` command (the editor chat has no
  workbench file access) and guessed what it does;
- invented a two-stage design — "prepare with /release but do NOT publish", then
  three parallel `/release` sessions — that the owner never asked for;
- read `s.status` off a `wait: "none"` session (only `{session_id}` exists) and
  told the owner that waiting for a session counts toward the minutes budget (it
  does not: `executor_wait.go` pauses the meter);
- did not know the workbench at all: a new automation's chat is always "Scope:
  personal", and no tool lists workbenches.

The save card showed the recipe text, but the session prompts sat inside the JS
block, in English, and the owner approved without seeing "do NOT publish". The real
run: session 1 cut the whole release (3.5 h), then the script started three more
release sessions.

## Goals

1. The assistant wraps an owner's existing procedure as is and adds nothing of its own
   without asking.
2. The assistant can read the workbench's own skills and commands instead of guessing.
3. Before saving, the owner sees, in plain words, what every session the recipe starts
   will be told.
4. A new automation can be created for a workbench — from the Automations tab and
   from the workbench itself — and the chat knows that workbench.

Not goals: a runtime guard that stops a run whose first session "already did it"
(the first three goals remove the cause; a guard can come later if needed).

## Design

### 1. Skill `create-automation` (Go, `internal/skills/shipped/create-automation.md`)

New section "Wrapping the owner's procedure" after "The interview":

- When the owner names an existing skill, command or procedure ("use /release",
  "run make deploy"), the recipe hands it over **as is**: one `session()` whose prompt
  names it and repeats the owner's own requirements in the owner's words. No extra
  stages, no prohibitions ("do not publish"), no splitting into parallel sessions
  unless the owner asked for exactly that.
- Anything you would add (a check before, a split, a stop condition) is a separate
  question to the owner with the reason, never a silent change.
- Never guess what a workbench skill or command does: read it with
  `workbench_skills` (below). If you cannot read it, ask the owner.
- Write `session()` prompts in the language the owner uses with you, so the owner can
  read them on the save card.

The SDK table gains the exact return shapes: `session()` with `wait: "finish"` (the
default) returns `{session_id, status, summary, error?}` (`status` one of `finished`,
`stopped`, `deleted`, `error`); with `wait: "none"` only `{session_id}`; a dry run
returns `{status: "dry_run"}` and never starts a session, so branches on a session's
summary are not exercised by a dry run — say so to the owner. The budget table states
that waiting for a session, an ask or a proposal does not count toward `minutes`.

The "Release button" example becomes the wrapping shape: one session that runs the
workbench's release command, then a report with the session's summary (the
`shell("make release")` variant stays as the second half of the same example, since
it is a different case: a plain command, not a skill). `TestCreateAutomationSkill_
ExamplesParse` keeps parsing every example.

### 2. Read tool `workbench_skills` (Go, `internal/tools`)

`AccessRead`, surfaces `automation_editor` and `main` (where `draft_automation`
lives), not in `tools.ReadTools()` (DEV-01, like `draft_automation`).

- `{workbench_id}` → the workbench's skills and commands: `[{name, kind, description}]`
  from `.claude/commands/*.md` (`kind: command`, name `/<file stem>`),
  `.claude/skills/*/SKILL.md` and `.agents/skills/*/SKILL.md` (`kind: skill`, name
  from frontmatter or folder). `description` = frontmatter `description`, else the
  first non-empty line, at most 300 characters.
- `{workbench_id, name}` → that one file's text, at most 64 KiB (`truncated: true`
  past it).
- Reads only those three locations under the workbench folder, lstat-only like the
  recipe indexer (no symlinks, no special files, no `..`); an unknown workbench or a
  missing folder is an error, not an empty list. The tool names its workbench, so it
  follows the existing rule that a command naming a workbench may read it
  (`automations.md`, TCC note).
- The text is the repository's own and goes back as data (the tool's description and the
  skill frame it as data, never instructions); Watchtower's own installed skill pack files
  (`devpack`) are listed like any other.

`AgentToolsContract` (Go `internal/chat/actions_contract.go` + Swift twin) lists write
tools only, so `workbench_skills` is not in it; the registry test pins the set.

### 3. Sessions on the save card and the Draft panel (Desktop, WatchtowerCore)

A dry run already journals every `session()` and `agent()` call with its args
(`title`, `prompt`). Show them:

- **Draft panel:** a "Sessions it starts" block above the steps: one row per
  session/agent step — title, then the full prompt (two lines, expandable).
- **Save card:** the same block, taken from the draft-cache record whose recipe text
  equals the card's text. No such record → the line "No dry run of this exact text —
  the sessions are not shown" (the existing "differs from the last draft" warning
  stays).
- Pure formatting in `AutomationCardPresentation` (`sessionPrompts(steps:)`), tested in
  `Tests/Core`.

### 4. Workbench scope at creation (Desktop)

- **New automation sheet:** a "For" picker at the top — Personal, or one of the
  workbenches (the gallery already has the list). It applies to **Describe in words**
  and **Template**; **Form** stays personal and says so when a workbench is picked.
  This closes `automations.md:286`.
- **From the workbench:** a **New Automation…** item in the workbench header's menu
  opens the same sheet with that workbench picked.
- **Editor chat context:** with a workbench picked, `newContextBlock` says
  "Scope: workbench N (<name>, folder <folder name>)" and "Always pass
  `workbench_id: N`", like an existing workbench recipe, and tells the assistant to
  start with `workbench_skills` when the owner names a skill or command.
- The save card shows the scope line: "For: Personal" / "For: workbench <name>".

## Tests

- Go: `workbench_skills` list/read, frontmatter and fallback descriptions, size cap,
  symlink and `..` refusal, unknown workbench; the surface registry test; the skill
  examples parse; the contract golden if any.
- Swift (`Tests/Core`): `sessionPrompts`, the save card's scope line and sessions
  block (matched/unmatched draft), `newContextBlock` with a workbench.

## Docs

`docs/features/automations.md` (P3 editor section, the line-286 follow-up removed),
the user guide's automations page (the For picker, New Automation… in the workbench,
sessions on the save card).
