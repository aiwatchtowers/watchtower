# User Guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `docs/app-guide.md` with a short, accurate, page-per-feature user guide in `docs/guide/` that a person on GitHub and the future help agent can use.

**Architecture:** Plain Markdown pages in `docs/guide/`, split into `start/`, `concepts/`, `features/`, `troubleshooting/` and `reference/`, plus a catalogue (`README.md`) and author rules (`WRITING.md`). Each task writes one group of pages. The content comes from `docs/app-guide.md` (dissolved as the work goes), `docs/features/*.md` and the code, with the code as the source of truth. The last task checks the coverage ledger and deletes `app-guide.md`.

**Tech Stack:** GitHub-flavoured Markdown, plus a one-off Python check script.

**Spec:** `docs/superpowers/specs/2026-10-16-user-guide-design.md` — read it first. Its "Writing rules", "Page template for a feature" and "Calls made after the builder check" sections are binding for every task.

## Global Constraints

- English only; plain GitHub Markdown. Relative links only. Mermaid only for a mechanism; no images.
- Short. Paragraphs are three sentences or fewer. A feature page stays under about 8 KB of Markdown (`wc -c`); split the page rather than exceed it.
- Only what the screen doesn't say. UI names are in **bold**, spelled exactly as the Swift source spells them.
- Every schedule, default, condition, UI string and shortcut is checked against the code. The code beats `app-guide.md` and `docs/features/`. Each mismatch with `docs/features/` gets a board comment on #429.
- Document only what ships on `main`: no roadmap, no "coming soon".
- "The assistant" is the only name for the AI persona.
- Public repo: no real names, ids, domains or paths (`acme`, `example.com`). Run `bash scripts/leak-check.sh` before each push, if the branch has it; otherwise run the pre-push hook through `git push`.
- Headings are anchors. Use only `##` and `###`, and keep the text stable once published.
- Feature page sections, in this order, dropping any that would be empty: lede → `## Why use it` → `## How it works` → `## Using it` → `## When it's empty or wrong` → `## Related`, then `For developers: docs/features/<x>.md`.

## Review Focus

The review is an accuracy review, not a style read. For each page, the reviewer opens the code paths named in its task and checks, most likely failures first:

1. **Schedules and gates.** Hours, intervals, "runs after X", feature-switch and source preconditions (`FeatureReadiness`, `EmptyStateCopyTable`, daemon phase gates in `internal/daemon`). These are the facts most likely to be stale in `app-guide.md`.
2. **UI strings and shortcuts.** Button, menu and empty-state text and key equivalents, checked by grepping the Swift source for the exact string.
3. **Unshipped behaviour described as shipped.** Checked against the "Pending" and "v1 limits" lines in `docs/features/*.md`.
4. **Self-containment.** A section read alone must still make sense. Reject "as above", undefined jargon, and a heading that doesn't say what it answers.
5. **Length.** The check script's size warnings, and paragraphs longer than three sentences.

## Checks (every task)

Save once per worktree as `$SCRATCH/guide_check.py`, where `$SCRATCH` is your scratchpad. Do not commit it.

```python
#!/usr/bin/env python3
"""guide_check.py <repo> — links resolve, catalogue lists every page once, size."""
import re, sys, pathlib
root = pathlib.Path(sys.argv[1]); g = root / "docs/guide"
pages = sorted(p for p in g.rglob("*.md"))
bad = 0
for p in pages:
    text = p.read_text()
    for m in re.finditer(r"\]\(([^)#\s]+)(#[^)]*)?\)", text):
        t = m.group(1)
        if t.startswith(("http://", "https://", "mailto:")): continue
        if not (p.parent / t).resolve().exists():
            print(f"BROKEN {p.relative_to(root)} -> {t}"); bad += 1
    if "/features/" in str(p) and len(text.encode()) > 8192:
        print(f"SIZE {p.relative_to(root)} {len(text.encode())} B")
cat = (g / "README.md").read_text() if (g / "README.md").exists() else ""
for p in pages:
    rel = p.relative_to(g).as_posix()
    if rel in ("README.md", "WRITING.md"): continue
    n = len(re.findall(r"\]\(" + re.escape(rel) + r"[)#]", cat))
    if n != 1: print(f"CATALOGUE {rel} listed {n}x"); bad += 1
print("exit", 1 if bad else 0); sys.exit(1 if bad else 0)
```

