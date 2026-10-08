# Mobile companion (POC)

Specs: [business](../superpowers/specs/2026-10-07-mobile-poc-business.md) and [technical design](../superpowers/specs/2026-10-07-mobile-poc-design.md).

## Building a hub-capable Mac app

The mobile hub syncs through CloudKit, so it needs a Developer ID build that carries the iCloud entitlements and an embedded provisioning profile (design §10).

- `scripts/build-app.sh` (the `app-codesign` block) signs the bundle with `scripts/Watchtower-cloud.entitlements` only when it has a real signing identity **and** `WATCHTOWER_PROVISION_PROFILE` points at a Developer ID provisioning profile that grants the container. The profile is copied to `Contents/embedded.provisionprofile` before the bundle is signed. A relative path resolves against the project root, so the variable can live in the build profile (`.env`, or the `ENV_FILE` of a flavor).
- The cloud entitlements are the base `scripts/Watchtower.entitlements` plus `com.apple.developer.icloud-container-identifiers` = `iCloud.com.aiwatchtowers.watchtower`, `com.apple.developer.icloud-services` = `CloudKit` and `com.apple.developer.aps-environment` = `production`. Keep the base keys in sync; the test checks it.
- Every build flavor (`BUILD_FLAVOR`, e.g. `ENV_FILE=.env.corp`) uses the same container: both are signed by the same Developer team.
- A real identity without a profile signs with the base entitlements and prints `WARNING: mobile hub disabled: no provisioning profile`; the app then shows "Needs a signed build" in Settings → Mobile. A profile path that does not exist fails the build.
- Ad-hoc signing (`make app-dev`, or no identity) always keeps the base entitlements and never embeds a profile: amfid kills an ad-hoc app that carries restricted entitlements. Hub logic is tested on `InMemoryCloudTransport` and needs no signing.
- Covered by `scripts/tests/test-build-app-cloud.sh` (`make test-scripts`), which runs the block against a stubbed `codesign`.
