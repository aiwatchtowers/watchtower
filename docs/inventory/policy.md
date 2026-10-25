# Behavior Inventory — Organization policy (MDM)

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/policy/`, `cmd/policy.go`, the
> policy guards (`cmd/accounts.go` `guardSource`, `cmd/provider_policy.go`,
> `internal/providers/policy.go`, `internal/automations/policy_check.go`) or
> `WatchtowerDesktop/Sources/WatchtowerCore/{Models/ManagedPolicy.swift,Services/ManagedPolicy*.swift}`,
> read this file first.

**Module:** `internal/policy/` (keys, `Normalize`, helpers, the CoreFoundation reader, the 30 s cache), `cmd/policy.go` (`policy show`), the Swift twin `ManagedPolicy` / `ManagedPolicyReader` / `ManagedPolicyCenter` in WatchtowerCore, and the shared fixture `internal/policy/testdata/policy_cases.json`. Feature note: `docs/features/mdm-policy.md`. Board #608, spec `docs/superpowers/specs/2026-10-25-mdm-policy-design.md` (approved 2026-10-25, asks #569 and #572).
**Last full audit:** 2026-10-25

## POLICY-01 — Forced values only, wrong types fail closed

**Status:** Enforced

**Observable:** Only a value the configuration profile forces for `com.watchtower.desktop` is policy. A value written with `defaults write` into the same domain changes nothing and never shows **Managed by your organization**. A key with a wrong type (a boolean given as the integer `1`, a string where an array belongs, a forced key whose value cannot be read) acts as its most restrictive value: no source, no Quick Connection, no provider, MobileSync `off`, shell and claude.ai tools not allowed, purge on. Unknown array entries are dropped; a list of only unknown entries is the empty list. No profile means no restriction, for every build.

**Mechanism:** Go reads through CoreFoundation (`CFPreferencesAppValueIsForced` per key, then `CFPreferencesCopyAppValue`; CFBoolean told apart from CFNumber by type id; anything unreadable is `unsupported{}`). The reader is installed only by `main` (`policy.UseSystemReader`), never in a test binary. Swift reads the same API (`ManagedPolicyReader`, a forced key without a value is `NSNull`), and the app's reader is empty under XCTest. `Normalize` / `ManagedPolicy.normalize` apply the same fail-closed rules and report each defect.

**Why locked:** A person could otherwise fake or lift a company's restriction with `defaults write`, and a malformed profile would silently allow what it meant to forbid.

**Test guards:**
- `internal/policy/policy_test.go`: `TestPolicy01_WrongTypesFailClosed`.
- `internal/policy/reader_darwin_test.go`: `TestPolicy01_UnforcedValueIgnored`, `TestPolicy01_ForcedValuesAreRead`.
- `internal/policy/collision_test.go`: `TestPolicy01_KeysNeverCollideWithAppDefaults`.
- `WatchtowerDesktop/Tests/Core/ManagedPolicyReaderTests.swift` (support).

**Locked since:** 2026-10-25

## POLICY-02 — Go and Swift read the policy the same way

**Status:** Enforced

**Observable:** The Desktop locks exactly what the CLI and the daemon refuse, for every profile: the same normalized keys, problems and Quick Connection matches (https only, host and port, the path on a `/` boundary, dot segments and encoded separators refused, byte comparisons).

**Mechanism:** One fixture, `internal/policy/testdata/policy_cases.json`, run by both sides; the Swift URL matcher mirrors Go's `net/url` by hand (EscapedPath, host and port rules, control characters).

**Why locked:** A drift lets the UI show a control as allowed that Go then refuses, or worse, lock nothing while Go allows.

**Test guards:**
- `internal/policy/policy_test.go`: `TestPolicy02_SharedFixture`.
- `WatchtowerDesktop/Tests/Core/ManagedPolicyTests.swift`: `sharedFixture`, `sharedConnectionCases`.

**Locked since:** 2026-10-25

## POLICY-03 — Tightening never deletes data or rewrites settings

**Status:** Enforced

**Observable:** A tighter policy outvotes the owner's settings without changing them: `config.yaml`, the Desktop's own UserDefaults and the database keep the owner's values, and removing the profile brings them back. A forbidden source stops syncing and keeps its data; its backfill rows keep their state. A forbidden provider fails each AI call with the policy error, never falling back to another. Loosening unlocks and never turns anything on by itself.

**Mechanism:** Every enforcement point reads the policy and refuses; none writes a setting. `config set` refuses before writing; the daemon's sync phases and the backfill runner skip; the mobile hub's `off` disables the hub (removing what it published) but leaves `mobileSyncEnabled`.

**Why locked:** A profile installed by mistake, or removed, must never cost the owner their configuration or history.

**Test guards:**
- `internal/historybackfill/policy_test.go`: `TestPolicyBackfill_SkipKeepsRowState`.
- `cmd/provider_policy_test.go`: `TestProviderPolicy_ConfigSetRefused`.
- `WatchtowerDesktop/Tests/MobileHub/MobileHubPolicyTests.swift`: `testOffStopsHubKeepsSetting`, `testLooseningDoesNotStartHubWhenSettingOff`.

**Locked since:** 2026-10-25

## Changelog

- 2026-10-25 (board #608, approved 2026-10-25, asks #569 and #572): POLICY-01..03 written with the feature. Amended with it: PURGE-01 (policy origin), QC-02 (allowed list), CHAT-02/03 note (claude.ai tools off reason), AUTO-13 and the `mcp()` path (policy refusals), the mobile POC and the provider registry notes.