Run: `python3 -I $SCRATCH/guide_check.py . > $SCRATCH/check.log 2>&1; echo "exit=$?"; cat $SCRATCH/check.log`

Expected: `exit=0`. `SIZE` lines are warnings: each one either gets split or gets a one-line reason in the hand-back.

Every task adds its pages to `docs/guide/README.md` in the same commit, one line each, so the catalogue check passes after every task.

## Coverage ledger

Every `app-guide.md` section, and the task that dissolves it. A task that drops a fact on purpose (obvious from the UI, stale, unshipped) lists it in its hand-back. The controller copies those lists into this table's "Dropped" column.

| app-guide.md section | Task | Dropped (filled during execution) |
|---|---|---|
| First launch: setup | 2 | |
| Home | 3 | |
| Menu | 3 | |
| Catch Up | 3 | |
| Briefings | 3 | |
| Day Plan | 3 | |
| Inbox | 3 | |
| Ideas | 3 | |
| Voice Dictation | 5 | |
| Calendar | 5 | |
| Gmail | 5 | |
| Targets (tasks) | 4 | |
| Workbench | 9, 10 | |
| Automations | 8 | |
| AI Chat | 7 | |
| Tracks | 4 | |
| Project Map, Releases, Blockers, Workload (Jira) | 6 | |
| Digests | 4 | |
| People | 4 | |
| Statistics | 4 | |
| Search | 6 | |
| Usage | 2 | |
| Boards | 6 | |
| MCP Server | 11 | |
| iPhone | 11 | |
| Settings | 12 | |
| Menu Bar & App Lifecycle | 11 | |
| Background Processes | 2 | |
| Memory | 7 | |
| Key Concepts | 2, 12 | |

---

### Task 1: Skeleton — WRITING.md and catalogue

**Files:**
- Create: `docs/guide/WRITING.md`, `docs/guide/README.md`

**Interfaces:**
- Produces: the catalogue's group headings, which later tasks append under. The headings are: `## Start here`, `## How Watchtower works`, `## Focus`, `## Execution`, `## Insights`, `## Workbench`, `## Automations & AI`, `## Meetings & calendar`, `## Apps & integration`, `## Troubleshooting`, `## Reference`. Catalogue line format: `- [Title](path/to/page.md) — what it does for you, one line.`

- [ ] **Step 1: Write `WRITING.md`.** It holds the spec's writing rules 1–9, the feature page template, the troubleshooting shape, the headings-are-anchors rule and "only what ships on main". Keep it under 4 KB. It is itself an example of the rules.
- [ ] **Step 2: Write `README.md`.** A three-sentence lede saying what Watchtower is, then the empty group headings. The three entry links (first-week tour, troubleshooting, how Watchtower works) go at the top of the README in Tasks 2, 13 and 14, as those pages' only catalogue lines (the check counts commented-out links, so no placeholders).
- [ ] **Step 3: Run the check.** Expected: `exit=0`.
- [ ] **Step 4: Commit** with `docs(guide): skeleton — writing rules and catalogue`.

### Task 2: Start and concepts

**Files:**
- Create: `docs/guide/start/setup.md`, and in `docs/guide/concepts/`: `how-watchtower-works.md`, `sources-and-accounts.md`, `history-backfill.md`, `features-on-and-off.md`, `ai-providers-and-cost.md`, `privacy.md`
- Modify: `docs/guide/README.md`

