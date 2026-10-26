# Mobile workbench remote — work a workbench from the phone (design)

Date: 2026-10-25. Board target #1072. Owner decisions: asks #609–#613.
Builds on: [mobile-companion.md](../../features/mobile-companion.md), [session-chat-feed.md](../../features/session-chat-feed.md) (phase 3 = the chat on the iPhone), [owner asks v2](2026-10-10-owner-asks-v2-design.md) (presence), the [phone permission answers](2026-10-17-phone-permission-answers-design.md), the [mobile design pass](2026-10-11-mobile-design-pass-design.md) (replaced by §6 here) and the [Desktop style guide](../../design/desktop-style-guide.md).

## 1. Intent

The owner wants to run workbench sessions **without sitting at the Mac**: walk away, and keep the work going from the phone. The three cases the owner named — "I left, an agent stopped on an ask", "I want to give the agent a new instruction", "I work without the computer at all" — are one case: the phone is a full remote for the Mac's sessions (owner, ask #610).

The Mac stays the engine: agents run there, the phone never runs one. The phone's job is to show what the sessions are doing, tell the owner when work stopped, and let them restart it.

Today's phone is a working POC that the owner calls "a prototype you can't show anyone". Its pieces exist (chat on request, Tell bar, start/stop, asks, permission answers, board writes) but the chat lags ~40 s, nothing pushes, and the look is generic.

## 2. Goals

