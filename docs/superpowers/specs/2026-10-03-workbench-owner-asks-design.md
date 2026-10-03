# Workbench owner asks — design (2026-10-03)

**Board:** feature target "Просьбы агента вместо вкладки Documents" (id in the plan header).
**Replaces:** the workbench Documents pane, attached documents and document comments
(`docs/features/workbench.md`, Phase 6 / #105 review flow).
**Plan:** `docs/superpowers/plans/2026-10-03-workbench-owner-asks.md`.

Part 1 is the one-page owner spec. Parts 2–10 are the technical spec: decisions and
contracts for the implementing sessions.

**Rulings made during implementation (2026-10-03), reflected below:**
- The contracts this spec calls PROJ-11 and PROJ-12 are numbered **PROJ-12** and
  **PROJ-13** in `docs/inventory/workbench.md`: PROJ-11 was taken on main by the session
  state hooks (board #312).
- Claude Code's Stop hook input has no `tool_calls`, so the Stop prompt's "an `ask_owner`
  call in the turn" pass clause became "`last_assistant_message` says it filed an ask, for
  example by naming `ask #<number>`"; the skill tells the agent to name every ask it filed.
- Every UI string is English (the owner's standing rule), so the Russian labels in Parts 1
  and 8 ship as: «Ждёт тебя (N)» → "Waiting for you (N)", «Есть правки» → "Request
  changes", «Вне приложения» → "Outside the app", "▸ N закрыто" → "▸ N closed", "k из N ›"
  → "k of N ›", «Показать дифф» → "Show diff", «агент отозвал» → "withdrawn by the agent",
  «заменено #N» → "replaced by #N", «Агент просит: <title>» → "Agent asks: <title>".
- Part 2's Down keeps target comments (only the document columns and rows go).
- PROJ-04 is reworded in the inventory (not part of the Part 9 approval): "exactly one entry
  of ours per event" no longer holds — `Stop` holds the drift command and the ask guard
  prompt, and `PreToolUse` (matcher `AskUserQuestion`) is a newly owned event.
- After a stop the ask guard blocks, the session state (PROJ-11) reads "waiting" for the
  nudged turn — an accepted v1 limit (Part 10).

---

## Part 1 — For the owner (one page)

**Problem.** The Documents tab is a file list, not a place where the agent asks you for
something. It fills with every spec and plan, including dead worktree copies, and each row
shows a path. The "revised" dots are on almost everything. The document reads like a text
dump: no column width, no rhythm. Comments sit in a fourth column that is empty most of the
time. Most important, the agent's real requests are scattered. A review hides behind a target
status, a manual checklist is buried in a PR, and a question lands as a comment on a ticket
or as text in the terminal ("от тебя ждут две вещи…"). So you have no single list of what is
waiting for you.

**What you will see.**
- **No Documents tab.** The header keeps Terminal · Board · Files.
- **A stack «Ждёт тебя (N)»** ("Waiting for you (N)" in the app) above the session list holds everything the agent asked you,
  from every session of the workbench, oldest first. Each session shows how many of its asks
  are open, and "▸ N closed" opens its past asks.
- **Three kinds of ask:**
  - **Review of a document** — a short header from the agent (what it is, where to look, what
    changed since the last round with a diff), decision cards, then the document in a readable
    column. Your comments sit in the margin next to the text they quote.
    Answer: **Есть правки** or **Approve**.
  - **Manual check** — steps to try in the app, each marked Ok, Broken (with a note) or
    Skipped. Answer: **Send**.
  - **Question** — context plus decision cards, the same cards as in the AI Chat.
    Answer: **Answer**.
- **Clicking an ask** selects its session. The ask slides out next to that session's terminal,
  so you always see whose request it is. **Later** closes it and keeps your drafts.
- **The agent never waits.** It files the ask and keeps working. When you answer, one line is
  typed into that session's terminal and you press Return, as today. If the session is not
  running, the answer goes into its brief when it starts again.
- **Documents stay in the repo.** Every `.md`/`.txt` in the folder, except what `.gitignore`
  ignores, is searchable by the workbench's own sessions, with no setup. Nothing is attached by
  hand any more.
- **The agent cannot dodge the stack.** A check at the end of each agent turn spots a request
  to you written as plain text and makes the agent file it as an ask. Claude Code's own
  blocking question dialog is turned off in workbench sessions.

**Decisions for you (recommendations marked).**
1. **Amend PROJ-03** (the Desktop never writes a workbench document). The document view goes
   away, and the ask view is read-only over a snapshot. The contract shrinks to "the Files
   editor rule (2026-10-02) and no workbench tool writes the folder". *Recommended: yes.*
2. **Amend PROJ-08** (workbench documents are searchable only from their own sessions). The
   rule stays, but its scope changes from "attached documents" to "every text file of the
   folder that git does not ignore". *Recommended: yes.*
3. **Add PROJ-11 "an ask reaches its session exactly as typed text, never submitted"** and
   **PROJ-12 "the agent's turn is never trapped by the ask guard"** (shipped as PROJ-12 and
   PROJ-13; see the rulings above).
   *Recommended: yes* (exact wording in Part 9).
4. **Drop the existing attached documents and document comments**, with no migration into
   asks. The files themselves stay. *Already agreed 2026-10-03.*

**Out of scope (v1).** Editing a document by hand from the ask view, since the Files editor
covers that. Asks from the AI Chat or the daemon. Deadlines and priorities in the stack.
Asks from codex sessions. Re-ordering the stack.

**Done when.** The agent in a workbench session files a review, a check and a question. All
three appear in the stack, open next to their session's terminal and are answered there. The
answer line lands in the right terminal unsubmitted, and `get_ask` returns exactly what you
chose. A request written as plain text is caught. The Documents tab and its tables are gone.
`search_knowledge` in a session finds a spec nobody attached.

---

## Part 2 — Data (migration `00100_owner_asks.sql`)

Written as `00097`; renumbered to `00100` on 2026-10-03 when main had taken `00098` and
`00099` (the `add-migration` skill's rule: a migration never sorts before an applied one).

**Up:**
1. `CREATE TABLE owner_asks` — see the schema below.
2. Document comments go:
   `DELETE FROM project_comments WHERE document_id IS NOT NULL`. Replies are removed by the
   existing `parent_id` cascade. `project_comments` is then rebuilt without `document_id`,
   `anchor_quote`, `anchor_prefix`, `anchor_suffix` and `anchor_heading` (the table-recreation
   dance of `00002`/`00003`). The new CHECK is `target_id IS NOT NULL OR parent_id IS NOT NULL`.
   Indexes are recreated, except `idx_project_comments_document`.
3. `DROP TABLE project_documents`.
4. Explicitly delete the old index entries:
   `DELETE FROM kb_chunks WHERE doc_id IN (SELECT id FROM kb_documents WHERE source = 'project_doc')`,
   then `DELETE FROM kb_documents WHERE source = 'project_doc'`. The `kb_chunks_ad` trigger
   keeps `kb_fts` in step. The key format changes (Part 7), and the next knowledge pass or a
   `workbench resync` rebuilds the entries from the folders.

**Down:** recreate `project_documents` (empty) and the old `project_comments` shape, keeping
the target comments, and drop `owner_asks`. The removed data is not restored. Say so in a
comment in the file.

```
owner_asks(
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id       INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  session_id       INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,
  target_id        INTEGER REFERENCES targets(id) ON DELETE SET NULL,
  kind             TEXT NOT NULL CHECK(kind IN ('review','check','question')),
  title            TEXT NOT NULL CHECK(title != ''),
  summary          TEXT NOT NULL DEFAULT '',
  changes          TEXT NOT NULL DEFAULT '',   -- review re-round: what changed, agent-written
  payload          TEXT NOT NULL DEFAULT '{}', -- JSON: focus[], questions[], checklist[]
  doc_path         TEXT NOT NULL DEFAULT '',   -- review only: rel path inside the folder
  doc_snapshot     TEXT NOT NULL DEFAULT '',   -- review only: file text at ask time
  previous_ask_id  INTEGER REFERENCES owner_asks(id) ON DELETE SET NULL,
  status           TEXT NOT NULL DEFAULT 'open'
                   CHECK(status IN ('open','answered','delivered','withdrawn')),
  withdrawn_reason TEXT NOT NULL DEFAULT '' CHECK(withdrawn_reason IN ('','agent','superseded')),
  answer           TEXT NOT NULL DEFAULT '',   -- JSON, Desktop-written (Part 4)
  created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  answered_at      TEXT NOT NULL DEFAULT '',
  delivered_at     TEXT NOT NULL DEFAULT '',
  CHECK ((kind = 'review') = (doc_path != '')),
  CHECK ((status IN ('answered','delivered')) = (answer != ''))
)
INDEX idx_owner_asks_project ON owner_asks(project_id, status, created_at)
INDEX idx_owner_asks_session ON owner_asks(session_id)
```

`internal/db/schema.sql`, `TestAllTablesExist`, the schema golden and the generated Swift test
schema are regenerated (`TestSchemaGolden|TestDesktopTestSchema -update`). `owner_asks` joins
the PROJ-02 cascade automatically, through `project_id`.

**Writers.** Go writes `open`, `withdrawn` and `delivered`. Swift writes only
`open → answered`, together with `answer` and `answered_at`, as one guarded `UPDATE … WHERE
status = 'open'`. Zero rows changed means the agent withdrew or superseded the ask meanwhile;
the Desktop says so and keeps the drafts. No other cross-writer transition exists.

## Part 3 — Payload and limits (Go `internal/asks`, pure)

`internal/asks` owns the validation, the payload and answer types, the readable rendering and
the delivery line. It does no I/O. `ask_owner` input is rejected as a whole, with the first
violation named as `field: reason`, when:

| Field | Rule |
|---|---|
| `kind` | `review`, `check` or `question` |
| `title` | 1–120 runes after trim |
| `summary` | ≤ 2000 runes |
| `changes` | ≤ 1000 runes; only with `previous_ask_id` |
| `focus` | ≤ 5 items `{text 1–300 runes, heading? ≤ 200, quote? ≤ 300}`; `heading`/`quote` only on `review` |
| `questions` | 0–4 (`question` kind: 1–4). Same shape and bounds as the chat question card (`docs/superpowers/specs/2026-10-02-chat-question-card-design.md`): `id?`, `question` non-empty, `multi?`, `options` 2–4 `{label 1–80, description? ≤ 300, recommended?}`. Ids are unique; a missing id is its 1-based position. |
| `checklist` | `check` kind only, 1–30 items `{id?, text 1–300, hint? ≤ 300}`; ids unique, default position |
| `doc_path` | `review` only, required. Resolved like `tools.ResolveWorkbenchDocumentPath` (inside the folder, symlinks only inside it, a regular file, `.md`/`.markdown`/`.txt`), ≤ 2 MiB, valid UTF-8. The text read becomes `doc_snapshot`. |
| `previous_ask_id` | an ask of this workbench of the same kind. If it is `open`, it becomes `withdrawn`/`superseded` in the same transaction. |
| `target_id` | a target of this workbench (the PROJ-01 scope) |
| open asks | at most 30 `open` per workbench, else `too many open asks (30) — withdraw or wait for answers` |

The question shape is a dual path with the Swift `ChatQuestionCard`. A shared fixture
directory `internal/asks/testdata/cards/*.json` (valid and invalid) is read by the Go
validator test and by a Swift Core test (path via `#filePath`) that runs the same files
through `ChatQuestionCard`'s decoder. Both must agree on accept and reject.

**Answer JSON** (written by Swift, read by Go; a dual path pinned by
`internal/asks/testdata/answers/*.json`, which the Swift encoder test reproduces byte-for-byte
after key sorting):

```
{"verdict": "approved"|"changes"|"",         // review only, required there
 "answers":  [{"id": "...", "labels": ["..."], "other": "..."}],   // one per question, all required
 "checklist":[{"id": "...", "state": "ok"|"broken"|"skipped", "note": "..."}], // every item; note required when broken
 "comments": [{"quote": "...", "prefix": "...", "suffix": "...", "heading": "...", "body": "..."}], // review only, anchored on doc_snapshot
 "note": "..."}                               // optional free text, ≤ 4000 runes
```

A check item left unmarked is sent as `skipped`. The Desktop's Send button says how many are
unmarked; it does not block.

## Part 4 — MCP tools (workbench sessions only, `internal/tools/workbench_asks.go`)

These are registered in `buildToolRegistry` next to the workbench tools, only under
`mcp --workbench N`. In legacy `--project` mode they are served under the same names, since
they have no legacy spelling. They need DirectApply semantics like the other workbench writes:
apply immediately, with an audit row.

- **`ask_owner`** `{kind, title, summary?, changes?, focus?, questions?, checklist?, doc_path?, previous_ask_id?, target_id?, reason}`
  → `{ask_id, status: "open", superseded?: id, session_bound: bool}`.
  - The session is `WATCHTOWER_TERMINAL_SESSION_ID` from the MCP server's environment, the
    same variable `cmd/workbench_brief_session.go` reads. It is set only when it parses as an
    id and names a `terminal_sessions` row of this workbench. Otherwise the ask is filed with
    `session_id NULL` and `session_bound: false` (an external terminal).
  - A nested `claude -p` run by the agent inherits the variable. Its asks count as the
    session's; this is accepted.
  - Returns at once. No waiting, no polling.
- **`get_ask`** `{ask_id}` → the ask (kind, title, status, target, session, created/answered
  times) plus, when answered, `answer` as structured JSON and `answer_text`. `answer_text` is
  the `internal/asks` readable rendering: the verdict line, each question `→ labels / Other:
  text`, each check item `✓/✗/–` with its note, each comment as `> quote` plus a heading line
  plus the body, and the note.
  - On an `answered` ask, it sets `delivered` with `delivered_at`, guarded `WHERE status =
    'answered'`. Reading from any session of the workbench counts.
  - Another workbench's ask answers `no ask with id N` (the PROJ-01 style).
- **`list_asks`** `{status?: open|answered|all (default: answered and not delivered, then open), session?: "mine"|"all" (default all)}`
  → ≤ 50 rows `{ask_id, kind, title, status, session_id, created_at, answered_at}`. Read-only.
- **`withdraw_ask`** `{ask_id, reason}` → `{ask_id, status: "withdrawn"}`. Only an `open` ask
  can be withdrawn; anything else returns `ask N is <status>`.

**Removed tools:** `attach_document`, and `list_comments`'s `document_id` parameter. A call
using it returns `documents were replaced by asks — use ask_owner (kind review)`. The
`workbench_board` output loses its documents. `resolve_comment` and `add_comment` stay for
target comments.

## Part 5 — Delivery (Desktop → agent)

- The Desktop answers through one transaction (Part 2), then calls `TerminalCenter.sendPrompt`
  for the ask's session with exactly this line:
  `Ask #<id> answered (<kind>: <short>) — read it with get_ask <id> using the watchtower-workbench skill.`
  - `<short>` is one of: `approved` / `changes requested` (review), `N ok, M broken, K skipped`
    (check), `answered` (question).
  - The line is built by a pure `OwnerAskPrompt.line(for:)` in WatchtowerCore, a dual path with
    `asks.DeliveryLine` in Go, pinned by a shared fixture. Every control character and newline
    becomes a space, the `WorkbenchCommentPrompt` rule.
- `sendPrompt`'s existing outcomes apply unchanged: `.sent` (bracketed paste, never Enter),
  `.copied` (clipboard hint) or `.noSession`. With `.noSession`, or an ask without a session,
  nothing is typed; the brief delivers it (below). After `.sent` or `.copied` the drawer closes,
  the page shows that session's terminal, and focus moves into it.
- Several answers to one session each paste their own line. Unsent lines join in Claude Code's
  input as consecutive sentences, which still read correctly.
- **Brief.** `workbench brief` gains a section "Answered asks for you" placed right after the
  new-comments section. It lists `answered` asks whose `session_id` is the brief's own session
  (`WATCHTOWER_TERMINAL_SESSION_ID`), or is NULL or names a gone row, one line each:
  `#id kind — title (answered <age>) → get_ask id`. It also prints a count line for other
  sessions' answered asks. The section is cut before the board, on the brief's existing 4000-rune
  priority order, but never dropped while it has rows.
- **Delivered** means only that `get_ask` read the answer. A typed line that the owner never
  submitted leaves the ask `answered`, so the next brief still lists it.

## Part 6 — Making the agent use asks

Three layers, all installed by `devpack.InstallWorkbench` (that is, `integrate claude-code
--workbench N` and `workbench resync`), removed by `RemoveWorkbench` (PROJ-02), and reported
by `integrate status --json` as `ask_guard: bool` and `ask_tool_block: bool`. A workbench
missing either is offered Repair, like the PROJ-07 Stop hook.

1. **Skill** (`internal/devpack/workbenchskill/watchtower-workbench/SKILL.md`, pack marker
   bumped to `v2` so the DEV-04 digest re-installs it):
   - "Documents for review" and "Revising an attached document" are replaced by
     **"Asking the owner"**: anything that waits for an owner answer, decision, manual check or
     document review is an `ask_owner` call — never text in the terminal and never a target
     comment. The final text names every ask filed in the turn as `ask #<id>` (the Stop
   prompt's pass clause relies on it).
   - When to ask: specs, plans and designs before building on them; decisions with no
     sensible default; manual checks the agent cannot run.
   - What not to ask: progress, reports, anything with a sensible default (state it and go on).
   - A review re-round passes `previous_ask_id` and `changes`.
   - After filing, keep working on whatever does not depend on the answer. If nothing can
     proceed, end the turn.
   - On "Ask #N answered", or on a brief entry, call `get_ask N` first.
   - "Blocked, or an owner decision is needed" now files an ask. The target goes `blocked`
     only when nothing on it can proceed.
   - "Comment discipline" drops "question"; comments are for blockers and done summaries only.
   - Setup step 1 loses the import paragraph.
2. **Stop prompt hook.** Added to the folder's `.claude/settings.local.json` under `hooks.Stop`
   as `{"type": "prompt", "prompt": <text>, "timeout": 30}`. It is identified as ours by the
   marker line `[watchtower-workbench ask-guard <N>]`, which opens the prompt.
   `looksLikeOurHook` gains a prompt matcher keyed on that marker; PROJ-04 merge rules apply.
   The text, kept in `internal/devpack/askguard_prompt.md` and embedded:

   ```
   [watchtower-workbench ask-guard <N>]
   You check whether a coding agent left a request to its owner as plain text instead of filing it.
   Input (JSON): $ARGUMENTS
   Return {"ok": true} when ANY of these holds:
   - stop_hook_active is true;
   - last_assistant_message says it filed an ask, for example by naming "ask #<number>";
   - last_assistant_message does not ask the owner to do, decide, check, review or answer anything.
   Return {"ok": false, "reason": "You asked the owner in plain text. File it with ask_owner (kind question, check or review), mention 'ask #<id>' in your text if useful, then stop."}
   only when last_assistant_message clearly waits on the owner: a question to them, a decision
   they must make, something they must try or check by hand, or a document they must read.
   Rhetorical questions, questions the agent answers itself, summaries of finished work and
   offers such as "say if you want X" are NOT requests. When unsure, return {"ok": true}.
   ```

   The marker keeps the hook identifiable and the `<N>` substituted. The rest is pinned by a
   golden test.
3. **PreToolUse block of `AskUserQuestion`.** A `hooks.PreToolUse` entry with matcher
   `AskUserQuestion` and a **command** hook (deterministic, no model):
   `<bin> workbench ask-guard --workbench N --pre-tool-use`. It prints
   `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "In a Watchtower workbench, questions to the owner go through ask_owner so they land in the owner's stack — file it there and keep working."}}`
   and exits 0. A deleted workbench, or any failure, prints nothing and exits 0, so the tool is
   allowed; the PROJ-07 "never trap" rule. It is identified by the command suffix, like the
   existing hooks.

## Part 7 — Workbench index (replaces attached-document indexing)

- **Shared mechanism `kb` file sets** (`internal/kb/fileset.go`). A *file set* is
  `(source, container id, root folder, []rel path)`. Each file becomes one `kb_documents` row
  keyed `<prefix><container>:<rel path>`, split at `#`–`###` headings (the current
  `markdownSections`), with an anchor `{container_id, rel_path, unreadable?, truncated?}`, a
  `file://` link and mtime gating (re-render when the mtime differs in either direction, or the
  file is gone). It reuses `resolveInside`, the 2 MiB cap, `privacyProtected` and the unreadable
  and truncated rules unchanged. Visibility stays a per-source SQL condition. The workbench is
  the first user. Board #211 (chat project files) is meant to add a second source on the same
  mechanism; nothing for #211 is built here.
- **Workbench file listing** (`internal/workbenchdocs`, rewritten as `ListTextFiles(folder)`):
  - Inside a git repository (`gitbin.InsideRepository`):
    `git -C <folder> ls-files -z --cached --others --exclude-standard -- .`, run through
    `internal/workbenchgit`'s environment rules, filtered to `.md`/`.markdown`/`.txt`, with a
    5 s budget.
  - Otherwise: a walk that skips `CodeFileTree.hiddenNames`' Go twin (`.git`, `.build`,
    `node_modules`, `.claude/worktrees`, …) and never follows symlinks.
  - Both are capped at 2000 files, newest mtime first; the cut is logged with the count.
  - A failed git run is an error for that pass (logged), never an empty set, so existing
    entries are not wiped.
- **Source `project_doc` keeps its name** (storage). Its key is now `wbdoc:<project_id>:<rel>`.
  `Keys` lists the current files of every workbench whose folder is not `privacyProtected`;
  `Changed` compares mtimes. A file that left the listing (deleted, or now ignored) has its
  entry removed.
- **Triggers:** the daemon knowledge phase covers unprotected folders. `kb.IndexWorkbenchDocs`
  covers any folder and runs on `workbench resync`, `kb reindex` and `workbench create`. The
  agent's `ask_owner` with `doc_path` indexes that one file, best-effort, warning in the result.
- **Visibility:** the PROJ-08 condition is unchanged (`workbenchDocVisible`; anchor
  `project_id`).
- **Removed:** `watchtower workbench import-docs`, `workbench attach-doc`, the import inside
  `workbench create` and `resync`, the `docs_import_*` keys of `create --json` and
  `docs_ok`/`docs_error` of `resync --json`. `resync --json` gains `index_ok`/`index_error`
  instead.

## Part 8 — Desktop

Names follow the existing `Workbench*` pattern. Core pieces are pure and tested in
`Tests/Core`.

- **Core models/queries:** `OwnerAsk` (GRDB record, payload and answer decoded),
  `OwnerAskQueries` (`openAsks(project:)`, `closedAsks(session:)`, `answer(_:with:) throws
  AskAnswerError.notOpen`), `OwnerAskAnswer` (encoder; pinned by the Part 3 fixtures),
  `OwnerAskPrompt` (Part 5 line), `OwnerAskStack` (ordering: `open` by `created_at`; session
  counts; asks without a session grouped as "Вне приложения").
- **State:** `OwnerAsksViewModel`, owned by `WorkbenchesViewModel` (AppState-owned, so drafts
  and a pending answer survive navigation). It polls with the board's fingerprint pattern
  every 5 s while the Workbench tab is visible and on app activation, since writes come from
  another process. `OwnerAskDrafts` holds per-ask picks, check marks, margin comments and the
  note. Quitting with drafts asks first, the `WorkbenchCommentDrafts` rule. Drafts are never
  written to the DB.
- **Views** (`Views/Workbench/Asks/`):
  - `OwnerAskStackSection` — the top of `WorkbenchSessionsPanel`: header «Ждёт тебя N», rows
    with a kind icon, title, session and age. A click selects the session and opens the drawer.
  - Session rows show the open-ask count, plus "▸ N закрыто", which opens a read-only list.
  - `OwnerAskBanner` — over the terminal of a session with an open ask.
  - `OwnerAskDrawer` — a trailing, resizable part of `WorkbenchSessionView` (width persisted
    under `workbench.asks.drawerWidth`), with expand-to-full and close. It holds the header
    (kind, title, target, age, "k из N ›") and a scroll body with `OwnerAskHeaderCard` (summary,
    focus links that scroll the document, changes plus a "Показать дифф" sheet) and
    `ChatQuestionCardView` reused for the questions. The body then shows, by kind:
    `OwnerAskReviewBody`, `OwnerAskChecklistBody` or nothing; the footer is `OwnerAskAnswerBar`.
  - `OwnerAskReviewBody` renders `doc_snapshot` through `DocumentRendering` and
    `CommentableDocumentText` with a new `ReviewTypography` style: a centered column of at most
    680 pt, body 14 pt with 1.55 line height, headings 22/17/15 pt with spacing above greater
    than below, hanging list indents, code blocks on a tinted background, tables as
    `NSTextTable`, inline code without wrapping artefacts. Margin comments
    (`OwnerAskMarginComments`) are laid out against the anchors' line rects, with collisions
    pushed down. Without comments the margin takes no width. Focus items (heading or quote)
    get a left bar.
  - Diff: a pure `OwnerAskSnapshotDiff` (line diff of the previous and current snapshots, plus
    the changed headings list), shown in a sheet.
  - A read-only mode for answered, delivered and withdrawn asks shows the answer. Withdrawn
    asks carry "агент отозвал" or "заменено #N".
- **Removed:** `WorkspacePane.documents` (a saved layout naming it decodes to `.default`, the
  Files precedent), `WorkbenchDocumentsView`, `WorkbenchDocumentsList`,
  `WorkbenchDocumentThreadsPanel`, `AddWorkbenchDocumentSheet`, `WorkbenchDocumentViewModel`,
  `WorkbenchDocumentGrouping`, the document parts of `WorkbenchQueries` and `Workbench.swift`,
  `WorkbenchCommentDrafts`' document drafts, and the "Documents" header toggle. The target
  detail lists its asks (title, status) instead of its documents.
- **Badge and notifications:** the sidebar badge counts open asks plus unread agent target
  comments (revised documents removed). `WorkbenchNotificationPolicy`:
  - `documentReady` and `answeredDocuments` are removed.
  - A new `askOpened` notice ("Агент просит: <title>", coalesced at ≥ 3) is driven by new
    `open` rows. A click opens the ask.
  - The snapshot gains the open asks' ids. Old persisted snapshots decode with an empty set
    and announce nothing on the first poll (the `reviewKnown` precedent).

## Part 9 — Inventory changes (owner approval required)

- **PROJ-03 (amend):** delete the document-view and comment re-anchoring paragraph. The
  contract becomes: the Desktop writes workbench folder files only through the Files editor
  rule of 2026-10-02, and no workbench tool writes a file in the folder (`ask_owner` only
  reads `doc_path`). Guards: the Files-editor tests stay; a new
  `TestProj03_AskOwnerNeverWritesTheFolder`.
- **PROJ-08 (amend):** "attached documents" becomes "every `.md`/`.markdown`/`.txt` file of the
  folder that git does not ignore (or the walk keeps outside git), ≤ 2000 per workbench". The
  visibility rule, privacy rule, symlink rule, caps and PROJ-02 deletion are unchanged. Guards
  are renamed in place where the subject changed; their assertions are not weakened.
  `TestProj08_OwnerAttachPathsIndexTheDocumentsAtOnce` becomes
  `TestProj08_ResyncAndCreateIndexTheFolderAtOnce`.
- **PROJ-12 (new; drafted as PROJ-11) — an ask reaches its session as typed text, never submitted.** The answer
  is stored before anything is typed. The typed line is the fixed `OwnerAskPrompt` line
  (control characters stripped), never followed by Enter. A session that is not running gets
  it from the brief. `delivered` is set only by `get_ask`. Guards: Go `asks` line fixture,
  Swift `OwnerAskPromptTests`, `TerminalCenter` paste tests, a brief test.
- **PROJ-13 (new; drafted as PROJ-12) — the ask guard never traps a turn.** The Stop prompt
  hook returns ok when `stop_hook_active` is set, or when `last_assistant_message` says it
  filed an ask, e.g. names `ask #<number>` (pinned prompt golden; Claude Code's Stop input has
  no `tool_calls`).
  The PreToolUse command hook exits 0 and prints nothing on any failure or for a deleted
  workbench.
- **PROJ-02:** unchanged wording, plus "asks" in the cascaded list and both new hooks in the
  removal list.

## Part 10 — Non-goals and v1 limits

- The Stop prompt hook costs one fast-model call per agent stop (about 1–2 s). A miss is
  possible: the model is told to pass when unsure.
- Asks are for Claude Code workbench sessions only. An external-terminal claude files
  session-less asks, delivered by the brief only.
- Margin comments anchor on the snapshot, never on the live file. A later round is a new ask.
- No owner hand-edit from the ask view, no ask templates, no ask search beyond the session's
  closed list.
- Codex-run sessions get the tools but no hooks; codex has no equivalent hooks.
- After a stop the ask guard blocks, the session state (PROJ-11) reads "waiting" for the whole
  nudged turn: the drift Stop hook records `waiting` in parallel, and `PostToolUse` only clears
  "approval".
