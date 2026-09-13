# Feature-state audit — Inbox + Situations Dashboard + Reaction Commands + Action Strip + Reminders + Catch-Up

Repo `/Users/user/PhpstormProjects/watchtower`, branch `feature/agent-actions` @ 37179540. Read-only trace; no binary run, no tests run.

## 1. Feature status table

| Feature | Gate key + default | Entry points (daemon / CLI / Desktop) | Reachable from UI? | Verdict | Why (one line) |
|---|---|---|---|---|---|
| Inbox detection (Slack mentions/DMs/thread replies/reactions, Jira, Calendar, Gmail, IMAP, watchtower) | `inbox.enabled` = **true** (`internal/config/defaults.go:27`) | `phaseFastInbox` + `phaseInbox` (`internal/daemon/daemon.go:593,827`); `Pipeline.Run`/`RunFastDetection` (`internal/inbox/pipeline.go:371,491`) | **No** — the only item-level view (`InboxCardView`/`InboxFeedView`) is not in navigation | WORKS DIFFERENTLY | Items are still detected, triaged, auto-resolved and archived every cycle, but no reachable Desktop surface lists `inbox_items`; only Catch-Up's `needs_you` area and Memory read them. |
| Full-stream triage (`inbox.triage`, light tier) | `inbox.enabled` (no own gate); `inbox.max_triage_messages` = 600 | `runTriagePhase` (`pipeline.go:269`), `triage.go` | n/a (feeds `inbox_items`) | WORKS DIFFERENTLY | Runs (AI cost) every cycle; its output (`item_class`/`priority`/`ai_reason`) drives nothing visible except Catch-Up's inbox area ordering and the sidebar badge colour. |
| Implicit learner + learned rules | `inbox.enabled` | `RunImplicitLearner` (`pipeline.go:418`) | **No** — Learned tab lived in `InboxFeedView` (`Views/Inbox/InboxFeedView.swift:260`), unreachable | UNREACHABLE (INBOX-05) | Rules still injected into triage prompts but the owner can no longer see/add/remove them; explicit 👍/👎 feedback UI is gone too, so the evidence pool only receives implicit dismissals from a UI nobody can open. |
| Assistant profile brief (`workspace.secretary_profile`) | — | Desktop `SecretaryProfileView` only (`InboxFeedView.swift:273`); no CLI writer | **No** | UNREACHABLE | Read by inbox triage brief (`internal/inbox/brief.go`) and Catch-Up compose (`internal/catchup/pipeline.go:122`), but there is no reachable way to write it (`SecretaryProfileQueries.save` is the only writer). |
| Situations compose + situation cards (Dashboard) | `inbox.situations.enabled` = **false** (`defaults.go:35`); sub-toggle of `secretary-inbox` in Feature Manager (`internal/features/registry.go:125-129`) | `runComposePhase`/`runSituationCards` (`pipeline.go:287-301`, `situation_card.go:34-37`) | **No** — `DashboardView` only mounted inside `InboxFeedView` (`InboxFeedView.swift:45`), which `Navigation.swift:203-204` no longer routes to | DARK + UNREACHABLE | Even if the owner flips the gate on, the generated situations have no Desktop surface any more; only MCP `list_situations` / `cmd/situations.go` / Memory ingest read them. |
| Feed publisher (`internal/feed`, `feed_items`) | none — Core, deliberately ungated (`daemon.go:1069-1077`) | `phaseFeed` (`daemon.go:1077`) | **No** — `FeedViewModel` consumed only by `DashboardView` via `InboxFeedView` | UNREACHABLE | Mechanical upsert into `feed_items` every daemon cycle for a timeline nobody can open (DASH-05/06 protect an invisible surface). |
| Inbox tab (sidebar "Inbox") = action strip | always visible (`SidebarDestination.swift:103-114`) | `ActionStripView` (`Navigation.swift:204`), `ActionStripViewModel` | Yes | WORKS (empty by default) | Pure read of `agent_actions` + due `reminders` (`AgentActionQueries.fetchStrip`, `ReminderQueries.fetchDue`); on a default install (reaction-commands OFF) it only ever shows un-acted chat proposals. |
| Inbox sidebar badge | — | `SidebarView.swift:243` → `situationsCount` | Yes | WORKS DIFFERENTLY | Badge counts **open situations** (`SituationQueries.openCount`), not strip rows; the number the owner sees has nothing to do with what the tab shows. |
| Reaction Commands Wave 1 (poll → compose → dispatch) | `reaction_commands.enabled` = **false** (`defaults.go:50`), `interval_hours` = 6 | `phaseReactionCommands` (`daemon.go:1004`); CLI `reaction-commands poll|list` (`cmd/reaction_commands.go:72-82`) | Settings → Features toggle; dictionary in Settings → Slack (`SlackConnectionDetail.swift:259`) | DARK, with a **landmine on enable** | No ledger seeding on enable (spec §9 promised it): first poll replays up to 2000 historical owner reactions as commands. |
| Reaction dictionary editor | — | `ReactionDictionaryViewModel`/`Queries`, Settings → Slack | Yes | WORKS | Reads/writes `reaction_command_map`, shows trust from `tool_trust`. |
| Wave 2 tools `create_track`/`create_idea`/`remind_me`/`brief_context` | seeded by migration 00064; trust `ask`/`execute`/`execute`/`execute` | registry (`internal/tools/{tracks,ideas,remind,brief}.go`) | via strip cards | WORKS DIFFERENTLY | Cards render raw tool name + raw args JSON (`AgentActionCardView.swift:14-41`); `brief_context`'s summary is never rendered from `result_json` (`:96-104`); reminder ref shown as raw `1:C…@ts` (`ActionStripView.swift:80-97`). |
| Reminders entity | — | `remind_me` Execute → `InsertReminder`; strip Done/Snooze (Swift) | Yes (strip) | WORKS | Due derived at read time (`internal/db/reminders.go:26`, `ReminderQueries.swift:5`); Go/Swift predicates identical; `account_id` always 0 (never populated, `remind.go:48-52`). |
| Catch-Up recap | `catchup.*` caps; tab requires feature `slack-digests` (`SidebarDestination.swift:105`) | **no daemon phase** — CLI `catchup run|ack|feedback|list|show` (`cmd/catchup.go:46-89`) spawned by `CatchUpViewModel` (`CatchUpViewModel.swift:205-227`) | Yes | WORKS | On-demand only, by design; window/top-up/gather/compose/validate/persist traced; ack dual path Go (`internal/db/catchup_store.go:135-167`) ↔ Swift (`CatchUpQueries.swift:94-152`) touches the same five surfaces with identical predicates. |
| Slack `reaction` auto-resolve | — | `autoResolveSlack` (`pipeline.go:878`) | n/a | BROKEN (pre-existing, documented) | Switch lists `"reaction_request"`, detector writes `"reaction"` (`internal/db/inbox.go:601`), CHECK permits only `reaction` (`schema.sql:466-467`) — reaction items never auto-resolve. |

