# Phone Workchat live line — mockups (#2112)

Spec: [`docs/superpowers/specs/2026-11-20-phone-workchat-live-design.md`](../../../superpowers/specs/2026-11-20-phone-workchat-live-design.md).
Rendered by `make mobile-shots SHOTS_ONLY=workchat-live` from `WatchtowerMobile/Tests/Support/WorkchatLiveMockups.swift`.

| Frame | State |
|---|---|
| L1 | Working on a step: symbol, summary, timer, steps chevron; toolbar agents 2 |
| L2 | Steps open: six-row slot, line "This turn · 9 steps" |
| L3 | Thinking between tools: "Working…" with the turn timer |
| L4 | Loading: "Loading activity…" |
| L5 | Error: "Activity unavailable" + Retry |
| L6 | Tower not sending updates: freshness line, line out of date, no timer |
| L7 | Busy behind a permission card: line hidden |
| L8 | Narrow scope: a subagent's chat |
| L9 | Agents sheet with live Working rows, Done collapsed |
| L10 | Empty: no turn running, no line |

The real views as built, with every difference from these frames and why: [`implemented/`](implemented/README.md).
