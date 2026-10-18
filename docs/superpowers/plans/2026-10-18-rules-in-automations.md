# Rules in one place: reaction events + Automations showcase — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The owner's Slack reactions publish a content-free `slack.reaction_added` event that recipes can subscribe to, and the Automations tab shows every rule kind (recipes, reactions, tracks) in one place.

**Architecture:** `phaseReactionCommands` already runs inside the daemon's event cycle (after `phaseSlackSync`, before `Flush`). It gets the cycle's bus and publishes one event per newly seen owner reaction. A separate `reaction_events` ledger plus a per-account seed stamp give exactly-once behaviour and never replay history; the dictionary path (`reaction_commands`) is not touched. The Desktop adds a section picker to `AutomationsView` (Automations / Reactions / Tracks). The dictionary editor moves from Settings → Slack into the Reactions section.

**Tech Stack:** Go 1.26, SQLite/goose, SwiftUI + GRDB (WatchtowerCore).

**Spec:** `docs/superpowers/specs/2026-10-18-rules-in-automations-design.md` (approved, ask #350).

**Board:** target #652; branch `feature/rules-in-automations`; worktree `../watchtower-wt/rules-in-automations`.

## Global Constraints

- Event type id `slack.reaction_added`. Matchable fields `account`, `channel_id`, `emoji`; also carried (not matchable): `message_ts`. No message text, author or channel name in the event.
- `emoji` is the bare short name without colons (the dictionary's spelling); `channel_id` is the namespaced `<account>:<raw>` id (the same as `slack.new_messages`); `account` comes from `db.SlackEventLabels`.
- `reaction_commands` (table, status CHECK, readers, REACT-01..05) is unchanged; a dictionary reaction's ledger row is exactly today's.
- With no runnable subscriber and an empty dictionary there is no `reactions.list` call.
- Reaction events need both `reaction_commands.enabled` (the poll) and `automations.enabled` (the bus).
- Docs in English; Desktop conventions in `docs/review/review-rules.md` "Swift / Desktop conventions".
- Inner-loop checks only per task (CLAUDE.md "Agent-driven runs"); Swift briefs also run `make lint-swift` (lint-diff is Go-only).

## Review Focus

1. **The owner has zero automations.** Today `AutomationsView` replaces the whole tab with `TabEmptyState` when `vm.items` is empty, which would hide Reactions and Tracks. The section picker must be reachable with zero recipes (Task 6 test).
2. **A recipe is enabled long after the account was first polled.** Old reactions must not fire (Task 3: reset while nobody listens, reseed on the first wanted poll).
3. **Dictionary emoji that is also subscribed.** The tool dispatch must still happen exactly once with today's row, and the event must also fire once (Task 3).
4. **The bus is not wired** (`automations.enabled` off → `d.cycleEvents == nil`). A typed-nil interface must not reach the pipeline as non-nil (Task 4 test).
5. **Re-reacting** (remove and add the same emoji on the same message) must not fire again (Task 3).

---

### Task 1: The `slack.reaction_added` event type

Depends on: none.

**Files:**
- Modify: `internal/automations/recipe.go` (`EventTypes`), `internal/automations/events.go` (`EventFields`)
- Create: `internal/automations/eventsrc_reaction.go`
- Test: `internal/automations/events_test.go`, `internal/automations/bus_test.go` (`TestBus_EventsCarryNoContent`)

**Interfaces:**
- Produces: `const SlackReactionAdded = "slack.reaction_added"`; `func ReactionEvent(account, channelID, messageTS, emoji string) Event` (fields `account`, `channel_id`, `message_ts`, `emoji`); `EventFields["slack.reaction_added"] = {"account","channel_id","emoji"}`; `EventTypes` gains it **last** (Swift mirrors the order).

- [ ] **Step 1: Failing tests.** `TestReactionEvent_FieldsAndWhere`: `ReactionEvent("acme","1:C1","1700000000.000100","eyes")` marshals to `{"type":"slack.reaction_added","account":"acme","channel_id":"1:C1","message_ts":"1700000000.000100","emoji":"eyes"}`; `MatchWhere({"emoji":"eyes"})` is true, `{"emoji":"EYES"}` is true, `{"emoji":"white_*"}` is false; a recipe whose `where` is `{message_ts: "x"}` fails to parse (unknown key). Extend `TestBus_EventsCarryNoContent` so its marker check covers a `ReactionEvent` (`ReactionEvent` has no text parameter, so the assertion is that the marshalled event has exactly those five keys).
- [ ] **Step 2:** `go test ./internal/automations -run 'TestReactionEvent|TestBus_EventsCarryNoContent'` → FAIL.
- [ ] **Step 3:** Implement the constant, the constructor and the two table entries.
- [ ] **Step 4:** `go test ./internal/automations` → PASS.
- [ ] **Step 5:** Commit `feat(automations): slack.reaction_added event type`.

### Task 2: The `reaction_events` ledger and seed stamp

Depends on: none.

**Files:**
- Create: `internal/db/migrations/00136_reaction_events.sql` (renumber at merge if main moved on)
- Create: `internal/db/reaction_events.go`, `internal/db/reaction_events_test.go`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), regenerated golden + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`

**Interfaces:**
- Produces (all on `*DB`, `OwnerReaction` is the existing type in `internal/db/reaction_commands.go`):
  - `InsertReactionEvent(r OwnerReaction) (inserted bool, err error)`: `INSERT OR IGNORE`, `seen_at` = now UTC RFC 3339; `inserted` is false for a duplicate.
  - `SeedReactionEvents(accountID int64, rs []OwnerReaction) error`: one transaction that inserts every row (ignore duplicates) and sets `slack_accounts.reaction_events_seeded_at`; errors when the account row is missing.
  - `ReactionEventsSeeded(accountID int64) (bool, error)`: a missing row reads false (the `ReactionCommandsSeeded` shape).
  - `ResetReactionEventsSeeded() error`: `UPDATE slack_accounts SET reaction_events_seeded_at = '' WHERE reaction_events_seeded_at != ''`.

Migration Up: `CREATE TABLE reaction_events (account_id INTEGER NOT NULL, channel_id TEXT NOT NULL, message_ts TEXT NOT NULL, emoji TEXT NOT NULL, seen_at TEXT NOT NULL, PRIMARY KEY (account_id, channel_id, message_ts, emoji))` + `ALTER TABLE slack_accounts ADD COLUMN reaction_events_seeded_at TEXT NOT NULL DEFAULT ''`. Down drops both.

- [ ] **Step 1: Failing tests.** `TestInsertReactionEvent_OncePerKey` (second insert → `inserted=false`); `TestSeedReactionEvents_StampsAndRecords` (after seeding, `ReactionEventsSeeded` true and a seeded key's insert → false); `TestResetReactionEventsSeeded` (stamp cleared, rows kept); `TestReactionEventsSeeded_MissingAccount` → false, nil.
- [ ] **Step 2:** `go test ./internal/db -run 'ReactionEvent'` → FAIL.
- [ ] **Step 3:** Migration, store, `schema.sql`, `TestAllTablesExist` entry; `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- [ ] **Step 4:** `go test ./internal/db` → PASS.
- [ ] **Step 5:** Commit `feat(db): reaction_events ledger for reaction automation events`.

### Task 3: The pipeline publishes reaction events

Depends on: Tasks 1, 2.

**Files:**
- Modify: `internal/reactioncmd/pipeline.go`, `internal/reactioncmd/extract.go`
- Create: `internal/reactioncmd/events.go`
- Test: `internal/reactioncmd/events_test.go` (+ adjust `pipeline_test.go` call sites to the new `Run` signature)

**Interfaces:**
- Consumes: `automations.SlackReactionAdded`, `automations.ReactionEvent` (Task 1); the Task 2 store; `db.SlackEventLabels(accountID) (account, owner string, err error)`.
- Produces:
  - `type EventSink interface { Wants(eventType string) bool; Publish(events ...automations.Event) }`
  - `func (p *Pipeline) Run(ctx context.Context, events EventSink) (int, error)`; `events` may be nil. The count stays "tool dispatches" (unchanged meaning).
  - `func ownerMessageReactions(items []slack.ReactedItem, ownerRawID string, accountID int64) []db.OwnerReaction`: every owner reaction on a message item, the same item and owner rules `extractOwnerReactions` applies minus the dictionary filter. `extractOwnerReactions` keeps its output.

Behaviour of `Run`:
1. `wants := events != nil && events.Wants(automations.SlackReactionAdded)`.
2. `!wants` → `ResetReactionEventsSeeded()` (an error is logged, not returned). Then, if the dictionary is empty, return as today.
3. Per account: the existing dictionary seeding/dispatch stays as it is. With `wants`, the account's reactions are listed **once** per poll and shared by both paths. When the event stamp is unset, `SeedReactionEvents` records them all and publishes nothing. Otherwise each `ownerMessageReactions` row goes through `InsertReactionEvent`, and only `inserted` rows are published, in list order, as `ReactionEvent(label, ChannelID, MessageTS, Emoji)`. A store error for one row is logged and skips that row.
4. A dictionary emoji that is also subscribed takes both paths independently.

- [ ] **Step 1: Failing tests** (fake lister + a recording `EventSink`, in the style of `pipeline_test.go`):
  - `TestRun_PublishesNewOwnerReaction`: a seeded account, an `eyes` reaction not in the dictionary → one event with the Global Constraints fields; `reaction_commands` has no row.
  - `TestRun_SecondPollPublishesNothing`.
  - `TestRun_ReReactSameMessageDoesNotFireAgain` (the same key reappears after it vanished from a poll).
  - `TestRun_FirstWantedPollSeedsWithoutPublishing`.
  - `TestRun_ResetWhileNobodyListensThenReseeds`: poll with wants → seeded; poll without → stamp cleared; a new reaction made in between; the next wanted poll publishes nothing.
  - `TestRun_DictionaryEmojiAlsoSubscribed`: one tool dispatch whose `reaction_commands` row equals the dictionary-only run's row, plus one event.
  - `TestRun_NoSubscriberEmptyDictionaryNoListCall`: the lister's call count is 0.
  - `TestRun_NilSinkKeepsTodayBehaviour`: existing dictionary tests pass `nil`.
  - `TestRun_EventCarriesNoText`: the item text carries a marker that is absent from the marshalled events.
- [ ] **Step 2:** `go test ./internal/reactioncmd` → FAIL.
- [ ] **Step 3:** Implement. Check first that `internal/automations` does not import `internal/reactioncmd` (no cycle).
- [ ] **Step 4:** `go test ./internal/reactioncmd ./internal/automations` → PASS; `make lint-diff`.
- [ ] **Step 5:** Commit `feat(reactioncmd): publish slack.reaction_added events`.

### Task 4: Daemon wiring, guard test and end-to-end

Depends on: Task 3.

**Files:**
- Modify: `internal/daemon/daemon.go` (`phaseReactionCommands`: `d.reactionCmdPipe.Run(ctx, sink)`), the `cmd/` call site of `Run`, if any
- Modify: `internal/daemon/automation_events_test.go` (replace `TestDaemon_ReactionCommandsUnchangedByBus`), `internal/daemon/automation_events_e2e_test.go`

**Interfaces:**
- Consumes: `reactioncmd.EventSink`, `Pipeline.Run(ctx, events)`.
- `sink` is `nil` (an untyped `reactioncmd.EventSink(nil)`) when `d.cycleEvents == nil`, never a typed nil.

- [ ] **Step 1: Failing tests.**
  - `TestDaemon_ReactionCommandsPublishToCycleBus` replaces the old guard. It keeps the static part (the poll directly follows `phaseSlackSync` under its `ctx.Err()` guard and before the Flush). At run time, with `ReactionCommands.Enabled` and a recording bus, the bus is asked `Wants("slack.reaction_added")`, and every asked type is in `automations.EventTypes`.
  - `TestDaemon_ReactionPollWithoutBusPassesNilSink`.
  - `TestEventAutomation_ReactionEndToEnd` in the e2e file: a recipe `trigger: event {type: slack.reaction_added, where: {emoji: eyes}}` and an inbox output, a seeded account, one `eyes` reaction → one cycle → one run whose `trigger.events[0].emoji == "eyes"`; the next cycle → no run.
- [ ] **Step 2:** `go test ./internal/daemon -run 'Reaction'` → FAIL.
- [ ] **Step 3:** Wire it.
- [ ] **Step 4:** `go test ./internal/daemon ./internal/reactioncmd`, plus `go test ./cmd -run 'Reaction|Automation'` → PASS; `make lint-diff`.
- [ ] **Step 5:** Commit `feat(daemon): reaction events reach event automations`.

### Task 5: Swift Core — the event type and reaction rows

Depends on: none (mirrors Task 1's constants).

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationFormModel.swift` (`eventTypes` + `eventFields`), `.../AutomationTriggerText.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/ReactionAutomationRows.swift`
- Test: `WatchtowerDesktop/Tests/Core/AutomationFormTests.swift`, `AutomationTriggerTextTests.swift`, new `ReactionAutomationRowsTests.swift`

**Interfaces:**
- Produces: `package struct ReactionAutomationRow: Identifiable, Equatable { id: Int64; name: String; emoji: String? }` and `package enum ReactionAutomationRows { static func rows(from items: [AutomationListItem]) -> [ReactionAutomationRow] }`: items with `triggerKind == "event"` whose `triggerSpecJSON` event type is `slack.reaction_added`; `emoji` = `where.emoji` or nil; sorted by name, case-insensitive.
- Trigger text: `"On a Slack reaction"`, or `"On :<emoji>: reactions"` when `where.emoji` is set.

- [ ] **Step 1: Failing tests.**
  - `AutomationFormTests`: the `eventTypes` list ends with `"slack.reaction_added"` (Go order), and its fields are `["account","channel_id","emoji"]`.
  - `AutomationTriggerTextTests`: both strings above.
  - `ReactionAutomationRowsTests`: picks only reaction-event items, reads the emoji, leaves `nil` without `where`, and sorts.
- [ ] **Step 2:** `make test-swift FILTER='AutomationFormTests|AutomationTriggerTextTests|ReactionAutomationRowsTests'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** The same filter → PASS; `make lint-swift`.
- [ ] **Step 5:** Commit `feat(desktop): slack.reaction_added in the automation form and reaction rows`.

### Task 6: Automations tab sections, the dictionary moved, Tracks listed

Depends on: Task 5.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Automations/AutomationsView.swift`
- Create: `WatchtowerDesktop/Sources/Views/Automations/AutomationsSection.swift` (the enum), `ReactionsSectionView.swift`, `ReactionDictionaryEditor.swift` (the editor moved out of `SlackConnectionDetail.reactionDictionarySection`, unchanged behaviour), `TracksSectionView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SlackConnectionDetail.swift` (the section becomes one line, "Reaction commands moved to Automations → Reactions", with a button that navigates there)
- Possibly add: `TrackQueries.fetchCustom(_ db: Database) throws -> [Track]` if no existing query returns only `origin='custom'` tracks
- Test: `WatchtowerDesktop/Tests/Core/AutomationsSectionTests.swift` (pure parts)

**Interfaces:**
- Produces: `enum AutomationsSection: String, CaseIterable { case automations, reactions, tracks }`, persisted in `UserDefaults` key `automations.section` (a per-viewer convenience); `static func visible(tracksVisible: Bool) -> [AutomationsSection]` drops `.tracks` when the Tracks sidebar destination is not visible (`SidebarDestination.tracks.isVisible(disabledFeatures:connected:)`); a stored section that is no longer visible falls back to `.automations`.
- `AppState` gains `navigateToAutomations(section: AutomationsSection)` for the Settings pointer.

Layout: a segmented picker at the top of the tab, always shown. `.automations` = today's view, including its `TabEmptyState` when there are no recipes. The empty state now sits **below** the picker, so Reactions and Tracks stay reachable with zero recipes.
- `.reactions`:
  - When the `reaction-commands` feature is off, a banner "Reactions aren't being read. Turn on Reaction commands" with **Turn on** (the `ActionStripView.enableReactionCommands` path: `featureManager.enableNow` + `DaemonManager.restart()`).
  - The dictionary editor, which stays editable while the feature is off.
  - "Automations that listen to reactions": `ReactionAutomationRows.rows(from: vm.items)`, emoji or "any emoji". A click switches to `.automations` and selects the row.
  - **New reaction automation** opens the existing New automation sheet (`cardActions.onNew`).
- The edit form (`AutomationFormView`): when the event type is `slack.reaction_added` and `reaction-commands` is off, one line under the type picker, "Reaction events need Reaction commands on", with the same **Turn on**.
- `.tracks`: the custom tracks (name, last scan, event count, the fields `Track` already has). A click calls `appState.navigateToTrack(id)`. **New track** opens `CustomTrackManagementSheet(linkedTargetID: nil)`. When there are none: one line explaining tracks, plus the button.

- [ ] **Step 1: Failing tests.** `AutomationsSectionTests`: `visible(tracksVisible: false)` has no `.tracks`; a stored `"tracks"` with tracks hidden resolves to `.automations`; an unknown stored value resolves to `.automations`.
- [ ] **Step 2:** `make test-swift FILTER=AutomationsSectionTests` → FAIL.
- [ ] **Step 3:** Implement the views; move the editor code (no behaviour change, the same `ReactionDictionaryViewModel`).
- [ ] **Step 4:** `make test-swift FILTER='AutomationsSectionTests|ReactionAutomationRowsTests|ReactionDictionary'` → PASS; `make lint-swift`; build and look at the tab with zero automations (the `run` skill or a screenshot) and confirm all three sections open.
- [ ] **Step 5:** Commit `feat(desktop): reactions and tracks sections in Automations`.

### Task 7: Docs, contracts, guide

Depends on: Tasks 4, 6.

**Files:**
- Modify: `docs/features/automations.md`: the event type row, the reaction source, the loss window between ledger and Flush, the gate dependency; remove reactions from "Not event sources"; update the test list.
- Modify: `docs/features/reaction-commands.md`, `docs/inventory/reaction-commands.md` (changelog: REACT-01..05 unchanged, `reaction_events` beside `reaction_commands`, owner approval ask #346/#350).
- Modify: `docs/guide/features/automations.md` (sections, reaction trigger), `docs/guide/features/automations-recipes.md` (the event and its fields), `docs/guide/reference/settings.md` and the reaction parts of `docs/guide/features/inbox.md` (the editor now lives in Automations → Reactions), following `docs/guide/WRITING.md`.
- Modify: `CLAUDE.md`, the Automations feature line (one clause: reaction events + showcase).

- [ ] **Step 1:** Write the docs.
- [ ] **Step 2:** `go test ./internal/userguide/...` (guide index) → PASS.
- [ ] **Step 3:** Commit `docs: reaction events and the Automations rule sections`.

## Phase gate (controller, once)

`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`; then `local-review` → PR into `main`.
