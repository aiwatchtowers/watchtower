# Confluence Page Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Let the owner read a Confluence page (with all comments) live from the chat and apply assistant-proposed fragment or section edits after a word-diff Approve. Edits are version-checked, and rich elements are preserved through markers.

**Architecture:** A pure `internal/confluenceedit` package converts storage XHTML ↔ editable text with `⟦k:label⟧` markers and applies edits by re-serialising only the touched blocks. Two registry tools, `get_confluence_page` (read, live) and `edit_confluence_page` (External write; Normalize pins `new_storage` and the diff; Execute re-checks the version and PUTs), ride the account's shared `*jira.Client` through a new `ConfluenceAPI.PutJSON`. On the Desktop, the agent-action card renders a word diff, and the Confluence section gains an "Allow editing" button.

**Tech Stack:** Go 1.25 (`golang.org/x/net/html`), the existing tool registry (`internal/tools`), SwiftUI + WatchtowerCore.

**Spec:** `docs/superpowers/specs/2026-09-30-confluence-page-editing-design.md`. Read it first; it is binding.

## Global Constraints

- English everywhere in the repo. Each task's commits end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. Stage by explicit path only.
- Worktree: `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/confluence-write`, branch `feature/confluence-write`. Never touch the main checkout.
- Tests cover the touched packages only (`go test ./internal/<pkg>`, `make test-swift FILTER=<Class>`). The harness refuses a literal `go test ./cmd` in this worktree, so use `make test` if cmd tests must run. Controller runs full gates once. Long commands write to a log file and the exit code is checked explicitly. Bound any fuzz with `-fuzztime`. Never use the `timeout` binary. Never delete `WatchtowerDesktop/.build`.
- Public repo: fixtures use `example.com`, fake ids, and generic names. `bash scripts/leak-check.sh origin/main..HEAD` must stay clean.
- Contracts: EXT-01 is narrowed (method pin `{Download, GetJSON, PutJSON}`, plus a guard that the extsync engine and the fetcher cannot reach PutJSON), never weakened. The new EXT-05 has three guards named `TestEXT05_*`. AGENT-03: the edit tool is `External`.
- Caps: editable text ≤ 60 000 runes; ≤ 200 comments; ≤ 20 edits per call.
- Write scopes: `write:page:confluence write:blogpost:confluence`, opt-in via `--with-confluence-write` (implies `--with-confluence`); a re-login keeps granted write scopes.
- Version message on PUT: `Edited via Watchtower`.
- Marker syntax: `⟦k:label⟧`, where k is a per-page ordinal starting at 1.
- Keep functions under the complexity gate (~13).

## Review Focus

1. **A page with macros, mentions, tables and layouts, edited in one paragraph** → every other byte of the storage is unchanged, and the macros survive.
2. **Two edits in one call touching the same block**, or the second edit's `old` text is created by the first → deterministic behavior: apply edits in order against the evolving doc, and fail cleanly if a later edit no longer matches.
3. **The page is edited by someone else between preview and Approve** → no PUT, and a clear conflict message.
4. **Cyrillic text and typographic quotes in `old`** → whitespace/NBSP-normalised matching still finds them.
5. **A title that matches several pages** → the candidates are returned; nothing is guessed.

---

### Task 1: Write scopes, `PutJSON`, login flag, EXT-01 narrowing

**Files:** `internal/jira/scopes.go`, `internal/jira/confluence_api.go` (+tests), `internal/jira/confluence_contracts_test.go`, `internal/confluence/*_test.go` (guard), `cmd/jira.go` (+tests), `docs/inventory/external-sources.md`.

**Produces:**
- `const ConfluenceWriteScopes = "write:page:confluence write:blogpost:confluence"`.
- `func HasConfluenceWriteScopes(tok *OAuthToken) bool`.
- `func (a *ConfluenceAPI) PutJSON(ctx context.Context, path string, body any, out any) error`: method PUT, JSON body, `Accept: application/json`, non-2xx → `*HTTPStatusError`. It uses `doURL` with the body bytes, and the retry-safe body rebuild already exists.
- `jira login|add --with-confluence-write`: scope set = JiraScopes + ConfluenceScopes + ConfluenceWriteScopes. `jiraReloginOptions` keeps write scopes when the stored token `HasConfluenceWriteScopes`. A token-read error is handled like the existing Confluence case: decide read from ext_sources, and never auto-add write.

