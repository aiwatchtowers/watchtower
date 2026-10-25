# Learn Watchtower — Home's zone of feature cards (2026-10-25, board #718)

Design: `docs/superpowers/specs/2026-10-19-home-zones-design.md` §9 (owner asks #417, #605); plan: `docs/superpowers/plans/2026-10-25-home-learn.md` (decisions D1–D5). Ships in v0.25.0.

## Summary

Home's last right-column zone shows three cards at a time out of every card written in the user guide; what the owner has seen is kept in `learn_seen`. Cards new in the running version come first with a **NEW IN X.Y** badge; a card that replaces one the owner saw shows **UPDATED IN X.Y**. **See all** opens the full list.

## Cards live in the guide

- A card is a `<!-- learn` … `-->` block right under the `##`/`###` heading it teaches; format and authoring rules in `docs/guide/WRITING.md` "Learn cards". `<!-- learn: none -->` marks a section with nothing to try.
- `docs/guide/guide.go` `parse` moves each block into `Section.Cards` and out of `Section.Text`, so the knowledge index (`kb` source `guide`), the chat's guide search and `TestFeaturePagesUnder8KB` (which measures the page with blocks stripped, D5) never see cards. Fenced blocks are text. An unclosed block stays in the text and `internal/learn` reports it (`guide.HasStrayCardOpen`). `Hash()` still covers the raw bytes.
- `internal/learn` parses and validates every card (`Load() (Catalog, error)`): strict `key: value`, ids unique and kebab-case, areas/levels/kinds per §9.3, `since` = `X.Y.Z` or `next`, title ≤ 40 and text/`changed`/`chat:` prompt ≤ 120 runes, `changed` only with `replaces`, retired ids (named in any `replaces` or in `internal/learn/retired.txt`) never reused. `retired.txt` (embedded, `<old> <new>` lines) keeps an id retired after the card that replaced it is deleted; it is validated (well-formed, each old id once, `new` a card or a retired id, no loops), and each card's JSON `replaces` is its own list expanded back through the file (C replaces [B] with `A B` in the file → [B, A]), so the Desktop reads `replaces` as is (§9.7). Action grammar: `nav:<screen>` (`navScreens` = `SidebarDestination` raw values + `InboxRoute.aliasHosts`, a Go↔Swift dual path named in the code), `connect:<source>`, `turnOn:<featureID>` (a registry id with a switch), `chat:<prompt>`, `hotkey:<name>` (the `hotkeys` table with labels). `TestGuideCardsValid` fails CI on any bad card. All errors are reported at once.
- `watchtower guide learn [--json]` (`cmd/guide.go`, no config or database): `{"cards":[{id,title,text,area,level,kind,since,action,changed,done_when,requires,replaces,page,anchor,hotkey_label}],"retired":[…]}`, empty optionals `""`/`[]`; keys pinned by `TestGuideLearnJSONKeys`.
- The starter set (v0.25.0): 236 cards over the feature, concept and reference pages; cards for features older than v0.25.0 carry `since: 0.24.0` (D4).

## Release

`.claude/commands/release.md` Step 3 replaces every `since: next` with the version being released (`sed`, D1) and warns about new `##` sections with no card. The warning never blocks a release.

## Seen state — `learn_seen` (migration 00159)

`item_id` PK, `how` ∈ `got_it` | `action` | `in_use`, `seen_at` (UTC ISO-8601 seconds). Written only by the Desktop (`LearnQueries.markSeen`, `INSERT OR IGNORE`); **Show again** deletes the row. An id no longer in the guide is ignored; its row stays.

## Desktop

- `WatchtowerCore`: `Models/Learn.swift` (`LearnCard`, `LearnCatalog`, `LearnArea(goal:)`, `LearnSignal`, `LearnSeenHow`), `Services/LearnSelector.swift` (pure: §9.4 order — fresh cards, then the onboarding goals' areas, then the rest in §9.3 order, then level, then met requirement, then guide order; one card per area unless one area is left; §9.7 replace chains; the ids to record `in_use`; the See all sections), `Services/LearnVersionPolicy.swift`, `Services/LearnInputs.swift` (signals and met requirements from app state; the primary-button mapping `LearnPrimary`), `Database/Queries/LearnQueries.swift`.
- `Services/LearnCenter.swift` on `AppState` (`AppState+Learn.swift`): loads `guide learn --json` once per launch through `ProcessCLIRunner`; a failed load or an empty catalog hides the zone; the load is one task per launch that a restart waits for rather than cancels. "Onboarding finished before this launch" is the local step at init or the profile `reconcileOnboarding` restores it from. It recomputes on a GRDB observation of `LearnQueries.observedTables`, on a 30 s tick, and when goals, disabled features or linked phones change.
- Views: `Views/Home/LearnZoneView.swift` (header "N of M seen" + bar + **See all →**; cards with the primary button, **Got it**, **Read more**, **Ask about this**; "You've seen everything…" when all are seen), `Views/Home/LearnAllSheet.swift` (New in X.Y, then per-area sections with n of m, level and kind filters, seen cards dimmed with **Show again**; an `in_use` card has "In use" instead, since the next read would record it again, and `LearnCenter.showAgain` ignores it). Card title, text and `changed` render their inline markdown (`LearnText.styled`).
- Actions: `nav:` → `openNavLink` (a hidden screen opens nothing, the card still counts as seen), `connect:` → `openAccountConnection` (imap → email, confluence → Jira's settings), `turnOn:` → `turnOnFeatureFromEmptyState`, `chat:` and **Ask about this** → the ⌘/ popup prefilled (keeps a draft), `hotkey:` → shows the key, **Read more** → `GuideLinks` page#anchor. The primary button records `action`, **Got it** records `got_it`.

## Signals (`done_when`, D2) — Go↔Swift dual path

`learn.Signals` (Go, pinned by `TestSignalsPinned`) and `LearnSignal` (Swift, pinned by `LearnModelTests.testSignalListPinned`) hold the same twelve values. Row-backed (`LearnQueries.rowSignals`, one read): `meeting.recorded` (`meeting_transcripts`), `chat.used` (a `chat_messages` row with role `user` in a main-chat conversation, `context_type IS NULL`; embedded chats do not count), `workbench.bound` (`projects`), `reaction.used` (a `reaction_commands` row with status `dispatched`; the seed's `skipped` rows for reactions older than the feature never count), `automation.created` (`automations` with origin `owner`), `confluence.connected` (an enabled `ext_sources` row for Confluence). From app state: `memory.on` (only once features loaded), `calendar.connected`/`jira.connected`/`linear.connected` (`ConnectedSources.fetch`, never the sidebar's fail-open value — a signal writes a permanent row), `iphone.paired` (linked phones), `dictation.used` (`UserDefaults` `learn.dictationUsed`, set by `DictationCenter` on a dictation that delivered text). A true signal records the card `in_use` and it never shows (unless it is an updated card).

## Version policy (D3)

`LearnVersionPolicy` per workspace (the database folder name): `learn.lastVersion.<ws>`, `learn.newAfter.<ws>` (the version the update came from) and `learn.newSince.<ws>` (when the update was first seen; the NEW badge lasts 14 days or until seen). A fresh install (onboarding not finished before this launch) has nothing new. The first launch of a version with Learn on an install that was already set up treats it as an update from X.(Y−1).0, so the v0.25.0 cards are new. A version string that does not parse (a plain "dev") behaves like a fresh install and writes nothing; a `git describe` version such as `v0.25.0-3-gabc` parses as 0.25.0 and is handled like that release.

## v1 limits

- Area sections in See all carry no "your goal" tag.
- A `nav:` card for a hidden screen opens nothing.
- No signal for an Inbox filter opened (the Day Plan and Ideas screens became Inbox filters in C1, so `dayplan.opened`/`ideas.opened` from §9.6 were dropped).
