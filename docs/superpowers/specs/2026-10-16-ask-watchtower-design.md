# Ask Watchtower — in-app help — design

> **Superseded/merged by reconciliation (ask #333, 2026-10-17).** #426 shipped as the in-app help design (`2026-10-16-in-app-help-design.md`, notes in `docs/features/in-app-help.md`): ⌘/ opens the AI Chat popup and the guide is searched only through Knowledge. From this spec only the `watchtower-nav://` screen links and the guide link ref by release version were kept; the Ask panel, `internal/userguide`, `search_guide`/`get_guide_page`, `watchtower guide index|search|catalog` and `ai query --no-tools` were removed. Kept here as history.

Board #426, from GitHub issues #289, #292 and #291 (triage asks #195, #197, #198).
Owner decisions: asks #231, #233, #235, #236, #238 (2026-10-16). Mockup:
https://claude.ai/artifact/28kLVXgsvbNfKj7yYPCiNe

## Why

A person installs Watchtower, gets through setup, and a few days later wants
to do something specific: get the recap of yesterday's meeting, set a
reminder, find out why the agent does not see the board. Today they have
nowhere to ask (owner, asks #231, #233):

- the AI chat knows the app only from a 14-line sidebar summary
  (`appGuide`, `internal/chat/prompt_sections.go:32`), so it guesses;
- the user guide (`docs/guide/`, board #429) lives on GitHub and nothing in
  the app points to it;
- the Search tab searches Slack only.

Home and its planned **Try this** cards (#785) cover the first day — "what
is this and where do I start". This design covers **day three and after:
"how do I do X"** (owner, ask #233). The first day stays with Home.

## Goals

- From any page, one key press opens a place to ask about the app.
- Typing shows instant matches from the guide and the app's screens, with no
  AI call.
- Asking gets a short, step-by-step answer grounded in the guide, aware of
  the page the person is on, with links that open the right screen.
- The main AI chat answers app questions from the same guide.
- **Help** in the menu bar leads to the guide.
- The guide stays true: every release checks it against what shipped.

## Non-goals

- **The panel does not act.** It explains and takes you to the screen. It
  never creates, sends or changes anything (my call in the proposal; the
  owner approved the proposal, ask #236).
- No change to the Search tab's scope. Its placeholder already says Slack
  (PR #310).
- No `?` button in every tab (owner, ask #195).
- No tooltips on sidebar rows or badges (owner, ask #198).
- No new guide content. Writing and fixing pages is board #429's job; this
  design only reads the guide.
- Not a first-run tour. Home and Try this own the first day.
- No help from outside the app. ⌘/ works while Watchtower is the active app
  (my call: the global hotkey slot is taken by dictation, and asking about
  Watchtower while looking at another app is rare).

## Anti-goals

These would make it a failure even if it technically works:

- **Answers that are made up.** An answer that disagrees with the app is
  worse than no answer. The panel answers from the guide or says the guide
  does not cover it.
- **Walls of text.** Owner, on the guide (ask #206): nobody needs a wall of
  text. Answers are a few steps, not an essay.
- **Slow typing.** Instant matches appear as you type; anything that waits
  on a process or a model per keystroke fails.
- **A second chat product.** The panel is a short, throwaway conversation.
  A long conversation belongs in AI Chat, one click away.

## What the person sees

Approved mockup (ask #238), two states on the Calendar page.

### Opening and typing

- **⌘/** on any page, or **Help → Ask Watchtower…**, opens a floating panel
  over the current page: a centred card on a dimmed backdrop, one text field,
  a result list below it. **Esc** closes it and returns focus where it was.
- A pill next to the field names the current page ("on Calendar").
- While the person types, the list shows, in this order:
  1. **Ask** — always the first row and selected by default: *Ask Watchtower:
     "<what you typed>"*. **↩** asks.
  2. **Guide** — matching guide sections: section heading plus the page it is
     on. Selecting one opens that section of the guide in the browser.
  3. **Go to** — matching app screens (the sidebar destinations by title).
     Selecting one, or **⌘↩**, closes the panel and opens that screen.
- ↑/↓ move the selection. With an empty field the list shows a few starter
  questions for the current page (my call: up to three per page, written by
  hand next to the page's guide entry; the builder may start with none).

### The answer

- **↩** on the Ask row replaces the list with the conversation: the question,
  then a streamed answer.
- The answer is short: one line that answers, then numbered steps when there
  are steps. It names screens and tabs the way the app labels them.
- **Links into the app.** Screen names in the answer can be links that open
  that screen and close the panel ("Open Calendar → Recordings"). Links to a
  specific object (a meeting, a target) are a later step; v1 links to
  screens only (my call — see Links below).
- Under the answer, a muted line names the guide section the answer was
  built from (the top section retrieved for that turn), as a link to that
  section on GitHub.
- A follow-up field under the answer continues the same conversation.
- **Open in AI Chat** moves the conversation to the full chat: it opens AI
  Chat with a new conversation that asks the same question, so the answer
  there has the full chat's tools and history (my call: re-asking is far
  simpler than transferring a transcript, and the panel conversation is
  short by design).
- The mockup's follow-up chips under the answer are **out of v1** (my call:
  they need the model to emit a structured trailing block; the follow-up
  field covers the need). They can come later.
- Closing the panel ends the conversation. Reopening starts fresh (my call:
  no history, no database rows).

### Elsewhere

- **Help menu**: *Ask Watchtower… ⌘/*, *Watchtower User Guide* (opens the
  guide index on GitHub — see open question 1), and the existing *Keyboard
  Shortcuts*. The stock Help search stays.
- **Home**: one muted line: "Press ⌘/ to ask anything about Watchtower."
  Shown after Getting ready folds away, so it does not compete with setup
  (my call).
- **Keyboard Shortcuts**: ⌘/ is added to `KeyboardShortcutCatalog` (Global)
  and to `docs/guide/reference/keyboard-shortcuts.md`; the catalog test keeps
  them in step.

## How it works

### The guide ships inside the app

- `docs/guide/` is embedded in the Go binary with `go:embed` from a small
  package at `docs/guide/` itself (`package guide`, an `embed.go` next to the
  pages). `go:embed` cannot reach `..`, and the package lives where the
  files are, so nothing is copied at build time.
- On load the Go side splits every page into sections at `##` and `###`
  (WRITING.md: headings are anchors and stay stable) and builds an in-memory
  index: page path, page title, section heading, GitHub anchor, section text.
  No database, no migration.
- `README.md`'s one-line-per-page catalogue (about 8.6 KB) is the guide's
  table of contents for prompts.

### Instant matches (no AI)

- New CLI: `watchtower guide index --json` prints every section's page path,
  page title, heading, anchor and its first sentence (WRITING.md: the first
  sentence carries the answer). The Desktop runs it once per app launch,
  lazily on the first ⌘/, and keeps the list in memory.
- Matching runs in Swift over that list and over `SidebarDestination`
  titles: case-insensitive word-prefix match on headings and titles first,
  then on first sentences. Ranking details are the builder's.
- Guide rows open the section on GitHub at the installed version's tag:
  `https://github.com/aiwatchtowers/watchtower/blob/v<version>/docs/guide/<page>#<anchor>`,
  so the link shows the same text the binary embeds. A dev build with no
  release version uses `main`. `guide index --json` reports the version it
  was built from (my call). The base URL changes when open question 1
  settles the website.

### Asking (the help chat)

The panel's chat **has no tools**. Instead, the guide sections it needs are
retrieved before each turn and put into the prompt (my call, after the
builder check):

- It works on every provider. Ollama mounts no tools, so a tool-based design
  would leave Ollama users with ungrounded answers.
- It has no access to the owner's data by construction: no MCP server, no
  read registry, no new surface in the Go chat server, no actions contract.
  The panel answers how the app works; what is in your data is AI Chat's job.
- It needs no conversation row: tools need a conversation id on the Desktop
  side, retrieval does not.

How:

- New CLI: `watchtower guide search --json "<query>" [--limit N]` returns the
  top sections from the embedded index (page, title, heading, anchor, text).
  Plain keyword ranking with headings weighted is enough; the guide is small
  (my call; the scoring details are the builder's). `watchtower guide
  catalog` prints `README.md`.
- The panel is an embedded chat (`ChatSurfaceSpec`, `EmbeddedChatEngine`,
  docs/features/embedded-chat.md): `.memory` persistence (no rows),
  `.draftOnly` tool access (AGENT-04: no tools, no actions), the 3-turn gate
  as today.
- `systemPrompt` (first turn): identity ("you answer questions about how to
  use Watchtower"), the guide catalogue, and the rules: answer only from the
  guide sections given; if they don't cover it, say so plainly and suggest
  AI Chat; short, steps, app labels; screen links only as
  `watchtower-nav://<destination>` from the list of visible screens given.
- `willSend` / `turnPrompt` (every turn): run `guide search` on the turn's
  text (plus the previous question, so a bare follow-up like "and then?"
  still finds the topic), and prepend the top sections, the current page and
  the list of screens visible in the sidebar. Total stays a few KB, well
  under the argv limit embedded chats carry.
- Model: the light tier of the configured provider (my call: answers are
  retrieval plus rewording).

### Links into the app

- A new link scheme `watchtower-nav://<destination>` where `<destination>` is
  a `SidebarDestination` raw value (`calendar`, `projects` for Workbench, …).
  It is added to `AllowedURLSchemes` and handled by the panel's (and AI
  Chat's) `OpenURLAction`: set `AppState.selectedDestination`, close the
  panel.
- Unknown destinations, and destinations hidden from the sidebar (onboarding
  v2 hides tabs), render as plain text, never as a dead link. The panel's
  **Go to** rows list visible destinations only (my call; the prompt gets
  the same visible list, so the model links only to those, and explains a
  hidden feature by naming where to turn it on, as the guide says).
- A link from a workbench window raises the main window first, then sets
  the destination.
- Object links (a meeting, a target) reuse the existing `navigateTo…` calls
  in AppState later; v1 does screens only.

### Which windows

- ⌘/ works in the main window and in workbench windows (my call: Workbench
  is where people get stuck most). In a workbench window the pill says
  "on Workbench". Settings and the Keyboard Shortcuts window don't host the
  panel; **Help → Ask Watchtower…** from there opens it in the main window.

### The main AI chat learns the guide

- The main chat has tools on Claude and Codex, so it gets two read tools,
  chat-only (registered in `buildToolRegistry` outside `tools.ReadTools()`,
  so dev-mode MCP does not mount them, DEV-01), on the `main` surface:
  - `search_guide(query)` — the same search as the CLI;
  - `get_guide_page(path)` — a whole page.
- `appGuide` in `prompt_sections.go` is replaced by a short section: what
  Watchtower is, plus "for any question about how the app works, search the
  guide with `search_guide` and answer from it". The full catalogue is not
  inlined into the main prompt (my call: it would cost about 2–3k tokens on
  every main session; the tool finds the page on demand).
- On Ollama the main chat has no tools, as today; for app questions the
  panel is the grounded path there.
- Main chat answers may use `watchtower-nav://` links too.

### Keeping the guide true

Owner, ask #195: check the guide's accuracy on every release.

- `/release` (`.claude/commands/release.md`) gets a step after the release
  notes: list the PRs in the release that changed user-facing code (Desktop
  views, CLI commands, settings) and did not touch `docs/guide/`, and ask
  the owner, per PR, whether the guide needs an update. The step proposes
  guide edits; it does not block the release.
- A Go test checks that every page in `docs/guide/` is listed in
  `README.md` (if #429 doesn't already test it), so the catalogue the
  panel's prompt carries never misses a page. Guide pages themselves carry
  no `watchtower-nav://` links: they would be dead on GitHub (my call).

## Constraints

- In-app only, macOS 14+, the Desktop's existing SwiftUI patterns: the
  overlay follows `RunAutomationPalette` (centred card, dimmed backdrop,
  `PreviousFirstResponder` restore, an `AppState` flag and a host modifier).
- ⌘/ is free today (no binding in the Desktop or the shortcut catalog). It is
  a menu command, so it shows in the Help menu.
- Go↔Swift dual path: the guide index lives in Go only; Swift reads it
  through the CLI. No copy of the guide in the app bundle.
- Prompt and argv: embedded chats carry the prompt on argv
  (embedded-chat.md). The help system prompt must stay well under that limit;
  the catalogue is about 8.6 KB.
- English guide, English prompts; the panel's UI copy is English like the
  rest of the app.
- Public repo hygiene: no live data in tests or fixtures.

## Left to the builder

- Ranking and matching details for instant matches.
- The exact help prompt wording, within the rules above.
- Whether the panel conversation reuses `EmbeddedChatView` or the rows +
  composer pieces.
- How `guide search` scores sections (keyword, BM25, headings weighted) and
  how many it returns per turn.
- Panel size, animation, empty-state copy.
- Starter questions: whether v1 ships any.

## Settled after review

1. **Where "Watchtower User Guide" leads.** The owner wants the Help menu to
   go to the website (ask #195), but the site has no guide pages yet. The
   spec was approved with the proposal (ask #240): link to
   `docs/guide/README.md` on GitHub now, and switch the base URL to the site
   once it publishes the guide. One constant holds the base URL.
