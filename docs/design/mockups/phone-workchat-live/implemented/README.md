# Phone Workchat live line — as built (#2112)

Real views captured on 2026-11-21 (iPhone 17 Pro simulator, light and dark) beside the mockups one folder up:

- L1–L8, L10: `make mobile-shots SHOTS_ONLY=workchat-live` (`ScreenshotTourTests+WorkchatLive.swift`, the real
  `WorkchatView` / `SessionChatView` over demo records), files `workchat-live-real-L*` renamed to `workchat-live-L*`.
- L9: `make mobile-shots SHOTS_ONLY=workchat-agents` (`ScreenshotTourTests+WorkchatAgents.swift`, the real
  `WorkchatAgentsSheet` over a published live block), file `workchat-phone-real-L9` renamed to `workchat-live-L9`.

The real captures draw the demo seed's sessions ("Session report", "Board lanes", "Live line"), so titles, dialog
text, summaries and timers differ from the mockups everywhere; that is content, not layout, and is not listed per frame.

| Frame | State | Differences from the mockup | Why |
|---|---|---|---|
| L1 | Working on a step | The line shows the bare summary (`go test ./internal/sessionreport`), without the mockup's `Running tests ·` prefix. Toolbar badge `✓ 1` instead of `2`. | The shared presentation's current-step text is the summary alone, as on the Mac; the mockup invented a verb. The demo session's only subagent has finished. |
| L2 | Steps open | Step rows are taller (26 pt, scaled with Dynamic Type) than the mockup's ~20 pt, so six rows take more height; summaries bare, no `Read ·`/`Grep ·` prefix. Toolbar `✓ 1`. | Rows are a `@ScaledMetric` 26 pt relative to the caption style, so they keep their spacing under larger text; the summary is the shared `stepsSlot` text, where the symbol names the tool. |
| L3 | Between tools: **Working…** | Toolbar shows the agents button (`✓ 1`); the mockup has none. | The demo session has a finished subagent, so the button stays (as on the Mac, #2065). |
| L4 | **Loading activity…** | A different session (**Live line**) with no record yet: the feed shows **Asking your tower…**, not dialog. | The capture opens a session the demo holds no chat record for (a first opening). With a record left from an earlier opening, the dialog shows above Loading as in the mockup, until a record echoing this opening's `open_id` arrives. |
| L5 | **Activity unavailable** + **Retry** | Text and icon in red, not orange. Toolbar shows `?`. | The phone keeps orange for waiting and asks (lint-enforced tone rule); failures use `ReplicaFreshness.tone` (red). A failed live read makes the agent state unknown, hence `?` (shared `agentsBadge`). |
| L6 | Tower not sending | Red, not orange; compact age **Activity out of date · 40m ago** instead of `42s ago`. Also shown: the existing **Acme Mac is asleep** banner, **as of 40 min ago** in the state line and **Waiting for your tower** under the field; toolbar `?`. | Compact age is the shared wording (the Mac uses it too). The capture's tower is 40 minutes silent, so the phone's existing asleep cues (over 35 minutes without a heartbeat) show beside the new line. |
| L7 | Behind a permission card, line hidden | A different session (**Board lanes**, **Needs approval**); the card shows **Turn On** (this demo phone may not answer prompts) instead of **Allow once** / **Deny**. Toolbar `✓ 1`. | The demo's waiting session is a separate one; the card's buttons follow the phone's grant. The line is hidden in both, which is what the frame checks. |
| L8 | A subagent's chat | The real subagent screen (`SessionChatView`): nav title **Subagent**, the task as a bubble, no workbench header, no state line, no composer; the line sits at the bottom edge. | Subagent chats were read-only screens before this work and stay so (no field, #486); only the line was added. |
| L9 | Agents sheet, live Working rows | Matches the layout: type, description, the agent's step under it with the tool's symbol, a running timer, **Done · 9** collapsed, toolbar `2`. The step text is bare (`func LiveOf`, `codex review --base main`), without the mockup's `Grep ·`/`Bash ·` prefix; timers read a few seconds more (0:11, 2:12) than the mockup's 0:04/2:05. | Same shared summary text as L1; the capture renders seconds after the block was published. |
| L10 | No turn running | Toolbar `✓ 1`. | As L3. |

The L9 run needed a fix in `ScreenshotTourTests+WorkchatAgents.swift`: since #2112 the demo seed's working chat
carries a live block, so the P1–P4 publishes (meant without one) now remove it; before, the run waited forever on P1.
