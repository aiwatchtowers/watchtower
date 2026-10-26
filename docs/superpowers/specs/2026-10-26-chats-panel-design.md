# Chats — the chat panel shaped like the Workbench sessions panel, a project switcher, a new project page

**Date:** 2026-10-26
**Board:** #1095 (under #518)
**Mockups:** [docs/design/mockups/chats-panel/index.html](../../design/mockups/chats-panel/index.html)
**Status:** draft for the owner's review

## 1. Why

The main chat's tab is called "AI Chat" and its left panel is a plain list: a "Chats" title, a "New chat" row, a PROJECTS section with a `+`, then date sections (Today / Yesterday / Previous 7 Days / …). A row is a title and nothing else: the panel does not say which chat is answering, which one waits for an Approve, or which one has an answer the owner has not read. The project page (`ProjectDetailView`) is one long form — name field, instructions editor, files, pinned sources, chat links, a Delete button — with no obvious "start a chat here".

The Workbench sessions panel already solves the same problem for agent sessions: a header that is a switcher, rows with a live state dot and a second line, quick delete with Undo, a keyboard, a folded group for old rows. This work gives the chat the same shape, adapted to chats.

## 2. Scope

1. **Rename** the tab and every user-visible "AI Chat" to **Chats**.
2. **Panel header**: the project switcher (`‹ 📁 <project> ⌄` / `All chats ⌄`) and `+`.
3. **Rows**: a state dot, the title, a second line (state or the last answer's start + age); ✕ on hover with Undo; the panel keyboard.
4. **Groups**: PINNED, RECENT, then a folded "▸ N older".
5. **Project page**: name + ⋯ menu, a new-chat composer, the project's chats, Instructions and Knowledge cards.

Out of scope: chat search (⌘K stays as is), archive view, the phone, any Go-side chat behaviour, the embedded/Discuss chats, the ⌘/ help popup (it keeps its own panel).

## 3. Rename: AI Chat → Chats

- `SidebarDestination.chat.title` → "Chats". The raw value `chat`, the `watchtower-nav://chat` screen name, `EmptyStateCopyTable` keys and every stored identifier stay (persona-merge rule: stable legacy identifiers).
- Every user-visible string that names the tab ("Open in AI Chat", "the AI Chat tab", the shortcut catalog's area "AI Chat", help/tooltips, Inbox card buttons) says "Chats" / "Open in Chats". Code comments and type names are not renamed.
- The guide: pages keep their paths (`docs/guide/features/ai-chat*.md` — Learn cards and `guide.Map()` link by path); their text and titles say "Chats". `docs/inventory/chat.md`'s title says "main chat (Chats tab)"; no contract changes.
- Go prompts that name the tab for the model (`appGuideSection`, the nav rule) follow the guide; if any Go string says "AI Chat" to the user it changes too. The main chat's system-prompt golden (`internal/chat/testdata/system_prompt_main.golden`, which lists the guide's page titles) is regenerated with the new titles.
- The guide also **describes the new panel**, not only the new name: the switcher and the two levels, the row states, delete with Undo, the keyboard, the older group and the project page (`docs/guide/features/ai-chat.md`, the shortcuts reference).

## 4. Panel header and the project switcher

The panel has two levels, like Workbench (level 1 = all workbenches, level 2 = one workbench):

- **All chats** (default): header `All chats ⌄` + `+`. No `‹`. The list shows every chat, projects' chats included (as today).
- **A project**: header `‹ 📁 <name> ⌄` + `+`. `‹`, ⌘[ and the popover's **All Chats** go back to All chats. The list shows only that project's chats, with a first row **Project overview** (folder icon) that opens the project page.

The `⌄` opens a popover modelled on `WorkbenchSwitcherPopover` (mockup board 2, column 1):

- **Find project** field, focused on open; filters by name.
- **RECENT**: projects, most recently active first (latest `updated_at` among the project's chats, else the project's own `updated_at`). The current one checked and highlighted. Under each name its state segments, from its chats: a blue badge "N new answer(s)" (unread, §5.2), orange "N waiting for approval", grey "N answering"; with none of those, the age of its last activity ("8d").
- Divider, **New Project…** (`folder.badge.plus`): creates an untitled project and opens its page with the name field focused (today's `createProject(name: "")` flow).
- **‹ All Chats**.

`+` in the header: a new chat (⌘N, the landing) — in the current project when one is selected (the landing composer creates the conversation with that `project_id`).

**⌘[** today exists only as the Workbench menu's **Back to Workbenches** item (`WorkbenchCommands`, enabled by `context.backAction(popAvailable:)`: pop a Workchat subagent first, else the workbench list). Like ⌘1…⌘9 (§5.4), it becomes **one** shared item, **View → Back** (⌘[), resolved by the same pure function: the workbench context → its existing `backAction` (unchanged behaviour, including the subagent pop), the Chats context → back to All chats while a project is selected, otherwise disabled. The Workbench menu loses the item; its title in the help/shortcut catalog stays "Back to the workbench list" under Workbench and gains "Back to All chats" under Chats. As today, the Files editor (Monaco) keeps ⌘[ inside it.

The PROJECTS section of the list goes away; projects live only in the switcher. The selected level (All chats or project id) is remembered across launches (UserDefaults, per workspace), falling back to All chats when the project is gone.

**Implementation note:** the popover shares its look with the workbench one. Extract the row and segments views into a shared DesignKit-level piece (`SwitcherPopoverRow` + the existing `WorkbenchStateSegments` generalised over a tone enum) rather than copying them; the chat twin owns its own data (`ChatProjectSwitcherPresentation` in WatchtowerCore: ordering, matching, segments — pure, tested).

## 5. Rows

### 5.1 Layout

A row is the `TerminalSessionRow` shape: a 16 pt dot column, then two lines.

- Line 1: the title (`displayTitle`), one line, tail-truncated; semibold while unread.
- Line 2 (`caption2`, secondary), by precedence:
  1. waiting for approval → "Waiting for approval: <tool's short label>" (orange);
  2. answering → "Answering…" (accent colour);
  3. otherwise the first line of the last assistant message on the active branch, markdown stripped, plus " · <age>" ("2h", "yesterday", "4d" — the sessions panel's age formatter). In All chats a project chat prefixes its project name ("Project A · …").
  A chat with no answer yet shows only the age.

### 5.2 State dot

| State | Dot | Source |
|---|---|---|
| waiting for approval | orange, filled | a `pending` `agent_actions` row with this `conversation_id` |
| answering | accent, pulsing | `ChatSessionPool.runningTurnID(conversationID:) != nil` (observable `clients`) |
| unread | accent, filled | the last complete assistant message is newer than `chat_conversations.read_at` |
| read | hollow grey ring | otherwise |

Precedence top to bottom: waiting for approval > answering > unread > read. The dot has an accessibility label naming the state; the line-2 text is not repeated to VoiceOver when it says the same.

**Read state (new):** migration `00161_chat_read_at.sql` adds `read_at REAL` to `chat_conversations` and sets it to `updated_at` for every existing row (no chat lights up as unread on upgrade). Swift is the only writer (as for every chat table): a conversation shown on screen is marked read when it is selected and again when a turn finishes on it while shown. A turn that finishes on a chat not on screen leaves it unread. Mirrored into `schema.sql`, the snapshot and the generated Swift test schema.

The rows read their line 2 and the unread/approval state through one query (`ChatHistoryQueries.panelRows`) — one pass over `chat_conversations` with correlated subqueries for the last assistant message and the pending-action count — observed with `ValueObservation` like today's list. "Answering" comes from the pool, not the database.

A pending `agent_actions` row is written by the session's MCP subprocess (Go), which a `ValueObservation` in this process does not see. The panel therefore also re-reads its rows when a proposal was just written and when a turn finished — and an Approve/Reject in the app is a Swift write the observation sees.

These signals are single closures, each with one owner: `ChatSessionPool.onActionAwaited`/`onTurnFinished` are assigned by `ChatViewModel` (its init), and `ChatViewModel.onActionAwaited`/`onTurnFinished` are assigned once in `AppState+Chat.swift` (they refresh the action strip). Nothing new assigns any of them — that would silently replace the existing handler. The panel's refresh is added **inside the existing `AppState+Chat.swift` closures**, next to the action-strip refresh (`chatHistoryViewModel.reloadRows()`), and a test pins that both still run.

### 5.3 Delete with Undo

- Hover (or the keyboard cursor) shows ✕ on the row. A click deletes at once and shows the Undo bar under the list (the `SessionDeleteToast` shape): "Chat “…” deleted · Undo ⌘Z". The real `DELETE` runs when the bar times out (same delay as sessions), another delete replaces it, or the tab is left/the app quits.
- A chat that is answering or waiting for approval shows no ✕; its context menu Delete… keeps the confirmation alert.
- The context menu stays: Rename…, Pin/Unpin, Move to Project, Archive, Delete….

### 5.4 Keyboard

As in the sessions panel, once a click on the panel's empty space, a label or the group header gives it the keyboard: ↑/↓ move a cursor (focus ring), Return opens, ⌘⌫ deletes the highlighted chat (with Undo), ⌘Z undoes, ⌘1…⌘9 open the first nine rows of the list (while the Chats panel is visible).

⌘1…⌘9 are already the Workbench sessions' menu items (`WorkbenchCommands`, "Sessions" menu). Today they are enabled by the Workbench tab's focused scene value (`@FocusedValue(\.workbenchMenu)`, published by `WorkbenchesView`) through `WorkbenchMenuContext.canUseSessionKeys` (no Go to… palette open and a workbench page shown), and `pageTakesKeys(keyWindow)` checks at fire time that the page's window itself is key. Two menu items with the same key equivalent would race, so there stays **one** set of ⌘1…⌘9 items:

- `ChatView` publishes its own focused scene value (`\.chatsMenu`, a `ChatsMenuContext` with the history view model) while the Chats tab is in the key window — the same mechanism, so at most one of the two contexts is set for a window.
- Each item is enabled when `workbenchMenu?.canUseSessionKeys == true` **or** `chatsMenu?.canUseRowKeys == true` (no sheet/alert/rename field taking the keys), and on fire still passes `pageTakesKeys`. It acts on whichever context is set: the workbench → `openSession(atShortcut:)` (unchanged), Chats → open the n-th row of the panel.
- The menu moves out of the Workbench menu into a neutral place (View → "Go to Item" ▸ 1…9) since it now serves two tabs; the Workbench menu keeps everything else. The choice is a pure function in Core (`ItemShortcutTarget.resolve(workbench:chats:)`) with tests: Workbench page → sessions, Chats → chats, palette open / other tab → disabled. A row click opens the chat and sends focus to the composer, as today. The shortcut catalog's "Chats" area lists them.

**v1 limit:** the panel re-reads its rows about once a second while an answer streams.

## 6. Groups

- **PINNED** — pinned chats, newest first.
- **RECENT** — chats updated in the last 7 days.
- **▸ N older** — everything else, folded by default; open/folded remembered (per level). The chat on screen that lives in the folded group shows pinned under the header (the sessions panel's pinned row).

`ChatHistoryGrouping` gains this three-part shape (the six date kinds go); tests move with it.

## 7. Project page

Opened by the **Project overview** row (and by New Project…). Mockup board 3.

- **Header**: the name, large, editable in place (click to rename, Return/blur saves — today's `nameDraft`/`commitName`). A `⋯` menu: Rename, Delete Project… (today's confirmation: "Its chats are kept and move out of the project.").
- **Composer**: "New chat in “<name>”…" — the landing composer bound to the project: the first keystroke creates the conversation in the project, Return sends and the panel selects it. Provider/model picker and attachments as on the landing.
- **Chats in this project · N**: rows with title and age; a click opens the chat. Empty: "No chats yet — ask something above."
- **Right column** (stacks under the main column below ~900 pt width):
  - **Instructions** card: the first lines of the instructions, **Edit** opens the editor in place (a `TextEditor`, Save/Cancel); empty → "Add instructions" with the caption "Given to the assistant in every chat of this project."
  - **Knowledge** card: files and pinned sources in one list, each with a kind badge (PDF, MD, image, Jira, Slack, Confluence, target, track, person) and a remove button on hover; **+ Add** offers "Files…" and "Source…" (today's picker); a drop zone accepts files. Caption: "The assistant looks here first in every chat of this project."

No new data: the page reads and writes what `ProjectDetailViewModel` does today. No description field (owner: no extra fields).

## 8. What stays

CHAT-01..05 untouched: nothing here sends, stores owner text differently or changes the session pool. The ⌘K search, archive, branch/regenerate, artifacts and sources panels are unchanged. The chat landing for All chats is unchanged.

## 9. Testing

- WatchtowerCore: `ChatHistoryGrouping` (three groups, pinned, folded), `ChatProjectSwitcherPresentation` (order, match, segments), the row state precedence, line-2 text, `panelRows` query (unread, pending, last answer on the active branch, project prefix).
- Desktop: render tests in the `ChatSidebarRenderTests` style for the header at both levels, rows in each state, the older group; delete + Undo timing (`PendingChatDeletes` twin of `PendingSessionDeletes`); the read mark on select and on turn finish.
- Go: the migration (`TestAllTablesExist` unaffected; schema golden + Desktop test schema regenerated); the system-prompt golden after the guide titles change; `go test ./docs/guide`.
- The pending-approval state appearing without a list reload (a proposal written by another process, signalled through `onActionAwaited`).
- ⌘1…⌘9 and ⌘[ dispatch: Workbench on screen → sessions / its `backAction`, Chats on screen → chat rows / All chats, elsewhere disabled.
- `make desktop-shots` of the panel and the project page before review.

## Decisions

- The tab is called **Chats** — ask #624.
- Projects live in a **switcher in the header**, not a PROJECTS section — ask #624.
- History: **PINNED + RECENT + folded "▸ N older"** — ask #624.
- Projects work; the **project page** is what needs redoing — ask #625.
- The switcher is **the Workbench switcher's shape** (‹, Find field, RECENT with state segments, New Project…, All Chats); no "Project Settings…" item — conversation (owner's screenshot of the workbench switcher).
- Mockups on the canvas accepted ("ну норм. Делаем") — conversation.
- **No project description field** — conversation (proposed by the agent, consistent with "prefer simple designs").
- Review round 3 (ask #640): ⌘[ becomes one shared View → Back item dispatching to Workbench's `backAction` or the Chats level, like ⌘1…⌘9.
- Review round 2 (ask #635): the panel refresh goes into the existing `AppState+Chat.swift` closures (no new assignment of the single-closure callbacks); ⌘1…⌘9 enable through a second focused scene value beside `workbenchMenu`/`canUseSessionKeys`.
- Review round 1 (ask #626): regenerate the system-prompt golden; ⌘1…⌘9 shared with Workbench through one dispatching set; the waiting-for-approval state refreshes on the pool's callbacks; the guide describes the new panel.
- Waiting for approval outranks answering — controller ruling during implementation (a turn blocked on an Approve shows what the owner must do).
- ⌘1…⌘9 and ⌘[ act on the Chats panel only while the panel is visible — ask #660.
- A row click opens the chat and sends the keyboard to the composer (as in Workbench) — ask #660.
