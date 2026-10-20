# Workbench header: one workbench row + a session strip

Date: 2026-10-20 · Board target #788 · Owner decisions: asks #451, #452, #455, #456 (variant 1 of the A+B mix)

## Why

The workbench page has two rows on top. The window's title row (`WorkbenchTitleRow`: panel toggle, the workbench name, Go to… ⌘K) and under it the page header (`WorkbenchPageView.header`), which packs a dozen equal-weight controls into one line: folder path, worktree crumb, branch crumb ▾, install status icon, automation buttons (e.g. **Release**), the `Terminal | Workchat ▾` twin, **Session**, **Board**, **Files**, **Analytics**, **Changes**, split, ⋯.

The owner uses two things daily: the session view (Terminal or Workchat — one session, two views of it) and the Board. Everything else is occasional. The row mixes two levels — controls that belong to *the session* and controls that belong to *the workbench* — at one visual weight, so nothing stands out.

## Goals

- One row for the workbench, merged into the window's title row: the separate page-header row disappears.
- Session-level controls move into a slim strip on top of the session's own pane.
- The daily two (session view, Board) are the most prominent controls; occasional ones are quiet icons.
- No function is lost: everything that leaves the header is reachable from the strip, a menu, or ⋯.

## Non-goals

- No new features, panes or data. The pane model (`WorkspaceLayout`, `WorkspacePane`, `WorkspaceView`) keeps its cases and persistence.
- Keyboard shortcuts unchanged (⌃` still swaps Terminal and Workchat, ⌥⌘S the panel, ⌘K Go to…).
- The standalone terminal page (no workbench) is out of scope; it keeps its current title row.
- No change to any behaviour contract (PROJ-10 branch switching, AUTO-09 header buttons only queue): controls move, their actions don't.

## Anti-goals

- A cleaner header that hides the daily controls behind a menu.
- A strip that is as dense as the old header, only lower down.
- Any control whose click does something different from today's.

## The design

### 1. Workbench row (the window's title row)

```
◧  watchtower ▾  ✓  [▤ Session | ▦ Board | </> Files]   ……   ⚡▾  ▥  ◫  ⋯   ⌕ Go to… ⌘K
```

Left to right:

- **◧** panel toggle — unchanged (with the back button when the panel is hidden, as today).
- **Workbench name** — today's title / `WorkbenchSwitcher` (the switcher as today when the panel is hidden). Help text carries the full folder path. The separate folder-path crumb is gone; **Show in Finder** moves into the ⋯ menu.
- **Install status icon** (`WorkbenchInstallStatusIcons`) and the install spinner sit right after the name: they describe the workbench, not the branch.
- **View tabs** — one `SegmentedToggleStyle` capsule with three toggles:
  - **Session** — lit when the pane shows any session view (terminal, Workchat, report, changes). Turning it on shows the session pane in the mode it was last in (`WorkspaceLayout.workchatSessions` decides terminal vs Workchat); turning it off closes that pane of a split, as today's Terminal toggle does.
  - **Board**, **Files** — exactly today's toggles.
  - In a split two tabs can be lit, as today.
- Spacer.
- **⚡▾ Automations** — one `.kitIcon` menu holding every `trigger.button` recipe of the workbench (today's `WorkbenchAutomationButtons` visible + More, now all in one list, slug order), then **New Automation…**. Each item keeps today's click semantics (queue only, `confirm: true` asks first, active run opens the run, needs-confirmation opens the sheet, broken/disabled opens the card) and help texts. While any of them has an active run the icon shows the running state (spinner or accent) so a running Release is still visible at a glance. Failure alert unchanged.
- **▥ Analytics** — `.kitIcon(isOn:)` toggle for the Analytics view (today's Analytics segment).
- **◫ Split** — today's `splitToggle`.
- **⋯** — today's `moreMenu`, plus **Show in Finder** at the top.
- **⌕ Go to… ⌘K** — unchanged.

Install error and archive-setting error captions stay, as a caption line under the row (as today under the page header).

### 2. Session strip (on top of a session pane)

```
ses…header ▾   ⑂ fix/connections-settings… ▾   [Terminal | Workchat]   Report   Changes        ⤢ ✕
```

Shown on every pane whose content belongs to a session: `.session`, `.sessionChat`, `.sessionReport`, `.changes` — in a single pane and in a split.

- **Session name ▾** — the sessions menu that today hangs off the Terminal|Workchat twin's chevron (`sessionMenu`: other sessions, New Session items). It also replaces the title row's `SessionSwitcher` that appears when the panel is hidden.
- **Place + branch** — today's `WorkbenchPlaceCrumb` and `WorkbenchBranchCrumb` (worktree, branch, dirty mark, ahead count, branch popover), unchanged in behaviour; they already resolve against the shown session's worktree (#565).
- **[Terminal | Workchat]** — a small capsule; swaps the pane's view of the same session (today's twin minus the chevron).
- **Report**, **Changes** — quiet toggles calling today's `showView(.report / .changes)` / `hideView`, so a split behaves exactly as today (report beside its session's terminal, etc.). Changes stays disabled with no session, as today.
- **⤢ ✕** — in a split only: today's split-pane header expand/close move here.

### 3. Other panes in a split

Board, Files and Analytics panes get a strip only in a split — today's split-pane header (`WorkspacePaneView.header`: picker, expand, close) restyled to the same height and look as the session strip. A single Board/Files/Analytics pane has no strip: the lit tab says what it is.

### 4. Look

Built from the design kit (`docs/design/desktop-style-guide.md`): tokens only, `.kitIcon` for icons, `SegmentedToggleStyle` for both capsules, `.caption` text in the strip, a hairline under the strip. The strip is visibly lighter than the title row (smaller controls, secondary text, no prominent action) — it must not read as a second header.

## Calls made without the owner (check these)

1. Board/Files/Analytics show a strip only in a split.
2. Show in Finder moves to ⋯; the path lives in the name's help text.
3. The install status icon moves next to the name (it is the workbench's install state, not the branch's).
4. The ⚡ menu shows the running state on its icon; no pinning of single automations to the row in this version.
5. The session strip's sessions menu replaces both today's twin chevron and the panel-hidden title-row `SessionSwitcher`.
6. **Changes (N)** badge from the mockup: shown only if a changed-file count is already loaded without a new git call per poll; otherwise left out of this version.

7. **Session tab lit rule.** Lit when at least one visible pane shows a session view (`.session`, `.sessionChat`, `.sessionReport`, `.changes`). In a single pane the three tabs behave as a picker: clicking an unlit tab replaces the pane, and clicking the lit tab does nothing, so the page is never left empty. In a split they toggle as today: turning a tab on shows its view beside the other pane. Turning Session off closes the session pane or panes and leaves the other pane single. With no session, turning Session on does what today's Terminal toggle does with none (`showView(.terminal)` and its empty state). Like today's Terminal toggle, it opens the most recent session, or starts one when the workbench has none (controller ruling during implementation, ask #459).
8. **One strip per pane.** Each session pane's strip acts on that pane's own session and slot: its sessions menu replaces that slot (today `sessionMenu(slot:)`), and its Terminal | Workchat swaps that pane only. In a split of `.session` + `.sessionChat`, each strip lights its own half. ⌃` keeps today's target.
9. **Branch and place crumbs** stay keyed to `vm.activeCodeRoot(project:)` as today, so there is one instance. They render on the strip of the pane whose session owns that root. A second session pane in a split shows its name and controls without crumbs. Per-pane crumbs are a follow-up.
10. **Session strip has no pane picker.** In a split, a session pane changes content through its sessions menu (another session) or ✕ plus a title-row tab. Board, Files and Analytics strips keep today's picker.
11. **Panel hidden + Board-only single pane.** No session switcher shows in the title row. The panel toggle (◧) and the Session tab are one click away. Accepted.
12. **Dead code goes.** The twin's chevron joining (`joinsChevron`, `chevronHovered`, the chevron branch of `SegmentedToggleStyle`) is removed if nothing else uses it.
13. **⚡ menu.** The "any active run" signal is a new accessor on `AutomationsViewModel` over `headerButtons(projectID:)`. The confirm alert and failure alert are owned by the ⚡ menu view, as they are owned by `WorkbenchAutomationButtons` today. Every state maps to a menu item action, and `testAuto09_HeaderButtonOnlyQueues` is repointed at the item without being relaxed.
14. **Where the row is built.** `WorkbenchTitleRow` is shared with the standalone terminal page. The new controls render only when a workbench page is shown, and the standalone page is unchanged. The page-owned state (delete confirm, sweep sheet, New Automation, the error captions) either moves up with the controls or is published by the page. That choice stays with the builder (see below).

## Left to the builder

- Exact widths, truncation priority (name and branch truncate first, tabs never), and whether the strip hides Report/Changes labels behind icons in a narrow pane.
- How `WorkbenchTitleRow` gets the page's controls (moving `WorkbenchHeaderControls` up into `WorkbenchesView`, or the page publishing them).
- Tests: update `WorkbenchHeaderControlsTests` and `WorkbenchHeaderAutomationButtonsTests` to the new places; `testAuto09_HeaderButtonOnlyQueues` must keep asserting exactly `automations run <id> --json` from the menu item (guard not relaxed). Add a pure test for the Session tab's lit rule.
- Docs: `docs/features/workbench.md` and `docs/features/automations.md` (header buttons → ⚡ menu), `docs/guide/` page for the workbench header, and an inventory changelog note in `docs/inventory/workbench.md` / `automations.md` (controls moved, no contract changed). Screenshots with `make desktop-shots`.
