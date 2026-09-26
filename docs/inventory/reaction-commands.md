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
(left out of the "seen forever" set) while a terminal outcome is not. The rows
the FEAT-03 enable hook seeds (`internal/reactioncmd.SeedLedger`, status
`skipped`, detail `"seeded as pre-existing reaction history"`, renamed from `"seeded on enable (pre-existing reaction)"` on 2026-09-26 when the first poll became a second seed site) are ordinary
ledger rows read by that same filter — the mechanism is unchanged, only its
starting content; the same holds for a candidate deferred by the per-run
dispatch cap, which is simply left unrecorded and is therefore still unseen on
the next poll, exactly like a transient failure. Since 2026-09-26 the poll
itself seeds too: an account whose `slack_accounts.reaction_commands_seeded_at`
stamp is empty (migration 00073) is seeded by its first poll — same rows, same
detail string — and stamped, dispatching only from the next poll on. The
stamp, not "the ledger is empty", is the signal: an owner who never reacted
has an empty ledger too, and their first real reaction must dispatch.

**Ledger status machine (since 2026-09-26, owner decision):** a command that
reaches compose/Propose writes its ledger row **before** the side effect —
`ClaimReactionCommand` inserts it as provisional (`pending`, the value the
00063 CHECK always permitted) — and `FinalizeReactionCommand` rewrites it to
the terminal `dispatched`/`failed` after. A provisional row counts as seen, so
a failure anywhere after the claim can at worst strand the row, never
re-dispatch the command (at most one side effect, never two). The transitions:
claim fails → nothing composed or proposed, retried next poll (and the
dispatch-budget slot is refunded — only compose calls spend it); transient
compose failure (provider down) → the claim is released
(`ReleaseReactionCommand`, the only delete this ledger ever performs, and only
of a provisional row) so the next poll retries exactly as before; a
non-validation Propose error is classified first, because Propose can fail
*after* inserting its `agent_actions` row: an action recorded for this
reaction's binding since the pre-Propose high-water mark
(`MaxAgentActionID`/`ReactionAgentActionSince`) → finalized `dispatched` with
that id, none → released for retry, lookup failed → left provisional; release
or finalize fails → the row stays provisional and is never retried; a
finalize/release that finds the row no longer provisional reports it and logs
the known outcome at ERROR; a provisional row older than one hour
(`strandedAfter`) is turned by the next poll into `failed` with a "stranded
provisional row: outcome unknown" error and logged at ERROR, so it shows in
`watchtower reaction-commands list` instead of silently sitting there. Known
limit of the Propose-error lookup: it keys on (message ref, tool), not emoji,
so if two dictionary emojis map to the SAME tool and two overlapping polls
dispatch both on one message while one Propose fails before inserting, that
one can be finalized `dispatched` with its sibling's action id — a lost
command in the safe direction (never a duplicate). A side-effect-free outcome (an emoji mapping
to no built-in tool, the seed) is still recorded terminal in one insert. The
claim's `INSERT OR IGNORE` also means two overlapping polls (daemon + a manual
`reaction-commands poll`) can no longer both dispatch the same reaction.

**Why locked:** A daemon phase that re-polls on every cycle must never
double-fire a tool for a reaction the owner made once.

