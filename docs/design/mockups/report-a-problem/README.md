# Report a Problem — mockups (target #1527)

**Spec:** [report-a-problem-design](../../../superpowers/specs/2026-11-04-report-a-problem-design.md).

Real SwiftUI renders of `ReportProblemShotFixtures` (`WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+ReportProblem.swift`), registered in `DesignShotCatalog`. Design-only: not wired into the app, sample data only (no live install). The strings are the spec's string table.

| State | Light | Dark |
|---|---|---|
| Collecting (loading, busy) | ![](report-problem-collecting-light.png) | ![](report-problem-collecting-dark.png) |
| Ready, nothing typed (empty) | ![](report-problem-empty-light.png) | ![](report-problem-empty-dark.png) |
| Ready, typed | ![](report-problem-filled-light.png) | ![](report-problem-filled-dark.png) |
| Database busy (lines with `unknown (database busy)`) | ![](report-problem-busy-light.png) | ![](report-problem-busy-dark.png) |
| Diagnostics failed, Retry (error) | ![](report-problem-failed-light.png) | ![](report-problem-failed-dark.png) |
| Opened, sheet stays | ![](report-problem-opened-light.png) | ![](report-problem-opened-dark.png) |
| Link too long, Copy Report | ![](report-problem-tooLong-light.png) | ![](report-problem-tooLong-dark.png) |
| Browser did not open, Copy Link | ![](report-problem-browserFailed-light.png) | ![](report-problem-browserFailed-dark.png) |
| Save failed | ![](report-problem-saveFailed-light.png) | ![](report-problem-saveFailed-dark.png) |
| Corporate build, Save only | ![](report-problem-corp-light.png) | ![](report-problem-corp-dark.png) |
| Narrow (360 pt) | ![](report-problem-filled-narrow-light.png) | ![](report-problem-filled-narrow-dark.png) |
| Settings → System → Logs entry | ![](report-problem-settings-entry-light.png) | ![](report-problem-settings-entry-dark.png) |

Re-render: `cd WatchtowerDesktop && DESKTOP_SHOTS_DIR=<dir> swift test --filter DesignShotsTests/testReportProblemShotsRender`.