**Tests:**
- scopes: the write flag reaches the auth URL; re-login with a write-scoped token requests the write scopes; re-login without one does not.
- `PutJSON`: sends PUT to `/ex/confluence/<cloud>/wiki/...` with the JSON body; a 409 comes back as `*HTTPStatusError{Status:409}`; a 401-then-refresh re-sends the full body.
- EXT-01 update: the method pin becomes exactly `{Download, GetJSON, PutJSON}`.
- New guard `TestEXT01_FetcherCannotReachPut`: the `confluence.API` interface has no PUT-capable method (reflect over its method set: exactly `GetJSON`, `Download`), and `go list -deps ./internal/extsync` still excludes `internal/jira`.
- Inventory: update the EXT-01 wording ("the sync path is GET-only; writes exist only for the edit tool, EXT-05").
- [ ] Implement with TDD, mutation-check the guards, and commit.

### Task 2: `internal/confluenceedit` — model, editable text, markers, round-trip law

**Files:** `internal/confluenceedit/{doc.go,parse.go,text.go,render.go}` + tests + `testdata/*.xhtml` (reuse copies of `internal/confluence/testdata/storage/*.xhtml`; add `rich.xhtml` with a table, nested list, mention, Jira macro, image, code, panel, layout, status macro, and emoticon).

**Produces:**
- `type Doc struct{...}` (unexported internals).
- `func Parse(storage string) (*Doc, error)`: reuses the self-closing and CDATA normalisation from `internal/confluence`. Export a helper there if needed, e.g. `confluence.NormalizeStorage(string) string`, and keep one implementation.
- `func (d *Doc) Text() string`: editable text per spec §3; markers as `⟦k:label⟧`.
- `func (d *Doc) Render() string`: storage XHTML; untouched blocks emit their original bytes.
- `func (d *Doc) Markers() []Marker` with `Marker{Ordinal int; Label string; Raw string}`.

**Tests:**
- `TestEXT05_RichElementsSurviveUntouched` (lives here): for every fixture, `Parse → Render` equals the canonical input byte for byte.
- `Text()` goldens: headings `#`, lists `-`/`1.`, bold `**`, italic `_`, code spans, links `[t](url)`, a plain table as a pipe table, a rich table as one block marker, mentions and macros as markers with sensible labels. Cyrillic is preserved.
- Marker ordinals are stable and unique; labels never contain `⟧`.
- A bounded fuzz (`-fuzztime=30s` once) on the Parse→Render round-trip for well-formed input seeds.
- [ ] Implement with TDD and commit.

### Task 3: `confluenceedit` — edits and markdown → XHTML

**Files:** `internal/confluenceedit/{apply.go,markdown.go}` + tests.

**Produces:**
- `type Edit struct{ Kind string; Old, New, Heading, NewBody string }`, where Kind is `replace_text` or `replace_section`.
- `type Change struct{ Kind, Locator, Before, After string; Removed []string }`.
- `func Apply(d *Doc, edits []Edit) (newStorage string, changes []Change, err error)`:
  - edits apply in order against the evolving doc;
  - errors are `*EditError{Index int; Msg string}` with actionable messages (not found / ambiguous (N matches) / spans blocks / heading not found / heading ambiguous / unknown marker ⟦k⟧ / duplicate marker ⟦k⟧ / empty edit).
- Markdown subset → storage:
  - paragraphs, `-`/`1.` lists (nested by indentation), pipe tables → `<table><tbody><tr><th|td>`, fenced code → the `ac:structured-macro ac:name="code"` with a CDATA body (escape `]]>` by splitting);
  - inline: bold, italic, strike, code, links, line breaks; markers → the original bytes;
  - text is HTML-escaped.