Verdict counts: WORKS 4 · WORKS DIFFERENTLY 5 · DARK 2 · UNREACHABLE 4 · BROKEN 1 (overlaps: situations is DARK+UNREACHABLE, reaction commands DARK+landmine).

## 2. Findings

### Critical

**C1. Enabling Reaction Commands replays the owner's entire reaction history as commands — including auto-executing `create_idea` for every past 💡.**
- Refs: `internal/reactioncmd/pipeline.go:92-136` (`processAccount`: `ListUserReactions` → `FilterUnseenReactionCommands` → dispatch every unseen), `internal/slack/client.go:385-412` (`ListUserReactions` pages `reactions.list` up to `maxReactionListPages`=20 × 100 items, "regardless of message age"), `internal/features/fastforward.go:23-38` (no `"reaction-commands"` case), `cmd/reaction_commands.go` (no seeding on enable anywhere), migration `00063` (ledger starts empty), `00064` (`bulb→create_idea`, trust `execute`; `eyes→create_track`; `white_check_mark→create_target`).
- Intended: Wave 1 spec §9 (`docs/superpowers/specs/2026-09-05-reaction-commands-design.md:202-204`): "Fast-forward hook on enable seeds the ledger from the *current* `reactions.list` so a freshly-enabled feature does not backfill every historical reaction (FEAT-03)."
- Actual: the hook was never written. `FastForward("reaction-commands")` falls to `default: return nil`. The ledger (`reaction_commands`) is empty until the first poll, and `FilterUnseenReactionCommands` therefore returns *every* dictionary-emoji reaction the owner ever placed (most recent ≤2000 items).
- Scenario: the owner turns the feature on in Settings → Features. Next daemon cycle: every ✅/👀/💡/⏰/📌/🎫 the owner has ever put on a Slack message (✅ and 👀 are among the most-used workplace emojis) becomes one light-tier AI compose call each (`pipeline.go:208`) — hundreds of calls in one cycle, no per-cycle cap — followed by `Registry.Propose`. Every past 💡 **auto-creates an idea** (trust `execute`), every ⏰ auto-creates a reminder, every ✅/👀 lands as a pending `create_target`/`create_track` proposal flooding the strip; every 🎫 becomes a pending Jira proposal. All of this is then permanently in the ledger (REACT-05: no undo) and in `ideas`/`agent_actions`.
- Contract impact: FEAT-03 (fast-forward on enable, `docs/inventory/features.md`) is violated for this feature; STRIP-01 is technically satisfied (they were owner gestures) but the "no trash bin by construction" promise (Wave 2 spec §1) dies on day one. **Needs owner decision** on the seeding semantics (seed-then-ignore vs. a time floor).

