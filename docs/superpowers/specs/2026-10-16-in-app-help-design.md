# In-app help — design

Board #426. Issues #289 and #292. Owner decisions: asks #195, #197 and #198 (triage), and #239, #241 and #242 (this design), all 2026-10-16.

## Why

When someone is stuck in Watchtower — a tab is empty, or they don't understand a feature — nothing in the app helps them.

- AI Chat knows the app only from a hand-written 14 KB `appGuide` in the system prompt. It doesn't mention Workbench, and it has drifted from the app.
- The user guide (`docs/guide/`, about 270 KB) now exists, but the app neither links to it nor reads it.
- **Search** covers Slack messages only.

Owner, ask #239: when someone is stuck, the first thing they reach for is a **hotkey that opens the chat over the tab they are on**. The chat must know much more about the app, and it must stay a normal chat — you can talk about anything, and the conversation is kept (ask #195).

## Goals

1. **⌘/ opens a chat popup over the current tab.** The popup knows which tab you are on and what that tab shows right now.
2. **The assistant answers app questions from the user guide**, retrieved by search rather than pasted whole into the prompt.
3. **Search shows matching guide pages on top**, with "Ask in chat".
4. **Help → Watchtower User Guide** opens the guide.
5. **Home tells you how to get help.**
6. **Every release checks that the guide is current.**

## Non-goals

