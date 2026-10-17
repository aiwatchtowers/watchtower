# In-App Help Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘/ opens the main AI Chat as a popup over any tab, with the current screen as context. The assistant answers app questions from the user guide, which is embedded in the binary and indexed for search. Search shows guide pages on top. Help links to the guide, Home says how to get help, and each release checks the guide.

**Architecture:**
- **Go side.** `docs/guide/` becomes a tiny Go package that embeds its Markdown. A new `guide` source in `internal/kb` indexes it on every daemon cycle, even with Knowledge search off. The chat prompt's map of the app is the embedded catalogue.
- **Desktop side.** The popup is a second view of the one `ChatViewModel` on `AppState`. It sends a per-turn screen block through the existing never-stored prefix path that `outcomes` already uses. A Swift query over the `kb_*` tables feeds the Search tab.

**Tech Stack:** Go 1.26 (`embed`, `internal/kb`, `internal/chat`, `internal/daemon`); SwiftUI and GRDB (WatchtowerCore, WatchtowerDesktop); GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-16-in-app-help-design.md` — read it first. Its "Calls made after the builder check" section is binding.

## Global Constraints

- **Guide links** take the form `https://github.com/aiwatchtowers/watchtower/blob/main/docs/guide/<path>#<anchor>`, defined once as `guide.BaseURL` in Go and `GuideLinks.baseURL` in Swift.
- **Knowledge source name:** `guide`. Doc ID `guide:<path>`, where `<path>` is relative to `docs/guide/` (e.g. `features/inbox.md`).
- **Guide anchors** use the GitHub slug: lowercase; spaces become `-`; characters other than letters, digits, `-` and `_` are dropped; repeats on a page get `-1`, `-2`, …
- **Hotkey:** ⌘/. The menu item is **Ask Watchtower…**, the Help-menu link **Watchtower User Guide**.
- **Copy:**
  - Home line: `Stuck? Press ⌘/ to ask, or open the User Guide.`
  - Search placeholder: `Search Slack messages and help…`
  - Search action: **Ask in chat**
  - Popup buttons: **New**, **Open in AI Chat**
- **Screen block**, prefixed to the provider text only and never stored:
  ```
  === CURRENT SCREEN ===
  Tab: <tab title>
  Status: <status line>          (only when the tab shows an empty-state status)
  Selected: <item title>         (only when the tab has a selected item)
  ===
  ```
- **The guide source is never deleted or gated** by the Knowledge search switch.
- **"The assistant"** is the only persona name in copy and prompts.
- **Swift:** run `swiftlint` on every touched Swift file (`make lint-swift`); lint-diff checks Go only.
- **Inner loop** per CLAUDE.md: `go test ./<pkg>` and `make test-swift FILTER=…`. The full gate runs once at the end.

## Review Focus

1. **⌘/ while the Workbench terminal has the keyboard** must open the popup. **⌘/ while the Files editor (Monaco) has the keyboard** must still toggle the comment.
2. **The screen block must not be stored.** After a popup turn, the stored owner message equals what was typed, and the AI Chat tab shows no block. A regenerate or edit of that message re-sends the typed text without a screen block.
3. **Knowledge search off:** the guide is still indexed, and turning the switch off or on doesn't delete guide rows.
4. **Search with an FTS-hostile query** (`"`, `*`, `-`, `AND`) shows neither an error nor a crash. The guide rows use the same sanitizer as the Slack query.
5. **Popup vs. AI Chat state.** **New** in the popup changes the AI Chat tab's selection. While an answer streams, the popup's composer is disabled exactly as the tab's is.

---

### Task 1: `docs/guide` Go package — embed, page API, guide check, CI job

