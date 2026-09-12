# Reaction Commands + Inbox Action Strip — Behavior Inventory

**Module:** `internal/reactioncmd/`, `internal/tools/` (the four reaction-facing tools: `create_track`, `create_idea`, `remind_me`, `brief_context`), `internal/db/reaction_commands.go`, `internal/db/reminders.go`, `cmd/reaction_commands.go`, `WatchtowerDesktop/Sources/Views/Inbox/ActionStripView.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/ActionStripViewModel.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/{AgentActionQueries,ReminderQueries,ReactionDictionaryQueries}.swift`
**Spec:** `docs/superpowers/specs/2026-09-05-reaction-commands-design.md` (Wave 1, REACT-01..05), `docs/superpowers/specs/2026-09-06-reaction-commands-wave2-inbox-action-strip-design.md` (Wave 2, STRIP-01..03/REMIND-01..02)
**Last full audit:** 2026-09-06

This is the first inventory file for the reaction-commands feature. REACT-01..05
were defined in the Wave 1 spec/code comments (`internal/reactioncmd/`,
migration 00063, merged 2026-09-05) but never got an inventory home; they are
recorded here for the first time, unchanged from their Wave 1 definitions.
STRIP-01..03 and REMIND-01..02 are new, added by Wave 2.

## REACT-01 — Owner-only

**Status:** Enforced

**Observable:** A reaction only ever becomes a command when it is the connected
owner's own reaction. This is a structural guarantee, not a runtime filter:
`Pipeline.processAccount` polls `ReactionLister.ListUserReactions(ctx, userID)`
— Slack's `reactions.list` scoped to the owner's own OAuth token — which the
Slack API can only ever return as "items this token's user reacted to." There
is no code path that reads any other user's reactions.

**Why locked:** The reaction-commands vocabulary is deliberately a
single-owner gesture channel (a colleague's 👍 on a shared channel message
must never file a Jira issue or create a target on the owner's behalf).

**Test guards:** `internal/reactioncmd/pipeline_test.go::TestReactionCmd_DispatchesNewCommandAsProposal` pins the per-account, per-owner-id dispatch shape; the owner-only guarantee itself rests on the Slack API's own scoping of `reactions.list`, which this codebase has no seam to fake (no test asserts a foreign user's reaction is skipped, because there is no code path capable of observing one).

**Locked since:** 2026-09-05 (Wave 1)

## REACT-02 — No invented provenance

**Status:** Enforced

**Observable:** Every entity a reaction command creates carries the reacted
message's real ref. `Pipeline.processAccount` sets
`Binding{Surface:"reaction", ContextType:"reaction", ContextID: c.ChannelID +
"@" + c.MessageTS}` (`internal/reactioncmd/pipeline.go`) from the actual
reacted item, never a placeholder; `remind_me`'s `Execute` threads that same
`call.Binding.ContextID` straight into `Reminder.MessageRef`
(`internal/tools/remind.go`).

**Why locked:** A fabricated source ref would make a reminder or proposal
point at the wrong (or no) Slack message — undiscoverable once created.

**Test guards:** `internal/reactioncmd/pipeline_test.go::TestReactionCmd_DispatchesNewCommandAsProposal` (binding carries the real channel/ts); `internal/tools/remind_test.go::TestRemindMe_ExecuteInsertsReminderWithRef` (the ref round-trips from `Binding.ContextID` into the `reminders` row).

**Locked since:** 2026-09-05 (Wave 1)

## REACT-03 — Idempotent

**Status:** Enforced

**Observable:** Re-polling `reactions.list` never re-creates a command already
recorded. The ledger key is `(account_id, channel_id, message_ts, emoji)`
(`internal/db/reaction_commands.go`); `FilterUnseenReactionCommands` excludes
any combination already in the ledger, and a transient failure is retried
(left out of the "seen forever" set) while a terminal outcome is not.

**Why locked:** A daemon phase that re-polls on every cycle must never
double-fire a tool for a reaction the owner made once.

**Test guards:** `internal/reactioncmd/pipeline_test.go::TestReactionCmd_Idempotent`, `internal/reactioncmd/pipeline_test.go::TestReactionCmd_TransientFailureRetries`; `internal/db/reaction_commands_test.go::TestFilterUnseenReactionCommands_Idempotent`, `internal/db/reaction_commands_test.go::TestFilterUnseen_TransientLeavesRetriable`, `internal/db/reaction_commands_test.go::TestFilterUnseenReactionCommands_Empty`.

**Locked since:** 2026-09-05 (Wave 1)

## REACT-04 — The model never writes directly

**Status:** Enforced

**Observable:** A dispatched reaction command is composed into tool args by
one light-tier AI call and then goes through `tools.Registry.Propose`/`Apply`
exactly like a chat-elicited proposal — inheriting AGENT-01..06 wholesale,
including "External tools never auto-execute" (AGENT-03).