- A hotkey that works outside the Watchtower window (owner, ask #241).
- A **?** button on each tab, or tooltips on sidebar rows and badges. Owner declined both in #289 and #292.
- Hosting the guide on aiwatchtowers.com. The Help link points to GitHub until the site can render the guide (ask #242). That is one URL to change later.
- Making the Search tab search every source.

## Anti-goals

- **A separate "help bot".** The popup is the same assistant, with the same history and the same tools. A conversation started from the popup is an ordinary AI Chat conversation.
- **Answers from memory that contradict the guide.** For anything about how the app works, the assistant must look in the guide first.
- **Two copies of the app description that drift apart.** The prompt's map of the app is the guide's own catalogue (`docs/guide/README.md`), embedded at build time, not a second hand-written text.

## Decisions

### The ⌘/ popup (owner, asks #239 and #241)

- **Opening it.**
  - **⌘/** works anywhere in the Watchtower window, including while the Workbench terminal has the keyboard. ⌃⌘A already sets that precedent.
  - It is listed in Help as **Ask Watchtower…** and added to `KeyboardShortcutCatalog`'s Global area. The keyboard-shortcuts guide page carries the catalog verbatim, so it changes with it.
  - It is not available in the main AI Chat tab, where the chat is already on screen. There, ⌘/ focuses the composer.
- **The conversation.**
  - The popup **continues the last AI Chat conversation**, and a **New** button starts a fresh one.
  - It is the main chat itself — same conversation list, same history — so whatever you say in the popup shows up in AI Chat.
  - **Open in AI Chat** switches to the tab on that conversation.
- **What the assistant can do.** Everything it can do in AI Chat: the same tools, and proposals you approve (ask #241).
- **The current screen.** Each turn sent from the popup starts with a short **current screen** block:
  - the tab's name;
  - for a tab with an empty state, the status line it shows (for example "Off — Turn on" or "Connect Slack to get this"), from `EmptyStateCopy`, `FeatureReadiness` and the readiness snapshot;
  - the selected item's title where the tab has one (a target, a session, a digest).

  The block goes in each turn rather than in the system prompt, because a resumed session drops the system prompt. Turns typed in the main AI Chat tab carry no such block.
- **Shape.**
  - A floating panel over the window's content, anchored to the top right, about 420×560 pt.
  - It uses the shared `ChatFeedView` and `ChatComposerBar` (the same components as the main chat).
  - **Esc** or ⌘/ closes it.
  - The tab underneath stays live: no modal sheet, and clicking outside the panel doesn't close it.

**Builder's note (my call):** drive the popup from the main chat's own `ChatViewModel` and `ChatSessionPool`, not from an `EmbeddedChatEngine`. An embedded engine on the same conversation would run a second provider session against the same rows. It would also be filtered out of AI Chat history, because embedded conversations carry a `context_type`.

### The guide as searchable knowledge (owner, ask #242)

- **Embedding.** The guide's Markdown is compiled into the Go binary with `//go:embed`, from a small Go package inside `docs/guide/`. `go:embed` cannot reach above its own package, and the Markdown stays where GitHub shows it.
- **A new knowledge source, `guide`.**
  - One document per page, ID `guide:<path>`.
  - Sections split at `##` and `###` headings. Each section's anchor is the GitHub heading slug.
  - The link points to that page on GitHub.
  - Its cursor is the embedded content's hash, so an app update re-indexes changed pages and deletes removed ones. Nothing is indexed per cycle when nothing changed.
- **Always indexed (my call).** The guide source is indexed even when **Knowledge search** is off, because help must work for everyone and the guide is small. The other sources still follow the switch.
- **No recency penalty (my call).** Guide documents are exempt from the recency factor in ranking; their age means nothing.
- **Search tool and prompt.**
  - `search_knowledge` accepts `guide` as a source, and its description says to use it for questions about Watchtower itself.
  - The chat prompt's hand-written `appGuide` is replaced by the embedded `docs/guide/README.md` catalogue, plus one instruction: *for any question about how Watchtower works, search the guide (`sources: ["guide"]`), answer from what you find, and link the section.*
  - `README.md` is short (about 9 KB) and already lists every page with one line, so the prompt stays about the size it is today.

### Search tab (owner, ask #242)

- **Guide pages on top.**
  - The tab first shows up to **three guide pages** matching the query, from the knowledge index, read straight from the database by a Swift query over the `kb_*` tables with source `guide`.
  - Each row shows the page title and the section heading. Clicking it opens that section on GitHub.
  - Below them is **Ask in chat**, which opens the ⌘/ popup with the query as the message.
  - The Slack results follow, as today.
- **Placeholder.** It changes to "Search Slack messages and help…".

### Help menu, Home and the release step

- **Help menu.** It gets **Watchtower User Guide**, which opens `docs/guide/README.md` on GitHub, and **Ask Watchtower…** (⌘/). Both sit beside the existing **Keyboard Shortcuts**.
- **Home.**
  - One quiet line at the bottom: "Stuck? Press ⌘/ to ask, or open the User Guide."
  - It always shows, has no dismiss button, and needs no new state.
- **Release step.** `.claude/commands/release.md` gets a docs step before the build:
  1. List the PRs merged since the last tag that changed `WatchtowerDesktop/`, `cmd/` or `internal/` but not `docs/guide/`.
  2. For each one that changes something a user sees, update its guide page or say in the release notes why none was needed.
  3. Run the guide check (links, catalogue, page size).

### Calls made after the builder check (mine, for the owner to check)

- **One chat, one view model.** `ChatViewModel` is already a single instance on `AppState` (`AppState.swift:224`).
  - The popup and the AI Chat tab are two views of it. Whatever conversation the tab has selected is "the last conversation", and **New** in the popup changes the tab's selection too.
  - While an answer is streaming, the popup shows that stream and can send nothing new, exactly like the tab.
- **The current-screen block is not stored.**
  - It is prefixed to what the provider receives for that turn.
  - The stored message is only what you typed, so history in AI Chat shows no blocks.
- **Prompt map.**
  - The embedded `README.md` has its relative links rewritten to GitHub URLs when it is put into the prompt.
  - Its one-line entries already cover Workbench and every other area.
  - A fixed list of about 15 app questions is the acceptance check: each must be answered from the guide with a link, by a manual run against a dev build, recorded in the PR.
- **Guide and the Knowledge search switch.**
  - Turning Knowledge search off or on never touches `guide` rows. The phase gate, cursors and any clean-up skip the guide source.
  - The guide is indexed on the daemon's first cycle. Until that cycle runs, Search simply shows no guide rows.
- **Links point to `main` on GitHub** (`https://github.com/aiwatchtowers/watchtower/blob/main/docs/guide/...#anchor`). Guide headings are stable by rule (`WRITING.md`), and the guide check also verifies that in-guide anchors resolve.
- **Search shows one row per page**: the best-ranked section of that page, ordered by that section's rank. There are three rows at most.
- **⌘/ in the Files editor.** While the Monaco editor has the keyboard, ⌘/ stays its toggle-comment, the same way the editor keeps ⌘K and ⌘[. Everywhere else in the window, ⌘/ opens the popup, the terminal included.

## Constraints

- Everything said in `CLAUDE.md` holds, in particular:
  - the Desktop conventions in `docs/review/review-rules.md`;
  - "the assistant" is the only persona name;
  - the guide rules in `docs/guide/WRITING.md` (this work updates pages: keyboard shortcuts, AI Chat, Search, Home, Help).
- The ⌘/ handler must not fire inside text fields where `/` is typed. It requires the ⌘ modifier, so a plain `/` is unaffected.
- `KeyboardShortcutCatalogTests` keeps the catalog and the guide page identical. Both change in the same commit.
- Periphery (`make release-check`) fails on unused code. Every new API is used.

## Left to the builder

- **The popup's exact look.** It keeps the shared chat components.
- **Which tabs report a selected item.** Start with Targets, Workbench, Digests and Calendar.
- **Splitting the work into plans.** The Go side (guide source, prompt, tool) and the Desktop side (popup, Search, Help, Home) are independent, except that the Desktop Search query reads what the Go side indexes.