**Files:**
- Create: `docs/guide/guide.go`, `docs/guide/guide_test.go`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces, in package `guide` (import path `watchtower/docs/guide`):
  - `const BaseURL = "https://github.com/aiwatchtowers/watchtower/blob/main/docs/guide/"`
  - `type Page struct { Path, Title string; Sections []Section }`
  - `type Section struct { Heading, Anchor, Text string }`. The section before the first `##` has `Heading == ""` and `Anchor == ""`.
  - `func Pages() []Page`: every embedded `.md` file except `WRITING.md`, sorted by path. The title comes from the first `# ` line.
  - `func Catalogue() string`: `README.md` with relative links rewritten to `BaseURL`-absolute ones.
  - `func Slug(heading string, seen map[string]int) string`: the GitHub slug, as in the Global Constraints.
  - `func Hash() string`: the hex sha256 over all embedded files in path order.

- [ ] **Step 1: Write the failing tests** in `guide_test.go`:
  - `TestPagesHaveTitles`: every page has a non-empty `Title`; no page path is `WRITING.md`.
  - `TestSlug`: `Slug("Why use it", m)` is `"why-use-it"`; `Slug("When it's empty or wrong", m)` is `"when-its-empty-or-wrong"`; a second `"Why use it"` with the same map gives `"why-use-it-1"`.
  - `TestRelativeLinksResolve`: every `](x.md)` and `](x.md#a)` in every page points to an embedded file. Its `#a`, when present, equals some section's `Anchor` in that page. This replaces the one-off `guide_check.py`.
  - `TestCatalogueListsEveryPageOnce`: each page path except `README.md` appears exactly once as a link target in `README.md`.
  - `TestFeaturePagesUnder8KB`: every file under `features/` is ≤ 8192 bytes.
  - `TestCatalogueLinksAreAbsolute`: `Catalogue()` contains no `](` followed by a relative `.md`, and contains `BaseURL + "features/inbox.md"`.
- [ ] **Step 2:** Run `go test ./docs/guide/`. Expected: FAIL to build (no package yet).
- [ ] **Step 3:** Implement `guide.go`:
  - `//go:embed *.md */*.md */*/*.md` into an `embed.FS`.
  - Parse headings `##` / `###` into sections.
  - Ignore headings inside fenced code blocks.
- [ ] **Step 4:** Run `go test ./docs/guide/`. Expected: PASS. If a real broken link or anchor surfaces in the guide, fix the page in this task.
- [ ] **Step 5:** In `.github/workflows/ci.yml`:
  - Add a `guide` filter (`'docs/guide/**'`) to the gate's `dorny/paths-filter` step, with output `guide: ${{ github.event_name != 'pull_request' || steps.filter.outputs.guide == 'true' }}`.
  - Add a job `guide-check` named **Guide Check** on `ubuntu-latest`, `needs: gate`, `if: needs.gate.outputs.run == 'true' && needs.gate.outputs.guide == 'true'`. Its steps are checkout, setup-go `1.26.9` and `go test ./docs/guide/`.
  - Keep the code filter as is: a guide-only PR runs just the leak check and the guide check.
- [ ] **Step 6:** Commit: `feat(guide): embed docs/guide as a Go package with a guide check`.

### Task 2: `guide` knowledge source

**Depends on:** Task 1

**Files:**
- Create: `internal/kb/source_guide.go`, `internal/kb/source_guide_test.go`
- Modify:
  - `internal/kb/source.go` (`allSources`)
  - `internal/kb/search.go` (recency exemption)
  - `internal/tools/knowledge.go` (sources description)

**Interfaces:**
- Consumes: `guide.Pages`, `guide.Hash`, `guide.BaseURL`.
- Produces:
  - `const GuideSource = "guide"`.
  - `guideSource{}` implementing `Source`. `Changed` returns every page key with `next = guide.Hash()` when `cursor != guide.Hash()`; otherwise it returns no keys, `done = true`. `Keys` returns all page paths. `Build(key)` returns the `Doc` for that path, or `nil` when it no longer exists.
  - The Doc has:
    - `ID "guide:"+path`;
    - `Source GuideSource`;
    - `Title` the page title;
    - `Link BaseURL+path`;
    - `Time` zero;
    - `Anchor {"path": path}`;
    - one `Section` per guide section, with `Text` set to `heading + "\n" + text` and `Anchor` set to the section's slug.