**Why locked:** Reaction commands are one more caller of the registry, not a
second write path; every AGENT-0N guarantee must hold here too, or the
registry's whole premise (model proposes, code disposes) has a side door.

**Test guards:** `internal/reactioncmd/pipeline_test.go::TestReactionCmd_ExternalStaysPending` (an `External` tool dispatched via a reaction still lands `pending`, never auto-applies); the underlying claim/CAS machinery is AGENT-05's guards in `docs/inventory/agent-actions.md`, unchanged by this caller.

**Locked since:** 2026-09-05 (Wave 1)

## REACT-05 — Read-only Slack

**Status:** Enforced

**Observable:** The reaction-commands pipeline adds no Slack write scope and
posts nothing back to Slack. Removing a reaction has no effect (there is no
undo path — the ledger row, once recorded, stays forever per REACT-03).

**Why locked:** The feature's entire premise ("react to get a task") must not
also mean "and Watchtower now messages your channels" — that would be a scope
and trust escalation nobody asked for.

**Test guards:** Structural — `internal/reactioncmd/pipeline.go`'s `Pipeline` holds only a `ReactionLister` (read) and the tools `Registry`; no Slack client method capable of a write (post/react) is reachable from it. No dedicated negative test (an absence-of-capability property, the AGENT-02/dev-surface "no test seam" precedent); the closest guard is `internal/db/reaction_commands.go`'s comment "Rows are never deleted (there is no undo, REACT-05)."

**Locked since:** 2026-09-05 (Wave 1)

---

## STRIP-01 — Gesture-gated

**Status:** Enforced

**Observable:** A card reaches the inbox action strip only because of an
owner gesture — a dictionary reaction (REACT-01 owner-only), a `remind_me`
call, or a chat proposal the owner elicited. `ActionStripViewModel.refresh()`
is a pure read (`AgentActionQueries.fetchStrip` + `ReminderQueries.fetchDue`)
over two tables — `agent_actions` and `reminders` — and every row in both is
written only by a `Registry.Propose` call or a `remind_me`
`Execute`/`InsertReminder`, all gesture-triggered. There is no third writer,
and no scan of ambient Slack/Jira/Calendar/Gmail traffic feeds either table.

**Why locked:** The whole point of replacing the situations Dashboard with
the strip was "no trash bin by construction" (design §1) — a flat list that
never accumulates ambient noise the owner didn't ask for.