**Test guards:** `internal/reactioncmd/pipeline_test.go::TestReactionCmd_Idempotent`, `internal/reactioncmd/pipeline_test.go::TestReactionCmd_TransientFailureRetries`; `internal/db/reaction_commands_test.go::TestFilterUnseenReactionCommands_Idempotent`, `internal/db/reaction_commands_test.go::TestFilterUnseen_TransientLeavesRetriable`, `internal/db/reaction_commands_test.go::TestFilterUnseenReactionCommands_Empty`; first-poll seed — `internal/reactioncmd/seed_test.go::TestReactionCmd_FirstPollOfUnseededAccountSeedsInsteadOfDispatching`, `::TestReactionCmd_PollAfterFirstPollSeedDispatchesOnlyNewReactions`, `::TestReactionCmd_NeverReactedOwnerKeepsTheirFirstReaction`, `::TestReactionCmd_SeedLedgerStampsTheAccount`; provisional-row state machine — `internal/reactioncmd/pipeline_test.go::TestReactionCmd_FinalizeFailureAfterProposeNeverRedispatches`, `::TestReactionCmd_ClaimFailureProposesNothingAndRetries`, `::TestReactionCmd_ReleaseFailureAfterTransientStrandsInsteadOfRetrying`, `::TestReactionCmd_StrandedProvisionalRowSurfacesAsFailed`, `::TestReactionCmd_ProposeErrorAfterRecordingNeverRedispatches`, `::TestReactionCmd_ProposeErrorBeforeRecordingRetries`, `::TestReactionCmd_ProposeValidationErrorMarksFailed`, `::TestReactionCmd_LostClaimDispatchesNothingAndRefundsBudget`; `internal/db/reaction_commands_test.go::TestClaimReactionCommand_ProvisionalRowIsSeenAndClaimedOnce`, `::TestFinalizeReactionCommand_OnlyRewritesProvisional`, `::TestReleaseReactionCommand_DeletesOnlyProvisional`, `::TestFailStrandedReactionCommands_OnlyOldProvisionalRowsOfTheAccount`, `::TestReactionAgentActionSince_OnlyNewerReactionRowsForTheBinding`.

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
undo path — the ledger row, once recorded with a terminal status, stays forever per REACT-03; only a provisional claim whose dispatch provably produced nothing is released for retry).

**Why locked:** The feature's entire premise ("react to get a task") must not
also mean "and Watchtower now messages your channels" — that would be a scope
and trust escalation nobody asked for.

**Test guards:** Structural — `internal/reactioncmd/pipeline.go`'s `Pipeline` holds only a `ReactionLister` (read) and the tools `Registry`; no Slack client method capable of a write (post/react) is reachable from it. No dedicated negative test (an absence-of-capability property, the AGENT-02/dev-surface "no test seam" precedent); the closest guard is `internal/db/reaction_commands.go`'s comment "A row with a terminal status is never deleted (there is no undo, REACT-05)" (reworded 2026-09-26 from "Rows are never deleted", when a provisional claim became releasable) and `internal/db/reaction_commands_test.go::TestReleaseReactionCommand_DeletesOnlyProvisional`.

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

**Why locked:** The whole point of the strip taking over from the situations
Dashboard was "no trash bin by construction" (design §1) — a flat list that
never accumulates ambient noise the owner didn't ask for. As of 2026-09-14 the
Dashboard is not merely superseded but **removed** (spec
`docs/superpowers/specs/2026-09-14-inbox-demolition-design.md`), so the strip is
the only thing the sidebar's "Inbox" tab shows besides its Learned and Profile
segments — which makes this contract the sole remaining guarantee that nothing
ambient can reach that tab.

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

