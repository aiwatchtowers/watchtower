# Tuning chat mockups

Mockups for the tuning chat beside the workbench Analytics pane (board #1517),
spec `docs/superpowers/specs/2026-11-03-tuning-chat-design.md` §3, §4.3a and §4.4.
Each state has a light and a dark PNG.

The pane and the panel sit side by side in a `PanelSplit` (`PanelSplitWidth`
460, range 360–720). The panel, its feed rows, the composer and the pane
header are mock views in the test target
(`WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+TuningChat.swift`).
These are real views running on fixture data:
the proposal card in the feed (`CoachProposalCardView`), the pane's coach
sections (`CoachSectionsView`) and the Statistics blocks. All data is synthetic.

| State | Spec | File |
|---|---|---|
| Analytics header: agent filter All / Claude Code / Codex, **Tune** (off) | §3.1 | `tuning-chat-analytics-header-{light,dark}.png` |
| Statistics blocks with Codex sessions in the period: main's caption "Not measured for Codex sessions." (ask #1132) | §4.7 | `tuning-chat-statistics-codex-caption-{light,dark}.png` |
| Empty: figures line, 4 starters | §3.3 | `tuning-chat-empty-{light,dark}.png` |
| Loading | §4.4 | `tuning-chat-loading-{light,dark}.png` |
| Streaming / busy (composer shows Stop) | §3.4 | `tuning-chat-streaming-{light,dark}.png` |
| Error: turn failed, Retry | §4.4 | `tuning-chat-error-{light,dark}.png` |
| Proposal: coach card inline, open ("Claude skill · review-pr") | §3.5 | `tuning-chat-proposal-{light,dark}.png` |
| Proposal: accepting (buttons disabled while Accept runs) | §4.4 | `tuning-chat-proposal-accepting-{light,dark}.png` |
| Proposal: accepted, folded to one line, "Show in Accepted edits" | §4.4 | `tuning-chat-proposal-accepted-{light,dark}.png` |
| Proposal: stale (the card's current error line) | §4.4 | `tuning-chat-proposal-stale-{light,dark}.png` |
| Proposal: accepted edit of the workbench folder's CLAUDE.md, folded to "Accepted · wrote CLAUDE.md on main — commit it yourself" (asks #1165, #1170) | §4.3a, §4.4 | `tuning-chat-proposal-accepted-repo-{light,dark}.png` |
| No tools (ollama): Open Settings | §4.1, §4.4 | `tuning-chat-no-tools-{light,dark}.png` |
| No tools midway: provider switched to ollama mid-conversation, the open card keeps Accept / Decline, no-tools line above the composer | §4.1, §4.4 | `tuning-chat-no-tools-midway-{light,dark}.png` |
| Narrow: panel at 360 pt, evidence above the buttons | §4.4 | `tuning-chat-narrow-{light,dark}.png` |

14 shots: 12 panel states, the analytics header and the Statistics blocks.
The A/B card states, the too-few-inputs line and the removed-conversation
state were dropped with the A/B replay and prompt-input capture (ask #1164,
spec D61, D62).

"Analytics off" has no shot: **Tune** is hidden, as the coach sections are.
When the panel leaves the pane narrow, the period picker and **Tune** wrap
onto a second line under the agent filter, as spec §4.4 Narrow scope says.

Render only these shots:

```sh
cd WatchtowerDesktop
DESKTOP_SHOTS_DIR=$PWD/../build/tuning-shots swift test --filter DesignShotsTests.testTuningChatShotsRender
```

Product changes made with the mockups:

- `CoachProposal.skill`: optional, decoded from the key `skill`.
- `destinationLabel` covers the new destinations: "Claude skill · <skill>",
  "Codex skill · <skill>", "Watchtower skill · <skill>", "Codex AGENTS.md" and
  "Codex rules". None of them has the "all workbenches" suffix.
- `CoachProposalCardView`: when the footer does not fit on one line, the
  evidence moves to its own line above the buttons.

Known gaps: the `proposal-accepted-repo` pane lists only the earlier accepted
edit in Accepted edits: the repository edit's row needs the `repo_*`
destination labels ("Workbench CLAUDE.md", …), which Task 5.14 adds to
`destinationLabel`. The stale line is `CoachCenter`'s existing text ("The text
changed since — this proposal is closed"), which the spec keeps.