**Test guards:** No dedicated negative test (an absence-of-writer property); covered indirectly by every writer-side guard above (`TestReactionCmd_DispatchesNewCommandAsProposal`, AGENT-05's guards in `docs/inventory/agent-actions.md`) each being reachable only from a gesture, plus `WatchtowerDesktop/Tests/Core/AgentActionQueriesTests.swift::testFetchStripReturnsNonTerminalAcrossConversations` and `WatchtowerDesktop/Tests/Core/ActionStripViewModelTests.swift::testRefreshPopulatesActionAndReminderRows` (the read side pulls only from `agent_actions`/`reminders`, nothing else).

**Locked since:** 2026-09-06

## STRIP-02 — The strip is a view, not a store

**Status:** Enforced

**Observable:** `ActionStripViewModel.refresh()` writes nothing — it is two
SELECTs. Every mutation a strip card triggers (Approve/Reject/Retry, Done,
Snooze) writes to the backing `agent_actions` or `reminders` row directly
(via `AgentActionFeed`/`ReminderQueries`); there is no strip-local table
(migration 00065 adds only `reminders` — no "strip" or "feed" table exists).

**Why locked:** A separate strip-owned store would create a second source of
truth for state that already lives on the agent-action/reminder row, risking
drift between what the strip shows and what `Registry.Apply` actually did.

**Test guards:** `WatchtowerDesktop/Tests/Core/ActionStripViewModelTests.swift::testMarkReminderDoneDropsItOnNextRefresh`, `WatchtowerDesktop/Tests/Core/ActionStripViewModelTests.swift::testSnoozeReminderMovesItOutOfTheDueWindow` (mutation lands on `reminders`, confirmed by a subsequent `refresh()`); `WatchtowerDesktop/Tests/Core/ReminderQueriesTests.swift::testMarkDoneRemovesFromDue`, `WatchtowerDesktop/Tests/Core/ReminderQueriesTests.swift::testSnoozeBumpsRemindAt`.

**Locked since:** 2026-09-06

## STRIP-03 — Decisions flow through the registry

**Status:** Enforced

**Observable:** `ActionStripViewModel.approve`/`reject`/`retry` delegate
directly to the composed `AgentActionFeed` — the same object the chat
surfaces use — which drives `watchtower actions approve|reject|apply` (the
CLI face of `Registry.Apply`, AGENT-05's exactly-once claim). The strip adds
no new write path for agent-action rows; only reminder Done/Snooze (a
different entity, §5.3 of the Wave 2 design) are direct GRDB writes.

**Why locked:** A second Approve/Reject implementation on the strip would
bypass the CAS claim (`approved|failed → executing`) that makes AGENT-05's
"exactly once" true, reopening the double-apply risk that guard exists to
close.

**Test guards:** `WatchtowerDesktop/Tests/Core/ActionStripViewModelTests.swift::testApproveDelegatesToTheComposedAgentActionFeed`, `WatchtowerDesktop/Tests/Core/ActionStripViewModelTests.swift::testApproveClearsAPriorErrorOnSubsequentSuccess`; transitively, every AGENT-05 guard in `docs/inventory/agent-actions.md`.

**Locked since:** 2026-09-06

## REMIND-01 — A reminder is inert until due

**Status:** Enforced

**Observable:** A `remind_me` call inserts a `reminders` row with
`status='pending'`. There is no separate `due` status and no daemon phase
that flips one — migration 00065 states this in its own comment: "'due' is
derived at read time (status='pending' AND remind_at <= now), so no daemon
phase flips it." `db.ListDueReminders`/`ReminderQueries.fetchDue` only return
rows where `status='pending' AND remind_at <= now`; a pending reminder whose
time has not arrived surfaces nothing. Snooze bumps `remind_at` forward and
sets `status='pending'` again, dropping it back out of the due set
immediately.

**Why locked:** This is what keeps `remind_me` a genuine "later," not a
same-cycle strip card — the owner asked to be interrupted at a chosen time,
not immediately.

**Test guards:** `internal/db/reminders_test.go::TestReminders_InsertListDueSnoozeDone`; `WatchtowerDesktop/Tests/Core/ReminderQueriesTests.swift::testFetchDueReturnsOnlyPendingPast`, `WatchtowerDesktop/Tests/Core/ReminderQueriesTests.swift::testSnoozeBumpsRemindAt`.

**Locked since:** 2026-09-06

## REMIND-02 — Read-only Slack

**Status:** Enforced

**Observable:** No code path from `remind_me`'s `Execute`
(`internal/tools/remind.go`, which only calls `d.InsertReminder`) through
Done/Snooze (`db.MarkReminderDone`/`SnoozeReminder`,
`ReminderQueries.markDone`/`snooze`) ever calls a Slack API. A reminder is a
Watchtower-local row; nothing is posted back to Slack when it is created,
fires, is done, or is snoozed.

**Why locked:** Same rationale as REACT-05, inherited: the reaction-commands
surface must never grow an implicit Slack-write side effect.

**Test guards:** Structural — none of `internal/tools/remind.go`, `internal/db/reminders.go`, or `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ReminderQueries.swift` reference a Slack client (the AGENT-02/dev-surface "no test seam for an absent capability" precedent).

**Locked since:** 2026-09-06

---

## Changelog

- 2026-09-06: file created. REACT-01..05 backfilled from the Wave 1 spec/code (`internal/reactioncmd/`, migration 00063, merged 2026-09-05 as commit `4b9d01d3`) — this is their first inventory entry, not a change to their definitions. STRIP-01..03 and REMIND-01..02 added by Wave 2 (`docs/superpowers/specs/2026-09-06-reaction-commands-wave2-inbox-action-strip-design.md`): four new tools (`create_track`, `create_idea`, `remind_me`, `brief_context`), the `reminders` table (migration 00065), and the inbox action strip (`ActionStripView`/`ActionStripViewModel`) replacing the situations Dashboard as the Inbox tab's content. `docs/inventory/README.md`'s module table gained a "Reaction Commands" row pointing here in the same pass.
- 2026-09-12 (merge into main, PR #152 review): `remind_me` now normalizes `remind_at` before `InsertReminder` (`normalizeRemindAt`, `internal/tools/remind.go`): RFC 3339 with any offset → stored UTC `YYYY-MM-DDTHH:MM:SSZ`; a bare owner-local `YYYY-MM-DDTHH:MM` is interpreted in the daemon's zone (the `create_target` due precedent); anything else is a `ValidationError`. REMIND-01's "inert until due" relied on this implicitly — both due readers (`db.ListDueReminders`, Swift `ReminderQueries.fetchDue`) compare the column as TEXT against a UTC "Z" now, so an unnormalized offset fired at the wrong instant and a natural-language value never. The reaction compose context gains an "Owner's local time now" line (offset + zone) so a relative default ("tomorrow 09:00") is deterministic. `connect_jira_board`'s partial-success `warning` (and any tool's `result_json.warning`) now renders on the chat card. The four Wave 2 tools are now `Surfaces: ["reaction"]`: with empty Surfaces they mounted in the main and target chats, where a turn could create a track/idea/reminder outside the chat's mandate (TGT-BRIEF-01 axis 3) with no reacted message to bind to and — for the three tools seeded `execute` — no Approve card; the seeded trust itself is unchanged (an owner call on the reaction path, §7 of the Wave 2 design).