- 2026-09-14 (**inbox demolition**, spec `docs/superpowers/specs/2026-09-14-inbox-demolition-design.md`): **no contract semantics changed, no guard relaxed** — wording only. Where STRIP-01..03 described the strip as having "replaced" the situations Dashboard, the Dashboard is now *removed*: every writer of `situations`/`situation_signals` is deleted and the tables are frozen read-only history, the `inbox.situations.enabled` key Wave 2 introduced to mute the composer is gone with the composer itself, and the already-unreachable `InboxFeedView`/`Views/Dashboard/` Swift files go in the demolition's Desktop half. The strip is unchanged code and remains what the sidebar's "Inbox" tab shows, alongside its Learned and Profile segments. Wave 2 §10 deferred exactly this demolition; it is now done.
- 2026-09-06: file created. REACT-01..05 backfilled from the Wave 1 spec/code (`internal/reactioncmd/`, migration 00063, merged 2026-09-05 as commit `4b9d01d3`) — this is their first inventory entry, not a change to their definitions. STRIP-01..03 and REMIND-01..02 added by Wave 2 (`docs/superpowers/specs/2026-09-06-reaction-commands-wave2-inbox-action-strip-design.md`): four new tools (`create_track`, `create_idea`, `remind_me`, `brief_context`), the `reminders` table (migration 00065), and the inbox action strip (`ActionStripView`/`ActionStripViewModel`) replacing the situations Dashboard as the Inbox tab's content. `docs/inventory/README.md`'s module table gained a "Reaction Commands" row pointing here in the same pass.
- 2026-09-12 (merge into main, PR #152 review): `remind_me` now normalizes `remind_at` before `InsertReminder` (`normalizeRemindAt`, `internal/tools/remind.go`): RFC 3339 with any offset → stored UTC `YYYY-MM-DDTHH:MM:SSZ`; a bare owner-local `YYYY-MM-DDTHH:MM` is interpreted in the daemon's zone (the `create_target` due precedent); anything else is a `ValidationError`. REMIND-01's "inert until due" relied on this implicitly — both due readers (`db.ListDueReminders`, Swift `ReminderQueries.fetchDue`) compare the column as TEXT against a UTC "Z" now, so an unnormalized offset fired at the wrong instant and a natural-language value never. The reaction compose context gains an "Owner's local time now" line (offset + zone) so a relative default ("tomorrow 09:00") is deterministic. `connect_jira_board`'s partial-success `warning` (and any tool's `result_json.warning`) now renders on the chat card. The four Wave 2 tools are now `Surfaces: ["reaction"]`: with empty Surfaces they mounted in the main and target chats, where a turn could create a track/idea/reminder outside the chat's mandate (TGT-BRIEF-01 axis 3) with no reacted message to bind to and — for the three tools seeded `execute` — no Approve card; the seeded trust itself is unchanged (an owner call on the reaction path, §7 of the Wave 2 design). Two Wave 2 gaps in the Desktop repoint closed the same day: the Learned-rules manager and the assistant Profile editor (hosted only by the retired `InboxFeedView`) had lost their only door — `ActionStripView` now carries the same Actions/Learned/Profile segmented control; and the Inbox sidebar badge now counts the strip's content (`AgentActionQueries.awaitingOwnerCount` + `ReminderQueries.dueCount`) instead of the muted situations backlog.
- 2026-09-13 (audit fix wave 5, owner decision 6): enabling the feature now seeds the ledger with every reaction the owner has already placed (FEAT-03's sixth hook — see `docs/inventory/features.md`), so the first poll after an enable replays nothing; seeded rows are ordinary ledger rows under REACT-03 and permanent under REACT-05. Seeding covers **every** owner reaction on a message item, not only dictionary matches, so a later dictionary edit cannot re-open an emoji's history — a non-dictionary row is inert because the ledger key includes `emoji`. Alongside it, `Pipeline.Run` gained a per-run dispatch budget (`maxDispatchPerRun = 25`, a code constant, shared across accounts) counting **AI compose calls** rather than ledger rows: a candidate whose emoji maps to no built-in tool is recorded `skipped` before compose is reached and costs nothing, and an over-budget candidate is left unrecorded so the next poll picks it up. Guards: `internal/reactioncmd/pipeline_test.go::TestReactionCmd_DispatchCapDefersOverflow`, `::TestReactionCmd_DispatchCapIsSharedAcrossAccounts`, `::TestReactionCmd_UnderCapDispatchesEverything`. No new contract number (REACT-06 was considered and rejected: "enabling never replays history" is FEAT-03's principle applied here).
- 2026-09-26 (owner call): the feature is **on by default** (`DefaultReactionCommandsEnabled = true`), polled **every daemon cycle** (`DefaultReactionCommandsIntervalHours = 0` = no throttle; an explicit `reaction_commands.interval_hours > 0` still throttles), and `phaseReactionCommands` moved from behind ideas/memory to right after `phaseSlackSync` — before the other source syncs, since Jira alone can take minutes — so a tray Sync Now delivers as soon as the Slack sync lands. The 6 h throttle had been copied from the batch pipelines by analogy; a reaction is a command the owner is waiting on, and the poll is one cheap `reactions.list` call — only a NEW reaction costs an AI call. What makes default-on safe under FEAT-03 is a second seed site: `Pipeline.processAccount` seeds any account whose `slack_accounts.reaction_commands_seeded_at` (migration 00073) is empty on its first poll instead of dispatching (the enable hook keeps seeding too — both go through `seedAccount`, which writes the stamp last). This also closes a pre-existing hole: a Slack account added after the enable was never seeded and replayed its history on the next poll. **Upgrade path (review round 1 blocker):** the migration backfills the stamp for every account that already holds a ledger row — a row proves the feature has polled that account — so an install that was already running the feature does not have its first post-upgrade poll swallow the reactions placed since its last poll; the residual (feature on, zero ledger rows ever) is at most one poll interval and documented in the migration (`internal/db/reaction_seed_migration_test.go::TestMigration00073_StampsAccountsThatAlreadyUseTheFeature`). Two more guards from the same round: `features enable` on an already-enabled feature is now a no-op (`cmd/features_test.go::TestFeaturesEnable_AlreadyEnabledSkipsFastForward` — its hook would otherwise re-seed against an actively polled account; the Desktop's `enableNow` already guarded this), and the phase skips the tracked run entirely when no Slack account is enabled (`internal/daemon/daemon_reactioncmd_test.go::TestDaemon_PhaseReactionCommands_NoSlackAccountsWritesNoRun` — a Google/Jira-only install writes no 0-item `pipeline_runs` row per cycle). Stamp-last is pinned by `internal/reactioncmd/seed_test.go::TestReactionCmd_PartWaySeedFailureLeavesAccountUnstampedAndReseeds` (a SQLite trigger injects the failure; mutation-checked) and budget isolation across accounts by `::TestReactionCmd_SeedingOneAccountLeavesTheOthersBudgetIntact`. Guards: `internal/daemon/daemon_reactioncmd_test.go::TestDaemon_PhaseReactionCommands_DefaultPollsEveryCycle`, `::TestDaemon_PhaseReactionCommands_ExplicitIntervalStillThrottles`, `::TestDaemon_ReactionCommandsDefaultOn`, `::TestDaemon_RunSync_PollsReactionsBeforeAIPipelines`; the four first-poll-seed tests listed under REACT-03. Known, unchanged: a reaction removed and re-placed on the same message is the same ledger key and never re-fires (REACT-05, no undo) — so a reaction placed *before* the seed cannot be re-armed by re-placing it.
- 2026-09-26 (**owner decision: provisional ledger row**, REACT-03 status machine amended — strengthened, no guard relaxed): the ledger row for a command that runs compose/Propose used to be inserted only *after* `Registry.Propose` returned, with an insert failure merely logged — so for an `execute`-trusted tool (`create_idea`, `remind_me`, `brief_context`) whose Propose applies synchronously, a failed ledger write (SQLITE_BUSY, disk I/O) left the reaction unseen and the next poll created a genuine duplicate idea/reminder/brief (or a second pending Jira proposal); materially more reachable since the same-day default-on/every-cycle change. The owner chose the provisional-row fix over single-transaction (infeasible: `Propose`/`Apply` own their writes) and log-only: `Pipeline.dispatchOne` now claims a `pending` row before compose, finalizes it to the terminal status after, releases it on a transient failure (retry semantics unchanged), classifies a non-validation Propose error against the `agent_actions` rows recorded since a pre-Propose high-water mark before releasing (review round 1: Propose can fail after inserting its row — a failed approve stamp or apply bookkeeping on an execute-trusted tool — which the pre-fix code, and the first cut of this one, treated as "nothing proposed" and retried into a duplicate card or entity), and a poll turns a provisional row older than one hour into `failed` with an explicit "outcome unknown" error plus an ERROR log line — the chosen surfacing for stranded rows (visible in `reaction-commands list`, never retried, since Propose may have run). No migration: `pending` was already in the 00063 CHECK, unused until now; no Swift reader of `reaction_commands` exists (the cheat sheet's "last check" reads `pipeline_runs`). Guards listed under REACT-03; the pre-existing `TestReactionCmd_TransientFailureRetries`/`_Idempotent`/`_ComposeFailureMarksFailed` pass unchanged. Backlog item `2026-09-26-reaction-ledger-write-failure-after-propose-double-fires.md` closed.
- 2026-09-26 (**owner decision: re-arm stays documented-only**, backlog item "Re-placed reaction on the same message never re-arms after the seed"): of the three options (document only; let a removed-then-re-placed reaction re-arm, loosening REACT-05; a Desktop "re-run this seeded reaction" affordance through the registry), the owner chose **document only** — no code or contract change. REACT-05 stands as written: a reaction placed before the seed (enable hook or first-poll seed) is a permanent `skipped` row, and removing and re-placing the same emoji on the same message never re-fires it (as with any reaction that already holds a terminal row — a `dispatched` one, or one whose compose `failed`, so re-reacting is not a retry either); the way to act on that message is a different dictionary emoji, or the same emoji on a different message. The limitation is now stated in three places: `docs/app-guide.md` (Inbox "How it works" paragraph and the cheat-sheet empty-state paragraph), CLAUDE.md's Reaction Commands default-on entry, and the Desktop cheat sheet's feature-off caption (`ReactionCheatSheetView`).