**Sources:**
- app-guide: "First launch: setup", "Background Processes", "Usage", and the "Key Concepts" items about sources and providers.
- `docs/features/`: `onboarding-v2.md`, `first-run.md`, `tray-daemon-lifecycle.md`, `history-backfill.md`, `feature-manager.md`, `model-provider-registry.md`, `claude-plan-limits.md`, `owner-identity.md`, and the three multi-account docs.
- Code: `internal/daemon` (the phase list and gates), `internal/features`, `internal/providers`, `internal/planusage`, `WatchtowerDesktop/Sources/WatchtowerCore` (`FeatureReadiness`), `WatchtowerDesktop/Sources/App/OnboardingV2View.swift`, `WatchtowerDesktop/Sources/Views/Settings`.

- [ ] **Step 1: Write `how-watchtower-works.md`.** Local DB → background sync cycle → pipelines. Include a Mermaid diagram of one cycle, and a "What runs when" table with columns output | when | needs, covering every scheduled output, read from the daemon phase gates.
- [ ] **Step 2: Write the other six pages.** `privacy.md` answers three questions: what stays on the Mac, what goes to the AI provider, and what goes to iCloud (the mobile hub).
- [ ] **Step 3: Add catalogue lines (`how-watchtower-works.md` as the top entry link, not under a group) and run the check.** Expected: `exit=0`.
- [ ] **Step 4: Commit** with `docs(guide): setup and concepts`.

### Task 3: Focus — Home, Catch Up, Briefings, Day Plan, Inbox, Ideas

**Files:**
- Create in `docs/guide/features/`: `home.md` (includes the sidebar/menu section), `catch-up.md`, `briefings.md`, `day-plan.md`, `inbox.md` (includes attention detection, reaction commands, reminders and approvals), `ideas-and-decisions.md`
- Modify: `docs/guide/README.md`

**Sources:**
- app-guide sections named in the ledger for Task 3.
- `docs/features/`: `first-run.md`, `catchup.md`, `attention-detection.md`, `reaction-commands.md`, `agent-actions.md`, `ideas-decisions-registry.md`, `strong-tier-cost-fixes.md`.
- Code: `Views/{Home,CatchUp,Briefings,DayPlan,Inbox,Ideas,Sidebar}`, `internal/{catchup,briefing,dayplan,inbox,reactioncmd,ideas}`, `EmptyStateCopyTable`.

- [ ] **Step 1: Write the six pages** from the feature template. `## When it's empty or wrong` on each covers every readiness state its tab can show.
- [ ] **Step 2: Add catalogue lines and run the check.** Expected: `exit=0`.
- [ ] **Step 3: Commit** with `docs(guide): focus features`.

### Task 4: Targets, Tracks, Digests, People, Statistics

**Files:**
- Create in `docs/guide/features/`: `targets.md` (includes next step and target brief chat), `tracks.md`, `digests.md` (includes the Decisions journal), `people.md`, `statistics.md`
- Modify: `docs/guide/README.md`

**Sources:**
- `docs/features/`: `target-brief-chat.md`, `ideas-decisions-registry.md`.
- `docs/target-roles.md`.
- Code: `Views/{Targets,Tracks,Digests,People,Statistics}`, `internal/{targets,tracks,customtracks,digest,guide}`.

- [ ] **Step 1: Write the five pages.**
- [ ] **Step 2: Add catalogue lines and run the check.** Expected: `exit=0`.
- [ ] **Step 3: Commit** with `docs(guide): targets, tracks, digests, people, statistics`.

### Task 5: Calendar, meetings, dictation, mail

**Files:**
- Create in `docs/guide/features/`: `calendar-and-meeting-prep.md`, `meeting-recording.md` (includes transcripts, voices, notes and the meeting chat), `voice-dictation.md`, `mail.md`
- Modify: `docs/guide/README.md`

**Sources:**
- `docs/features/`: `meeting-transcriber.md`, `voice-dictation.md`, `google-multi-account.md`.
- Code: `Views/{Calendar,Voices,QuickCapture}`, `internal/{calendar,caldav,meeting,gmail,imap}`.
- app-guide's Calendar section is 31 KB. Expect it to shrink to two pages by the "only what the screen doesn't say" rule.

