# Workchat live activity proposal

Source: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+WorkchatActivity.swift`.
All ten fixtures are registered in `DesignShotCatalog`; PNGs use synthetic data only.

Canonical rendering (only these shots, not the whole catalog):

```sh
cd WatchtowerDesktop
DESKTOP_SHOTS_DIR=../docs/design/mockups/workchat-live-activity swift test --filter 'DesignShotsTests.testWorkchatActivityShotsRender|WorkchatLiveProposalCopyTests'
```

The initial SPM attempt was blocked before manifest compilation by sandbox access to the default module cache. These PNGs were rendered with the same fixture views and repository `ViewRenderProbe`, using a small temporary Swift executable linked against existing DesignKit and WatchtowerDesign build objects. Its shot records were copied directly from the new DesignShotCatalog entries; no image editing or AI generation. The copy XCTest suite ran in that executable and passed (one test, zero failures). This validates these views and images; it does not claim a full Desktop package build.

Both light/dark variants were rendered. Busy, narrow, opened popover and empty images were inspected for layout; compare the implementation against these references after approval. The temporary renderer and build command are retained in `/private/tmp` during this session; the canonical test above is the portable reproduction path.
