# Plans production screenshots

[Open the gallery](index.html). These are the actual `PlansContent`, `UsageTabs` and `TrayPopupContent` components, rendered on synthetic snapshots by `DesignShotCatalog`.

The approved reference images remain in [mockups/plans](../../mockups/plans/index.html). Their archived fixtures are under `scripts/design/approved-plans`; `bash scripts/design/render-plans-mockups.sh <output-directory>` still reproduces all 40 reference PNGs byte for byte. The production catalog does not render those draft views.

To regenerate production shots, run from `WatchtowerDesktop`:

```sh
swift test --filter PlansScreenTests.testRenderProductionPlansShots
```

The explicit render test writes both appearances to `/tmp/watchtower-plans-production-shots`. Its windows remain hidden. The ordinary unfiltered suite skips that render pass.

The production differences follow the approved final specification: Retry and manual sign-in guidance replace draft Connect buttons; stale or unconfirmed Codex values are hidden; unknown identity allows current numbers but no chart; unavailable and expired forecasts show their reason. Additional Codex quotas remain visible. Menu shots host the production card panel used by `MenuBarExtra.window`; its native Watchtower actions menu retains the existing application callbacks. The outer shot backdrop and hairline represent the system window chrome.

The popup keeps provider headings and state messages when no quota can be shown. Its Refresh/Retry actions target the named provider, the footer refreshes both providers, and Open Plans navigates to the Plans screen. The existing menu-bar toggle controls both subscriptions. Bucket cards use typed window metadata and the same most-restrictive selection policy as the menu-bar label.

Layout and behavior sources: design ask #919, menu ask #931, specification ask #934 and implementation plan ask #936.