- [ ] **Step 1: Write the four pages.** Split `meeting-recording.md` if it goes over 8 KB.
- [ ] **Step 2: Add catalogue lines and run the check.** Expected: `exit=0`.
- [ ] **Step 3: Commit** with `docs(guide): calendar, meetings, dictation, mail`.

### Task 6: Jira & Linear, Search & knowledge

**Files:**
- Create in `docs/guide/features/`: `jira-and-linear.md` (Boards, Workload, Blockers, Project Map, Releases; Linear as shipped — the connector and sync only), `search-and-knowledge.md` (includes Confluence in search)
- Modify: `docs/guide/README.md`

**Sources:**
- `docs/features/`: `jira-multi-account.md`, `jira-changelog.md`, `jira-custom-fields.md`, `linear.md`, `knowledge-search.md`, `confluence-knowledge-connector.md`.
- `docs/jira-setup.md`.
- Code: `Views/{Boards,Blockers,Workload,Jira,Search}`, `internal/{jira,linear,kb,confluence}`.

- [ ] **Step 1: Write the two pages.**
- [ ] **Step 2: Add catalogue lines and run the check.** Expected: `exit=0`.
- [ ] **Step 3: Commit** with `docs(guide): jira, linear, search`.

### Task 7: AI Chat, Quick Connections, Memory

**Files:**
- Create in `docs/guide/features/`: `ai-chat.md` (includes projects, attachments, artifacts, proposals, Slack send, Confluence editing and embedded chats), `quick-connections.md`, `memory.md`
- Modify: `docs/guide/README.md`

**Sources:**
- `docs/features/`: `chat-redesign.md`, `embedded-chat.md`, `slack-send.md`, `confluence-page-editing.md`, `quick-connections.md`, `memory.md`, `persona-merge.md`, `agent-actions.md`.
- `docs/review/review-rules.md`, the "assistant & chat contracts" section — the draft-only surfaces must be described correctly.
- Code: `Views/{Chat,Memory}`, `Services/Chat`, `internal/{chat,memory,externalmcp,mcpoauth,tools}`.

- [ ] **Step 1: Write the three pages.** Split `ai-chat.md` if it goes over 8 KB.
- [ ] **Step 2: Add catalogue lines and run the check.** Expected: `exit=0`.
- [ ] **Step 3: Commit** with `docs(guide): chat, quick connections, memory`.

### Task 8: Automations

**Files:**
- Create: `docs/guide/features/automations.md`, and `docs/guide/features/automations-recipes.md` if the recipe format doesn't fit
- Modify: `docs/guide/README.md`

**Sources:**
- `docs/features/automations.md`. Only the phases shipped on `main`: check its status line against `git log origin/main -- internal/automations`.
- Code: `Views/Automations`, `App/RunAutomationCommand.swift`, `cmd/automations*.go`, `internal/automations`.

- [ ] **Step 1: Write the page(s).** Cover: what a recipe is, why confirming is required (the approval hash, said in plain words), templates, Run Automation… ⌃⌘R, budgets, and auto grants.
- [ ] **Step 2: Add catalogue lines and run the check.** Expected: `exit=0`.
- [ ] **Step 3: Commit** with `docs(guide): automations`.

### Task 9: Workbench, part 1

