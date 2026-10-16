# In-app help — ⌘/ popup, guide as knowledge, Search help block (2026-10-16)

Board #426, issues #289/#292. Spec: `docs/superpowers/specs/2026-10-16-in-app-help-design.md`. User view: `docs/guide/features/ai-chat.md` ("Asking from any tab") and `search-and-knowledge.md`.

## Architecture

- **Guide embedded in the binary.** `docs/guide/guide.go` (`//go:embed` of the Markdown, `guide.BaseURL`, GitHub-slug anchors, section split at `##`/`###`, link rewriting for the README). `go test ./docs/guide/` checks links, catalogue and page size.
- **Knowledge source `guide`.** `internal/kb/source_guide.go`: one doc per page (`guide:<path>`), cursor = content hash, so an update re-indexes changed pages and deletes removed ones. Wired in `internal/daemon/daemon.go`; indexed even with Knowledge search off, and the switch never deletes guide rows (`internal/kb/status.go`). `internal/kb/search.go` exempts guide docs from the recency factor; `internal/tools/knowledge.go` accepts `guide` in `sources`.
- **Prompt.** `internal/chat/prompt_sections.go` replaces the hand-written `appGuide` with the embedded `docs/guide/README.md` catalogue plus the instruction to search `sources: ["guide"]` and link the section (golden: `internal/chat/testdata/system_prompt_main.golden`).
- **Popup.** `HelpChatPanel` (420×560, top right) drives the one `ChatViewModel` on `AppState`, with `ChatThreadView` and `ChatComposerBar`. **New** changes the AI Chat selection; **Open in AI Chat** selects `.chat`; Esc stops a stream, then closes.
- **⌘/ routing.** Help → **Ask Watchtower…** calls `AppState.askWatchtower()` (`AppState+HelpChat.swift`); `HelpChatPolicy` picks: on the AI Chat tab focus the composer (`chatComposerFocusTick`), with a web view holding the keyboard call `wt.toggleComment()` (`CodeEditorWeb/editor.js`; false opens the popup), else toggle the popup. The key works while the Workbench terminal has focus.
- **Screen block.** `AppState+ScreenContext.swift` builds `ScreenContext` (`WatchtowerCore/Services/ScreenContext.swift`: tab, empty-state status, selected item). `ChatViewModel.send(text:keepsComposer:screen:)` prefixes `=== CURRENT SCREEN ===` to the provider text only; the stored owner message is the typed text, and regenerate/edit re-send it without a block.
- **Search.** `SearchViewModel.guideHits` from `GuideQueries` (Swift over `kb_*`, source `guide`, same FTS sanitizer as the Slack query, one row per page, at most 3); **Ask in chat** calls `openHelpChat(prefill:)`, which appends to an existing draft (`HelpChatPrefill.merge`).
- **Entry points.** Home line "Stuck? Press ⌘/ to ask, or open the User Guide." (`HomeView`), **Watchtower User Guide** in Help (`GuideLinks.readme`), `KeyboardShortcutCatalog` Global entry (and `reference/keyboard-shortcuts.md`).
- **Release.** `.claude/commands/release.md` Step 3b "Docs check"; CI runs the guide check.

## Acceptance list

Ask each in the popup on a dev build. Pass = the answer comes from the guide and links the section.

| # | Question | Guide page expected | Result |
|---|---|---|---|
| 1 | What is a Workbench and how do I start a session? | features/workbench/ | not run |
| 2 | An agent asked me a question. Where do I answer it? | features/workbench/ (asks) | not run |
| 3 | Why is my Briefings tab empty? | troubleshooting/no-briefing-or-day-plan.md | not run |
| 4 | What changes when I turn Knowledge search off? | features/search-and-knowledge.md | not run |
| 5 | How do I confirm an automation? | features/automations.md | not run |
| 6 | Where do I find the four-digit pairing code for my iPhone? | features/iphone.md | not run |
| 7 | What do the Claude plan limits show? | troubleshooting/plan-limits-or-high-cost.md | not run |
| 8 | Why isn't my mail in Inbox? | features/inbox.md, features/mail.md | not run |
| 9 | Where are the Day Plan settings? | features/day-plan.md | not run |
| 10 | What does reacting with ✅ to a Slack message do? | features/inbox.md, features/targets.md | not run |
| 11 | Can I use Catch Up without Slack? | features/catch-up.md | not run |
| 12 | How do I make the assistant remember something? | features/memory.md | not run |
| 13 | Sync looks stuck. What do I check? | troubleshooting/sync-stuck-or-slow.md | not run |
| 14 | How do I set up Codex as a Workbench agent? | features/claude-code-integration.md, troubleshooting/ai-tool-not-found-or-not-signed-in.md | not run |
| 15 | What keyboard shortcuts exist? | reference/keyboard-shortcuts.md | not run |

A failure is fixed in the guide page (heading or first sentence) or in the prompt instruction, then re-asked.

## Manual checks

- **⌘/** from Home, Targets and a Workbench with the terminal focused opens the popup.
- **⌘/** in the Files editor toggles the comment; with a diff or a recipe form focused it opens the popup.
- A popup turn shows in AI Chat as the typed text, with no screen block; regenerate re-sends it without a block.
- **Ask in chat** from Search keeps an unsent AI Chat draft and appends the query.
- With Knowledge search off, Search still shows guide rows; searching `"`, `*`, `-` or `AND` shows no error.