### High

**H1. The Inbox tab was hollowed out: situations, feed, Learned tab, Profile tab and per-item inbox are all unreachable, while their pipelines keep running.**
- Refs: `WatchtowerDesktop/Sources/App/Navigation.swift:203-204` (`.inbox` → `ActionStripView()` only); `Views/Inbox/InboxFeedView.swift:45,260,273` (Dashboard / `InboxLearnedRulesView` / `SecretaryProfileView` only mounted here); `App/AppState.swift:663-671,684-687` (the VMs are still built); `internal/daemon/daemon.go:1077` (`phaseFeed` ungated), `internal/inbox/pipeline.go:412-428` (triage + learner + auto-resolve still run).
- Intended: Wave 2 spec §4.2 says the Dashboard code is "not deleted … kept reachable-in-code"; CLAUDE.md still describes the Inbox tab as Dashboard + "unchanged Learned tab … and Profile tab". INBOX-05 (`docs/inventory/inbox-pulse.md:85-98`) requires a visible, editable "Learned" tab.
- Actual: none of Dashboard, Learned, Profile, per-item feedback (👍/👎, snooze, "Never show me this", convert-to-target) is reachable from any sidebar destination, notification, or deep link (checked `Navigation.swift`, `WatchtowerApp.swift:117-209`, `NotificationService.swift`, `DigestWatcher.swift`). No CLI writes `workspace.secretary_profile` either (only `SecretaryProfileQueries.save`, `WatchtowerCore/Database/Queries/SecretaryProfileQueries.swift:15`).
- Scenario: the owner wants to tell the assistant "I'm the payments lead, ignore #random" — there is no place to type it; triage and Catch-Up compose keep using whatever brief was saved before 2026-09-06 (or empty on a new install). A learned mute rule that misfires cannot be removed (INBOX-04's "escape hatch" and INBOX-05's editability are both gone). Meanwhile `phaseInbox` still spends the light-tier triage budget on up to 600 messages per cycle whose results only Catch-Up's `needs_you` list ever shows.
- Contract impact: **INBOX-05 unreachable; INBOX-04 escape hatch unreachable; DASH-03/04/05/06/07 protect invisible surfaces.** Needs owner decision (this is the §10 "demolition" the spec deferred, arriving as silent loss instead of a decision).

