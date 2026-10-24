# Automations tab polish — list like Chats, built-in descriptions, draft save, chat scroll, editor tools

**Date:** 2026-10-24 · **Board:** #929 (under #405) · **Owner decisions:** ask #527 · **Mockup:** https://claude.ai/artifact/SZFgLSAgcX3F3USpahoqKD (Russian sample copy; the app's copy stays English)

## Why

The owner's review of the Automations tab (screenshot of 2026-10-24) found six problems:

1. The left list does not look like the rest of the app. Chats and the Workbench sessions panel share one panel shape; Automations draws its own.
2. Built in, Personal and every workbench are flat sections. With many workbenches the list grows without bound.
3. The built-in automations explain themselves poorly: the list shows only a trigger, and the card does not say plainly what the automation does.
4. **Bug:** pressing Save on a draft opens the new automation, but the draft row stays in the list. The screenshot shows "TO DO на неделю вперёд" twice: the draft and the saved automation.
5. The editor chat lags while scrolling.
6. The editor chat cannot see what it needs to fix a recipe. For example, it cannot see the last run's error.

Two follow-ups from the owner on the mockup: drop the "New automation" row (the header's **+** is enough), and give every row extra facts plus a very short description. The draft column needs a button that hides it.

## Goals

- **G1** The list panel matches Chats and the Workbench sessions panel. It uses the same surface, tab-style rows and section labels.
- **G2** Built in, Personal and each workbench are collapsible groups. The app remembers which ones are collapsed.
- **G3** Each row shows three things: its state, a very short description, and its trigger plus one fact.
- **G4** A built-in's card says in plain words what it reads, what it does and where the result lands.
- **G5** Saving a draft removes its draft row.
- **G6** The editor chat scrolls smoothly. The fix is chosen from a measurement, not a guess.
- **G7** The editor chat can read four new things, all read-only:
  - this automation's run history;
  - the data a recipe can read;
  - the Slack channel list;
  - other recipes and Confluence pages.
- **G8** The editor's draft column can be hidden and shown, and the choice is remembered.

## Non-goals and anti-goals

- **No Quick Connections on the editor surface.** The owner did not pick them in ask #527, so D11 stays as it is.
- **No write tool is added to `automation_editor`.** `save_automation` stays its only write.
- **No change to the approval hash.** A summary edit never needs the owner's confirmation again.
- **No new list row kinds.** No "New automation" row, no template rows.
- **Anti-goal:** a row so dense that the list stops being scannable. Each row is three short lines at most and each line is one line, truncated.
- **Anti-goal:** a description field the owner must fill in. Per the "prefer simple designs" rule, the assistant writes it, and when it is missing the app derives one.

## Design

### 1. List panel (G1, G2, G3)

**Shape.** The panel is the Chats and Workbench panel (`panelSurface()`, `PanelTab`, `sidebarSectionLabel()`):

- **Header row:** "Automations" with **+**, the same New flow as today.
- **Search field:** stays.
- **List:** a plain `List` with `.clearPlainList()` and no List selection.
- **Selected row:** a `panelTab(isSelected:)` that runs into the detail. The other rows use the faint hover fill.
- **Removed:** the old `kitRow` look and the `SectionHeader` with an icon.

**Groups.** The groups are:

- **BUILT IN**
- **PERSONAL**
- one group per workbench, labelled with the workbench name in upper case

Each group header has:

- a chevron (▾ open, ▸ collapsed) and a count;
- a short attention suffix when collapsed, made only from what the group holds: `1 failed`, `1 draft`, `1 needs confirmation`.

A click on the header toggles the group.

The order stays as `AutomationListSections.make` has it. Empty groups are still omitted.

**Collapse state:**

- **Storage:** a set of section ids in `UserDefaults` (`automations.collapsedSections`). This is per-viewer UI state. It follows the house pattern of `projects.boardFoldedLanes.<id>`.
- **Default:** every group starts expanded.
- **Search:** while the search text is non-empty, every group with a match shows expanded. The stored set is not changed. Clearing the search restores it.
- **Selection:** when the selected automation or draft sits in a collapsed group (opened from the Inbox, a notification or auto-select), that group expands and the expansion is stored.

**Row (three lines).**

1. The on/off dot, the name, and on the right a compact state. This line shows one of:
   - a chip when there is one (Draft, Needs confirmation, Paused, Can't read; same precedence as today);
   - otherwise `failed` in the warning tone when the last run failed;
   - otherwise `off` for an off recipe;
   - otherwise the last run's outcome and its age (`ok · 2 d`);
   - otherwise the next run (`in 26 min`).
2. The very short description (§2), in secondary colour, one line, truncated.
3. Today's row detail line (`AutomationCardPresentation.rowDetailLine`), meaning the trigger and its fact: last run, next run, tokens this week for a built-in, or the error.
   - When the last run failed, the line is in the warning tone and leads with the error.
   - It is one line, truncated.

A draft row keeps its dashed dot and the **Draft** chip. Its line 2 is the draft's summary when the draft has one, else its derived description. Its line 3 is "Not saved · edited N ago".

Rows have no context menu in this change. Keyboard behaviour stays as it is.

### 2. Short description: `summary` (G3)

- **Frontmatter key.** A recipe may carry an optional top-level `summary:` key: plain text, at most 60 characters (runes), one line.
  - Go adds it to `topLevelKeys` and to the `Recipe` struct.
  - Validation refuses a summary that is too long or has more than one line, with the line number, like other field errors.
  - It is **not** in `approvalCanonical` (the same as `name` and the description), so it never asks for confirmation again.
- **Who writes it:** the assistant. The `create-automation` skill and the editor surface prompt say: always write `summary`, a few words, what it does rather than when.
- **Swift form path.** The form path (`RecipeFrontmatter`) reads `summary` and writes it back unchanged. A Form or Script save must never drop it. There is no form field for it in this change.
- **Built-ins:** each built-in recipe ships a `summary`, for example:
  - Morning brief: "Your brief and day plan"
  - Track my threads: "Slack threads waiting on you"
  - Idea finder: "Ideas and decisions from your talk"
  - Reactions: "A Slack emoji → an action"

  The shipped text changes, so the confirm path for shipped bytes applies as it does for any shipped-text update (`ConfirmShippedBuiltin`, `upgrade-builtins`). The builder checks that an overridden copy is not disturbed.
- **Fallback when there is no `summary`:** the first sentence of the recipe's description, cut to 60 characters on a word boundary with "…". When there is no description either, line 2 is omitted and the row has two lines.
- **Where it is computed:** in Swift, from the indexed `recipe_text` the list already reads. The summary and the fallback live in WatchtowerCore with unit tests. No migration is needed.

### 3. Built-in card description (G4)

At the top of the card, under the header:

- **Lede:** one plain sentence, which is the recipe's description.
- **Three boxes in a row:**
  - **Reads:** the existing `reads`, rewritten as a short list.
  - **Does:** new `does []string`, the steps in order.
  - **Result:** the existing `sends`, plus a link that opens the Inbox filter where the result lands.
- **Below them:** today's When, Last run and Costs boxes, then the history.

Go changes in `builtin.Entry`:

- add `Does []string`;
- add `ResultFilter`, which is the Inbox filter the result lands in: `day` / `tracks` / `ideas` / `automations`;
- rewrite `Reads` and `Sends` copy for all four entries;
- emit both new fields in `CardInfo` (`does`, `result_filter`), with non-null slices;
- update the pinned `testdata/show_morning_brief.json`, which the Desktop tests read too.

The link uses the existing Inbox navigation. It changes no state.

### 4. Draft save removes the draft row (G5)

**Cause:** a new draft's save finishes in `AutomationEditorPanel.finish` → `editor.discard(key)` + `onSaved(id)`. The draft's cache file `<workspace>/automation-drafts/<conversation id>.jsonl` is never removed. `AutomationDraftRows` therefore keeps listing it.

**Required behaviour:**

- When a new draft's save lands, its cache file is removed and its row leaves the list at once.
- This holds on every save path:
  - the draft column's Save / Save and Turn On / Save Turned Off;
  - an approved `save_automation` proposal from the editor chat;
  - a save that lands while the panel is away (`settleUnwatched`).
- The selection moves to the saved automation as today. It must not drop to the empty panel, which `discardDraft`'s `select(nil)` would do.
- A save that fails, or that lands with a later step failing, keeps the draft.

**The draft's chat carries over (owner, ask #528).** The conversation that wrote the automation becomes the saved automation's editor chat. Opening the automation shows that conversation, and the owner continues it there.

- **How:** one write re-keys the draft's `chat_conversations` row from `context_type='automation_draft'`, `context_id=<draft key>` to `context_type='automation'`, `context_id=<new automation id>`. It runs on every save path listed above, in the same step that removes the cache file.
- **When the automation already has a conversation:** this should never happen for a new id. If it does, the draft's conversation wins only when the automation's conversation has no messages. Otherwise the draft keeps its key and is only unlisted, and nothing is merged or deleted.
- **Live engine:** the draft's `EmbeddedChatKey` may still hold a live engine, for example a `save_automation` approved while the turn still streams. The re-key waits until that engine is idle. Then the center drops the draft engine, and the automation's chat opens on the same conversation id, so it never runs two engines on one conversation. A save that lands with the panel away re-keys at once, because no engine is live.
- **Prompt:** from its next turn the carried-over chat gets the existing-automation prompt (its id, the recipe re-read from the index). The earlier turns stay as they are.

The test reproduces the bug first: a draft row exists, the save lands, and the row is still listed. The carry-over gets its own tests:
- after a save, the automation's chat holds the draft's messages;
- a streaming turn finishes before the re-key;
- a failed save leaves the conversation keyed as a draft.

### 5. Editor chat scroll (G6)

`ChatFeedView` is shared by the main chat and every embedded chat. The research found suspects but did not measure them:

- **(a)** `MarkdownView` builds an `AttributedString` and strips links on every body pass. A LazyVStack row that scrolls back into view pays this cost again. Tables pay it per cell.
- **(b)** `.textSelection(.enabled)` sits on the whole markdown tree.
- **(c)** The content-frame `GeometryReader` preference runs follow-state work on every scroll tick.
- **(d)** `AutomationEditorPanel` rebuilds the `EmbeddedChatView` with new closures whenever editor state changes, and recomputes the footer and proposal cards.
- **(e)** `EmbeddedChatRows` does O(n²) look-ups per pass.

**Required:**

- Profile a long editor thread (Instruments, SwiftUI + Time Profiler) both while it streams and while it is static, and compare it with the main chat at the same length.
- Fix what the profile shows. For (a), the expected fix is to memoise the inline attributed text per block, the same way block parsing is already memoised.
- Fixes in shared code help every chat, so the main chat's behaviour must not change: the same rendering, link rules (`AllowedURLSchemes`) and selection.
- **Acceptance:** scrolling a 100-message editor thread with long markdown answers holds the display frame rate on the owner's machine. The before and after profiles are recorded in the PR.

### 5b. Native text for finished messages (owner, ask #539)

Measurement in §5 showed the remaining scroll cost lives inside SwiftUI and AppKit: every selectable SwiftUI `Text` (11–20 % of a scroll step), table `Grid` layout (~6 %) and each table's own horizontal scroll view (~3 %). The owner chose to fix it in this branch.

- **What changes.** A *finished* answer's runs of prose are drawn by one non-editable, selectable `NSTextView` (TextKit 2) per run, instead of one SwiftUI `Text` per block. A run is the stretch of paragraphs, headings, lists and block quotes between blocks that keep their own views (code blocks, tables, artifacts, step blocks, question and action cards).
- **What stays.** A message that is still streaming keeps today's SwiftUI path, and switches when it completes. User bubbles, code blocks and cards are unchanged.
- **Tables.** A table that fits the column width gets no horizontal scroll view. Only a table wider than the column keeps one.
- **Same look.** The fonts, sizes, colours (light and dark), list markers, heading weights, inline code, block-quote bar and spacing match the current rendering. The builder compares screenshots of the main chat before and after and records them in the PR.
- **Same rules:**
  - Links go through `AllowedURLSchemes` exactly as today.
  - `watchtower-nav://` links open through `AppState.openNavLink`, never `NSWorkspace`.
  - Code-reference links keep their popover.
- **Selection gets better.** Selection works within a run and across its paragraphs, and ⌘C copies plain text. "Ask about this" (`ChatSelectionQuote`) keeps working: it reads the selection from the run's own text view instead of the field editor.
- **Accessibility.** VoiceOver reads the run as text, with its links reachable.
- **Height.** The text view reports its height for the width it is given (`sizeThatFits`), so `LazyVStack` rows measure correctly and do not jump when they scroll back in.
- **Acceptance.** On the 100-message benchmark (`ChatScrollBenchmarkTests`, `WT_BENCH=1`), the selectable-text share of a scroll step drops clearly below today's 11–20 %. The p90 scroll step is recorded before and after in the PR. Then the owner checks by scrolling a long editor chat.

### 5c. Tables as one native view (owner, ask #541)

After §5b, most of the remaining scroll cost is selectable table cells. Each cell is its own selectable SwiftUI `Text`, and the benchmark answer has 28 of them. The owner chose to draw a finished answer's table as **one** native, selectable, non-editable text view. A streaming answer keeps today's table.

- **Look:** the same as today: header row weight, column alignment, cell padding, grid lines or row separators, light and dark. The builder compares before and after screenshots.
- **Selection:**
  - selection works inside a cell and across cells and rows;
  - ⌘C copies plain text, with tab-separated cells and one line per row;
  - "Ask about this" works on a table selection as it does on a run.
- **Links in cells:** they go through the same gate as runs (`AllowedURLSchemes`, `openNavLink`, gated Open Link in the menu).
- **Width:**
  - a table that fits the column has no scroll view;
  - a wider table keeps one horizontal scroll view around the single text view;
  - the height comes from `sizeThatFits` without probe-width side effects, the same rule as runs.
- **VoiceOver:** reads the table, rows and cells in order.
- **Acceptance:** on the benchmark, with the per-step run-loop pass timed, the ChatFeedView p90 approaches the non-selectable-cells experiment (about 20 ms). The streamed-delta guard still passes. The before/after numbers are recorded.

### 6. Editor draft column toggle (G8)

A toolbar-style icon button sits at the right end of the editor header:

- **Icon:** `sidebar.right`.
- **Help text:** "Hide Draft" / "Show Draft".
- **Shortcut:** ⌥⌘0, scoped to the Automations tab.

It hides the draft column and the chat takes the full width. The choice is stored in `@AppStorage("automations.draftColumnHidden")`.

While the column is hidden, a save still needs it. When there is something to save, the header shows a compact **Save** button that opens the column. It never saves blind, because the column is where the owner sees what will be saved.

### 7. Editor chat tools (G7)

These are all read tools on `automation_editor`. Each joins the AGENT-06 read-only guard list.

- **Run history**, new `list_automation_runs` and `get_automation_run`:
  - **Arguments:** `list_automation_runs` takes an automation id or slug and returns the newest N runs (default 10, at most 50): id, trigger, status, start and end, tokens, error summary. `get_automation_run` takes a run id and returns its steps (kind, status, error, a size-capped result summary) and its outputs (kind, title, a capped body).
  - **Surfaces:** `main` and `automation_editor`.
  - **Data fencing:** outputs and step results may carry external text, so they go back as data under the existing tool-result rules. The tool never inlines them into the prompt in any other way.
  - **Prompt line:** on an existing automation's chat, the prompt names its id, so "why did it fail" works without asking.
- **What a recipe sees:** the automation-only reads get `automation_editor` added to their `Surfaces`:
  - `list_inbox`, `list_calendar_events`;
  - `list_meeting_recaps`, `get_meeting_recap`, `list_meeting_notes`;
  - `list_day_plans`, `get_day_plan`, `list_reminders`;
  - `list_jira_sprints`, `list_jira_releases`;
  - `list_emails`, `get_email`;
  - `list_linear_cycles`.

  `main` gets nothing new from this group. Adding them there is a separate decision.
- **Slack channels**, new `list_slack_channels`:
  - **What it returns:** the synced channels per Slack account, with id, name, kind (public, private, DM, group), member flag and last activity, from the local database. No network.
  - **Surfaces:** `main` and `automation_editor` only (author's call). Putting it on the `automation` surface would need a manifest permission for it (D21/D22 territory, owner rulings), so recipes keep their gap until that is decided separately.
- **Other recipes**, new `list_automations` and `get_automation`:
  - `list_automations` returns name, slug, scope, workbench, trigger and enabled.
  - `get_automation` returns the indexed recipe text and its parse error.
  - **Surfaces:** `main` and `automation_editor`.
  - **Scope (author's call):** no scope filter. Every editor chat, and `main`, may read any of the owner's automations and their runs (not removed ones), exactly what the owner can open in the tab. This matches the existing read tools on the surface, which already read all of the owner's data; it needs no binding plumbing and changes no AGENT-04 guard. The same holds for `list_automation_runs` / `get_automation_run`: they take any automation id or slug and any run id, and a new-draft chat may read them too.
- **Confluence:** `get_confluence_page` gets `automation_editor` added to its `Surfaces`. It is a live network read, as on `main` and `target`.

**Contract updates in the same change:**

- `TestAutomationEditorSurface_MountsOnlyDraftSaveAndReads` keeps asserting that `save_automation` is the only write. It now also expects the new reads.
- The `actions_contract_automation_editor.txt` fixture changes only if the action-tool list changes. It should not.
- AGENT-04 gets a dated note in `docs/inventory/agent-actions.md` saying that more reads were added and the surface still has one write. This is not a relaxation.
- `docs/features/automations.md` is updated.
- The user guide page for the editor chat lists what it can look at.

## Constraints

- Swift follows `docs/review/review-rules.md` (the Swift / Desktop conventions) and the design kit. Run `make desktop-shots` before review.
- Go and Swift dual paths:
  - The summary length rule (60 runes, one line) exists in Go validation and in the Swift fallback cut, with tests on both sides.
  - The card JSON keys are pinned by the shared testdata.
- Public repo hygiene: sample names in tests and docs are neutral.
- The inner loop is per CLAUDE.md, and the full gate runs once before the PR.

## Left to the builder

- Exact copy for the four built-ins' Reads / Does / Result and summaries, within the meaning above.
- How the compact state on row line 1 and the trigger fact on line 3 avoid saying the same thing twice. Line 1 is state; line 3 is trigger and detail.
- The memoisation shape for the scroll fix, once the profile is in.
