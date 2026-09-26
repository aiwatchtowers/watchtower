# Persona Skills (Secretary & Assistant) — Design

**Date:** 2026-08-19
**Status:** Approved (owner, 2026-08-19)

## Overview

A skill is a packaged instruction set one of the app's two AI personas can load
on demand during a Discuss chat — the same concept the dev-surface pack ships
for external coding agents (`internal/devpack/`), turned inward. Skills teach
the secretary and the assistant *how* to handle a class of request ("untangle
this thread", "draft a status update", "break this target down"), on top of the
owner profile and learned rules.

Two authorship tiers share one mechanism:

- **Shipped** skills — embedded in the binary, deployed to the workspace on
  daemon start, upgraded in place unless the owner edited them (the devpack
  non-clobbering contract).
- **Owner** skills — plain files the owner creates in the same directory, via
  the Desktop editor or any text editor.

Scope decisions (owner, 2026-08-19): chats only — the background pipelines
(triage, compose, situation cards, digests) are explicitly out; activation is
model-driven (Claude-style list + load tool), never keyword matching; no CLI
surface in v1.

## Skill format

One markdown file per skill in `<workspace>/skills/<name>.md`. The filename
stem is the skill's identity (`^[a-z0-9][a-z0-9-]*$`); frontmatter carries the
rest:

```yaml
---
description: Use when the owner asks for a status update on a situation.
persona: secretary   # secretary | assistant | both
enabled: true        # optional, default true
---
<body: instructions; may reference existing MCP tools by name>
```

Parsing is strict on what matters, lenient elsewhere: a file with a missing or
malformed frontmatter block, an empty `description`, or an unknown `persona`
value is skipped (never listed, never loadable) and logged — one bad file must
not break the catalog. Unknown frontmatter keys are ignored (the memory-vault
Obsidian precedent).

The file is the single source of truth — the enable toggle lives in
frontmatter, not in a DB or UserDefaults, so Go and Swift always agree. No
migrations, no new tables.

## Storage & deploy (Go: `internal/skills/`)

- `Dir(workspaceDir)` → `<workspaceDir>/skills`.
- `List(dir)` → parsed skills, sorted by name; missing dir = empty list.
- Shipped skills live in `internal/skills/shipped/*.md` (`//go:embed`).
- `Deploy(dir)` mirrors the devpack installer semantics (`internal/devpack/install.go`):
  a per-directory sidecar records the sha256 of every shipped file we last
  wrote; on upgrade, a file that still matches its shipped digest is replaced,
  a file the owner edited is left untouched, a file we never shipped is never
  touched. The implementation is a fresh small copy inside `internal/skills`
  (deliberate dual, like `saveNotes`), not a refactor of devpack.
- The daemon calls `Deploy` once at startup (log-only on failure, non-fatal),
  so the Desktop app's managed daemon keeps shipped skills current without any
  user action.

## Activation in chats (model-driven)

- **Swift side** — new `SkillsCatalog` in
  `WatchtowerDesktop/Sources/WatchtowerCore/Services/Skills/`:
  - `list()` reads `Constants.activeWorkspaceDir()/skills` and parses
    frontmatter with semantics matching the Go parser (documented dual-path,
    the `saveNotes` precedent; equivalence pinned by matching fixtures on both
    sides).
  - `promptBlock(persona:)` returns a `SKILLS` block — one line per enabled
    skill matching the persona (`both` matches either): name + description —
    followed by the instruction: *if a skill is relevant to the request, call
    the `load_skill` MCP tool with its name first and follow its
    instructions.* Returns `nil` when nothing matches, so surfaces with no
    skills keep byte-identical prompts (the sentinel-gate precedent).
- Each chat ViewModel appends the block in its own `buildSystemPrompt` (the
  prompt duplication stays a house pattern; the catalog is the single shared
  piece). Resumed sessions (`--resume`) drop the system prompt as today; the
  model already saw the list in-session.
- **Go side** — new MCP tool `load_skill` (`internal/mcp/skills.go`): takes
  `name`, validates it against the identity pattern (path-traversal guard),
  reads `<workspace>/skills/<name>.md`, returns the body (with description).
  Read-only, like every MCP tool (DEV-01 untouched). A disabled skill is not
  an error to load — the gate is what the list shows, not the read.

## Persona mapping

One constant table, one place per side:

| Surface (chat `context_type`) | Persona |
|---|---|
| situation | secretary |
| meeting | secretary |
| target | assistant |
| track | assistant |
| idea | assistant |

Setup/onboarding chats are out of v1 (never listed skills). The mapping
follows the pinned persona contract in `docs/review/review-rules.md`
("Personas & chat contracts", 2026-08-18).

## Safety: the persona contract is not weakened

A skill is instructions plus pointers at existing read-only MCP tools. It adds
no action path: secretary chats have no action mechanism at all, and assistant
chats keep routing every mutation through the proposal→Approve gate. A shipped
skill that would give the secretary action capability is a contract violation
and must be flagged for owner review (per review-rules).

## Desktop UI

Settings → **Skills** card:

- List: name, persona badge, shipped/custom origin, enable toggle.
- Toggle rewrites the file's `enabled` frontmatter in place.
- "New Skill" + row tap → editor sheet (name — locked after creation,
  description, persona picker, body). Save writes the file.
- Delete is offered only for owner-created files; shipped skills can only be
  disabled (Deploy would resurrect a deleted shipped file anyway).
- `SkillsSettingsViewModel` (`@Observable`, on the Settings screen — no
  navigation-surviving state needed, operations are synchronous file writes)
  ships with its own test suite (house rule).

## Shipped v1 skills

Three starters (English, like all repo content):

- `thread-untangle` (secretary) — reconstruct who asked what in a tangled
  thread and what is still unanswered.
- `status-update` (secretary) — draft a status update on the situation in the
  owner's voice; the intent-draft contract holds (owner states what to say).
- `target-breakdown` (assistant) — decompose a target into sub-targets via
  proposal cards through the standard Approve gate.

## Testing

- Go: parser (valid / malformed frontmatter / bad persona / disabled default),
  `List` on a missing dir, `Deploy` (fresh install / clean upgrade /
  owner-edited file untouched / foreign file untouched), `load_skill`
  (happy path, traversal attempt rejected, unknown name).
- Swift (`Tests/Core`): catalog parser + `promptBlock` (persona filtering,
  disabled skips, nil on empty) with fixtures matching the Go parser tests;
  `SkillsSettingsViewModel` suite; one prompt test per persona side asserting
  the block appears in `SituationChatViewModel` (secretary) and
  `TargetChatViewModel` (assistant) system prompts and is absent when no
  skills exist.

## Out of scope (v1)

- Pipeline surfaces (owner decision), CLI commands (owner decision).
- Skills carrying their own tools or scripts.
- Skill import/sharing, autogeneration from learned rules.
- Setup/onboarding chats.
