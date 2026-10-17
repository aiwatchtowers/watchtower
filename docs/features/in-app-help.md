# In-app help — ⌘/ popup, guide as knowledge, Search help block (2026-10-16)

Board #426, issues #289/#292. Spec: `docs/superpowers/specs/2026-10-16-in-app-help-design.md`. User view: `docs/guide/features/ai-chat.md` ("Asking from any tab") and `search-and-knowledge.md`.

## Reconciliation with Ask Watchtower (#330, ask #333)

Two sessions built #426 in parallel; #330 (Ask Watchtower, spec `docs/superpowers/specs/2026-10-16-ask-watchtower-design.md`) merged first, and this PR reconciles the two per the owner's ruling on ask #333:

- **⌘/ is this feature's popup** over the AI Chat (full tools, the last conversation, the screen block). #330's separate tool-less Ask panel (`AskPanel`, `AskCenter`, `HelpChatSurface`, `GuideSearch`, `HelpPrompt`, `GuideIndex`, the Home "Press ⌘/" hint) is gone.
- **The guide is searched only through Knowledge** (source `guide`). #330's second index is gone: `internal/userguide` and its fixture, `watchtower guide index|search|catalog` (`cmd/guide.go` deleted; the pre-#330 deprecated stub pointed to `people` and would misdirect v0.20.0 users), the chat tools `search_guide`/`get_guide_page`, and `docs/guide/embed.go`. `ai query --no-tools` (the Ask panel's only caller) is gone with it, on the Go and Swift sides.
- **Kept from #330:** in-app screen links (`watchtower-nav://<screen>`, below) and the guide link ref by release version (`guide.BaseURL(version)`, below).

## Architecture

- **Guide embedded in the binary.** `docs/guide/guide.go` (`//go:embed` of the Markdown, `guide.BaseURL(version)` — `https://github.com/aiwatchtowers/watchtower/blob/v<X.Y.Z>/docs/guide/` for a clean `X.Y.Z` version, a leading `v` allowed, `blob/main/` for anything else such as `dev` or `v0.19.0-12-gabc-dirty`; `guide.Version` is set from `cmd.Version` in `cmd/version.go` — GitHub-slug anchors, section split at `##`/`###`, `Map()`, the compact README map). `go test ./docs/guide/` checks links, catalogue and page size.
- **Knowledge source `guide`.** `internal/kb/source_guide.go`: one doc per page (`guide:<path>`, link `guide.BaseURL(guide.Version) + <path>`), cursor = content hash + link base (`guideCursor`), so an update re-indexes changed pages and deletes removed ones, and a new release version relinks every page to its tag. Wired in `internal/daemon/daemon.go`; indexed even with Knowledge search off (`phaseKnowledgeIndex` in `internal/daemon/daemon.go`, which never reindexes on the off path, so the switch never deletes guide rows); `internal/kb/status.go`'s empty-index count and staleness check ignore the guide row, and a guide-only search (`sources: ["guide"]`) gets no owner-index note. `internal/kb/search.go` exempts guide docs from the recency factor; `internal/tools/knowledge.go` accepts `guide` in `sources`.
- **Prompt.** `internal/chat/prompt_sections.go` replaces the hand-written `appGuide` (about 1.3 KB) with `guide.Map()` (group headings and `Title (path)` lines, no descriptions or URLs; links come from search hits as `link#chunk_anchor`) plus the instruction to search `sources: ["guide"]` and link the section (a session without tools gets the map and the page URL to link only); the main surface also gets the screen-link rule (`appGuideNavRule`: the `SidebarDestination` raw values, Workbench = `projects`) (a controller change to the spec's Calls bullet, which embedded the whole README with GitHub URLs: that catalogue would add +11.5 KB to every prompt; golden: `internal/chat/testdata/system_prompt_main.golden`).
- **Popup.** `HelpChatPanel` (420×560, top right) drives the one `ChatViewModel` on `AppState`, with `ChatThreadView` and `ChatComposerBar`. **New** opens the AI Chat landing (`showLanding()`, the tab's own New: no conversation row until a send); **Open in AI Chat** selects `.chat`; Esc stops a stream, then closes.
- **⌘/ routing.** Help → **Ask Watchtower…** calls `AppState.askWatchtower()` (`AppState+HelpChat.swift`); `HelpChatPolicy` picks: on the AI Chat tab focus the composer (`ChatViewModel.requestComposerFocus()`, main's UUID `composerFocusRequest`), with a web view holding the keyboard call `wt.toggleComment()` (`CodeEditorWeb/editor.js`; false opens the popup), else toggle the popup; opening it fronts the main window first (`bringMainWindowForward`, for the Settings window or tray-only mode). The key works while the Workbench terminal has focus.
- **Screen links (from #330).** `watchtower-nav://<screen>` (`WatchtowerCore/Services/Help/NavLink.swift`), `<screen>` a `SidebarDestination` raw value. `MarkdownView` reads the environment value `markdownNavScreens` (`AppState.visibleHelpScreenIDs`, the sidebar's visible destinations, set on the main window, so AI Chat and the popup both get it) and `AllowedURLSchemes.strippingDisallowedLinks(navScreens:)` keeps the link only for a visible screen; any other becomes plain text. The scheme is never handed to NSWorkspace: `AppState.mainWindowOpenURL` routes it to `openNavLink`, which selects the destination and closes the popup.
- **Screen block.** `AppState+ScreenContext.swift` builds `ScreenContext` (`WatchtowerCore/Services/ScreenContext.swift`: tab, empty-state status, selected item). `ChatViewModel.sendDraft(screen:)` (the tab's own send path, so quotes, attachments, mentions and skill ride along) prefixes `=== CURRENT SCREEN ===` to the provider text only; the stored owner message is the typed text, and regenerate/edit re-send it without a block.
- **Search.** `SearchViewModel.guideHits` from `GuideQueries` (Swift over `kb_*`, source `guide`, same FTS sanitizer as the Slack query, any-word fallback, bm25 weights 4/1/2 mirrored from `internal/kb/search.go` (change both together), one row per page, at most 3); **Ask in chat** calls `openHelpChat(prefill:)`, which appends to an existing draft (`HelpChatPrefill.merge`).
- **Entry points.** Home line "Stuck? Press ⌘/ to ask, or open the User Guide." (`HomeView`), **Watchtower User Guide** in Help (`GuideLinks.readme`; `GuideLinks` applies the same tag-or-main rule to the app's `CFBundleShortVersionString`, mirrored from Go `guide.BaseURL`), `KeyboardShortcutCatalog` Global entry (and `reference/keyboard-shortcuts.md`).
- **Release.** `.claude/commands/release.md` Step 3 "Check the user guide is current" (from #330: the PRs since the last tag that touched user-facing code without `docs/guide/`, asked per PR, never blocking) ends with the guide check (`go test ./docs/guide/ ./internal/kb/ ./internal/chat/`, golden regeneration on a catalogue change); CI's Guide Check job runs the same packages.

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
- An answer naming a screen links it (`watchtower-nav://briefings`): the click opens the tab and closes the popup; with that feature turned off the link is plain text.
- **Ask in chat** from Search keeps an unsent AI Chat draft and appends the query.
- With Knowledge search off, Search still shows guide rows; searching `"`, `*`, `-` or `AND` shows no error.
