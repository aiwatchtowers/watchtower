# Workchat live activity

The approved proposal images sit beside this file. The implementation snapshots
in `implemented/` use the production `WorkchatLiveLine` and
`WorkchatRunningAgentsPicker`, with the same composer scaffold as the proposal.
All fixture data is synthetic. Both sets are registered in `DesignShotCatalog`.

Render only these states in light and dark mode:

```sh
cd WatchtowerDesktop
DESKTOP_SHOTS_DIR=../build/workchat-shots swift test --filter 'DesignShotsTests.testWorkchatActivityShotsRender|WorkchatLiveProposalCopyTests|WorkchatLiveLineTests'
```

The implementation matches the compact proposal: one caption line, action text
truncated in the middle, and agent count and time visible at 340 pt. Its height
stays 22 pt in idle, loading, working and error states. The agent list opens only
on click and wraps long task labels without moving the conversation.

The picker screenshot supplies the system surface in its fixture host, because
a native popover normally gets that surface from a separate window. Production
receives no extra background. Tests never order a window onto the screen.

The full Desktop and Kit suites, Go suite, linters and scoped race checks passed.
Presentation, store, copy and geometry tests cover the new behavior. The actual
wide, narrow and opened-picker snapshots were compared with the approved views.
