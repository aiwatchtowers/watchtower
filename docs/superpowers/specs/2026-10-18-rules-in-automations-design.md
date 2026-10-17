# Rules in one place: reactions as events, Automations as the rules showcase

Date: 2026-10-18. Status: draft for the owner's review. Owner decisions: ask #346, ask #347.

## Intent

Watchtower has three engines for owner-defined rules: automations (recipes), reaction commands (emoji → tool dictionary) and custom tracks (describe in words → scan → timeline). The owner wants **one place for rules** without demolishing the engines that already work (ask #346: "connect, do not demolish"; "one place for rules" is the goal). Ask #347 chose a **showcase in the Automations tab**: reactions and tracks get their own sections there; engines and data stay as they are.

Two parts:

1. **Reactions become an event source.** A Slack reaction by the owner publishes a content-free `slack.reaction_added` event on the P4 bus, so any recipe can run "when I put :emoji: on a message". This is what lets one emoji drive more than a single tool.
2. **The Automations tab shows every rule.** Sections: recipes (as today), **Reactions** (the dictionary editor moves here from Settings → Slack, plus a read-only list of recipes that listen to reactions) and **Tracks** (custom tracks, opening their timeline).

## Goals

- A recipe can subscribe to `slack.reaction_added` with `where` on `emoji`, `account`, `channel_id`, like any P4 event.
- The owner sees and edits every rule from the Automations tab.
- Existing reaction mappings and custom tracks behave exactly as before.

## Non-goals

- Rewriting reaction commands or custom tracks as recipes; no migration of their data.
- A unified rule model (one row type for recipes, mappings and tracks). Ask #347 rejected it as too much work for now.
- New track features, or reaction events for anyone other than the owner.

## Anti-goals (a failure even if it works)

- Any change to how an existing dictionary emoji behaves (same tool, same trust, same ledger row).
- A reaction firing a recipe twice, or firing one for a reaction made before the feature saw the account (FEAT-03 "never replay history", REACT-03).
- Message text reaching the event (P4's content-free rule, `TestBus_EventsCarryNoContent`).
- Extra Slack API calls when no recipe listens to reactions and the dictionary is empty.

## Current state (main at 6095dcb78)

- `phaseReactionCommands` (`internal/daemon/daemon.go`) runs right after `phaseSlackSync` and before `Flush` (which follows `phaseExternalSync`), so a reaction published there lands in the same cycle's flush. Gated by `reaction_commands.enabled`.
- `reactioncmd.Pipeline.processAccount` lists the owner's reactions (`reactions.list`), keeps only dictionary emoji (`extractOwnerReactions(items, owner, dict, …)`), filters ledger-unseen ones and dispatches each through the tools registry. The ledger `reaction_commands` is keyed `(account_id, channel_id, message_ts, emoji)`; history is seeded on an account's first poll.
- P4 deliberately left reactions out: no `reaction.*` event type, `TestDaemon_ReactionCommandsUnchangedByBus`, and "Not event sources: … reaction commands" in `docs/features/automations.md`. This design reverses that decision with the owner's approval (ask #346).
- The dictionary editor is in Settings → Slack (`ReactionDictionaryViewModel`, `ReactionDictionaryQueries`). Custom tracks live in the Tracks tab (`CustomTrackManagementSheet`, `CustomTrackTimelineView`).
- The owner's live install today has 0 reaction ledger rows, 0 tracks and 0 automations. No data is at risk, and nobody depends on the current layout.

## Design

### 1. `slack.reaction_added` event

- New entry in `automations.EventTypes` / `EventFields`: `slack.reaction_added` with matchable fields `account`, `channel_id`, `emoji`; also carries `message_ts` (not matchable, like `count`). `account` follows the P4 Slack rule (label, else team domain). No channel name, message text or author is included. `emoji` is the bare name without colons, the same spelling the dictionary uses.
- Published from `phaseReactionCommands` straight into the cycle's bus (`Bus.Publish`), not through a Before/After snapshot. The ledger, not a table diff, is what makes a reaction new.
- **Which reactions the pipeline looks at:** the dictionary emojis as today, **plus** reactions that some runnable recipe subscribes to. In v1 that means every owner reaction whenever `Bus.Wants("slack.reaction_added")` is true. The `where` filter decides later, in `Publish`, so the pipeline needs no knowledge of `where`. When the bus does not want the type, the pipeline behaves exactly as today.
- **Exactly once — a separate event ledger (my call):** a new table `reaction_events(account_id, channel_id, message_ts, emoji, seen_at)`, primary key on the first four, the same identity as `reaction_commands`. `reaction_commands`, its status CHECK, its readers (history views, the stranded-row sweep) and REACT-03 stay untouched. A reaction is published only when its insert into `reaction_events` succeeds; there is no provisional state, because `Publish` is in memory and has nothing to claim. One row per message + emoji, as in the dictionary ledger: removing and re-adding a reaction does not fire again.
- **Both handlers:** an emoji that is in the dictionary **and** subscribed to by a recipe does both: the tool dispatch through `reaction_commands` as today, and the event through `reaction_events`. The two ledgers are independent, so a dictionary reaction's row is exactly today's.
- **Never replay history (my call):** event seeding is separate from the dictionary's. A per-account `slack_accounts.reaction_events_seeded_at` is set the first time a poll runs with `Bus.Wants("slack.reaction_added")`. That poll records every reaction currently listed into `reaction_events` without publishing anything. While no runnable recipe subscribes, the pipeline does not read non-dictionary reactions and clears `reaction_events_seeded_at` for every account. The next subscriber therefore reseeds instead of replaying the reactions made while nobody was listening. A recipe added while another one already listens sees only reactions made after the last poll. This is acceptable: it never sees old ones.
- **Volume:** no own budget. The bus already keeps at most 100 events per run (`MaxEventsPerRun`, `truncated`), and one run per automation per cycle (AUTO-09) bounds the executor.
- **Early return:** today's "empty dictionary → no `reactions.list`" becomes "empty dictionary **and** the bus does not want `slack.reaction_added` → no `reactions.list`".
- **Loss window:** `Publish` is in memory until `Flush`. If the daemon dies between the ledger write and `Flush`, the event is lost, not replayed. This is accepted for v1 and documented (P4 has the same window for snapshot events).
- **Feature gates:** the event needs `reaction_commands.enabled` (it owns the Slack poll, FEAT-01: off = zero API calls) and `automations.enabled` (no bus otherwise). With reaction commands off, the recipe editor and the Reactions section say that reaction events need Reaction commands on, with a turn-on button (the existing `FeatureManagerService.enableNow` path).
- Read-only Slack (REACT-05, REMIND-02) is unchanged: the event adds no Slack write. A recipe that wants the message reads it through the existing automation reads, i.e. `list_messages` under `slack:read@*` or `tool:list_messages` (D22), like any `slack.new_messages` recipe. A narrower per-message read tool is out of scope.
- STRIP-01 holds: a run started by the owner's reaction is gesture-gated.

### 2. Automations tab as the showcase

- `AutomationsView` gets three sections in its sidebar list: **Automations** (today's list), **Reactions**, **Tracks**. The section headers are always visible. An empty section shows a one-line explanation and a create button.
- **Reactions section:**
  - The dictionary editor (`ReactionDictionaryViewModel`) moves here unchanged: add, remove, toggle, see trust.
  - Below it, **Recipes that listen to reactions**: every recipe whose trigger is `slack.reaction_added`, shown with its emoji (from `where.emoji`, or "any emoji" when absent). Clicking one opens its normal card.
  - "New reaction automation" opens the New automation flow with the event trigger preset to `slack.reaction_added`.
  - Settings → Slack keeps a single line pointing to Automations → Reactions; the editor itself lives in one place only.
- **Tracks section:** a list of custom tracks (name, enabled, last scan, events count). Clicking one opens its timeline in the Tracks tab (navigation, not a copy of the view). "New track" opens `CustomTrackManagementSheet`. The Tracks tab itself stays.
- No new Desktop tables. The sections read what their existing view models already read.
- With `reaction_commands.enabled` off, the Reactions section stays visible and the dictionary stays editable (it is configuration). A banner says that reactions are not being read, with **Turn on**.
- The Tracks section is shown only while the tracks feature is visible in the sidebar. Opening a track needs a deep link to one custom track's timeline. If `SidebarDestination`/AppState has none, adding one is part of this work.

### 3. Docs and contracts

- `docs/features/automations.md`: the event type, its fields, the loss window, the gate dependency; remove reactions from "Not event sources".
- `docs/features/reaction-commands.md` + `docs/inventory/reaction-commands.md`: a changelog entry stating that REACT-01..05 still hold, and how the event row coexists with REACT-03.
- `TestDaemon_ReactionCommandsUnchangedByBus` is replaced by tests asserting the new behaviour; dictionary-only behaviour stays covered.
- User guide: the Automations page gets the Reactions and Tracks sections; the Slack reactions page points to Automations.

## Tests that must exist

- A reaction on a subscribed emoji → one event run with the event's fields; the same poll repeated → no second run.
- A dictionary emoji with no subscriber → today's ledger row and dispatch, byte for byte.
- A dictionary emoji that also has a subscriber → the tool dispatch and the event, each once.
- An account's first poll (seeding) → no events.
- No subscriber and an empty dictionary → no `reactions.list` call.
- The event carries no message text (extend `TestBus_EventsCarryNoContent`).
- Desktop: the Reactions section lists the dictionary and the subscribed recipes; Settings → Slack shows only the pointer.

Also: no runnable subscriber for a while, then a new one → the first poll seeds and publishes nothing; a reaction made while nobody listened never fires.

## Calls made without the owner (check these)

- A separate `reaction_events` ledger plus a `slack_accounts.reaction_events_seeded_at` column (one migration), instead of reusing `reaction_commands`.
- Re-add of a removed reaction does not fire again.
- Seeding resets while nobody subscribes, so the gap is never replayed.
- The dictionary stays editable with Reaction commands off.

## Left to the builder

- How the pipeline gets the bus (`SetBus` or a `Wants`/`Publish` interface passed from the daemon); the bus is per cycle (`Begin` … `Flush`).
- The Desktop layout details of the three sections, within `docs/review/review-rules.md`'s Swift conventions.
