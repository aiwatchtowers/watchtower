# Session state during a spec review (screens on fixtures)

Spec: `docs/superpowers/specs/2026-11-18-session-spec-review-state-design.md` (board #1945, decisions in asks #1492 and #1497). Rendered by `make desktop-shots` from `DesignShotFixtures+SpecReviewState.swift`; sample data only.

Sessions panel rows: Spec review · round 1 (live, selected), Spec review · round 3 (not live, ring), then Working, Ready for review and Idle for contrast.

![Light](session-state-spec-review-light.png)
![Dark](session-state-spec-review-dark.png)

Narrow panel (190 pt): captions truncate, dot and glyph stay.

![Narrow light](session-state-spec-review-narrow-light.png)
![Narrow dark](session-state-spec-review-narrow-dark.png)

iPhone Sessions tab (`make mobile-shots SHOTS_ONLY=spec-review`): the session under Working, green magnifier, "Spec review · round 2".

![iPhone light](05r-workbench-sessions-spec-review-light.png)
![iPhone dark](05r-workbench-sessions-spec-review-dark.png)
