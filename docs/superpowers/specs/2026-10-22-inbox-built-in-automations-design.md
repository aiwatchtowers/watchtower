# C — Brief, plan, tracks, ideas, reactions and mentions as parts of one Inbox, produced by built-in automations

Board #801 (under Automations #405). Follows parts A and B (`2026-10-21-automations-panel-and-inbox-design.md`, shipped in PR #449). Mockups: `.superpowers/brainstorm/10532-1792618484/content/c-inbox-v1.html` (local, not committed).

## 1. Intent

The owner, 2026-10-21: daily briefs, day plans, tracks and ideas "should not be separate entities but part of the Inbox, solved by preinstalled automations". Earlier answers in the same direction: reactions and tracks are "not separate tabs but preinstalled automations" (ask #470), "rewrite the engines", not only unify the screens (#472), "one place for rules" (#346/#347), the Inbox reads like mail with general card buttons (#466–#468).

Today the owner meets the same day in six places: Briefings, Day Plan, Tracks, Ideas, the Inbox tab (proposals, reminders, automation cards) and Home's feed (mentions, DMs, waiting replies — `inbox_items` have no screen of their own). The rules behind them are scattered: Settings → Features (hours, switches), the Reactions dictionary, per-track instructions, prompts reachable only through the DB prompt store.

**Done means:** one Inbox where everything that needs the owner arrives as a card; the screens Briefings, Day Plan, Tracks and Ideas are gone from the sidebar; every producer is an automation in Automations → **Built in**, visible, editable through the chat like any recipe, turned off when its tokens are not worth it, and reset to the shipped version.

## 2. Decisions taken (owner, ask #499 — all as recommended)

1. **Brief and plan = one morning card "Your day"**: the plan on top (checkboxes, Add, Regenerate with feedback…), the brief below.
2. **One card per track**: a new event raises it to the top and makes it unread; inside, "New since you looked" and the history.
3. **An approved idea stays in the Inbox**: the ideas registry is the Inbox's **Ideas** filter (approved and decided included). No board task is made unless the owner presses **Make a Task**.
4. **One Inbox for everything**: mentions, DMs, thread replies, "waiting for your reply", assigned tickets (`inbox_items`) become Inbox cards too.

Also from the mockup the owner did not object to (treated as agreed, flagged in the review ask): the sidebar loses Briefings, Day Plan, Tracks, Ideas; the filter over the list is **All · Day · Messages · Tracks · Ideas · Automations**; built-ins arrive turned on; the brief link on Home opens the Inbox on the day card.

## 3. Goals, non-goals, anti-goals

Goals
- G1. One Inbox list and reading pane shows every kind: day card, track, idea, mention/DM/waiting item, proposal, reminder, automation card, save_automation proposal.
- G2. Each producer is a built-in automation (a recipe the app ships), listed in Automations → Built in, with When / Reads / Sends / Costs, **Edit in Chat**, **Turn Off/On**, **Reset to built-in**.
- G3. The owner's edits of a built-in follow the normal automation rules (their copy, their confirmation).
- G4. Nothing the owner has today is lost: history of briefings, plans, tracks, ideas stays readable in the Inbox filters; MCP read tools, Catch-Up, meeting prep, phone slices keep working.
- G5. An upgrade keeps today's behaviour: what runs today runs after the upgrade without a click.

Non-goals
- Digests and the Decisions ledger in the Digests tab stay where they are.
- Catch-Up stays its own flow (it reads the same tables).
- The phone app's screens do not change in C (its slices read the same tables).
- No new sources; custom tracks may read more than today only through tools that already exist (§6.3).

Anti-goals (would make it a failure even if it works)
- A built-in that silently costs the owner tokens they cannot see or stop.
- An Inbox that becomes noisier than today's six places together (a card per track update, a card per channel mention).
- Built-ins that bypass the automation contracts (AUTO-02 writes through the registry, AUTO-06 only confirmed content runs) except by the one explicit amendment in §5.2.
- Re-implementing the Go invariants (track dedup, idea floors, the reaction ledger) in recipe JavaScript where the SDK cannot enforce them.

## 4. Shape

```
Built-in recipe (shipped .md, owner-editable copy)      Go primitives (SDK calls only built-in-capable recipes get)
  schedule / sync / event trigger                        gather → validated context, escaped as data
  prompt text = the owner-editable part        ──►       llm() strong/light as today's tier table says
  orchestration: which primitives, in which order        save → the existing tables, with today's invariants
                                                             │
                                                             ▼
                              briefings · day_plans · tracks/track_events · ideas · reaction_commands · inbox_items
                                                             │
                                                             ▼
                                Inbox list builder (one view over all of them + automation_outputs + agent_actions + reminders)
```

The engines are rewritten in the sense the owner asked (#472): the daemon's hard-coded phases for these producers go away; what runs, when, and with which prompt is the recipe. What the recipe cannot be trusted to enforce stays in Go behind a narrow SDK call. Data stays in today's tables, so every reader that is not a screen (MCP tools, Catch-Up, meeting prep, briefing context, phone slices) keeps working untouched.

**Where built-ins run (my call).** Built-ins run **inside the daemon's sync cycle, at the slot their phase holds today**, not in the executor's queue: the cycle order matters (custom-track scan before auto tracks "so folds land", tracks before rollups through `TrackContext`, inbox before ideas, briefing before day plan) and built-ins must not compete with the owner's recipes for the executor's two slots. A new trigger kind **`sync`** ("at its slot in every sync cycle") is allowed only for `origin = 'builtin'` recipes; a built-in with a time (Morning brief) is a `sync` trigger plus its hour gate, evaluated at its slot as today (once per date, fresh-install bypass, 3 failed attempts). Each in-cycle run still writes an `automation_runs` row (history, costs, failure notices). **Run Now** on a built-in queues a manual run that executes at its slot in the next cycle (it wakes the daemon).

**Primitives own the AI call (my call).** A primitive does gather → `llm` → validate → save in Go, with the prompt text supplied by the recipe. So per-source tiers and routing (`briefing.daily`, `tracks.extract_batch` …), role variants (`GetForRole`), attempt budgets, `pipeline_runs`-style telemetry and the cross-process locks stay where they are. The shipped recipe passes `prompt: builtin.defaultPrompt()` (the role-aware default); an owner copy may pass its own literal text instead.

## 5. Built-in automations

### 5.1 The set

| Built-in | Replaces | Trigger (default) | Writes | Card |
|---|---|---|---|---|
| **Morning brief** | `phaseBriefing` + `runDayPlanPhase` | `sync` at the briefing slot, hour = `briefing.hour` (default 08:00), first run right after setup (today's fresh-install rule); the plan is made in the same run right after the brief (the plan already reads the brief) | `briefings`, `day_plans`/`day_plan_items` | one "Your day" card per date |
| **Track my threads** | `phaseTracksAndRollups` tracks part | `sync` at the tracks slot (needs Slack Digests, as today) | `tracks` (auto) | one card per track |
| **Idea finder** | `phaseIdeas` (stage 2, consolidate) | `sync` at the ideas slot, throttle `ideas.mine_interval_hours` (6 h); takes `ideas_backfill.lock` as today | `ideas`, `idea_mentions` | one card per proposed idea; decisions go to the brief and the Ideas filter |
| **Reactions** — one built-in whose card is the dictionary (✅ → Task, 🎫 → Jira/Linear, 👀 → Track, 💡 → Idea, ⏰ → Reminder, 📌 → Brief note; rows editable, + adds a row) | the dispatch half of `phaseReactionCommands` | `sync` inside the reaction pass (see below) | proposals through the registry on the `reaction` surface (as today) | the proposal card (as today) |

**Reactions in detail (my call).** Poll, claim, finalize, the 25-per-run cap and the one-hour stranded rule stay in Go's one pass (REACT-03, one owner of the cap). For each claimed `reaction_commands` row the pass runs the Reactions built-in synchronously: the recipe supplies the compose prompt (today's `reactioncmd.command`, light tier) through `reaction.compose({prompt})`; Go proposes with `ContextID = <channel>@<ts>` on the **`reaction` surface**, so today's per-surface trust holds (`create_idea`, `remind_me`, `brief_context` stay instant; G5) and `brief_context` stays reachable. The `slack.reaction_added` bus event for the owner's own recipes is unchanged. The mockup showed one row per emoji; one card with the dictionary is simpler and matches the dictionary being owner-editable data.

Stays a plain Go phase, not a recipe (my call — no owner-facing rule): Slack reaction polling and the ledger, stage-1 idea material (`phaseStreamDigests`, digests' `ideas`/`decisions` arrays), `internal/inbox` detectors (`inbox.enabled` unchanged), the day plan's per-cycle conflict check (mechanical, marks the day card), rollups, people cards. The Messages cards (§6) are a view over `inbox_items`, not a built-in: turning detection off would starve the brief, Catch-Up and meeting prep.

Custom tracks (the owner's own "Watch for something") are **not** built-ins: each is an ordinary Personal automation made from the **+ → Watch for something** tile (§6.3).

### 5.2 How a built-in is shipped, confirmed and edited — AUTO-06 amendment (owner approval needed)

- Shipped recipe files are embedded in the binary (like the template gallery) and indexed with `origin = 'builtin'` and a `builtin_id` (e.g. `morning-brief`). Their `automations.path` is a synthetic `builtin:<id>` (the column is `NOT NULL UNIQUE`); no file is written until the owner edits one. The owner's copy lives at `<workspace>/automations/.builtin/<id>.md`, which the Personal scanner skips and the built-in indexer reads (one row per built-in, never two).
- **Parameters are not recipe bytes (my call).** A built-in's When fields (brief hour, working hours, ideas interval, the reaction dictionary) are parameters kept where they are today (config, `reaction_command_map`), edited directly on its card by the owner and outside the approval hash. Changing the hour does not make an owner copy and does not stop shipped updates. Only the recipe text (prompt, orchestration) is hashed and overridable.
- **Amendment:** a built-in whose recipe bytes equal the version shipped in the running app is runnable without the owner's confirmation — the release is its confirmation. This is the one exception to "only owner-confirmed content runs". Everything else in AUTO-06 holds: any other content, including the owner's edited copy, runs only after the owner confirms it in the panel; capabilities and outputs are hashed as today.
- **Edit in Chat** opens the editor (A) on the built-in's text. The first save writes the owner's copy (`<workspace>/automations/builtin-<id>.md`) with `origin = 'builtin'` kept and `overridden = 1`; it is confirmed and turned on or off by the panel's normal Save buttons. From then on it is the owner's recipe.
- **Reset to built-in** (in ⋯) deletes the owner's copy and returns to the shipped version (runnable at once, per the amendment). Confirm with an inline "Reset — your changes are lost" row, no modal.
- **App upgrade with a new shipped version:** an un-overridden built-in moves to the new version silently. An overridden one keeps the owner's copy; its card shows "Built-in version updated" with **Show changes** (the existing diff view) and **Reset to built-in**.
- **Delete** is not offered for built-ins; **Turn Off** is.
- Built-ins write only what their Go primitives write (today's tables) and propose through the registry where today's pipelines propose (reactions). They get no auto grants (AUTO-03 unchanged).

### 5.3 Primitives (Go, SDK)

New SDK namespace available only to recipes with `origin = 'builtin'` (shipped or the owner's copy), each behind a hashed capability in the manifest. Each runs today's pipeline step in Go with the recipe's prompt text:

- `brief.compose({date, prompt})` → today's `briefing.RunForDate`: gather (sources, learned rules, owner profile, FROM YOUR AUTOMATIONS block, external text escaped as data per #553/#554), strong-tier call, `blankUnshownIDs`, upsert `briefings`; idempotent per (owner, date).
- `plan.compose({date, prompt, feedback?})` → today's day plan generation (manual items kept across regenerate, working hours, counts).
- `tracks.extract({prompt})` → today's batch extraction; fingerprint/Jaccard dedup, relevance, retries, `TrackContext` for rollups stay inside (TRACKS-01..07).
- `ideas.consolidate({prompt})` → today's consolidate step with floors, validated refs and ref-level dedup in one transaction (IDEA-01..05), under `ideas_backfill.lock`.
- `reaction.compose({prompt})` → for the claimed row the pass is handling: message text, thread and channel come from Go; proposals keep `ContextID = <channel>@<ts>` (REACT-02).
- `builtin.defaultPrompt()` → the shipped, role-aware prompt for this built-in.

**Manual and CLI paths (my call).** `watchtower briefing generate`, `day-plan generate`, Regenerate with feedback, `tracks generate|scan`, `ideas mine --from` and the foreground `watchtower sync` keep calling the same Go steps, with the prompt taken from the built-in's current recipe (shipped or the owner's copy) instead of the prompt store. `tracks enable|disable` and the feature CLI toggle the built-in (§5.4). History backfill is unchanged.

The prompt each primitive uses today moves into the recipe text (the owner-editable part). The DB prompt store rows for these ids are read once at migration (§8) so a customised prompt is not lost.

Budgets: a built-in keeps today's guards in Go — 3 failed AI attempts per date for brief/plan, the 6-hour ideas throttle, the 25-per-run reaction cap — in addition to the recipe's token/minute budget. **Costs** on the card reads the run history (`reported_cost_usd`) and today's `pipeline_runs` for the days before C.

### 5.4 Settings move

Settings → Features rows for Briefing hour, working hours, Ideas interval, the Tracks/Ideas/Reactions/Day plan/Briefing switches become the built-in's **When** fields and its Turn On/Off. `day_plan.hour` is retired: the plan is made with the brief (the upgrade keeps `briefing.hour`). Settings keeps a one-line pointer "These now live in Automations → Built in".

**One source of truth for on/off (my call):** the config keys (`briefing.enabled`, `day_plan.enabled`, `tracks.enabled`, `ideas.enabled`, `reaction_commands.enabled`) stay the truth, so every Go and Swift reader that checks them today (`ideas.Pipeline.Run`, readiness, `Tracks.Enabled && Digest.Enabled`) keeps working. A built-in's Turn On/Off writes its key through the feature-toggle path, and the built-in's `enabled` is derived from it. Turn On runs the FEAT-03 fast-forward hook as today (ideas floors, reaction ledger seed), so turning on never replays history. FEAT-01..03 amended in wording only (the switch moves to the built-in's card), owner approval in the spec review.

## 6. The Inbox

### 6.1 List

- One list, sections **Needs your decision / Today / Earlier** (B's).
- Filter segments: **All · Day · Messages · Tracks · Ideas · Automations**. Day = day cards (the briefing history). Messages = `inbox_items` cards. Tracks = all tracks incl. read. Ideas = proposed, approved, decided, rejected (the registry). Automations = cards from the owner's own recipes, proposals and reminders.
- Placement: proposals, pending save_automation, ideas waiting for a verdict → Needs your decision. The day card is pinned first in Today until Done. A track card's time = its last event. Messages cards sort by their own time.
- Badge (my call): Needs your decision + unread Messages cards + an unread day card. Track and automation cards count only in the list's unread dots, not the badge.
- Old navigation (`watchtower-nav://briefings`, `day-plan`, `tracks`, `ideas`, the sidebar destinations, notifications that opened them) routes to the Inbox with that filter and the item selected.

### 6.2 Cards

- **Your day** (Morning brief): the plan block (items with checkboxes → `day_plan_items` status, Open source, delete; **+ Add**; **Regenerate with feedback…** opens an inline text row, not a sheet; conflict chips from the per-cycle conflict check), then Needs you / Your day / What happened / Team pulse / Coaching with today's deep links. Header: **Discuss in Chat**, **Done**. Reading it marks `briefings.read_at` (CATCHUP-01's surface kept).
- **Track**: title, watched sources, **New since you looked** (events after `read_at`), history folded ("Earlier · N", show all), each event's source link. A target-linked custom track's proposed action (today applied by the Swift `TargetActionExecutor` outside the registry) becomes a card button whose press proposes the matching target edit through the registry (`update_target` and friends on the owner's surface) — closes gap 17. For a custom track the card also carries its controls (instruction, Turn On/Off = Collecting/Paused, Scan from date) — in C1 directly on the card, from C3 as its recipe's card. Common row: Discuss in Chat, Hand to Agent…, Done (= mark read; a new event reopens it, TRACKS-04), **Stop watching** in ⋯ (dismiss, TRACKS-07).
- **Idea**: text, mentions chronology, **Approve**, **Make a Task**, **Not now ▾** (1 week / 1 month / no date), **Reject**; decided ideas show their status and Supersede/Reverse for decisions. Writes are today's verdict writes (IDEA-04 resurfacing respects the verdict).
- **Message** (`inbox_items`): who, where, the text (fenced as data in any chat/agent hand-off), **Open in Slack/Mail/Jira**, **Discuss in Chat**, **Done** (resolve), **Hide** (dismiss), **Snooze ▾**. INBOX-02 auto-resolve still removes them; INBOX-09 one record per channel accumulates mentions (#310).
- Proposals, reminders, automation cards, save_automation proposals: as B shipped.

### 6.3 Watch for something → custom tracks as automations

The **+** screen's "How do you want to start?" gains **Watch for something** (moved here from A, review #493). It drafts a Personal recipe in the chat: an instruction, the sources it watches, a trigger (after every sync by default), output = the track's card. A primitive `track.scan({instruction, since})` keeps today's scan (one extract call forward; the two-stage shortlist and the last-400-summaries dedup only for a backfill) and the failure budget, and is allowed to Personal recipes made from this tile; it runs at the custom-track slot of the sync cycle (before auto tracks) like a built-in, with the owner's confirmation as for any Personal recipe. The recipe may widen sources through existing read tools (`list_messages`, Gmail, Jira reads), with a per-track watermark in the primitive so volume stays bounded. Existing custom tracks migrate into such recipes (§8). Collecting/Paused = Turn On/Off; Scan from date = **Run Now** with a "since" field on the card.

## 7. What disappears

Sidebar destinations Briefings, Day Plan, Tracks, Ideas and their screens; the Automations tab's Reactions/Tracks sections (the reaction dictionary editor becomes the reaction built-ins' cards; "New reaction automation" stays as a template); Settings → Features rows listed in §5.4; the daemon phases listed in §5.1 (replaced by built-in runs). Onboarding's goal → sidebar visibility mapping drops the four destinations; a goal that used to show them now turns the built-in on.

## 8. Upgrade

One-time daemon upgrade step (like #671's):
- Each built-in starts **on** if its feature was on (or had no switch), **off** if the owner had turned that feature off.
- Parameters (hours, working hours, interval, dictionary) stay where they are; they never make an owner copy.
- A prompt-store row marked customised for a built-in's prompt becomes an owner copy of that built-in (overridden, confirmed — it was the owner's own content already running), so the behaviour is unchanged; its card shows "Built-in version updated" whenever a later release changes the shipped text.
- Each custom track becomes a Personal recipe made from the Watch-for-something template, its instruction and Collecting/Paused carried over, confirmed (owner content already running). Its `tracks`/`track_events` rows stay and keep feeding its card.
- History is not moved: Inbox cards are a view over the existing rows.
- The step is idempotent and records itself; a failure leaves the old phases running for that producer and shows one Inbox card "Couldn't move <name> to Automations — Retry".

## 9. Contracts touched (owner approval in the spec review)

- **AUTO-06** amended (§5.2): shipped built-in bytes run without the owner's confirmation.
- **FEAT-01..03** amended (§5.4): the feature switch for these producers is the built-in's on/off.
- **INBOX (inbox-pulse)**: `inbox_items` gain a screen (the Messages cards); detectors, INBOX-02/05/09 unchanged.
- **STRIP-01..03**: the strip shows more kinds; still a view (STRIP-02), decisions still through the registry (STRIP-03) — now also track actions.
- **TRACKS-01..07, IDEA-01..05, REACT-01..05, OWNER-01/02, CATCHUP-01**: unchanged, enforced by the primitives; their guards move with the code they guard, assertions kept.

## 10. Phasing (one spec, three plans)

- **C1 — One Inbox.** List builder over all kinds, the four cards (custom-track controls on the track card), filters, badge, routing of old links; the four screens removed. Producers still run as today's phases. Ships value alone.
- **C2 — Built-in engine + Morning brief.** origin/builtin, the `sync` trigger, shipped recipes, the AUTO-06 amendment, Edit/Reset/upgrade flow, Automations → Built in, `brief.compose`/`plan.compose`, Settings move for brief/plan, upgrade step for them.
- **C3 — Tracks, ideas, reactions as built-ins; Watch for something.** The remaining primitives, custom track migration, reaction dictionary → built-ins, the rest of the upgrade step and Settings move.

## 11. Left to the builder

Exact SDK signatures and capability names; the list builder's query shape and paging; how the day card's plan block reuses today's Day Plan views; card layout details within the design kit; how "Costs" aggregates; test fixtures. Any change that would weaken a guard listed in §9 is a stop-and-ask.

## 12. Calls I made (check these while reading)

- Built-ins run in the daemon's sync cycle at their phase's slot (new `sync` trigger, built-ins only), not in the executor's two-slot queue — keeps today's ordering and never delays the owner's recipes.
- Primitives own the AI call; the recipe supplies the prompt. Tiers, role variants, attempt budgets, locks stay in Go.
- Reactions: one built-in whose card is the dictionary (not one per emoji, as the mockup showed); proposals stay on the `reaction` surface so instant ideas/reminders/brief notes stay instant.
- Hours, working hours, the ideas interval and the dictionary are parameters on the card, outside the approval hash; changing them does not freeze a built-in into an owner copy.
- The config `*.enabled` keys stay the on/off truth; the built-in's Turn On/Off writes them and runs the FEAT-03 fast-forward.
- `day_plan.hour` is retired; the plan is made with the brief at `briefing.hour`.
- Mentions/DMs are an Inbox view over `inbox_items`, not a built-in with an off switch (detection keeps feeding the brief, Catch-Up and meeting prep).
- Badge = Needs your decision + unread Messages + an unread day card.
- Filter adds **Messages** for mentions/DMs (the mockup had five segments).
