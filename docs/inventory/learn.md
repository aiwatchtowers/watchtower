# Behavior Inventory — Learn Watchtower (Home)

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when changing how the guide is parsed, the `guide learn`
> command, the `learn_seen` table or the Desktop's Learn code, read this file
> first. Any proposed change that would break a guard test or remove a
> contract must be raised as a question before touching code.

**Module:** `docs/guide/guide.go`, `internal/learn/`, `cmd/guide.go`, `internal/db/migrations/00159_learn_seen.sql`, `WatchtowerDesktop/Sources/WatchtowerCore/{Models/Learn.swift,Services/LearnSelector.swift,Services/LearnVersionPolicy.swift,Services/LearnInputs.swift,Database/Queries/LearnQueries.swift}`, `WatchtowerDesktop/Sources/Services/LearnCenter.swift`, `WatchtowerDesktop/Sources/Views/Home/Learn*.swift`
**Last full audit:** 2026-10-25

## LEARN-01 — cards are metadata, their contract is pinned, seen state is the owner's

**Status:** Enforced

**Observable:**
- A `<!-- learn` … `-->` block in a guide page is a card, never guide text: `guide.parse` moves it into `Section.Cards`, so the knowledge index (`guide` source), the chat's guide search and the 8 KB page limit never see it (a fenced block stays text). Every shipped card passes `internal/learn` validation, so a broken card fails CI, not an install.
- `watchtower guide learn --json` prints `{"cards":[…],"retired":[…]}` with the keys `id, title, text, area, level, kind, since, action, changed, done_when, requires, replaces, page, anchor, hotkey_label` (empty optionals `""`, `replaces` `[]`), reads no config and opens no database. The Desktop decodes exactly these keys.
- A card id never changes or comes back once retired (`internal/learn/retired.txt` keeps the history; a replacing card's `replaces` covers its whole chain).
- `learn_seen` (one row per card, `how` ∈ `got_it`/`action`/`in_use`) is written only by the Desktop (`LearnQueries.markSeen`, `INSERT OR IGNORE`) and only from the owner's press or real use of the feature — never from a fail-open state (features not loaded, the sidebar's default sources) or seeded history. **Show again** deletes the row and is not offered for an `in_use` card.

**Test guards:**
- Guard: `docs/guide/cards_test.go::TestParseLearnCards`, `TestStripCards`; `docs/guide/guide_test.go::TestFeaturePagesUnder8KB`; `internal/learn/learn_test.go::TestGuideCardsValid`, `TestSignalsPinned`; `cmd/guide_test.go::TestGuideLearnJSONKeys`, `TestGuideLearnNeedsNoConfig`; `WatchtowerDesktop/Tests/Core/LearnModelTests.swift::testDecodesTheContract`, `testSignalListPinned`; `WatchtowerDesktop/Tests/Core/LearnQueriesTests.swift::testSeenInsertIgnoreAndShowAgain`, `testReactionSignalSkipsSeededRows`, `testChatSignalOnlyFromTheMainChat`
- Supporting: `internal/learn` load/validation tests (rejects, retired ids, history file, chains), `TestNavScreensMatchDesktop`, `TestHotkeyLabelsInShortcutsPage`; `LearnSelectorTests`, `LearnVersionPolicyTests`, `LearnInputsTests`, `LearnCenterTests`, `LearnZoneViewTests`

**Why locked:** Cards ship in the binary to every install and their seen state is keyed by id: a reused id would mark a new card seen, a key change would hide the zone, and a card leaking into guide text would pollute the chat's answers and search. A false `in_use` row hides a card for good, so the signals must mean real use.

**Locked since:** 2026-10-25

## Changelog

- 2026-10-25: file created with LEARN-01, introduced by Home's Learn zone (board #718, owner approval in ask #608).
