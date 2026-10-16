# Ask Watchtower (2026-10-16, board #426)

The ⌘/ panel answers "how do I use the app" from the embedded user guide (`docs/guide/`), and the main chat answers the same questions through two read tools. User-facing page: [docs/guide/features/ask-watchtower.md](../guide/features/ask-watchtower.md). Spec: `docs/superpowers/specs/2026-10-16-ask-watchtower-design.md`.

## Go side

- `docs/guide/embed.go` embeds the guide; `internal/userguide` parses each page (except `README.md` and `WRITING.md`) into `Section`s (page, page title, heading, GitHub-slug anchor, level 1 = intro / 2 / 3, text), caches them (`Load`), exposes `Catalog()` (the README text), `BaseURL(version)` (`https://github.com/aiwatchtowers/watchtower/blob/v<version>/docs/guide/`) and `Search`. The ranker: each query word adds only its best match, 3 for a heading word prefix, else 2 for a page-title word prefix, else 1 for a text substring; ties keep index order. `TestEveryPageIsInCatalog` fails when a page is missing from `docs/guide/README.md`.
- `watchtower guide index [--json]`, `guide search <q> [--limit N] [--json]`, `guide catalog`. This replaced an old deprecated stub that pointed to `people`.
- `guide index --json` is the contract the Desktop decodes: `{"version", "base_url", "catalog", "sections": [{"page", "page_title", "heading", "anchor", "level", "text"}]}`. Keep the keys pinned; Swift `GuideIndex` / `GuideSection` read them.
- Chat-only tools `search_guide` (query, limit 5, max 10 -> sections with `url`) and `get_guide_page`, `AccessRead`, surface `main` only (`internal/tools/guide.go`). DEV-01: they are chat tools, not part of the developer MCP surface (`--workbench`/`--project`). The main chat prompt carries a short `appGuide` block (`internal/chat/prompt_sections.go`) that tells it to call `search_guide` and lists the `watchtower-nav://<screen>` ids.

## Desktop side

- `AskCenter` (on `AppState`, `makeAskCenter`) loads the index once per launch through `guide index --json` (retried on the next open after a failure, `indexError`), ranks in Swift with `GuideSearch.rank` (the same algorithm as Go; no per-turn CLI), matches screens by title (prefix before contains), and keeps the open conversation's `sources` (the top section of each turn, by assistant message id).
- `AskPanel` (`Views/Help/AskPanel.swift`): typing lists **Ask**, **Guide** (opens `section.url(in:)` in the browser) and **Go to** rows; Return asks, ⌘Return opens a screen. Asking swaps in an `EmbeddedChatView`; **Open in AI Chat** re-asks the first question there. `Help > Ask Watchtower…` (⌘/) and `Watchtower User Guide` live in `HelpCommands`; `showAskPanel` fronts the main window first.
- `HelpChatSurface`: `.memory` persistence (no conversation row, closing releases the engine), `toolAccess: .draftOnly` (AGENT-04, no tools, never the owner's data), the configured provider's light tier (`aiModelLight`, else the model catalog's resolved light). Each turn's prompt (`HelpPrompt.turn`) carries the current page, the visible screens and the top four sections ranked over the question plus the previous question. A run that resumes no provider session (Codex, Ollama) gets earlier turns through `EmbeddedChatReplay`. Memory is not used on this surface.
- `watchtower-nav://<screen>` (`NavLink`): `<screen>` is a `SidebarDestination` raw value (Workbench is `projects`, a tab of the single main window). `MarkdownView` reads the environment value `markdownNavScreens` (`AppState.visibleHelpScreenIDs`, set on the main window) and `AllowedURLSchemes.strippingDisallowedLinks(navScreens:)` keeps the link only for a visible screen; any other becomes plain text. The scheme is never handed to NSWorkspace: `AppState.openNavLink` selects the destination and closes the panel.

## Keeping the guide true

A user-facing change updates its guide page in the same PR (`docs/guide/WRITING.md`). `/release` step 3 lists PRs since the last tag that touched Views, `cmd/` or settings code without touching `docs/guide/`, and asks the owner per PR whether the guide needs an update; it never blocks the release.
