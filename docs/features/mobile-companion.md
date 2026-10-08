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

## Workbench slice mirrors and action params (Kit, B1)

- **Kinds.** `SliceKind` gains `workbench`, `workbench_target`, `workbench_comment`, `terminal_session`, `owner_ask`, `session_report` and `session_timeline` (design §4.2–§4.9). The phone decodes each record's payload with its `SliceMirror` in `WatchtowerKit/Models` (`Workbench`, `WorkbenchTarget`, `WorkbenchComment`, `TerminalSessionState`, `OwnerAsk`, `SessionReport`, `SessionTimeline`) through `RelayCoder` — snake_case keys, Unix-second dates, a nil optional is an absent key, unknown keys are ignored.
- **Enum-like fields** (state kind and tone, target status and priority, ask kind/status/withdrawn reason, verdict, check state, milestone kind, start mode) are `OpenWireValue`s: a value from a newer Mac decodes, keeps its raw string and reads `isKnown == false`.
- **Clipping on the wire.** `<field>_clipped` and `<list>_more` are absent unless the hub cut something, so the mirrors keep them optional (`Bool?`, `Int?`).
- **`session_report`** is the CLI's report as Go writes it (`internal/sessionreport.Report`): datetimes stay Go's UTC strings and every key may be absent, as in Core's `SessionReport`; the hub adds only `<list>_more`, `items_more` and `phases_clipped`. The other kinds carry dates as `Date`.
- **`session_timeline`** payload is `{session_id?, milestones, milestones_more?}`: `session_id` repeats the record id and may be absent. An ask's `withdrawn_reason` is absent (or `""`, read as nil) unless the ask is withdrawn.
- **`OwnerAskAnswer`** (Kit) encodes byte for byte like Core's and Go's (`internal/asks/testdata/answers`); an ask's `payload` resolves missing question and check item ids to their 1-based position, as Core and Go do.
- **Action params.** `ActionKind` gains the twelve §5.2 kinds. Each has a typed `ActionParams` struct whose `wireParams()` is the request's `params` object. Because `ask_answer` carries an object and `session_start` carries bools, `JSONValue` (WatchtowerSync) gains `.bool`, `.array` and `.object`; a row never produces them, and `databaseValue` stores them as 0/1 and JSON text.
- **Fixtures.** `WatchtowerKit/Tests/Fixtures/workbench/*.json` are the frozen payloads (`WorkbenchMirrorFixtureTests`); the hub's projection tests pin their encoder against the same files.