1. **Workchat on the phone, near live, without activity.** An open session shows the dialog (owner lines, agent text, asks and answers, Watchtower lines, subagent markers — FEED-02 kinds) and one state line: working (with its timer) / waiting for you / finished / stopped / failed. No tool calls, no thinking, no live activity line (owner item 1). New entries appear within a few seconds while the screen is open.
2. **Chat in the workchat.** A composer at the bottom of the workchat sends a line to the session, including while the agent works (as the Desktop Workchat does since #846), with the same delivery states the Mac shows.
3. **Pushes for every stop of work while the owner is away from the Mac.** Ask, permission request, session finished / waiting for input, session failed (owner, ask #612: "every case when I'm not at the computer and the work stopped"). While the owner is at the Mac the phone stays silent: the Mac's own notices are enough (owner, ask #612).
4. **A real design for the whole app** — Now, Workbench, sessions, workchat, asks, board, Calendar, recordings, Settings, linking — in the Desktop's visual language (owner, ask #611: "like our Desktop"; ask #613: "the whole app").

## 3. Non-goals

- Running an agent, a model or the chat assistant on the phone (the AI chat research, 2026-10-14, stays parked).
- Diff review / Branch review, attachments, photos or dictation in the workchat (owner, ask #613: "the four items are enough").
- Waking a sleeping Mac (impossible, see the 2026-10-14 research §2). The phone says the Mac is asleep instead (§5.6).
- A server of our own or a third-party push service. Transport stays CloudKit, E2E stays as it is.
- Codex sessions get the workchat read and the composer only as far as the Mac supports them today (Codex keeps the busy hold).

## 4. Anti-goals (failure even if it works)

- The phone buzzes while the owner sits at the Mac working.
- One stop of work buzzes twice (ask + "session waiting" for the same stop; a re-publish; a second phone push after the owner came back and left again for the same ask).
- A line typed on the phone lands in the wrong place (a permission prompt, a subagent, the middle of the owner's draft on the Mac). PROJ-16 / PROJ-21 guards stay.
- The phone looks live but is stale without saying so (a sleeping or offline Mac must read as such).
- Any plaintext of the chat or alert on disk or in iCloud outside the existing sealed records (FEED-01, E2E).
- A "mobile" look that differs from the Mac: new colours, new fonts, iOS-default grouped lists everywhere.

## 5. Behaviour

### 5.1 Away from the Mac (the push gate)

The hub (Desktop process) computes one value, **owner away**, in a pure Core policy next to `OwnerPresencePolicy`:

- **Away** when the screen is locked (`OwnerPresenceCenter` already reads `CGSSessionScreenIsLocked` and the lock notification), or the Mac's console has had no keyboard/mouse input for **3 minutes** (`CGEventSourceSecondsSinceLastEventType(.combinedSessionState, …)`, no TCC prompt), or the Desktop process is not running a UI session (fast user switch away).
- **Back** at once on unlock or input.
- 3 minutes is the builder's starting value (my call), one named constant.
- **A new policy, not a change to `OwnerPresencePolicy`.** That policy deliberately ignores idleness (its header comment; it feeds `ChatQuestionEscalator` and the Stop guard). The away gate is its own pure Core policy (`OwnerAwayPolicy` or similar) reading the lock state, idle seconds and the UI session; `OwnerPresencePolicy` is untouched (my call).
- **A quit or crashed Desktop pushes nothing**: the hub lives in that process. Keeping the hub alive without the app is out of scope; the phone shows the Mac as offline once the heartbeat goes stale (§5.6) (my call).

"At the Mac" means at the Mac at all, not in that session (owner, ask #612): an ask from another session while the owner works at the Mac does not push.

### 5.2 What pushes

One alert per **stop of work**, on these events of a board session in a published workbench:

| Event | Source on the Mac | Alert title / body (sealed) |
|---|---|---|
| New open ask | `owner_asks` (today's `ask_alert`) | workbench · ask title |
| Permission request | `permission_requests` `pending` | workbench · "Needs approval: <tool>" |
| Session finished or waiting for input (Stopped, Finished, Waiting for you with no open ask) | resolved session state (`SessionStatePresentation`) | workbench · session title · "Finished" / "Waiting for you" |
| Ready to check | its open check/review ask | pushes as that ask (row 1), never as a separate session alert |
| Session failed | Error state, `agent_error` | workbench · session title · "Failed" |

Rules:

- **Only while away.** An event that happens while the owner is at the Mac does not push. If it is **still unresolved when the owner goes away** (ask still open, request still pending, session still stopped and not resumed) it pushes at that moment — once. Otherwise the stop the owner left behind on the Mac is lost on the phone (my call, accepted in the ask #613 summary without objection).
- **One stop, one push.** A session that stops with an open ask pushes the ask only, not also "waiting". A permission request that is the reason a session waits pushes the request only. Debounce state changes the way the Mac's own notice does (a Stopped that becomes Working again within a short grace does not push; the builder reuses the Mac's existing debounce if one exists, else 20 s).
- **Remembered once.** Each alert keys on its event (`ask-<id>`, `perm-<id>`, `stop-<session>-<state_at>`), remembered in the sidecar like today's `alerted_asks`, so a hub restart, republish, rotation or a second away period never repeats it. The ledger tells **suppressed** (seen while the owner was at the Mac) from **pushed**: a suppressed event pushes on the next departure if still unresolved, then becomes pushed; a pushed one never pushes again. Today's guard stays: nothing older than the hub's `enabled_at` ever alerts (my call).
- **Debounce.** The Mac has no session-state notice debounce to reuse; a Stopped/Finished/Waiting state pushes only after it has held 20 s (my call).
- **Cleared when resolved.** When the ask is answered, the request decided, or the session works again, the alert record is deleted and the phone removes the delivered notification (`removeDeliveredNotifications` by thread/id from the app; the extension cannot, so the builder does it on the next app fetch or a silent push).
- **Tap** opens the right place: the ask, the session's workchat with the permission card, or the session's workchat.
- **Grouping**: notifications thread by session (`threadIdentifier`).

Transport: today's `ask_alert` path generalised — the record is sealed under `K_alert`, a payload-free `WatchtowerSignal` fires the `CKQuerySubscription` (private scope) or the sync engine's silent push (shared scope, best-effort, D14), and the NotifyService extension opens it. **The subscription registration (A13) is part of this work**; today nothing registers it. The alert payload stays free of chat text: titles only, as now. (Today `AskAlertSubscription.subscription(for:hubID:)` exists and the extension opens alerts, but nothing calls the registration.)

- **One record kind** for all four events: `ask_alert` is generalised with an `event` field (`ask` | `permission` | `session_stopped` | `session_failed`) and its target ids, or replaced by a new `work_alert` kind — the builder picks; the extension reads the new shape and falls back to the generic "A session is waiting" on anything it cannot open. Both ends are the owner's own devices: a hard cut with the phone and Mac updated together is acceptable, no capability flag (my call, as the E2E hard cut D13).
- **Shared scope** (a phone on a different Apple ID) gets these pushes best-effort (D14). Settings → Notifications says "Alerts may be late on this phone" in that scope (my call).

### 5.3 The workchat on the phone

- The session screen **is** the workchat (today's Session detail + its "Chat" row merge): header with the session title, workbench, state line, actions menu (Stop, Finish, Interrupt, Open board target); the feed; the composer.
- **State line** at the top of the feed area or above the composer: glyph + caption from the Mac's `SessionStatePresentation`, plus "· m:ss" while working (from `state_at`, counted on the phone). No tool summary.
- **Latency.** While a phone has a session's chat open, the `session_chat` record goes through the **fast lane** (urgent tick) instead of the 30 s full tick, and the runner reads the feed every **3 s** instead of 10 s while the agent is live. Target: a new agent line on the phone within ~5 s on a healthy connection (CloudKit push delivery dominates; the builder measures it on a device and states the number). The 5-minute watch and the 60 s repeat stay; the caps stay.
- **Older entries.** Still the tail only (300 entries). Paging is out of scope.
- **Permission card** and **asks** show inline at the bottom of the feed (as on the Mac's Workchat), not as separate screens; tapping an ask opens the full ask view for review/check asks.
- **Subagents** stay as markers that push the subagent's own read-only chat.

### 5.4 Chatting in the workchat

- The composer replaces the Tell bar and lives on the main chat only (a subagent screen has none, as today).
- **Send while busy** for Claude sessions, matching the Desktop (`SessionControl.workchatLineCheck`): a working agent no longer holds a phone line. The other holds stay (not live, needs approval, the owner's draft in the Mac's prompt, settling, session gone). This **amends PROJ-16** (owner approved, ask #614; §9). Codex keeps the busy hold.
- Delivery states mirror the Mac: "Queued · the agent reads it at its next step", "Sent", "Held — <reason>" with Cancel, "Typed into the session — press Return on the Mac".
- The typing grant (PROJ-16) is unchanged: a phone that may not type shows the Turn On / waiting hint in place of the composer.

### 5.5 Now and the Workbench tab

- **Now** leads with **Waiting for you** (asks, permission requests, stopped/failed sessions, newest first), then **Working** (live sessions with their timers), then the next meeting.
- **Workbench** lists workbenches; a workbench opens on its sessions (Desktop's sessions panel order: Waiting for you, Agents working / Working, Ready to check, then "▸ N finished"), with Board as the second segment.
- **New session** stays where it is (StartSessionSheet), restyled.

### 5.6 Honest staleness

- A header chip on Now and on every session screen shows the Mac: online, "Mac asleep · last seen 12 min ago" (heartbeat older than its period), or offline. A workchat whose Mac is not online says so above the composer, and a sent line reads "Waiting for your Mac".
- **Keeping the Mac awake.** Work without the computer fails silently if the Mac idles to sleep. The hub holds a "prevent idle system sleep" power assertion (`IOPMAssertionCreateWithName`, `PreventUserIdleSystemSleep`; the display may still sleep) while at least one board session is live **and** a linked phone was in contact in the last 24 hours, released as soon as either stops holding. On by default; a Settings → Mobile toggle turns it off (owner, ask #614).

## 6. Design

### 6.1 Direction

The phone speaks the Desktop's visual language (owner, ask #611): the reference screens are the Mac's Workbench sessions panel, Workchat and Calendar. Concretely:

- **Same tokens.** The phone's `DesignSystem` takes the Desktop's `DesignKit` scale as its source of truth: `Spacing`, `Radius`, `Fill` (card 0.06 etc.), `Stroke.hairline`, `Tone.status/priority`, `Motion`. The cleanest route is to move the token values (not the AppKit-bound views) into a module both targets link (e.g. `WatchtowerKit` or a small `DesignTokens` target); the builder chooses, the values must be one copy.
- **Same structure rules.** Space and soft fills separate, not lines; no dividers between rows; one prominent action per screen; text styles and semantic colours only; status colours only from `Tone`.
- **Same components, phone-sized.** Session row = the Desktop sessions panel row (state glyph with tone, title, workbench, caption, age); chat bubbles = the Desktop Workchat bubbles (owner right on the accent fill, agent left without a bubble, Watchtower lines as captions); chips/badges = `Chip`/`CountBadge`; cards = `.card()` with `Fill.card` + hairline.
- **Not iOS-grouped-list default.** No `insetGrouped` lists as the main surface of a screen (Settings may keep a list, styled to the kit). Touch targets stay ≥ 44 pt; text sizes follow Dynamic Type, so the Mac's `.small` control size does not carry over.
- Dark and light both, from semantic colours.

### 6.2 Process

1. **Mockups first.** The builder renders every main screen (Now, Workbench list, workbench sessions, workchat working / waiting / with permission card / with ask, composer states, board, target detail, ask views, Calendar agenda, event detail, recordings, recap, Settings, Macs, linking, empty and offline states, a push notification) from the demo seed on the simulator (light + dark), and puts the shots in front of the owner as one `kind: review` ask before building the rest. The owner's verdict on the shots gates the redesign phase.
2. Then screen by screen; each screen's PR carries its before/after shots.
3. The design-pass spec (2026-10-11) is superseded where they conflict; `docs/features/mobile-companion.md` "Design layer" is rewritten.

## 7. Constraints

- CloudKit transport, E2E (sealed records, `K_alert` for alert titles only, `K_data` for chat), FEED-01 (chat never stored in clear), I-4 as amended in phase 3.
- PROJ-16, PROJ-21, PROJ-12 guards; the inventory rule (any change to a guard needs the owner — §9).
- iOS 17 minimum (WatchtowerMobile), macOS 14 (hub).
- Battery: the faster chat cadence applies only while a chat screen is open; the hub's 3 s read only while a watch is open and the agent is live.
- The repo's inner-loop and gate rules (CLAUDE.md), phone tests with `make mobile-test`, Kit with `make kit-test`.

## 8. Left to the builder

- Where the shared tokens live and how the Desktop keeps reading them.
- The exact debounce for "session stopped" pushes if the Mac has none to reuse.
- Whether the fast lane for `session_chat` needs a separate budget so a busy chat cannot starve asks (asks must stay first).
- How the phone clears delivered notifications when an alert is resolved.
- Phase split; a reasonable one: (A) away gate + alert kinds + subscription registration, (B) workchat latency + composer + send while busy, (C) mockups → owner review, (D) redesign screen by screen. A and B do not wait for the mockup verdict; C may run in parallel with them; only D is gated (my call). Screens A/B touch are built functionally in today's style and restyled in D.

## 9. Owner decisions on contracts and Mac behaviour (ask #614)

- **PROJ-16 amended (approved):** a phone line may go while a Claude agent works (send while busy), as on the Desktop; every other PROJ-16 hold stays, Codex keeps the busy hold. The inventory entry and its guard test are updated in the same PR.
- **Keep the Mac awake (approved, on by default):** while at least one board session is live and a linked phone has been in contact (a relay record or fetch the hub saw) in the last 24 hours (§5.6), with the Settings → Mobile toggle. A lid-closed Mac on battery is not covered.