- [ ] **Step 1:** Write the failing tests:
  - `TestGuideSourceChangedOnlyWhenHashMoves`: an empty cursor gives all keys and `next == guide.Hash()`; that cursor gives no keys.
  - `TestGuideSourceBuild`: `features/inbox.md` builds with `Link` ending in `features/inbox.md` and a section whose anchor is `why-use-it`; an unknown key gives `nil`.
  - `TestSearchGuideNotPenalisedForAge`: index the guide with `Run(… Sources: []string{"guide"})`, search a phrase from one page, and the hit's score is not multiplied by `recencyMin` (extend the existing search test helpers).
- [ ] **Step 2:** Run `go test ./internal/kb/ -run Guide`. Expected: FAIL.
- [ ] **Step 3:** Implement the source and register it in `allSources()` before `calendarSource{}` (smallest first). In `search.go`, use factor `1` instead of `recencyFactor` when the doc source is `GuideSource`.
- [ ] **Step 4:** In `internal/tools/knowledge.go`, add `guide` to the sources description list, with the phrase "guide: the Watchtower user guide — use it for questions about the app itself".
- [ ] **Step 5:** Run `go test ./internal/kb/ ./internal/tools/`. Expected: PASS. Fix any contract test that enumerates sources.
- [ ] **Step 6:** Commit: `feat(kb): index the user guide as the guide source`.

### Task 3: Daemon — guide always indexed, never cleared by the switch

**Depends on:** Task 2

