# Mobile companion (POC)

Specs: [business](../superpowers/specs/2026-10-07-mobile-poc-business.md) and [technical design](../superpowers/specs/2026-10-07-mobile-poc-design.md).

## Building a hub-capable Mac app

The mobile hub syncs through CloudKit, so it needs a Developer ID build that carries the iCloud entitlements and an embedded provisioning profile (design §10).

- **The profile.** A Developer ID provisioning profile (developer.apple.com → Profiles → Developer ID) for App ID `com.watchtower.desktop` — the app's `CFBundleIdentifier` (`BUNDLE_ID` in `scripts/build-app.sh`), not `com.aiwatchtowers.watchtower` — on the signing identity's team, with the iCloud capability and the container `iCloud.com.aiwatchtowers.watchtower`. Point `WATCHTOWER_PROVISION_PROFILE` at the downloaded `.provisionprofile`; a relative path resolves against the project root, so the variable can live in the build profile (`.env`, or the `ENV_FILE` of a flavor).
- **Early check** (`provision-profile-check`, before the Swift build): the profile is decoded with `security cms -D`; the build fails if the file is missing or undecodable, if its `com.apple.application-identifier` is not `<its team-identifier>.com.watchtower.desktop`, or if it does not grant the container.
- **Signing** (`app-codesign`): with a real identity and a checked profile, the profile is copied to `Contents/embedded.provisionprofile` and the bundle is signed with a temporary copy of `scripts/Watchtower-cloud.entitlements` into which the profile's `com.apple.application-identifier` and `com.apple.developer.team-identifier` are merged. A hand-signed app with restricted entitlements needs both (Xcode adds them; `codesign` does not). The team id is never written in the repo.
- The cloud entitlements are the base `scripts/Watchtower.entitlements` plus `com.apple.developer.icloud-container-identifiers` = `iCloud.com.aiwatchtowers.watchtower`, `com.apple.developer.icloud-services` = `CloudKit`, `com.apple.developer.icloud-container-environment` = `Production` and `com.apple.developer.aps-environment` = `production`. Keep the base keys in sync; the test checks it.
- Every build flavor (`BUILD_FLAVOR`, e.g. `ENV_FILE=.env.corp`) uses the same bundle id and container: both are signed by the same Developer team. The signing blocks have no flavor logic.
- A real identity without a profile signs with the base entitlements and prints `WARNING: mobile hub disabled: no provisioning profile`; the app then shows "Needs a signed build" in Settings → Mobile.
- Ad-hoc signing (`make app-dev`, or no identity) always keeps the base entitlements and never embeds a profile: amfid kills an ad-hoc app that carries restricted entitlements. A set `WATCHTOWER_PROVISION_PROFILE` is still checked early, then ignored with the note `provisioning profile ignored: ad-hoc signing`. Hub logic is tested on `InMemoryCloudTransport` and needs no signing.
- Whether amfid accepts the signed bundle and CloudKit reaches Production can only be shown on a real device (A3 smoke).
- Covered by `scripts/tests/test-build-app-cloud.sh` (`make test-scripts`), which runs both blocks against stubbed `security` and `codesign`.
