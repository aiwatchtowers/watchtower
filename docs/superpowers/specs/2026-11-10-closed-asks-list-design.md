# Closed asks list — design (target #1713)

Status: design for review. Phase 1 of #1713 (spec + mockups only, no app code).

## Goal

"▸ N closed" on a session row (and the stack's "outside the app" and automations lines) must open a list the owner can actually use with 80+ asks: every ask readable, findable and one click from its read-only drawer, and back again.

## Problem (owner report)

`OwnerAskClosedButton` opens `OwnerAskClosedList` (`WatchtowerDesktop/Sources/Views/Workbench/Asks/OwnerAskClosedList.swift`) in a popover. The popover shows the header and one truncated row: its `ScrollView` has only `.frame(maxHeight: 360)`, so its ideal height is about zero and the popover collapses around it. Even with the height fixed, 81 asks in a 320 pt popover — one-line titles, no grouping, no search, and a click that dismisses the popover so the next ask means reopening it and scrolling again — is unusable.

## Context (recon, 2026-11-10)

- Data: `OwnerAskQueries.closedAsks(db, projectID:sessionID:automations:)` (status `!= 'open'`, not hidden in the spec author loop, newest first by `created_at, id`), row-by-row into `OwnerAskRows` (`problem` names unreadable rows); `closedCounts` / `closedAutomationCount` feed the "N closed" labels.
- `OwnerAsksViewModel.loadClosed` reads the list, the replacements, the counts and the automation labels in one `dbPool.read` into `closedLists[ClosedListKey]` / `closedErrors[ClosedListKey]`. It is called once, from the popover's `.task`; nothing re-reads an open list.
- `OwnerAskPresentation.askStatusLine` gives "Answered", "Delivered", "Dismissed", "withdrawn by the agent", "replaced by #N".
- A row click calls `WorkbenchesViewModel.showAsk`: drills into the workbench, reveals the ask's session (terminal or Workchat) when it has one, then `asks.openDrawer(ask)` shows it read-only in the ask drawer (`OwnerAskDrawerHost`, one drawer per workbench, `drawerAskIDs[projectID]`). The session pane hosts (`WorkbenchSessionView`, `WorkchatAskDrawerHost`) show a session's ask; `WorkbenchCoveredWorkspace` shows a session-less one over the whole workspace.
- Three entry points: `SessionsPanelFinishedGroup` / `TerminalSessionRow` (a session), `OwnerAskStackSection` (outside the app: `sessionID` nil; automations: `sessionID` nil, `automations: true`).
- The asks VM polls every 5 s (`refreshIfChanged`): its fingerprint covers the count, max id, open count, max `answered_at`, max `delivered_at` and the session-less count, so every status change and every delete re-runs `load(projectID:)`.
- Style guide: "Panels, not pop-ups … A popover is only a small picker anchored to its control." A browsable list of 80+ items is not a small picker.

## Design

### Choice: the list opens in the ask drawer, not in a popover

The closed list becomes a second thing the existing ask drawer can show. "▸ N closed" opens the drawer in **list mode**, beside the same session pane (or over the workspace for the session-less lists) where a click on a row will open the ask. A row click swaps the drawer to that ask, read-only, exactly as today, with a **‹ Closed asks** back row on top; back returns to the list with its search text, its keyboard cursor and its scroll position.

Why this over a bigger popover (decided by the agent, see Decisions):

1. It is the style guide's rule (panels, not pop-ups), and the drawer is already the place a closed ask is read.
2. It removes the popover's real cost: today every ask read means reopen + scroll + find. With back navigation the owner can go through ten asks in a row.
3. The drawer already has width (default 440 pt, resizable 320–900, Expand), so two-line titles and an answer preview fit without inventing a new surface.
4. No new window, panel or navigation concept: one more drawer mode and one back row.

The cost: clicking "▸ N closed" now navigates (reveals that session's pane) instead of floating a popover over the sessions panel. That is a behaviour change, flagged below for the owner's yes.

### Entry point (unchanged look)

`OwnerAskClosedButton` keeps its label "▸ N closed", place and help text. Its action becomes `vm.showClosedList(projectID:sessionID:automations:)`:

- a session list: the same reveal path as `showAsk` (drill into the workbench, reveal the session's pane — terminal or Workchat, whichever mode it is in — skip a session waiting in the Undo batch with the existing "That session no longer exists."), then the drawer shows the list;
- a session-less list (outside the app, automations): the workspace-level drawer host shows it.

Clicking the button while its list is already shown keeps it shown (no toggle; Esc or ✕ closes).

### The list (drawer list mode)

Top to bottom, on `Surface.text` like the ask drawer:

1. **Header** — tray icon, **Closed asks**, the count (secondary, monospaced digits; "N of M" while searching), a mini spinner while a refresh with a list on screen runs (help "Refreshing…"); under the title the scope: `Session · <session title>`, `Filed outside the app` or `Automation runs`. Trailing: the drawer's Expand and ✕ (`.kitIcon`). A hairline under the header separates it from the body (pane separation, not a row divider).
2. **Search** — a `SearchField` on a `Fill.card` capsule, placeholder "Search titles, answers, #number". Shown only when the list has 10 or more asks (`ClosedAskListModel.searchThreshold`); a short list has nothing to search. Matching is case- and diacritic-insensitive over the title, `#id`, the status chip text and the detail line (answer preview, automation label). The query lives in the VM per `ClosedListKey` for the app run (not persisted) so it survives opening an ask and coming back.
3. **Banner** (only when needed) — a `.card()` line with `Tone.warning` icon: a refresh that failed while a list is shown ("Could not refresh the list: … It shows what was read at HH:MM." + **Retry**), unreadable rows (the existing `OwnerAskRows.problem`, "2 asks could not be read (#212, #219)."), or a clicked ask that no longer exists.
4. **Day groups** — rows grouped by the local calendar day the ask was filed (`created_at`, the query's own order, so no query change): "Today", "Yesterday", then "Friday, 7 November" (year added when not the current year). Each group title is `.subheadline.weight(.semibold)` secondary with its count in tertiary; spacing separates groups, no lines.
5. **Rows** (`.kitRow(isSelected:)`, hover and keyboard-cursor fill, no separators):
   - kind icon (`OwnerAskPresentation.askKindIcon`, secondary, VoiceOver label = kind);
   - **title, up to two lines**, wrapping;
   - second line: a status `Chip` + caption "#id · detail" (one line, tail-truncated);
   - trailing: the time filed, `HH:mm`, caption monospaced digits, tertiary (the group gives the day).
6. Lazy rows (`LazyVStack` in a `ScrollView`) — 80–300 rows need no paging.

Status chip (text and `Tone.status` name):

| Ask | Chip | Tone |
|---|---|---|
| `answered` (the agent has not read it yet) | Answered | `blue` |
| `delivered` (the agent read the answer) | Delivered | `green` |
| `withdrawn`, reason `superseded` | Replaced | `gray` |
| `withdrawn`, any other reason | Withdrawn | `gray` |
| answer `dismissed` (any status) | Dismissed | `gray` |

Detail line after "#id · " (first part that applies; an automation's ask is prefixed with its "⚙ <automation> · run #N" label, `automationLabel`):

| Ask | Detail |
|---|---|
| replaced | "replaced by #N" (or "replaced by a newer ask") |
| withdrawn | "withdrawn by the agent" |
| dismissed | the note, else nothing |
| review | "Approved" / "Changes requested", then " · N comments" when any, then the note in quotes |
| question | the picked labels and the "Other" text, "; "-joined, in question order |
| check | `OwnerAskPresentation.checkSummary` ("OK 4 · Broken 1") |
| no answer stored | nothing |

The drawer footer keeps `askStatusLine` unchanged; only the list uses the short chip words.

### States

| State | When | What shows |
|---|---|---|
| Loading | no list read yet for the key, no error | header (no count), centred small spinner + "Loading closed asks…" |
| Error | the first read failed | header, centred warning icon + "Could not load the closed asks: <reason>" + **Retry** (`.kitSecondary`) |
| Empty | read OK, 0 asks (the last one was deleted, or the count was stale) | "No closed asks here yet." + hint "Asks you answer, and asks the agent withdraws, are kept here." |
| Narrow scope | fewer than 10 asks | no search field, groups and rows as usual |
| Big | 10+ asks | search field, groups, rows |
| Busy | a reload runs with a list on screen | the list stays, mini spinner in the header |
| Stale error | a reload failed with a list on screen | the old list stays under the warning banner with **Retry** |
| Partial | some rows could not be decoded | the readable rows + the `problem` banner |
| No match | the query matches nothing | "No closed asks match “<query>”." + **Clear Search** |
| Opened ask | a row was opened | the ask's read-only drawer, unchanged, with the **‹ Closed asks N** back row above its header |

### Keyboard

With the list focused (a click in it, or opened by its button): ↑/↓ move the cursor (selection fill, scrolled into view), Return opens the ask, ⌘F focuses the search, Esc clears a non-empty search, else closes the drawer. In an opened ask the back row is a button (no new shortcut; the ask drawer's own keys are unchanged). The list does not use `OwnerAskDrawerKeys`: those keys write an open ask's draft and do not apply.

### Model and strings (WatchtowerCore, pure, tested)

- `ClosedAskListCopy` — every string above (title, scope captions, placeholder, loading, empty + hint, load-failed prefix, refresh-failed with time, ask gone, retry, clear search, back, busy help, no-match, "N of M", chip words, review verdict words, comment count). Pinned one by one in `ClosedAskListCopyTests`. The design-only `ClosedAsksMockCopy` in the shots fixture is replaced by it in the implementation.
- `ClosedAskListModel.sections(asks:replacements:labels:query:now:calendar:) -> [Section]` — filters by the query, groups by local day of `created_at`, titles the groups, builds each `Row` (id, kind icon, title, chip text + tone name, detail, time). A `created_at` that does not parse goes to a last "Unknown date" group rather than being dropped.
- `ClosedAskListModel.searchThreshold = 10`.
- `ClosedAskListModelTests`: grouping across midnight and in another time zone, Today/Yesterday/weekday/date titles and the year rule, every chip row of the table, every detail row of the table, the automation prefix, search over title / #id / chip / detail / diacritics, threshold 9 vs 10, unparseable date group, "N of M".

### State (OwnerAsksViewModel)

- The drawer's content per workbench becomes `enum DrawerContent { case ask(Int64), closedList(ClosedListKey) }` in place of `drawerAskIDs[projectID]` (callers that read the ask id use a computed `drawerAskID(projectID:)`; behaviour for asks is unchanged).
- `closedListOrigin[projectID]: ClosedListKey?` — set only when an ask is opened from a list row; cleared by any other `openDrawer` (stack row, notice, terminal link) and by close. It draws the back row.
- `closedListQuery[ClosedListKey]`, `closedListCursor[ClosedListKey]` — kept for the app run.
- `closedReadAt[ClosedListKey]` — the time of the last good read, for the stale banner.
- `closedLoading: Set<ClosedListKey>` — the busy spinner.
- `closedGeneration[ClosedListKey]` — each `loadClosed` takes the next number and applies its result only if it is still the newest started read for that key.
- `load(projectID:)` (the poll after a fingerprint change) also re-runs `loadClosed` for the list the drawer shows, if any.

## Live updates, writers and races

The list never writes `owner_asks`. Everything that changes what it shows:

| Writer | Process | Change | Guard |
|---|---|---|---|
| `OwnerAskQueries.answer` (drawer, Quick ask, phone relay through `MobileHubCommandDispatcher`) | Desktop | open → answered | `WHERE status = 'open'` and not in the spec loop; a lost race changes no row |
| `handlers.storeAnswer` (`internal/hub/actions/handlers/ask.go`) | Go hub | open → answered | same guard (twin of the Swift write) |
| `db.MarkOwnerAskDelivered` (`get_ask` in `internal/tools/workbench_asks.go`, automations `sdk_ask.go`) | MCP server, daemon | answered → delivered | `WHERE status = 'answered'` |
| `db.WithdrawOwnerAsk` (`withdraw_ask`, automations) | MCP server, daemon | open → withdrawn | `ErrAskNotOpen` when not open |
| `supersedeOwnerAsk` inside `InsertOwnerAsk` (a new round) | MCP server | open → withdrawn `superseded` | only when still open |
| `db.WithdrawAsksOfEndedAutomationRuns` | daemon executor | open → withdrawn | open asks of ended runs only |
| `DeleteAutomation` and the run-delete paths (`deleteRunAsksSQL`) | CLI, daemon | ask deleted | — |
| workbench delete | Desktop / CLI | asks deleted (`ON DELETE CASCADE`) | — |
| terminal session delete | Desktop / CLI | `session_id` → NULL (`ON DELETE SET NULL`): the ask moves from the session's list to "outside the app" | — |
| spec review reveal / leave loop | CLI, daemon | a hidden ask becomes visible (`notInSpecLoop`) | — |

Who wins: every status change leaves `open` or goes answered → delivered, each a guarded single-row write, so the database decides and the first committed writer wins; the list only reflects the database. The list shows its newest completed read: the 5 s poll's fingerprint covers all of the changes above, `load(projectID:)` then re-reads the shown list, and the generation number drops any older read that finishes after a newer one. Rows only enter the list (a status leaves `open`) or leave it (delete, session delete, hidden in a loop); a row's chip can change (Answered → Delivered) while the list is open, and the next read shows it within one poll.

## Failure paths and their tests

| Path | Behaviour | Test |
|---|---|---|
| The first read throws | Error state with Retry; Retry runs `loadClosed` again | `OwnerAsksViewModelTests.testClosedListFirstReadFailureShowsRetry` (pool closed / table renamed fixture) |
| A reload throws with a list on screen | The list stays; stale banner with the last good read time; the error clears on the next good read | `testClosedListReloadFailureKeepsList` |
| Rows undecodable mid-read | The read is one transaction: readable rows shown, `problem` banner names the rest | existing `OwnerAskRows` tests + `testClosedListPartialRowsBanner` |
| Two reads overlap (open + poll) | Only the newest started read applies | `testClosedListOlderReadIsDropped` (generation applied out of order) |
| A status changes while the list is open | Within one poll the row's chip changes (Answered → Delivered) or a newly closed ask appears | `testClosedListFollowsStatusChange` (Go-side write simulated with SQL, then `refreshIfChanged`) |
| The clicked ask was deleted | `lookUp` finds nothing: the list stays, banner "That ask no longer exists.", the list reloads | `testClosedListRowOfDeletedAsk` |
| The session is deleted while its list is shown | The drawer closes (its pane is gone); the asks now count under "outside the app" | `testClosedListClosesWhenSessionDeleted` |
| The session waits in the Undo batch | "That session no longer exists." (the `showAsk` path), no drawer | `testClosedListOfPendingDeleteSession` |
| Workbench switched while the list is shown | The drawer content is per workbench: switching away and back shows the list again, re-read if the fingerprint changed | `testClosedListSurvivesWorkbenchSwitch` |
| Workbench deleted | Its asks cascade away; its drawer state, queries, cursors and lists are dropped | `testClosedListStateDroppedWithWorkbench` |
| Another ask is opened (stack row, notice, link) while the list is shown | The drawer shows that ask with no back row; the list's query and cursor stay for next time | `testOtherOpenClearsListOrigin` |
| Back from an opened ask | The list returns with its query, cursor on the opened row, scrolled to it | `testBackRestoresQueryAndCursor` |

Model tests are listed under Model and strings. Shots cover every state (below).

## Decisions

| # | Decision | Source |
|---|---|---|
| 1 | The list opens in the ask drawer (list mode) instead of a popover | decided by the agent (style guide "panels, not pop-ups"); **needs the owner's yes** — behaviour change |
| 2 | Clicking "▸ N closed" reveals that session's pane first, like a row click does today | decided by the agent; **needs the owner's yes** — behaviour change |
| 3 | Opening the list replaces whatever ask the drawer showed (its draft is kept by `OwnerAskDrafts`, as on any drawer switch) | decided by the agent; **needs the owner's yes** — behaviour change |
| 4 | "▸ N closed" keeps its label, place and help | owner (brief: keep the entry point) |
| 5 | Back row "‹ Closed asks N" in an ask opened from the list; back keeps query, cursor and scroll | decided by the agent |
| 6 | Groups by the day the ask was filed, newest first (the query's order) | decided by the agent |
| 7 | Two-line titles, status chip, answer preview line, time on the right | owner's brief (ideas list), shaped by the agent |
| 8 | Short chip words (Answered / Delivered / Withdrawn / Replaced / Dismissed) in the list; the drawer footer keeps `askStatusLine` | decided by the agent |
| 9 | Answered = blue, Delivered = green, the rest gray, through `Tone.status` | decided by the agent |
| 10 | No status filter control; search also matches the chip word ("withdrawn", "replaced") | decided by the agent (owner prefers simple) |
| 11 | Search shown from 10 asks | decided by the agent |
| 12 | Query and cursor kept per list for the app run, not persisted | decided by the agent |
| 13 | Keyboard: ↑/↓, Return, ⌘F, Esc; no new shortcut in an opened ask | decided by the agent |
| 14 | No paging; lazy rows | decided by the agent |
| 15 | In-drawer empty/loading/error blocks, not `TabEmptyState` (that one is keyed by a sidebar tab and feature readiness) | decided by the agent |
| 16 | All strings in `ClosedAskListCopy` with a test; colours only through `Tone`; no row separators; kit components only | owner's workbench rules |
| 17 | The phone is not changed (it shows the closed count only) | decided by the agent |

Flagged for a separate ask (owner did not approve them yet): decisions 1, 2 and 3. If the owner says no to 1, the fallback is the popover fixed (`.frame(width: 400, height: 520)`, same rows, groups, search and states; a row click still closes it), which this spec's model, strings and tests serve unchanged.

## Mockups

Design-only SwiftUI shots in `DesignShotCatalog` (`ClosedAsksShotFixtures`, `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+ClosedAsks.swift`, sample data only), rendered by `DesignShotsTests.testClosedAsksShotsRender`, light and dark, committed under `docs/design/mockups/closed-asks-list/`:

| Shot | State |
|---|---|
| `closed-asks-big` | 84 asks, default drawer width 440, keyboard cursor on a row |
| `closed-asks-big-min-width` | the same at the drawer's least width 320 |
| `closed-asks-search` | query "login", "N of 84" |
| `closed-asks-noMatch` | no match + Clear Search |
| `closed-asks-narrow` | automations list with 2 asks: no search, automation labels |
| `closed-asks-empty` | 0 asks |
| `closed-asks-loading` | first read running |
| `closed-asks-error` | first read failed, Retry |
| `closed-asks-busy` | reload running with the list on screen |
| `closed-asks-staleError` | reload failed, old list kept under the banner |
| `closed-asks-opened` | an ask opened from the list: back row over the unchanged read-only drawer |

## Out of scope / v1 limits

- The phone's closed list (it shows only the count).
- Paging and a status filter control.
- Next/previous closed ask from inside an opened ask (J/K stay the open stack's).
- Reordering by closed time.

## Docs

`docs/guide/` workbench asks page: "▸ N closed" opens the list in the ask panel, search, back. `docs/features/workbench.md`: the drawer's list mode.

## Open questions for the owner

1. Drawer instead of popover (decisions 1–3): OK that "▸ N closed" switches to that session's pane?
2. Group by the day the ask was filed (as now) or by the day it was closed (answered/withdrawn)?
3. Is a status filter worth a control, or is search by "withdrawn"/"replaced" enough?
