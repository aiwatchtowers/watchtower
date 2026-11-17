# Background AI consent — mockups for review

Design-only mockups for target #1886 (owner decision: ask #1415). Nothing is built yet.

**Spec:** [background-ai-consent-design](../../../superpowers/specs/2026-11-17-background-ai-consent-design.md).

21 scenes, each in light and dark, registered in `DesignShotCatalog` through `BackgroundAIConsentShotFixtures.shots` (`WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+BackgroundAIConsent.swift`). Strings: `BackgroundAIConsentMockCopy`, pinned by `BackgroundAIConsentMockCopyTests`. Re-render with `cd WatchtowerDesktop && DESKTOP_SHOTS_DIR=<dir> swift test --filter DesignShotsTests/testBackgroundAIConsentShotsRender`. Sample data only (`acme`).

## The consent screen — onboarding's last step (spec §5)

Claude Code picked:

![step claude light](ai-consent-step-claude-light.png)
![step claude dark](ai-consent-step-claude-dark.png)

Codex picked, another provider, the automatic reserve on, a 600 pt window:

![step codex](ai-consent-step-codex-light.png)
![step ollama](ai-consent-step-ollama-light.png)
![step reserve](ai-consent-step-claudeReserve-light.png)
![step narrow](ai-consent-step-claude-narrow-dark.png)

Saving, and a failed write:

![step saving](ai-consent-step-saving-light.png)
![step error](ai-consent-step-error-light.png)

## The one-time sheet after an upgrade (spec §7)

![sheet](ai-consent-sheet-claude-light.png)
![sheet dark](ai-consent-sheet-claude-dark.png)
![sheet error](ai-consent-sheet-error-light.png)

## Settings → AI → Background AI (spec §6.1)

![allowed](ai-consent-settings-allowed-light.png)
![paused](ai-consent-settings-paused-light.png)
![organization off](ai-consent-settings-orgOff-light.png)
![organization allowed](ai-consent-settings-orgAllowed-light.png)
![saving](ai-consent-settings-saving-light.png)
![error](ai-consent-settings-error-light.png)

## Home, empty states, Automations (spec §6.2–§6.4)

![home paused](ai-consent-home-paused-light.png)
![home organization](ai-consent-home-org-light.png)
![empty paused](ai-consent-empty-paused-light.png)
![empty organization](ai-consent-empty-org-light.png)
![automations paused](ai-consent-automations-paused-light.png)
![automations organization](ai-consent-automations-org-light.png)
