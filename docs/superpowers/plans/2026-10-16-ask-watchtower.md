# Ask Watchtower Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A ⌘/ panel on any page that searches the user guide and app screens as you type and answers "how do I do X" from the guide, plus guide search in the main AI chat, Help-menu entries and a release-time guide check.

**Architecture:** Go embeds `docs/guide/` and exposes it two ways: a `watchtower guide index --json` CLI the Desktop loads once, and `search_guide`/`get_guide_page` read tools on the main chat. The Desktop keeps the index in memory and ranks it in Swift both for instant matches and for the sections it puts into each help-chat turn; the help chat is an embedded chat with no tools (`.draftOnly`, `.memory`), so it works on every provider and cannot see the owner's data.

**Tech Stack:** Go 1.26 (`embed`, cobra), SwiftUI macOS 14+, WatchtowerCore, the embedded chat component.

**Spec:** `docs/superpowers/specs/2026-10-16-ask-watchtower-design.md` (approved, ask #240).

**Plan decision beyond the spec:** the spec has the panel run `guide search` per turn. `ChatSurfaceSpec`'s `turnPrompt`/`willSend` are synchronous `@MainActor` closures, so a per-turn process call does not fit. The index the panel already loads for instant matches carries the full section text (~270 KB), and one Swift ranker serves both instant matches and per-turn retrieval. `watchtower guide search` still exists for the CLI and mirrors the Go tool.

## Global Constraints

- The panel never acts: no tools, no writes, no actions (`.draftOnly`, AGENT-04).
- Help-chat persistence is `.memory`: no `chat_conversations` rows, no migration.
- New chat-only Go tools are registered in `buildToolRegistry`, never in `tools.ReadTools()` (DEV-01), with `Surfaces: []string{"main"}`.
- ⌘/ is in-app only (a menu command), not a Carbon global hotkey.
- Link scheme `watchtower-nav://<SidebarDestination rawValue>`; screens only in v1.
- Guide links: `https://github.com/aiwatchtowers/watchtower/blob/v<Version>/docs/guide/<page>#<anchor>`; the base URL lives in one constant per side (Go `guide.BaseURL(version)`, Swift reads `base_url` from the index JSON — no Swift copy of the URL).
- "Watchtower User Guide" opens `<base_url>README.md`.
- Answers come only from the guide sections given; when they don't cover the question the model says so and suggests AI Chat.
- Help chat uses the light model of the configured provider (`ConfigService().aiModelLight` when set, else `""` = the provider default).
- English for all UI copy, prompts and docs.
- Public repo hygiene: fixtures use neutral samples only.
- Swift inner loop: `make test-swift FILTER=…`, `swiftlint lint --strict --baseline .swiftlint-baseline.json` (lint-diff is Go-only).

## Review Focus

1. **A follow-up with no keywords** ("and then?", "why?") — retrieval uses the previous question too, so the answer stays on topic. Test in Task 4 (`testFollowUpUsesPreviousQuestion`).
2. **A link to a hidden or unknown screen** in the model's answer — renders as plain text, never a dead or crashing link. Test in Task 4 (`testNavLinkRejectsHiddenAndUnknown`) and Task 5 (renderer strips it).
3. **The CLI fails or the index is missing** (no binary, decode error) — the panel still opens, shows "Go to" rows, and the Ask row says help is unavailable instead of spinning. Test in Task 5 (`testIndexFailureKeepsScreensAndExplains`).
4. **A query with no guide match** — the Ask row is still first and selectable, and the turn prompt tells the model nothing matched, so it answers "the guide doesn't cover this". Test in Task 4 (`testTurnPromptWhenNothingMatches`).
5. **Headings with punctuation or duplicates** ("Why the briefing skips a day?", two "Troubleshooting" sections on one page) — anchors match GitHub's (`why-the-briefing-skips-a-day`, `troubleshooting-1`). Test in Task 1 (`TestAnchorMatchesGitHub`).

---

### Task 1: Go — embedded guide and its index

Depends on: none.

**Files:**
- Create: `docs/guide/embed.go` (package `guide`, `//go:embed README.md start concepts features troubleshooting reference`, `var FS embed.FS`)
- Create: `internal/guide/guide.go`, `internal/guide/search.go`
- Test: `internal/guide/guide_test.go`

**Interfaces:**
- Produces (package `watchtower/internal/guide`):
  - `type Section struct { Page, PageTitle, Heading, Anchor, Text string; Level int }` — `Page` is the path under `docs/guide/` (`features/calendar.md`); the page intro (text before the first `##`) is a section with `Heading == PageTitle`, `Anchor == ""`, `Level == 1`.
  - `func Load() ([]Section, error)` — parses every embedded `.md` except `WRITING.md` (README.md is the catalogue, not a page); cached after the first call.
  - `func Catalog() string` — `README.md` text.
  - `func Search(sections []Section, query string, limit int) []Section`
  - `func Page(sections []Section, page string) ([]Section, bool)`
  - `func BaseURL(version string) string` → `https://github.com/aiwatchtowers/watchtower/blob/v<version>/docs/guide/`
  - `func Anchor(heading string, seen map[string]int) string` — GitHub slug: lowercase; drop every rune that is not a letter, digit, space or `-`; spaces → `-`; a repeat gets `-1`, `-2`.

- [ ] **Step 1: Write the failing tests** in `internal/guide/guide_test.go`:
  - `TestLoadSplitsAtH2AndH3` — on the real embedded guide: `features/calendar.md` yields an intro section plus one per `##`/`###`; no section text contains a `## ` line.
  - `TestAnchorMatchesGitHub` — `Anchor("Why the briefing skips a day?", seen) == "why-the-briefing-skips-a-day"`; `Anchor("Recordings → Recap", …) == "recordings--recap"`; second `"Troubleshooting"` → `"troubleshooting-1"`.
  - `TestEveryPageIsInCatalog` — every embedded page path (except README/WRITING) appears as a link target in `Catalog()`.
  - `TestSearchPrefersHeadings` — `Search(sections, "recap", 3)` returns first a section whose heading contains "Recap"; `Search(sections, "zzzz-no-match", 3)` is empty.
- [ ] **Step 2: Run** `go test ./internal/guide` — expect FAIL (package missing).
- [ ] **Step 3: Implement.** Ranking: lowercase words of the query (drop words under 2 chars); per word, +3 if a heading word has it as a prefix, +2 page title, +1 text; ties keep guide order; return at most `limit` with score > 0.
- [ ] **Step 4: Run** `go test ./internal/guide` — PASS; `make lint-diff` clean.
- [ ] **Step 5: Commit** `feat(guide): embed docs/guide and index it by section`.

### Task 2: Go — `watchtower guide` CLI

Depends on: Task 1.

**Files:**
- Create: `cmd/guide.go`, Test: `cmd/guide_test.go`

**Interfaces:**
- Produces the pinned JSON the Desktop decodes (Task 4):
  - `watchtower guide index --json` → `{"version": "<Version>", "base_url": "<BaseURL(Version)>", "catalog": "<README>", "sections": [{"page", "page_title", "heading", "anchor", "level", "text"}]}`
  - `watchtower guide search --json "<query>" [--limit 5]` → `{"sections": [...same objects...]}`
  - `watchtower guide catalog` → README text (plain).
- No database is opened by any `guide` subcommand.

- [ ] **Step 1: Failing test** `TestGuideIndexJSONKeys` — run the command in-process, decode into `map[string]any`, assert the four top-level keys and the six section keys exactly; `version == Version`; `base_url` ends with `/blob/v` + `Version` + `/docs/guide/`. `TestGuideSearchLimit` — `--limit 2` returns ≤ 2 sections.
- [ ] **Step 2: Run** `go test ./cmd -run TestGuide` — FAIL.
- [ ] **Step 3: Implement** `guideCmd` with `index`, `search`, `catalog` subcommands, registered on `rootCmd`.
- [ ] **Step 4: Run** `go test ./cmd -run TestGuide` — PASS; `make lint-diff` clean.
- [ ] **Step 5: Commit** `feat(cli): watchtower guide index|search|catalog`.

### Task 3: Go — guide tools on the main chat

Depends on: Task 1.

**Files:**
- Create: `internal/tools/guide.go`, Test: `internal/tools/guide_test.go`
- Modify: `cmd/actions_registry.go` (`buildToolRegistry`, next to the Slack/Confluence chat-only tools)
- Modify: `internal/chat/prompt_sections.go` (`appGuide`), its prompt test/golden if one pins it

**Interfaces:**
- Produces: `func NewSearchGuide(version string) *Tool` (`Name: "search_guide"`, args `{query string, limit int (default 5, max 10)}`, returns `{sections: [{page, heading, anchor, url, text}]}` where `url = guide.BaseURL(version)+page+"#"+anchor`), `func NewGetGuidePage(version string) *Tool` (`Name: "get_guide_page"`, args `{page string}`, returns `{page, title, url, text}`; unknown page → `ValidationError{Msg: "unknown guide page; use search_guide"}`). Both `Access: AccessRead`, `Surfaces: []string{"main"}`. `buildToolRegistry` passes `Version` (the version reaches `internal/tools` as an argument, never an import of `cmd`).
- `appGuide` becomes: the current first sentence on what Watchtower is, then: "For any question about how to use Watchtower — a tab, a setting, why something is empty — call search_guide and answer from the sections it returns, using screen names as the app shows them; if nothing matches, say the guide doesn't cover it. To link a screen write watchtower-nav://<screen> with one of: home, chat, catchUp, briefings, dayPlan, inbox, ideas, calendar, targets, tracks, projects (Workbench), automations, digests, people, memory, workload, blockers, projectMap, releases, statistics, search, boards, usage, mcpServer." The list is only a hint to the model; the Desktop renderer is the guard (Task 5) — no cross-language test.

- [ ] **Step 1: Failing tests:** `TestSearchGuideToolMainOnly` — registry built by `buildToolRegistry` lists `search_guide` for surface `main` and not for `target`, `automation_editor`, `project`; `tools.ReadTools()` contains neither (DEV-01). `TestSearchGuideReturnsURL` — a query for "recap" returns a section whose `url` starts with `BaseURL(version)`. `TestPromptAppGuideMentionsSearchGuide` — `BuildSystemPrompt` for `main` contains `search_guide` and no longer contains `"Sidebar:"`.
- [ ] **Step 2: Run** `go test ./internal/tools ./internal/chat ./cmd -run 'Guide|AppGuide'` — FAIL.
- [ ] **Step 3: Implement**; register both tools in `buildToolRegistry` with a comment "chat-only, never ReadTools (DEV-01)".
- [ ] **Step 4: Run** the same command — PASS; update any prompt golden with `-update` and review the diff; `make lint-diff` clean.
- [ ] **Step 5: Commit** `feat(chat): the main chat answers app questions from the guide`.

### Task 4: Swift Core — guide index, ranker, help prompts, nav links

Depends on: none (codes against Task 2's pinned JSON; tests use a fixture).

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/GuideIndex.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Help/GuideSearch.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Help/HelpPrompt.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Help/NavLink.swift`
- Test: `WatchtowerDesktop/Tests/Core/GuideSearchTests.swift`, `HelpPromptTests.swift`, `NavLinkTests.swift` (fixture JSON inline, neutral text)

**Interfaces:**
- Produces:
  - `package struct GuideIndex: Decodable, Sendable { version, baseURL, catalog: String; sections: [GuideSection] }` (snake_case keys from Task 2), `package struct GuideSection: Decodable, Sendable, Identifiable { page, pageTitle, heading, anchor: String; level: Int; text: String; var id: String { page + "#" + anchor } }`, `func url(in index: GuideIndex) -> URL?`.
  - `package enum GuideSearch { static func rank(_ query: String, in sections: [GuideSection], limit: Int) -> [GuideSection] }` — same scoring as Go Task 1 (heading 3, title 2, text 1, word-prefix, ties keep order).
  - `package struct HelpScreen: Sendable { rawValue: String; title: String }`.
  - `package enum HelpPrompt { static func system(catalog: String) -> String; static func turn(question: String, previousQuestion: String?, currentPage: String, screens: [HelpScreen], sections: [GuideSection]) -> String }`.
  - `package enum NavLink { static let scheme = "watchtower-nav"; static func url(_ raw: String) -> URL; static func destination(from url: URL, allowed: Set<String>) -> String? }`.
- `HelpPrompt.system` copy (exact rules, wording may be tightened by the implementer, meaning may not):
  - "You answer questions about how to use the Watchtower Mac app. Answer only from the guide sections given with each question. If they don't cover it, say the guide doesn't cover it and suggest asking in AI Chat. Start with one line that answers, then numbered steps if there are steps. Use screen and button names exactly as the app shows them. To link a screen write a markdown link to watchtower-nav://<screen> using only the screens listed with the question. Never invent features, settings or shortcuts."
  - then `"Guide contents:\n" + catalog`.
- `HelpPrompt.turn` layout: `"Current page: <title>"`, `"Screens: <raw>=<title>, …"`, then `"Guide sections:"` with each section as `"### <page_title> › <heading>\n<text>"`, or the line `"Guide sections: none matched"` when empty; then `"Question: <question>"`. Retrieval query = `question + " " + (previousQuestion ?? "")`, done by the caller (Task 5) — `turn` only formats.

- [ ] **Step 1: Failing tests:**
  - `testRankPrefersHeading`, `testRankEmptyForNoMatch` (mirror Task 1).
  - `testFollowUpUsesPreviousQuestion` — `GuideSearch.rank("and then? " + "how do I get a recap", …)` returns the recap section first.
  - `testTurnPromptWhenNothingMatches` — `turn(…, sections: [])` contains `"Guide sections: none matched"` and the question.
  - `testTurnPromptListsOnlyGivenScreens` — screens `[calendar]` → prompt has `calendar=Calendar` and not `projects`.
  - `testNavLinkRejectsHiddenAndUnknown` — `destination(from: watchtower-nav://calendar, allowed: ["calendar"]) == "calendar"`; `…//projects` with allowed `["calendar"]` → nil; `…//nope` → nil; `https://…` → nil.
  - `testDecodesIndexFixture` — a two-section fixture decodes; `section.url(in:)` == `base_url + page + "#" + anchor`.
- [ ] **Step 2: Run** `make test-swift FILTER='GuideSearchTests|HelpPromptTests|NavLinkTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same — PASS; swiftlint strict clean.
- [ ] **Step 5: Commit** `feat(desktop-core): guide index, ranking, help prompts, nav links`.

### Task 5: Desktop — the ⌘/ panel and the help chat

Depends on: Task 2, Task 4.

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/AskCenter.swift` (on `AppState`, `@Observable @MainActor`)
- Create: `WatchtowerDesktop/Sources/Services/ChatSurfaces/HelpChatSurface.swift`
- Create: `WatchtowerDesktop/Sources/Views/Help/AskPanel.swift` (+ `AskPanelHost: ViewModifier`)
- Modify: `App/AppState.swift` (`askCenter`, `isAskPanelShown`, `showAskPanel()`), `Utilities/AllowedURLSchemes.swift` (add `NavLink.scheme`), the main window root and the workbench window root (attach `AskPanelHost` next to `RunAutomationPaletteHost`)
- Test: `WatchtowerDesktop/Tests/AskCenterTests.swift`

**Interfaces:**
- Consumes: `GuideIndex`, `GuideSearch.rank`, `HelpPrompt`, `NavLink` (Task 4); `CLIRunnerProtocol`; `SidebarVisibility.isVisible` / `SidebarDestination.isVisible(disabledFeatures:connected:)`.
- Produces:
  - `AskCenter(runner: any CLIRunnerProtocol)`: `var index: GuideIndex?`, `var indexError: String?`, `func loadIfNeeded() async` (runs `guide index --json` once per launch; a failure sets `indexError` and is retried on the next open), `func matches(for query: String, screens: [HelpScreen]) -> AskMatches` where `AskMatches { guide: [GuideSection]; screens: [HelpScreen] }` (guide ≤ 5, screens ≤ 4, screens by case-insensitive title prefix then contains).
  - `HelpChatSurface.spec(center: AskCenter, currentPage: @MainActor () -> String, screens: @MainActor () -> [HelpScreen]) -> ChatSurfaceSpec` — key `EmbeddedChatKey(contextType: "help", contextID: UUID per panel open, conversationID: nil)`, `.memory`, `.draftOnly`, `systemPrompt` = `HelpPrompt.system(catalog:)`, `turnPrompt` = rank on question + previous question (the spec keeps the last owner text) then `HelpPrompt.turn`, `runOptions` = provider from config, `model` = light model or `""`. `postTurn` records the top section of that turn so the view shows "From the guide: <page_title> › <heading>" linked to its URL.
  - `AppState.showAskPanel()` — sets `isAskPanelShown = true` in the key window's host; called by the ⌘/ command (Task 6).
- Behaviour pinned by the spec (copy verbatim): Ask row text `Ask Watchtower: "<query>"`; pill `on <Page title>`; footer `↑↓ choose  ↩ ask  esc close`; a guide row opens its URL in the browser; a screen row or ⌘↩ sets `selectedDestination` (raising the main window when the panel is in a workbench window) and closes; `Open in AI Chat` calls `chatViewModel.newConversation()` then `send` with the first question and navigates to `.chat`; Esc closes and restores the previous first responder (`PreviousFirstResponder`); closing drops the conversation (the engine is released, nothing stored).
- Answer links: the panel's markdown view gets an `OpenURLAction` that maps `NavLink.destination(from:allowed:)` with `allowed` = the visible screens; a nil result is ignored (the link does nothing) and the renderer shows such links as plain text.

- [ ] **Step 1: Failing tests** (`AskCenterTests`, a stub runner):
  - `testLoadsIndexOnce` — two `loadIfNeeded()` calls run the CLI once with args `["guide", "index", "--json"]`.
  - `testIndexFailureKeepsScreensAndExplains` — the runner throws; `matches("cal", screens: [calendar])` still returns the Calendar screen, `indexError != nil`.
  - `testMatchesCapAndOrder` — ≤ 5 guide rows, ≤ 4 screens, title-prefix screen before a contains match.
  - `testHelpSpecIsDraftOnlyMemory` — `spec.toolAccess == .draftOnly`, `spec.persistence == .memory`, `spec.key.conversationID == nil`.
  - `testTurnPromptCarriesCurrentPageAndSections` — with a loaded fixture index and current page "Calendar", `spec.turnPrompt(input("how do I get a recap"))` contains `Current page: Calendar` and the recap section heading.
- [ ] **Step 2: Run** `make test-swift FILTER=AskCenterTests` — FAIL.
- [ ] **Step 3: Implement** the center, the surface and the panel (overlay pattern: `RunAutomationPalette` — centred card, dimmed backdrop, host modifier on an `AppState` flag). Reuse `EmbeddedChatRows` + `EmbeddedChatComposer` for the conversation; the empty/typing state is the panel's own list.
- [ ] **Step 4: Run** `make test-swift FILTER='AskCenterTests|GuideSearchTests|HelpPromptTests|NavLinkTests'` — PASS; `swift build`; swiftlint strict clean.
- [ ] **Step 5: Commit** `feat(desktop): the ⌘/ Ask Watchtower panel`.

### Task 6: Desktop — menu, shortcut, Home line

Depends on: Task 5.

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/WorkbenchCommands.swift` (`HelpCommands`): add before "Keyboard Shortcuts": `Button("Ask Watchtower…") { appState.showAskPanel() }.keyboardShortcut("/", modifiers: .command)` and `Button("Watchtower User Guide") { open(<base_url>README.md) }` — the URL comes from `askCenter.index?.baseURL`, falling back to `https://github.com/aiwatchtowers/watchtower/blob/main/docs/guide/` only while the index has not loaded (the one fallback constant, in `AskCenter`).
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/KeyboardShortcutCatalog.swift` — Global: `Entry("⌘/", "Ask Watchtower: search the guide or ask how to do something")`.
- Modify: `docs/guide/reference/keyboard-shortcuts.md` — the same line under Global (the catalog test keeps them equal).
- Modify: `WatchtowerDesktop/Sources/Views/Home/HomeView.swift` — a muted line "Press ⌘/ to ask anything about Watchtower." shown only when the Getting ready zone is not shown.
- Test: extend `KeyboardShortcutCatalogTests` (existing guide-equality test covers the doc); add `testHomeHintHiddenWhileGettingReady` where Home's visibility logic lives (`GettingReadyPolicy`/Home view model) if it is testable without the view; otherwise no new test.

- [ ] **Step 1: Failing test** — catalog test fails until the guide line is added (existing `KeyboardShortcutCatalogTests`); add the Home hint test if applicable.
- [ ] **Step 2: Run** `make test-swift FILTER='KeyboardShortcutCatalogTests|Home'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same — PASS; `swift build`; swiftlint strict clean.
- [ ] **Step 5: Commit** `feat(desktop): Help › Ask Watchtower ⌘/ and the User Guide link`.

### Task 7: Release check and docs

Depends on: Tasks 1–6.

**Files:**
- Modify: `.claude/commands/release.md` — new step after "Generate Release Notes": list PRs merged since the previous tag whose changed files include `WatchtowerDesktop/Sources/Views/**`, `cmd/**` or settings code and none under `docs/guide/`; show them to the user with a one-line "does the guide need an update?" each; propose guide edits for the ones the user marks; never blocks the release.
- Create: `docs/features/ask-watchtower.md` — architecture, the JSON contract of `guide index`, the help-chat contract (no tools, memory, light model), `watchtower-nav://`, chat-only tools (DEV-01 note).
- Modify: `CLAUDE.md` Feature Notes — one line linking the new file.
- Create or modify: a guide page for the panel — `docs/guide/features/ask-watchtower.md` per `docs/guide/WRITING.md` (what it is, why, how, when it doesn't answer) and its line in `docs/guide/README.md` (Task 1's catalogue test enforces the README line).

- [ ] **Step 1:** Write the docs and the release step.
- [ ] **Step 2: Run** `go test ./internal/guide` (catalogue test still passes with the new page) and `make lint-diff`.
- [ ] **Step 3: Commit** `docs: Ask Watchtower feature notes, guide page and the release guide check`.

## Execution lanes

- Lane Go: Tasks 1 → 2, 3 (2 and 3 may run in parallel after 1).
- Lane Swift: Task 4 in parallel with the Go lane; Tasks 5 → 6 after Task 2 and 4 merge.
- Task 7 last. Heavy Swift work stays one lane at a time (CLAUDE.md).