**H2. `inbox.situations.enabled=false` is a landed default the owner never chose, and the sub-toggle's own description is the only place it is explained.**
- Refs: `internal/config/defaults.go:32-35`, `internal/config/config.go:449`, `internal/features/registry.go:112-131` (feature `secretary-inbox` still described as "clusters them into situations on the Dashboard and writes a situation card"), `internal/inbox/pipeline.go:288`, `situation_card.go:35`.
- Intended: Wave 2 spec §6 + owner-review call SIT-A (`…wave2…design.md:110`): "flagged for explicit confirmation because it darkens a shipped surface." The spec is marked **"Status: design, pending owner review"** (`:3`).
- Actual: the default shipped as `false` on the branch; the owner's live config predates the key, so the owner's install is now dark for compose/cards. Additionally `AutoCloseResolvedSituations` lives inside `runCompose` (`internal/inbox/compose.go:62`) so historical open situations no longer auto-close on the owner's replies — they only decay to `stale` after 7 days via `MarkStaleSituations` (`pipeline.go:328-333`, `internal/db/situations.go:461-471`). Memory situations-ingest (`internal/memory/ingest.go`) and MCP `list_situations` (`internal/mcp/situations.go`) keep reading a frozen, un-closing set.
- Scenario: Memory (enabled on the owner's install) keeps ingesting the last pre-mute situations as "open" for a week, then everything reads `stale`; no new situation episodes are ever minted again — the `situation:<id>` episode source silently dried up on 2026-09-06 with no log line saying so.
- Contract impact: DASH-01/02/07 muted without inventory changelog; **needs owner decision** (confirm SIT-A).

**H3. Inbox badge counts a table the tab no longer shows.**
- Refs: `WatchtowerDesktop/Sources/Views/Sidebar/SidebarView.swift:243` (`case .inbox: situationsCount`), `ViewModels/SidebarCountsViewModel.swift:150,163,202` (`SituationQueries.openCount`), `:217-218` (red when `inboxHighPriorityCount > 0` — from `inbox_items`).
- Intended: a badge is "things waiting on you" on that tab (Wave 2 spec §4.2: strip = "everything awaiting my decision").
- Actual: badge = `COUNT(*) FROM situations WHERE status='open'`; strip rows (`agent_actions` non-terminal + due `reminders`) contribute nothing. With situations muted the badge decays to 0 within `dashboard.stale_after_days` (7) and then never lights again, no matter how many proposals or due reminders pile up.
- Scenario: a `create_jira_issue` proposal from the target chat sits pending for days; the Inbox badge stays empty; the owner never opens the tab. Conversely, for the first week after upgrade the badge shows N open situations the owner cannot see or clear from the tab.

**H4. `reactions.list`-driven `remind_me` cannot honour "09:00 local" — the composer is never told the local time zone.**
- Refs: `internal/reactioncmd/prompt.go:36-40` ("use tomorrow at 09:00 local converted to UTC"), `pipeline.go:205-206` (only `today` in UTC is passed), `internal/tools/remind.go:33-41` (only checks non-empty; no time parse), `internal/db/reminders.go:26-29` and `ReminderQueries.swift:5-10` (string compare against an ISO-Z `now`).
- Actual: the model has no way to know the owner's offset, and `remind_at` is stored verbatim as whatever string the model emitted; nothing validates it is ISO-8601-Z. A `+03:00`-suffixed value, a date-only value, or a natural-language value ("tomorrow 9am") either compares wrongly or (date-only `2026-09-13`) becomes due at 00:00Z instead of 09:00 local.
- Scenario: owner in Kyiv (UTC+3) reacts ⏰ at 18:00; the model guesses "09:00 UTC" → reminder appears at 12:00 local; or emits `2026-09-13T09:00:00+03:00` → `'2026-09-13T09:00:00+03:00' <= '2026-09-13T06:30:00Z'` is string-false until the Z-string date passes it, then true — fires at a time unrelated to 09:00. REMIND-01 ("inert until due") holds only by accident of string ordering.

### Medium

**M1. Strip cards for the four Wave 2 tools are raw JSON; `brief_context`'s brief is never rendered as its result.**
- Refs: `WatchtowerDesktop/Sources/Views/Chat/AgentActionCardView.swift:14-20` (title switch knows only `create_target`/`create_jira_issue`), `:22-41` (`default: return [action.argsJSON]`), `:96-104` (`outcome` renders only Jira url/key or `target_id`; `result_json.summary` from `internal/tools/brief.go:47` is ignored), `ActionStripView.swift:80-97` (reminder shows raw `<channel_id>@<ts>`, no link — the comment admits it).
- Intended: Wave 2 spec §5.4 "the card renders the brief and is dismissable"; §1 "brings me a ready decision".
- Actual: a 📌 reaction produces a card titled `brief_context`, status "Done", body `{"summary":"…","reason":"…"}`; it ages out of the strip after the 24 h terminal tail (`ActionStripViewModel.swift:40`, `AgentActionQueries.swift:43`) and is then unreachable anywhere. `create_track`/`create_idea`/`remind_me` proposals show `{"text":…}` blobs. No dismiss action exists for terminal cards.

**M2. The strip only refreshes on tab appear; daemon-written proposals never show while the owner is looking at the tab.**
- Refs: `ActionStripView.swift:24` (`.task { refresh() }` once per appear), `ActionStripViewModel.swift:33-48` (no polling/observation; the comment explains `ValueObservation` cannot see subprocess writes).
- Scenario: owner sits on Inbox, reacts ✅ in Slack, the daemon dispatches within the 6 h poll — nothing appears until the owner navigates away and back. Compare `CatchUpViewModel`, which polls while building (`CatchUpViewModel.swift:95`).

**M3. Slack `reaction` inbox items never auto-resolve (INBOX-02 gap, re-verified still open).**
- Refs: `internal/inbox/pipeline.go:878-881` lists `"reaction_request"`; `internal/db/inbox.go:601` sets `c.TriggerType = "reaction"`; `internal/db/schema.sql:466-467` CHECK does not contain `reaction_request`.
- Actual: unchanged from the 2026-08-15 changelog note (`docs/inventory/inbox-pulse.md:172`). With no UI to close them, `reaction` items now live until `ArchiveStaleActionable` (14 d) — and every one of them is an `actionable` row Catch-Up's `ListCatchupInbox` (`internal/db/catchup.go:307`) surfaces in `needs_you`. **Needs owner decision** (Enforced INBOX-02).

**M4. `phaseFeed` and `NotifyDueTargets` produce for surfaces nobody can open.**
- Refs: `internal/daemon/daemon.go:1077-1088` (feed publish every cycle, Core/ungated), `daemon.go:652-656` (`NotifyDueTargets` mints `target_due` inbox items "so they reach the user through the same channel as Slack/Jira/Calendar reminders"), `pipeline.go:486-490` (`RunFastDetection` comment: "surface DMs/mentions in the UI immediately").
- Actual: the "UI" these comments describe is `InboxFeedView`. Due-target reminders now reach the owner only if they run a Catch-Up and the item is still pending. Cheap (no AI) but dead work, and misleading comments.

**M5. `reminders.account_id` is never populated.**
- Refs: `internal/tools/remind.go:48-52` (no `AccountID`), migration `00064` (`account_id INTEGER NOT NULL DEFAULT 0`), `internal/db/reminders.go:17-24`.
- Actual: every row has `account_id=0`; the account is recoverable only by parsing the `1:C…` prefix of `message_ref`. Harmless today (nothing reads it), but it is the column a future permalink/attribution join would key on.

### Low

**L1. Feature-registry copy is stale for `secretary-inbox`.** `internal/features/registry.go:114` still sells "clusters them into situations on the Dashboard and writes a situation card" while its own sub-toggle (`:126-129`) says off = "the inbox shows the action strip only" and defaults off. The onboarding splash reuses these strings (`FeatureSplashView`).

**L2. Spec vs. implementation drift on `reminders`.** Wave 2 spec §5.3 specifies columns `channel_id, message_ts`, a `due` status and a `phaseReminders` daemon phase; shipped: `message_ref` only, statuses `pending|done|dismissed`, due derived at read time. The inventory (`docs/inventory/reaction-commands.md:162-182`) documents the shipped form, so this is a spec-not-updated note, not a bug.

**L3. Catch-Up tab visibility is tied to `slack-digests` only** (`SidebarDestination.swift:105`) although the recap gathers Gmail/Jira streams, meetings, decisions, inbox, tracks, targets. Disabling Slack digests hides the whole tab.

**L4. `situations` CLI/MCP still advertise a live surface.** `cmd/situations.go`, `internal/mcp/situations.go` (`list_situations`/`get_situation`, DEV contracts) and the `watchtower-*` skills keep exposing a table that stopped growing on 2026-09-06; nothing tells the dev's agent the data is historical.

### Clean bills (WORKS, traced)
- **Catch-Up**: `cmd/catchup.go:168` wires the real `cliTopUp`; `Pipeline.Run` (`internal/catchup/pipeline.go:89-141`) follows resolveWindow → insert(building) → topUp (gated on `Digest.Enabled`/`Streams.Enabled`, failures recorded not returned, `:190-222`) → gather (7 areas, `:225-250`) → compose with `prompts.Directive` (`:128`) → `validateBody` → `finish`/`failRun`. `ResolveWindow` (`internal/catchup/window.go:34-98`) clamps to now, 31-day cap, 24 h fallback. No daemon phase — Desktop `CatchUpViewModel` spawns `catchup run --json` (`CatchUpViewModel.swift:205-214`) and polls the row while building. Acknowledge: Go `AcknowledgeCatchupWindow` (`internal/db/catchup_store.go:154-159`) and Swift `CatchUpQueries.acknowledge` (`CatchUpQueries.swift:107-151`) issue the same six statements with the same predicates (overlap for `digests`/`stream_digests`, `(from,to]` for `tracks`/`inbox_items`, `to−1s` local date for `briefings`), both inside one transaction (`CatchUpViewModel.swift:346`), both refuse non-`ready`.
- **Inbox watermark (INBOX-09)**: `decideWatermark` (`pipeline.go:346-363`) freezes on detector error, partial-advances on triage error/cap, else `now−30min`; `advanceWatermark` clamps to `lastTS` (`:473-480`). `detectSlackAccounts` loops `ListEnabledSlackAccounts` per-account with joined errors (`:603-627`).
- **Reaction ledger idempotency (REACT-03)**: `FilterUnseenReactionCommands` before dispatch, transient compose/propose failures not recorded (`pipeline.go:114-134,147-186`).
- **Strip contracts STRIP-02/03**: `ActionStripViewModel.refresh` is two SELECTs; approve/reject/retry delegate to `AgentActionFeed` (`ActionStripViewModel.swift:36-86`).
- **Reaction dictionary editor** reachable at Settings → Slack (`SlackConnectionDetail.swift:253-259`).

## 3. Needs owner decision
1. **C1** — how enabling `reaction-commands` should treat history: seed the ledger from the current `reactions.list` (spec §9), or a `ts` floor. Until decided, the feature must not be flipped on a real account.
2. **H1/H2 (SIT-A)** — confirm `inbox.situations.enabled=false` as the shipped default, and decide the fate of the now-unreachable Learned tab (INBOX-05), Profile brief editor, per-item feedback (INBOX-04 escape hatch), Dashboard conversion (DASH-03), and the feed publisher (DASH-05/06). Either re-home them (Settings?) or retire the contracts via the deferred demolition spec.
3. **M3** — `autoResolveSlack` `"reaction_request"` → `"reaction"`: a one-token fix, but it changes Enforced INBOX-02 behaviour.
4. **H3** — what the Inbox badge should count now (strip rows? nothing?).
5. **L3** — whether Catch-Up should be visible independent of `slack-digests`.

## 4. What I could not verify
- Whether Slack's `reactions.list` returns most-recent-first (the C1 blast radius is "≤2000 most recent" only if so; otherwise it is the oldest 2000).
- The live install's actual counts (open situations, pending `agent_actions`, existing reminders) — out of scope for this auditor.
- Whether `decided_at` on `agent_actions` is written in the same `…Z` format the Swift `terminalSince` string uses (`AgentActionQueries.swift:43`); registry code at `internal/tools/registry.go:288` suggests `strftime('…Z')` but I did not trace every writer.
- Runtime behaviour of the Wave 2 tools' `Execute` paths (`create_track`/`create_idea`) against the live schema — only read, not executed.
- Test suites were not run (brief allows ≤3 targeted runs; none of the findings hinged on one).