- `replace_text`:
  - normalises whitespace and NBSP;
  - matches within one block's text;
  - re-serialises only that block (keeping the block's tag and attributes);
  - inline formatting outside the replaced span within the block is preserved by re-serialising from the block's editable text with the edit applied.
- `replace_section` keeps the heading and replaces the body up to the next heading at the same or higher level.

**Tests:**
- every error kind;
- a single-paragraph edit on `rich.xhtml`: the diff of Render output vs original touches only that `<p>`;
- a table-cell edit;
- a list-item edit;
- a section replace with a table + list + code + marker kept;
- a removed marker listed in `Removed`;
- two edits in one call;
- the second edit fails because the first removed its target;
- `]]>` in code;
- Cyrillic/quotes/NBSP matching;
- a no-op edit (old == new) → an error ("edit changes nothing").
- [ ] Implement with TDD, mutation-check the block-locality test, and commit.

### Task 4: Tools, registry, prompts, EXT-05, inventory

**Files:** `internal/tools/confluence_page.go` (+tests), `cmd/actions_registry.go` (+ the pin test), a client factory in `cmd/`, `internal/ai/prompt.go` (+test), the 5 Swift chat prompt copies (the same files that carry the `search_knowledge` paragraph — find with grep), `docs/inventory/external-sources.md` (EXT-05), `docs/inventory/agent-actions.md` if it lists tools.

**Produces:**
- A `ConfluencePageClient` interface in `internal/tools`: `GetPage(ctx, id) (Page, error)`, `PutPage(ctx, id string, kind string, body PutBody) (int /*new version*/, error)`, `Comments(ctx, id) ([]Comment, error)`, `HasWriteScopes() bool`. The factory builds one from the account's `*jira.Client` + `confluence.Fetcher`.
- `NewGetConfluencePage(factory)` and `NewEditConfluencePage(factory)` per spec §4 (surfaces main + target; `External` on edit; Normalize pins `{account_id,page_id,kind,title,url,base_version,new_storage,changes}`; Execute re-checks the version).
- The title resolution uses `kb.Search` (Sources `["confluence"]`) through the DB.

**Tests:**
- `TestEXT05_WriteRequiresMatchingVersion`: the fake client's live version differs at Execute → error and zero PutPage calls. Also the propose-time mismatch.
- `TestEXT05_OnlyEditToolReachesPut`: an import/grep guard that only `internal/tools/confluence_page.go` + its factory in cmd call `PutJSON`/`PutPage`.
- propose pins; the successful Execute PUT body (version+1, message, representation storage); 403 → the scope hint; 409 → conflict; the missing-write-scope Validate message; ambiguous title → candidates; comment rendering (inline anchor, resolved, replies); the 60k-rune truncation flag.
- The registry pin test lists both tools with their surfaces. The prompt pin tests are updated (Go + Swift).
- [ ] Implement with TDD and commit.

### Task 5: Desktop — diff card, Allow editing, access reporting

**Files:** WatchtowerCore `WordDiff.swift` (+ `Tests/Core/WordDiffTests.swift`), `AgentActionCardView.swift` (+ its tests), `ConfluenceSpacesViewModel.swift` + `ConfluenceSpacesSection.swift` (+ tests), the CLI `cmd/confluence.go` access reporting (`confluence spaces --json` gains a top-level wrapper? NO — keep the array shape; add `watchtower confluence access --account N --json` → `{"read":bool,"write":bool}`), `docs/app-guide.md`.

**Produces:**
- `WordDiff.diff(before:after:) -> [Segment]` with `Segment{kind: .same|.removed|.added, text}` (word-level; whitespace-preserving).
- The card for `edit_confluence_page`: title + link; per change, the locator + the diff (red strikethrough / green); a "Removes:" line; errors from `result_json.error`.
- The VM exposes `canEdit` from `confluence access`; the section shows **Allow editing** when read is true and write is false. It runs the existing re-login flow with `--with-confluence-write` (a sibling of `reloginWithConfluence`).

**Tests:**
- WordDiff (insert/delete/replace/Cyrillic/empty);
- the card summary for the tool;
- the VM `canEdit` + button visibility;
- the Allow editing action invokes the right args;
- the Go `confluence access` command (read/write combos, token error).
- [ ] Implement with TDD and commit.

### Task 6: Docs + gates hand-off

**Files:** `CLAUDE.md` (a new subsection under the Confluence connector note: editing from chat, tools, markers, EXT-05, scopes flag, v1 limits: no comment replies, no new pages, rich tables are one marker), and spec §10 "Implementation deltas" if any rulings were made.
- [ ] Write it, run leak-check, and commit.