**Files:**
- Create in `docs/guide/features/workbench/`: `README.md` (overview: what a workbench is, why you'd use one, a one-line map of the sub-pages), `board-and-targets.md` (includes hierarchy, archive and the drift check), `sessions.md` (includes states, the sessions panel, Agents working, reports and Ready to check), `asks.md` (levels, delivery, the ask guard, presence)
- Modify: `docs/guide/README.md`

**Interfaces:**
- Produces: `features/workbench/README.md`'s sub-page map. Task 10 appends its pages to it.

**Sources:**
- app-guide's Workbench section (91 KB). It is split with Task 10 by topic.
- `docs/features/workbench.md`.
- Code: `Views/Workbench`, `internal/{workbenchcheck,sessionreport,asks,terminal}`, `cmd/workbench*.go`.

- [ ] **Step 1: Write the four pages.**
- [ ] **Step 2: Add catalogue lines and run the check.** Expected: `exit=0`.
- [ ] **Step 3: Commit** with `docs(guide): workbench — board, sessions, asks`.

### Task 10: Workbench, part 2, and agent analytics

**Depends on:** Task 9

**Files:**
- Create in `docs/guide/features/workbench/`: `code-viewer.md` (includes code navigation and Open Quickly), `worktrees-and-cleanup.md` (includes session placement), `diff-review.md`, `methodology.md`, `codex.md`
- Create: `docs/guide/features/agent-analytics.md`
- Modify: `docs/guide/features/workbench/README.md`, `docs/guide/README.md`

**Sources:**
- `docs/features/`: `workbench.md`, `code-navigation.md`, `diff-reviewer.md` (Plan 1 only), `agent-analytics.md`.
- Code: `Views/Workbench`, `internal/{reviewdiff,sessioncleanup,workbenchgit,workbenchmethod,agentkind,agentlog,codeindex}`.

- [ ] **Step 1: Write the six pages.**
- [ ] **Step 2: Add the sub-pages to the workbench map and the catalogue, then run the check.** Expected: `exit=0`.
- [ ] **Step 3: Commit** with `docs(guide): workbench — code, worktrees, review, methodology, codex; agent analytics`.

### Task 11: iPhone, menu bar, Claude Code integration

**Files:**
- Create in `docs/guide/features/`: `iphone.md` (includes pairing, multi-Mac and the CloudKit environments in plain words), `menu-bar-and-updates.md`, `claude-code-integration.md` (MCP server, skill pack, `integrate claude-code` / `integrate codex`)
- Modify: `docs/guide/README.md`

**Sources:**
- `docs/features/`: `mobile-companion.md`, `tray-daemon-lifecycle.md`, `developer-surface.md`.
- `docs/mcp-server.md`.
- Code: `App/TrayAppDelegate.swift`, `Views/TrayMenuView.swift`, `Views/StatusBarView.swift`, `App/AppState+MobileHub.swift`, `internal/mcp`, `cmd/integrate*.go`.

- [ ] **Step 1: Write the three pages.**
- [ ] **Step 2: Add catalogue lines and run the check.** Expected: `exit=0`.
- [ ] **Step 3: Commit** with `docs(guide): iphone, menu bar, claude code integration`.

### Task 12: Reference

**Files:**
- Create in `docs/guide/reference/`: `settings.md`, `keyboard-shortcuts.md`, `cli.md`, `glossary.md`
- Modify: `docs/guide/README.md`

**Sources:**
- app-guide: "Settings" and "Key Concepts".
- Code: `Views/Settings`.
- Shortcuts: `grep -rn "keyboardShortcut" WatchtowerDesktop/Sources`, plus the global hotkeys in `App/GlobalHotKey.swift`.
- CLI: `grep -n "Use:" cmd/*.go`.

- [ ] **Step 1: Write `settings.md`.** One section per settings tab, listing only what is non-obvious. Each item links to the feature page that explains it.
- [ ] **Step 2: Write `keyboard-shortcuts.md`.** One table per area, with every shortcut found by the grep.
- [ ] **Step 3: Write `cli.md`.** One line per user-facing command group; skip developer-only commands such as `db lockstats` unless a troubleshooting page uses them.
- [ ] **Step 4: Write `glossary.md`.** Every term the guide uses that a newcomer wouldn't know (target, track, digest, ask, workbench, recipe, briefing, attention item, …), one or two sentences each, linked to its page.
- [ ] **Step 5: Add catalogue lines and run the check.** Expected: `exit=0`.
- [ ] **Step 6: Commit** with `docs(guide): reference — settings, shortcuts, cli, glossary`.

### Task 13: Troubleshooting

**Depends on:** Tasks 2–12 (it links to their pages)

**Files:**
- Create: `docs/guide/troubleshooting/README.md` (the symptom index: "What you see" → page), plus one `docs/guide/troubleshooting/<symptom>.md` per failure mode
- Modify: `docs/guide/README.md` (`troubleshooting/README.md` as the top entry link; each symptom page under `## Troubleshooting`)

**Sources:**
- `EmptyStateCopyTable` and the `FeatureReadiness` states.
- User-facing error strings: `grep -rn "Text(\"" WatchtowerDesktop/Sources/Views | grep -iE "fail|couldn|error|not "`.
- `docs/backlog/`: open, user-visible items only.
- `gh issue view` for #274–#292.
- `docs/incidents/`.

- [ ] **Step 1: List the failure modes.** Write the list, each with its evidence (file or issue), into the hand-back. The minimum set is the spec's list:
  - a tab is empty;
  - sync stuck or slow;
  - no briefing or day plan today;
  - Claude/Codex CLI not found or not signed in;
  - an account needs attention or was revoked;
  - calendar events missing;
  - recording or transcript problems;
  - a workbench session or ask not reaching the agent;
  - the iPhone not syncing;
  - plan limits or high cost.
- [ ] **Step 2: Write one page per failure mode** in the troubleshooting shape: symptom (the exact text the user sees) → cause → fix steps → how to check → if it didn't help. A known unfixed bug is labelled "Known issue" and names its workaround.
- [ ] **Step 3: Link each feature page's `## When it's empty or wrong` section to its troubleshooting page.** This is a one-line link edit per page.
- [ ] **Step 4: Run the check.** Expected: `exit=0`.
- [ ] **Step 5: Commit** with `docs(guide): troubleshooting`.

### Task 14: First-week tour

**Depends on:** Tasks 2–12

**Files:**
- Create: `docs/guide/start/first-week.md`
- Modify: `docs/guide/README.md` (the tour as the top entry link)

- [ ] **Step 1: Write the tour.** It is a story, not a list of links: setup → first sync → Home → morning briefing / Catch Up → targets and Inbox → meetings → Workbench → automations. Each stop gives one thing to try, what you'll see, and what it needs ("needs a calendar"), with a link to the full page. Keep it under 8 KB.
- [ ] **Step 2: Run the check.** Expected: `exit=0`.
- [ ] **Step 3: Commit** with `docs(guide): first-week tour`.

### Task 15: Dissolve app-guide.md and repoint references

**Depends on:** all previous tasks

**Files:**
- Delete: `docs/app-guide.md`
- Modify:
  - `CLAUDE.md` — add a "User guide" note under Feature Notes: a user-facing change updates its `docs/guide/` page in the same PR, following `docs/guide/WRITING.md`;
  - `README.md` — link to `docs/guide/README.md`;
  - `docs/review/review-rules.md:117` — `docs/app-guide.md` becomes `docs/guide/`;
  - `.claude/team/tech-writer.md` — repoint its `app-guide.md` mentions;
  - `docs/features/automations.md` — its pending item naming `docs/app-guide.md` becomes `docs/guide/`.
- Leave alone: the dated `app-guide.md` mentions in `docs/inventory/`, `docs/superpowers/` and `docs/backlog/`, which are history.

- [ ] **Step 1: Walk the coverage ledger.** For every row, confirm the new page covers the section and the "Dropped" column is filled. Read each app-guide section once more against its page and move any reader-relevant fact still missing.
- [ ] **Step 2: Check for stray references.** Run `git grep -n "app-guide.md" -- ':!docs/inventory' ':!docs/superpowers' ':!docs/backlog' ':!docs/audit' ':!.claude/team/logs'` and edit every hit listed above. Expected after the edits: no hits except the ones listed under "Leave alone".
- [ ] **Step 3: Delete `docs/app-guide.md` and run the check.** Expected: `exit=0`. Then run `bash scripts/leak-check.sh` (or `git push --dry-run` through the hook). Expected: clean.
- [ ] **Step 4: Commit** with `docs(guide): dissolve app-guide.md into docs/guide`.
- [ ] **Step 5: Open the PR into `main`** and comment the link on board #429.
