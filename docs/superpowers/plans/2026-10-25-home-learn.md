# Home — Learn Watchtower zone (board #718) — implementation plan

Design: `docs/superpowers/specs/2026-10-19-home-zones-design.md` §9 (approved,
asks #417 and the comments on #416); mockups: screens 1 and 5 of
`docs/superpowers/specs/2026-10-19-home-zones-mockups.html`. This plan only
pins what §9 leaves to the builder; where it says nothing, §9 rules.

Branch: `feature/718-home-learn` off main. Lanes run in their own worktrees
and are merged into it by the controller. Ships in v0.25.0 (owner, ask #605).

## Decisions this plan takes (builder's calls, §9 leaves them open)

- **D1 — no Go stamping code.** The release step replaces `since: next` with
  a `sed` over `docs/guide/**/*.md` in `.claude/commands/release.md`, and the
  "new sections without a card" warning is a shell snippet there too.
- **D2 — signals vocabulary for v1:** `meeting.recorded`, `chat.used`,
  `workbench.bound`, `reaction.used`, `automation.created`, `memory.on`,
  `calendar.connected`, `jira.connected`, `linear.connected`,
  `confluence.connected`, `iphone.paired`, `dictation.used`. `dayplan.opened`
  and `ideas.opened` are dropped: those screens became Inbox filters (C1).
  `dictation.used` is a per-install `UserDefaults` flag set by
  `DictationCenter` on a finished dictation. The list is a Go↔Swift dual path:
  Go validates it (`learn.Signals`), Swift reads it (`LearnSignal`); a test on
  each side pins the same list.
- **D3 — first release with Learn.** An install with no
  `learn.lastVersion.<workspace>` whose onboarding was already finished
  before this launch counts as updated from the previous minor: cards whose
  `since` equals the running version are **new**. A fresh install (onboarding
  not finished at first launch of this version) has no new cards.
  `learn.newSince.<workspace>` stores when the update was first seen, for the
  14-day badge window.
- **D4 — `since` of the starter cards.** A card about a feature that shipped
  before v0.25.0 carries `since: 0.24.0` (a floor: older history is not
  reconstructed). Cards for what shipped since v0.24.0 carry `since: next`.
- **D5 — the 8 KB page limit measures the page without its cards**
  (`TestFeaturePagesUnder8KB` strips `<!-- learn … -->` blocks first), as §9.2
  says cards are not guide text.

## Contracts

`watchtower guide learn --json` prints one JSON object (last stdout line):

```
{"cards":[{"id","title","text","area","level","kind","since","action",
           "changed","done_when","requires","replaces":[],"page","anchor"}],
 "retired":["…"]}
```

Empty optional values are `""` (and `[]` for `replaces`); `page` is the guide
path (`features/home.md`), `anchor` the section's `guide.Slug`. Keys are
pinned by a Go test.

`action` grammar: `nav:<screen>` (a `SidebarDestination` raw value accepted
by `watchtower-nav://`), `connect:<source>` (slack, google, jira, linear,
confluence, imap, calendar), `turnOn:<featureID>` (an
`internal/features/registry.go` id), `chat:<prompt>` (≤ 120 chars),
`hotkey:<name>` (a key named in `internal/learn` with its label, e.g.
`help` → ⌘/, `sidebar` → ⌘B, `quick-run` → ⌃⌘R).
`requires`: `feature:<id>` or `source:<name>`.

Table (migration 00159):

```sql
CREATE TABLE learn_seen (
  item_id TEXT PRIMARY KEY,
  how     TEXT NOT NULL CHECK (how IN ('got_it','action','in_use')),
  seen_at TEXT NOT NULL
);
```

Written only by the Desktop (GRDB); Show again deletes the row.

## Tasks

### Task 1 — `internal/learn` + guide parsing + CLI (Go). Depends on: none

- `docs/guide/guide.go`: `parse` pulls every `<!-- learn` … `-->` block out
  of the text into `Section.Cards []string` (raw block bodies, in order);
  `Section.Text` no longer contains them. A one-line `<!-- learn: none -->`
  is dropped from the text too and sets nothing. `TestFeaturePagesUnder8KB`
  measures the page with the blocks removed (D5).
- `internal/learn`: `Card` (the contract keys), `Load() ([]Card, []string,
  error)` over `guide.Pages()`, strict key: value parsing (unknown key,
  duplicate key, missing required key → error naming page and id),
  validation per §9.2/§9.3/§9.7 (unique ids, retired ids never reused, every
  `replaces` id is retired, areas, levels, kinds, action grammar, `requires`
  grammar, signals = D2, title ≤ 40, text and changed ≤ 120 runes, `since`
  `X.Y.Z` or `next`, `changed` only with `replaces`). Retired ids = every id
  named in some `replaces`.
- `TestGuideCardsValid` loads the real guide and fails on any error.
- `cmd/guide.go`: `watchtower guide learn --json` (and a plain text table
  without `--json`). No database, no config needed.
- Tests: parser cases, each validation rule, pinned JSON keys, the strip
  from `Section.Text`.
- Checks: `go test ./docs/guide/ ./internal/learn/ ./internal/kb/
  ./internal/chat/`, `go test ./cmd -run Guide`, `make lint-diff`.

### Task 2 — migration `learn_seen` (Go). Depends on: none

- `internal/db/migrations/00159_learn_seen.sql` (Up/Down), mirror in
  `schema.sql`, `TestAllTablesExist`, regenerate the golden and the Swift
  test schema (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`).
- Checks: `go test ./internal/db/`, `make lint-diff`.

### Task 3 — Learn core (Swift, WatchtowerCore). Depends on: Tasks 1, 2

- `Models/Learn.swift`: `LearnCard` (Decodable from the contract),
  `LearnArea` (the nine areas in §9.3 order), `LearnLevel`, `LearnKind`,
  `LearnSignal` (D2), `LearnCatalog` (`cards`, `retired`).
- `Services/LearnSelector.swift` (pure): input = catalog, seen rows
  (`id → how`), true signals, met requirements, onboarding goals, the
  previous version / new window (D3), now. Output = the three Home cards
  (§9.4 order and variety rule, never a seen card, `in_use` cards to record),
  each with its variant (`.normal`, `.new(version)`, `.updated(version)` with
  `changed` text, §9.7 incl. replace chains), seen count `N of M`, and the
  See all model (New section, then per-area sections with `n of m`, every
  card incl. seen ones dimmed).
- `Database/Queries/LearnQueries.swift`: read seen rows, insert (`INSERT OR
  IGNORE`), delete (Show again), and the row-backed signals in one read
  (`meeting_transcripts`, owner messages in the chat tables, `projects`,
  `reaction_commands`, `automations` where origin is the owner's).
- `Services/LearnVersionPolicy.swift`: D3 over `UserDefaults` keys
  `learn.lastVersion.<workspace>` / `learn.newSince.<workspace>`, injectable
  defaults, semantic version compare.
- Tests in `Tests/Core`: selector order, variety, requires sorting, new and
  updated variants, chains, in_use recording, all-seen state, the version
  policy (fresh, first-with-Learn, normal update, 14-day expiry), the
  queries against the test schema, `LearnSignal` list pinned against D2.
- Checks: `make test-swift FILTER='Learn'`, `make lint-swift`.

### Task 4 — Learn zone and See all sheet (Swift UI). Depends on: Task 3

- `LearnCenter` on `AppState`: runs `watchtower guide learn --json` through
  the existing CLI runner at launch (and after an update, i.e. once per
  launch), keeps the catalog in memory; a failed read hides the zone and logs.
  Home refresh computes the selection with live seen rows and signals
  (non-row signals from `FeatureVisibility` / accounts / `MobileHubService` /
  the dictation flag) and writes `in_use` rows the selector returns.
- `Views/Home/LearnZoneView.swift`: last zone of the right column
  (`HomeSideColumn`), header "Learn Watchtower" + "N of M seen" + thin bar +
  **See all →**; three cards: badge (NEW IN X.Y / UPDATED IN X.Y), title,
  text, primary button (from `action`, or Turn on / Connect when `requires`
  is missing, else **Read more**), **Got it**, **Ask about this**. All seen →
  "You've seen everything. New cards come with each update." + See all.
  Design kit components only; follow the mockups.
- `Views/Home/LearnAllSheet.swift`: New in X.Y on top, per-area sections with
  "n of m", level and kind filters, seen cards dimmed with **Show again**.
- Actions: `nav:` → `openNavLink`, `connect:` → `openAccountConnection`,
  `turnOn:` → `turnOnFeatureFromEmptyState`, `chat:` → the ⌘/ popup with the
  prompt in the composer (keeps a draft, like Search's Ask in chat),
  `hotkey:` → shows the key and records seen on press; Read more →
  `GuideLinks` URL for page#anchor; Ask about this → popup with "How do I use
  <title>?". A pressed action records `action`, Got it records `got_it`.
- `DictationCenter` sets the `dictation.used` flag on a finished dictation.
- Tests: ViewInspector for the zone states (cards, all seen, hidden on
  failure), action → seen row, sheet sections/filters/Show again.
- Checks: `make test-swift FILTER='Learn|HomeContent'`, `make lint-swift`,
  `make desktop-shots` of Home with the zone and the sheet.

### Task 5 — the starter cards (content). Depends on: Task 1

About 150–200 cards over `docs/guide/features/**` and `concepts/`, written
under the heading they teach, following §9.2 and the WRITING.md card rules
added in Task 6 (Task 5 lanes get them in their brief). D4 for `since`.
Every feature and change merged since v0.24.0 gets its card with
`since: next`. Run in four lanes by page group (disjoint files):
(a) communication + planning pages, (b) meetings + tasks + iPhone,
(c) workbench/** + development, (d) assistant + automations + setup +
concepts. Each lane: `go test ./docs/guide/ ./internal/learn/`.

### Task 6 — docs and the release step. Depends on: Tasks 1–4

- `docs/features/learn.md` (feature note: card format, contract, table,
  selector, signals dual path, version policy, v1 limits), CLAUDE.md index
  entry, `docs/inventory/` entries for the contract and the table writer
  rule, `docs/guide/WRITING.md` "Learn cards" section, the guide's Home page
  (Learn zone, See all) with its own card.
- `.claude/commands/release.md` Step 3: the `since: next` stamp and the
  "new `##` sections without a card" warning (D1).
- Checks: `go test ./docs/guide/ ./internal/learn/`.

### Gate (controller)

`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, then the
PR with the `local-review` final review.
