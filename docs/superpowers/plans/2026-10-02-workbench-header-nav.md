# Workbench header navigation: workbench switcher, collapsed-panel switchers, ⌘K palette — spec + plan

**Targets:** board #249 (group) → #250 (variant F), #251 (variant H), #252 (palette from variant I). The design is owner-approved on the canvas (artboards F, H, I); this file pins the decisions and contracts, it does not redesign. The board intents of #250–#252 are the business spec.
**Branch:** `feature/workbench-header-nav`, off `origin/main`. One PR feature → main at the end.
**Delivery:** ONE Swift lane, tasks in order (T1 → T6). Inner loop per task only: `make test-swift FILTER=…` (prefer `Tests/Core`), `make lint-diff`. The full gate runs once before the PR.

## Facts that shaped the design

- The panel is two levels: `WorkbenchesView.panel` shows the workbench list, or `WorkbenchSessionsPanel` when `vm.drilledWorkbench` is set. Its header has the Back button (`vm.drilledWorkbenchID = nil`), the name and "+".
- The panel can already be hidden: `@AppStorage("projects.panelVisible")` in `WorkbenchesView`, toggled by the `sidebar.leading` button in `titleRow`. No shortcut.
- Sessions: table `terminal_sessions` (`TerminalSession`: `projectID`, `kind`, `title`, `targetID`, `lastActiveAt`). The VM caches only loaded workbenches in `terminalSessions[projectID]`; panel order is `orderedSessions(projectID:)`.
- Session state is only live / not live (`TerminalCenter.liveIDs`, `vm.isLive`). **No "waiting for answer" state exists** anywhere.
- `WorkbenchQueries.summaries` gives `openTargets`, `inProgressTargets`, unread agent comments; no blocked count, no session count, list ordered by name.
- Free shortcuts: ⌘T, ⌘1…⌘9, ⌥⌘S, ⌘⇧O, ⌘K outside Chat (ChatView's ⌘K is a button shortcut that exists only while the Chat tab is shown).
- No fuzzy ranking helper in Core; `WorkbenchBoardSearch` already parses `#163`.
- Inventory `docs/inventory/workbench.md` (PROJ-01..10): no contract governs the panel, switching or shortcuts. PROJ-01 (workbench targets reach board readers only): the blocked count stays inside the Workbench UI. PROJ-08: the palette searches session and workbench names only, never documents. PROJ-10: do not touch `TerminalCenter.hasLiveClaudeSession`.

## Decisions (fixed for this plan)

1. **No "waiting for answer" in v1.** A session is *running* (green dot, in `liveIDs`) or *not started* (hollow dot, caption "not started · <age>", age from `lastActiveAt`). Detecting "waiting" needs a Claude Code hook or terminal parsing; it is a follow-up target, raised with the owner on #251.
2. **Keys.** Panel visibility keeps the existing key `projects.panelVisible` (users keep their state; spec 2026-10-02 A1 allows legacy keys). It moves from `@AppStorage` in the view to a VM property backed by the VM's injected `defaults`, so it is testable. No other new persisted key.
3. **Switcher data (F).** One new query, `WorkbenchQueries.switcherSummaries`, per workbench: everything `summaries` has, plus `blockedTargets` (`status='blocked'` among the workbench's own targets, the same rows the board counts), `sessionCount` (rows in `terminal_sessions` with that `project_id`), `lastSessionActivity` (`MAX(last_active_at)`, may be empty). "N running" = live sessions of that workbench, from `TerminalCenter.sessionIDs(ofWorkbench:)` ∩ `liveIDs`, not from the DB.
4. **"Recent" order** = `lastSessionActivity` desc; workbenches without sessions follow, by name. The current workbench is listed in place, highlighted with a check. All workbenches are listed (no cap); the search filters by name and folder, case- and diacritic-insensitive substring.
5. **Row state text (F)**, left to right, each only when non-zero: blue badge "N new comments" (unread agent comments + revised documents, the same number as the list row's badge today); orange "N blocked"; then, with a session running, grey "N sessions · N running", else grey relative age of `lastSessionActivity` ("3d"), or nothing (artboard F). Green dot at the far right when live > 0. English one/other plural forms ("1 session", "2 sessions").
6. **Choosing a workbench** = `drill(into:)` + open its most recent session the way `openMostRecentSession` does (live-focused first, else newest `lastActiveAt`); none → the page without a session. "New Workbench…" runs the existing create flow of the workbench list. "All Workbenches" and ⌘⇧O = `drilledWorkbenchID = nil`, and show the panel if hidden.
7. **Back button is removed.** The switcher button (`▦ <name> ▾`) fills the header width; "+" stays on the right.
8. **⌥⌘S** toggles the panel (button in `titleRow` gets the help "Show/Hide Sessions Panel ⌥⌘S"). ⌃⌘S is not used.
9. **Collapsed header (H).** Only while the panel is hidden and a workbench page is shown: `titleRow` shows `[◧] ▦ <workbench> ▾ › ● <session> ▾` instead of the plain title. The workbench part opens the same popover as F (one component, two anchors). The session part shows the session in focus (`panelSelection`, else the active session), or "No session". With the panel shown, the title row is unchanged.
10. **Session popover (H)**: search "Find session" (title and `#id`); rows in `orderedSessions` order — dot, title, `#id` badge, state caption, `⌘N` for the first nine; current one highlighted; separator; "New Session ⌘T"; "Show Sessions Panel ⌥⌘S". Selecting = the same open path as a panel row click (`showFromPanel`).
11. **Shortcuts scope.** ⌘1…⌘9, ⌘T, ⌥⌘S, ⌘⇧O and ⌘K are `.keyboardShortcut`s on views inside `WorkbenchesView`, so they live only on the Workbench tab. ⌘1…⌘9 and ⌘T need a selected workbench page (disabled on a standalone terminal or the empty state); ⌘N maps to the N-th row of `orderedSessions` — the same order as the panel and the popover. They work with the panel shown or hidden. The implementer checks they fire with focus in the SwiftTerm terminal and in the Monaco Files editor; if one swallows a key, report it, do not hack the editor.
12. **Palette (⌘K, I).** A centered overlay with a dimmed backdrop inside `WorkbenchesView` (not a window), also opened by a "⌘K Go to…" button at the right of `titleRow`. Field "Go to session or workbench…". Sections: "SESSIONS · <current workbench>" (dot, title, `#id`, state) and "OTHER WORKBENCHES" (workbench rows with the F state text, and their sessions as `<workbench> › <session>`). Data: a new `TerminalSessionQueries.fetchAllWorkbenchSessions` (every row with `project_id` set, `last_active_at` desc) loaded when the palette opens, plus `switcherSummaries`. Without a current workbench (standalone / empty state) there is no first section.
13. **Ranking (`GoToRanking`, pure Core).** Fields: session title, `#<targetID>`, workbench name. Per field score: exact (case/diacritic-insensitive) 100 > prefix 80 > word-start 60 > substring 40 > subsequence 20 (all query chars in order) > no match. `#163` or `163` matches `targetID` exactly → 100. Item score = best field; +10 for items of the current workbench; ties by `lastActiveAt` desc, then title. Empty query: current workbench's sessions in panel order, then other workbenches by recency, each followed by at most two of its most recent sessions. Non-empty query: matches only, sorted by score, at most 50. Sections keep their order; ranking is within a section.
14. **Palette keys.** ↑↓ move (wrap off), ↵ open, ⌘↵ open in split, esc or click on the backdrop closes. Opening a session of another workbench = `drill(into:)` + `open` of that row; a workbench row = decision 6. ⌘↵ on a current-workbench session = new VM helper `openInSplit(session:)`: the chosen session goes to the second pane and the focused one stays (split first if not split; already shown in a pane → just focus it). ⌘↵ on another workbench's item behaves like ↵.
15. **Not in v1:** "waiting for answer", ⌘⇧[ / ⌘⇧] session cycling, searching documents or targets in the palette, reordering from the popover.
16. **UI strings are English** like the rest of the app; the canvas labels are Russian only for the owner's review.

## Tasks

Each task: commit on `feature/workbench-header-nav` in the worktree `.claude/worktrees/workbench-header-nav`; own tests green with a filter; `make lint-diff` clean; the touched section of `docs/app-guide.md` (Workbench, lines ~258–291) and `docs/features/workbench.md` (Desktop bullet) updated in the UI tasks.

### T1 — Core: switcher data (#250)
- Files: `WatchtowerCore/Database/Queries/WorkbenchQueries.swift`, `WatchtowerCore/Models/Workbench.swift` (new `WorkbenchSwitcherSummary`), new `WatchtowerCore/Services/WorkbenchSwitcherPresentation.swift`.
- Produces: `WorkbenchQueries.switcherSummaries(db) -> [WorkbenchSwitcherSummary]`; `WorkbenchSwitcherPresentation` — `ordered(_:)` (decision 4), `matching(_:query:)`, `stateSegments(summary:liveCount:)` (decision 5), Russian plural helper if none exists.
- Tests (`Tests/Core`): blocked counts only the workbench's own `blocked` targets (a `blocked` target of another workbench and a non-workbench target are not counted); `sessionCount`/`lastSessionActivity` with zero, one, several sessions; order — by last activity, no-session workbenches after by name; filter by name and by folder, diacritics; segments — each combination of comments/blocked/sessions/live, the age fallback, empty when nothing; plurals 1/2/5/11/21.

### T2 — Desktop: workbench switcher in the panel header (#250, variant F)
- Depends on: T1.
- Files: `Views/Workbench/WorkbenchSessionsPanel.swift` (header), new `Views/Workbench/WorkbenchSwitcherButton.swift` + `WorkbenchSwitcherPopover.swift` (pattern of `WorkbenchBranchButton`/`WorkbenchBranchPopover`), VM: `switcherSummaries` load + `switchTo(workbenchID:)` + `showAllWorkbenches()` (decision 6).
- Tests: VM — `switchTo` drills and opens the most recent session (live-focused first; none → no session); `showAllWorkbenches` un-drills and sets the panel visible; live counts come from `TerminalCenter`. View (ViewInspector) — header has no Back button, has the switcher and "+".
- Docs: app-guide "Sessions" paragraph (Back → switcher, ⌘⇧O).

### T3 — Core: session switcher presentation (#251)
- Files: new `WatchtowerCore/Services/SessionSwitcherPresentation.swift`.
- Produces: rows from `[TerminalSession]` (already in panel order) + live ids + now: state (running / not started + age caption), `#id` badge, shortcut index 1…9 (nil after nine), `matching(query:)` by title and `#id`.
- Tests: ten sessions → only the first nine have ⌘1…⌘9 in the given order; a live session has no age caption; not-started captions "not started · 5m / 3h / 1d"; `#233` and `233` match `targetID`; title match is case/diacritic-insensitive.

### T4 — Desktop: collapsible panel, collapsed-header switchers, shortcuts (#251, variant H)
- Depends on: T2, T3.
- Files: `Views/Workbench/WorkbenchesView.swift` (`titleRow`, panel visibility from the VM), new `Views/Workbench/SessionSwitcherButton.swift` + popover, VM: `panelVisible` (decision 2), `openSession(atShortcut:)`.
- Tests: `panelVisible` persists under `projects.panelVisible` through injected defaults and survives a new VM (the owner-required test); default is visible; `openSession(atShortcut: n)` opens the n-th `orderedSessions` row, out of range → no-op; ⌘ shortcuts disabled without a selected workbench page. View: collapsed + page → breadcrumb switchers present; shown panel → plain title.
- Manual check in the brief: ⌥⌘S, ⌘1…⌘9, ⌘T with focus in the terminal and in the Files editor; report which fire.
- Docs: app-guide panel toggle and shortcuts.

### T5 — Core: palette data and ranking (#252)
- Files: `WatchtowerCore/Database/Queries/TerminalSessionQueries.swift` (`fetchAllWorkbenchSessions`), new `WatchtowerCore/Services/GoToRanking.swift`.
- Produces: `GoToRanking.results(query:current:sessions:workbenches:...) -> [GoToSection]` per decision 13.
- Tests (the owner-required ranking test): exact > prefix > word-start > substring > subsequence on titles; `#233` hits the target's session first; a current-workbench item beats an equal-score other one; ties by recency; empty query layout (current sessions in panel order, then workbenches by recency with ≤2 sessions each); 50 cap; no current workbench → no first section; the query skips standalone sessions (`project_id` NULL).

### T6 — Desktop: ⌘K palette (#252)
- Depends on: T4, T5.
- Files: new `Views/Workbench/GoToPalette.swift`, `WorkbenchesView.swift` (overlay, ⌘K, title-row button), VM: `openInSplit(session:)` (decision 14) and cross-workbench open.
- Tests: `openInSplit` — unsplit → split with the chosen session in the second pane and the focused one kept; already split → replaces the unfocused pane; already shown → focus only. Cross-workbench open drills into that workbench and opens the row. Keyboard model (selection index moves, ↵/⌘↵/esc outcomes) as a small testable state type if the view logic grows beyond trivial.
- Manual check: ⌘K on the Workbench tab with focus in the terminal / Files editor; ⌘K in Chat still opens chat search.
- Docs: app-guide palette paragraph; `docs/features/workbench.md` Desktop bullet (switcher, collapsed header, palette, shortcuts, v1 limits — decision 1 and 15).