**Files:**
- Modify: `internal/daemon/daemon.go` (`phaseKnowledgeIndex`), plus any Knowledge-off clean-up path a grep finds (`grep -rn "Reindex\|Knowledge.Enabled" internal cmd`)
- Test: `internal/daemon/` (the existing `phaseKnowledgeIndex` tests' file)

- [ ] **Step 1:** Write the failing test `TestPhaseKnowledgeIndexGuideRunsWhenKnowledgeOff`: with `Knowledge.Enabled = false`, one cycle leaves `kb_documents` rows with `source = 'guide'` and no other source's rows.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** In `phaseKnowledgeIndex`, when Knowledge search is off, run `kb.Run(ctx, d.db, kb.Options{Budget: kbCycleBudget, Sources: []string{kb.GuideSource}})` instead of returning. Any clean-up triggered by turning Knowledge search off must exclude `guide` (pass every source but `guide`).
- [ ] **Step 4:** Run `go test ./internal/daemon/ -run Knowledge` and `go test ./internal/kb/`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(daemon): keep the guide indexed when knowledge search is off`.

### Task 4: Chat prompt — the catalogue replaces `appGuide`

**Depends on:** Task 1

**Files:**
- Modify:
  - `internal/chat/prompt_sections.go` (drop the `appGuide` const)
  - `internal/chat/prompt.go:66`
- Test: `internal/chat/prompt_test.go` (or the file holding `BuildSystemPrompt` tests), plus any golden/snapshot the prompt has (`grep -rn appGuide internal`)

**Interfaces:**
- Produces: `func appGuideSection() string`. It returns:
  ```
  === WATCHTOWER APP ===
  For any question about how Watchtower works, search the user guide first: search_knowledge with sources ["guide"]. Answer from what you find and link the section you used. The guide's catalogue:
  ```
  followed by `guide.Catalogue()`, then `===`.

- [ ] **Step 1:** Write the failing test `TestSystemPromptCarriesGuideCatalogue`: the built prompt contains `sources ["guide"]`, contains `BaseURL + "features/workbench/README.md"`, and no longer contains the old literal `=== WATCHTOWER APP (answer questions about the app from this) ===`.
- [ ] **Step 2:** Run `go test ./internal/chat/`. Expected: FAIL.
- [ ] **Step 3:** Implement. Update every golden or size assertion the change trips; the prompt must not grow by more than 2 KB over today's.
- [ ] **Step 4:** Run `go test ./internal/chat/ ./cmd/ -run Prompt`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(chat): the prompt's app map is the user guide catalogue`.

### Task 5: Swift — `GuideQueries` (top guide pages for a query)

**Depends on:** Task 2. It reads the rows Task 2's source writes; the test seeds them directly.

**Files:**
- Create:
  - `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/GuideQueries.swift`
  - `WatchtowerDesktop/Sources/WatchtowerCore/Models/GuideLinks.swift`
  - `WatchtowerDesktop/Tests/Core/GuideQueriesTests.swift`

**Interfaces:**
- Produces:
  - `struct GuideHit: Equatable { let path: String; let title: String; let heading: String?; let url: URL }`
  - `enum GuideQueries { static func search(_ db: Database, query: String, limit: Int = 3) throws -> [GuideHit] }`. It searches `kb_fts` joined to `kb_chunks`/`kb_documents` (read the table and column names from `internal/db/schema.sql`) with `d.source = 'guide'`. It returns one hit per document, the best-ranked chunk's anchor as the heading anchor, ordered by that rank. The query string goes through the existing `sanitizeFTS5Query`; an empty query gives `[]`.
  - `enum GuideLinks { static let baseURL: URL; static func url(path: String, anchor: String?) -> URL; static let readme: URL }`

- [ ] **Step 1:** Write the failing tests in `GuideQueriesTests`. Seed two guide docs and one Slack doc in the generated test schema.
  - `testFindsGuidePagesOnly`: a word in both a guide doc and the Slack doc returns only the guide doc.
  - `testOneHitPerPage`: two matching chunks of one page give one hit.
  - `testHostileQueryDoesNotThrow`: `"\"*- AND"` returns `[]` without throwing.
  - `testURLCarriesAnchor`: the hit URL ends with `features/inbox.md#why-use-it`.
- [ ] **Step 2:** Run `make test-swift FILTER=GuideQueriesTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Map a chunk's anchor back to its heading by de-slugging is not needed: show the page title, and the anchor only drives the URL. Set `heading` to `nil` unless the chunk text starts with a heading line, in which case use that line.
- [ ] **Step 4:** Run `make test-swift FILTER=GuideQueriesTests` and lint. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(desktop): query guide pages from the knowledge index`.

### Task 6: Swift — screen context and the never-stored prefix

**Files:**
- Modify:
  - `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift` (`send`, `TurnPlan`, the `ChatTurnText.compose` call at ~:858)
  - `ChatTurnText` (find with grep)
- Create:
  - `WatchtowerDesktop/Sources/WatchtowerCore/Services/ScreenContext.swift`
  - `WatchtowerDesktop/Tests/Core/ScreenContextTests.swift`
  - a `ChatViewModel` test in the existing ChatViewModel tests file

**Interfaces:**
- Produces:
  - `struct ScreenContext: Equatable { let tab: String; let status: String?; let selected: String?; var block: String }`. `block` renders the Global Constraints format and omits nil lines.
  - `ChatViewModel.send(…, screen: ScreenContext? = nil)`: a new trailing parameter, default `nil`. `TurnPlan` gains `screen: ScreenContext?`. The composed provider text is `screen.block + "\n\n" + (outcomes-composed text)` when present. The stored message stays `userText`.
  - `AppState.currentScreenContext() -> ScreenContext`, built in the App target:
    - `tab` is the current `SidebarDestination` title.
    - `status` is `FeatureReadiness.line(...)` when `EmptyStateCopy` has a copy for that destination with a feature and the tab currently shows its empty state (use `emptyStateContext.readiness` and the readiness snapshot's content-present flag). Otherwise it is `nil`.
    - `selected` is the selected item's title for Targets (selected target), Workbench (session on screen), Digests (selected digest) and Calendar (selected event). Otherwise it is `nil`.

- [ ] **Step 1:** Write the failing tests:
  - `ScreenContextTests.testBlockOmitsMissingLines`
  - `ScreenContextTests.testBlockFormat`: exact string match with the Global Constraints format.
  - In the ChatViewModel tests, `testScreenBlockIsSentButNotStored`: send with a screen, then the stub client's received text starts with `=== CURRENT SCREEN ===` and the stored owner message text equals the typed text.
  - `testRegenerateDoesNotResendScreen`
- [ ] **Step 2:** Run `make test-swift FILTER='ScreenContextTests|ChatViewModel'`. Expected: FAIL.
- [ ] **Step 3:** Implement. Regenerate and edit build `TurnPlan` with `screen: nil`.
- [ ] **Step 4:** Run the same filter and lint. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(chat): send a never-stored current-screen block with a turn`.

### Task 7: Swift — the ⌘/ popup

**Depends on:** Task 6

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Chat/HelpChatPanel.swift`
- Modify:
  - `WatchtowerDesktop/Sources/App/WorkbenchCommands.swift` (`HelpCommands`: add **Ask Watchtower…** ⌘/)
  - `AppState` (an `isHelpChatShown` flag and `toggleHelpChat()`)
  - the root window view that overlays content (where the main `NavigationSplitView` lives)
  - `WatchtowerDesktop/Sources/WatchtowerCore/Models/KeyboardShortcutCatalog.swift`
  - `docs/guide/reference/keyboard-shortcuts.md`
- Test: `WatchtowerDesktop/Tests/Core/KeyboardShortcutCatalogTests.swift` (it already pins the page), plus a small `HelpChatPolicyTests` for the pure decision below

**Interfaces:**
- Consumes: `AppState.chatViewModel`, `currentScreenContext()`, the shared `ChatFeedView` and `ChatComposerBar`.
- Produces: `enum HelpChatPolicy { static func action(destination: SidebarDestination, editorHasKeyboard: Bool) -> Action }` with `enum Action { case togglePopup, focusChatComposer, editorToggleComment }`:
  - `.chat` gives `focusChatComposer`;
  - `editorHasKeyboard` gives `editorToggleComment`;
  - anything else gives `togglePopup`.

- [ ] **Step 1:** Write the failing `HelpChatPolicyTests`, covering the three cases. Add the catalog row `**⌘/** | Ask Watchtower: the chat over any tab` to the Global area. Update `docs/guide/reference/keyboard-shortcuts.md` by pasting `KeyboardShortcutCatalog.markdown`, so `KeyboardShortcutCatalogTests` passes.
- [ ] **Step 2:** Run `make test-swift FILTER='HelpChatPolicyTests|KeyboardShortcutCatalogTests'`. Expected: FAIL, then PASS after Step 3.
- [ ] **Step 3:** Implement:
  - **The menu item.** It lives in `HelpCommands` with `.keyboardShortcut("/", modifiers: .command)`. Menu key equivalents reach the app even while the terminal has the keyboard, as ⌃⌘A does.
  - **`editorToggleComment`.** It runs Monaco's `editor.action.commentLine` through the code editor's existing JS bridge, because the menu equivalent pre-empts Monaco.
  - **The panel.** It is an overlay at the top right, about 420×560, with a material background. It holds the header (**New**, **Open in AI Chat**, close), a `ChatFeedView` over `chatViewModel`, and a `ChatComposerBar` whose send calls `chatViewModel.send(text:…, screen: appState.currentScreenContext())`.
  - **Closing.** **Esc** closes it. Clicking outside does not.
  - **New** calls `chatViewModel.newConversation()`.
  - **Open in AI Chat** selects `.chat` and closes the panel.
- [ ] **Step 4:** Run the build (`make test-swift FILTER=HelpChatPolicyTests`), then lint. Do a manual check on a dev build, recorded in the report:
  - ⌘/ from Home, Targets and Workbench with the terminal focused opens the popup;
  - ⌘/ in the Files editor toggles a comment;
  - a popup turn appears in AI Chat without the screen block.
- [ ] **Step 5:** Commit: `feat(desktop): ⌘/ opens the chat over any tab`.

### Task 8: Swift — Search help rows, Help link, Home line

**Depends on:** Tasks 5 and 7

**Files:**
- Modify:
  - `WatchtowerDesktop/Sources/Views/Search/SearchView.swift`
  - `SearchViewModel` (find with grep)
  - `WorkbenchCommands.swift` (`HelpCommands`)
  - `WatchtowerDesktop/Sources/Views/Home/HomeView.swift`
- Test: `SearchViewModel` tests (existing file or new `SearchViewModelGuideTests`)

**Interfaces:**
- Consumes: `GuideQueries.search`, `GuideLinks`, `AppState.toggleHelpChat()`.
- Produces: `SearchViewModel.guideHits: [GuideHit]`, refreshed with `results` on every query change (same debounce).

- [ ] **Step 1:** Write the failing test `testGuideHitsFollowQuery`: seeded guide rows, `query = "inbox"`, then `guideHits` is non-empty; an empty query leaves `guideHits` empty.
- [ ] **Step 2:** Run `make test-swift FILTER=SearchViewModel`. Expected: FAIL.
- [ ] **Step 3:** Implement:
  - **Search.** A **Help** section above the Slack list, shown only when `guideHits` is non-empty. Each row shows the title and the heading, and clicking it calls `NSWorkspace.shared.open(hit.url)`. Below the rows is an **Ask in chat** button that opens the popup with the query typed into its composer. Set the placeholder to `Search Slack messages and help…`.
  - **Help menu.** Add **Watchtower User Guide**, which opens `GuideLinks.readme`, above **Keyboard Shortcuts**.
  - **Home.** At the bottom, the copy line, where "⌘/" is a button that calls `toggleHelpChat()` and "User Guide" a link to `GuideLinks.readme`.
- [ ] **Step 4:** Run the same filter and lint. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(desktop): help in Search, the Help menu and Home`.

### Task 9: Docs, release step, acceptance check

**Depends on:** Tasks 1–8

**Files:**
- Modify:
  - `.claude/commands/release.md`: a new step between Step 3 and Step 4, "Docs check"
  - `docs/guide/features/ai-chat.md`, `docs/guide/features/search-and-knowledge.md`, `docs/guide/features/home.md`, `docs/guide/start/first-week.md` (one line on ⌘/), `docs/guide/concepts/privacy.md` (the screen block goes to the AI provider)
  - `CLAUDE.md`: one Feature Notes line
- Create: `docs/features/in-app-help.md`, the developer note with the 15-question acceptance list

- [ ] **Step 1:** Write the release step:
  - Run `git log --merges --format='%s' <last-tag>..HEAD` and list the PRs that touched `WatchtowerDesktop/`, `cmd/` or `internal/` but not `docs/guide/`, using `gh pr view N --json files`.
  - For each one that changes something a user sees, update its guide page or name in the release notes why none was needed.
  - Run `go test ./docs/guide/`.
- [ ] **Step 2:** Update the guide pages per `docs/guide/WRITING.md`: short, true to the code, ⌘/ in bold. Then run `go test ./docs/guide/`. Expected: PASS.
- [ ] **Step 3:** Write `docs/features/in-app-help.md`: the architecture in about 15 lines, plus the acceptance list of 15 app questions. Spread them over Workbench, asks, an empty Briefings tab, Knowledge search off, Automations confirm, the iPhone pairing code, plan limits, mail not in Inbox, Day Plan settings, the reaction ✅, Catch Up without Slack, Memory "remember this", the sync stuck, Codex setup and keyboard shortcuts.
- [ ] **Step 4:** Run the acceptance check on a dev build: ask each question in the popup and record pass/fail in the PR description. A pass means the answer comes from the guide with a section link. Fix the guide or the prompt for any failure.
- [ ] **Step 5:** Commit: `docs(help): guide pages, release docs step and the in-app help note`.
