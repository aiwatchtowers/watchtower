# Workchat live activity proposal

Source: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+WorkchatActivity.swift`.
Ten proposal fixtures and ten actual implementation fixtures are registered in `DesignShotCatalog`; PNGs use synthetic data only.

Canonical rendering (only these shots, not the whole catalog):

```sh
cd WatchtowerDesktop
DESKTOP_SHOTS_DIR=../docs/design/mockups/workchat-live-activity swift test --filter 'DesignShotsTests.testWorkchatActivityShotsRender|WorkchatLiveProposalCopyTests'
```

The initial SPM attempt was blocked before manifest compilation by sandbox access to the default module cache. The initial proposal PNGs were rendered with the same fixture views and repository `ViewRenderProbe`, using a small temporary Swift executable linked against existing DesignKit and WatchtowerDesign build objects. Its shot records were copied directly from the new DesignShotCatalog entries; no image editing or AI generation. The copy XCTest suite ran in that executable and passed (one test, zero failures). This validates these views and images; it does not claim a full Desktop package build.

Both light/dark variants were rendered. Busy, narrow, opened popover and empty images were inspected for layout. The canonical test above is the portable reproduction path.

## Implementation comparison

`workchat-activity-actual-*` shots use the production `WorkchatLiveLine` and
`WorkchatRunningAgentsPicker`, not a reproduction of their status logic. The
existing composer scaffold is shared with the approved proposal. The actual
picker is embedded in a fixture-only system surface because a native popover
normally supplies its background from a separate host window; production does
not receive a second surface. Tests never order a window onto the screen.

Actual busy wide and narrow variants were inspected against the approved shots:
there is one caption line, no panel, the action truncates in the middle, and the
agent count and time remain visible at 340 pt. The actual row is fixed at the
existing 22 pt slot in idle/loading/current/error states; mini button metrics
avoid the extra button padding present in the illustrative proposal fixture.
Picker task labels wrap within the popover width and retain a flat list.

The targeted implementation run passed 36 tests including all registered shots,
store/presentation regressions and copy checks. A separate
`WorkchatLiveLineTests.testTheExistingCaptionSlotHasOneStableHeightInEveryState`
checks the fixed slot directly. The full Desktop suite passed (10,749 XCTest tests and 386 Swift Testing tests),
as did the full Kit suite (1,151 tests), Go suite, lint and race checks. The final
implementation snapshots in `implemented/` were refreshed after that run.
