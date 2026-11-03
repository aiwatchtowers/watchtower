# Tuning chat mockups

Mockups for the tuning chat over the workbench Analytics pane (board #1517),
spec `docs/superpowers/specs/2026-11-03-tuning-chat-design.md` §3 and §4.4.
Each state has a light and a dark PNG.

The panel, its feed rows, the composer and the A/B card are mock views in the
test target (`WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+TuningChat.swift`
and `+TuningChatReplay.swift`). The proposal card in the feed and the pane's
coach sections are the real `CoachProposalCardView` and `CoachSectionsView`,
running on fixture data. All data is synthetic.

| State (§4.4) | Spec | File |
|---|---|---|
| Analytics header with **Tune** | §3.1 | `tuning-chat-analytics-header-{light,dark}.png` |
| Empty: figures line, 4 starters | §3.3 | `tuning-chat-empty-{light,dark}.png` |
| Loading | §4.4 | `tuning-chat-loading-{light,dark}.png` |
| Streaming / busy (composer shows Stop) | §3.4 | `tuning-chat-streaming-{light,dark}.png` |
| Error: turn failed, Retry | §4.4 | `tuning-chat-error-{light,dark}.png` |
| Proposal: coach card inline, open (`claude_skill_user`) | §3.5 | `tuning-chat-proposal-{light,dark}.png` |
| Proposal: stale (the card's current error line) | §4.4 | `tuning-chat-proposal-stale-{light,dark}.png` |
| A/B proposed: Run / Not now, cost line | §3.6 | `tuning-chat-ab-proposed-{light,dark}.png` |
| A/B running: "Running 3 of 10" | §3.6 | `tuning-chat-ab-running-{light,dark}.png` |
| A/B done: Without / With side by side | §3.6 | `tuning-chat-ab-done-{light,dark}.png` |
| A/B failed: "Stopped after 4 of 10 calls", Retry | §4.4, §4.6 | `tuning-chat-ab-failed-{light,dark}.png` |
| No tools (ollama): Open Settings | §4.1, §4.4 | `tuning-chat-no-tools-{light,dark}.png` |
| Narrow: panel at 360 pt, outputs stacked | §4.4 | `tuning-chat-narrow-{light,dark}.png` |

"Analytics off" has no shot: **Tune** is hidden, as the coach sections are.

Render only these shots:

```sh
cd WatchtowerDesktop
DESKTOP_SHOTS_DIR=../build/tuning-shots swift test --filter DesignShotsTests.testTuningChatShotsRender
```

Known gaps in the real card, visible in these shots:

- The destination chip and diff caption read `claude_skill_user · all workbenches`.
  `CoachProposal.destinationLabel` has no case for the new destinations, and
  the proposal JSON has no skill name.
- At 360 pt, the card's footer (evidence, Decline, Edit…, Accept) does not fit
  on one line, so `session #41` wraps.
- The stale line comes from `CoachCenter`: "The text changed since — this
  proposal is closed". The spec asks for "The file changed since — ask again".
