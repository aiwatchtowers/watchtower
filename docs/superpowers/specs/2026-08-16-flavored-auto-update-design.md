# Flavored Auto-Update Channel Routing — Design

**Date:** 2026-08-16
**Status:** Approved

## Problem

Watchtower ships in two distribution channels: the public build (GitHub Releases)
and flavored builds (`corp`, future `b2`) distributed through a gated download
space. `UpdateService` today only knows the public channel; any flavored build
(`WTBuildFlavor` non-empty) has updates disabled entirely — a deliberate PR #96
guard so a public release can never silently replace a flavored build (same
signer, so the Team-ID pin alone would not stop it). The cost: flavored builds
never auto-update; users re-download manually.

Goal: each build updates from the channel it was installed from. Public →
GitHub Releases (unchanged). Flavored → the gated space, automatically.

## Non-Goals (v1)

- Delta updates, beta/stable channels, version rollback.
- Auto-updating `dev` builds — they stay non-updating.
- Per-flavor buckets or separate gated spaces.
- Any change to the install path (helper script, Team-ID codesign pin).

## Channel Routing

`UpdateService.checkForUpdates()` routes by build flavor:

| Flavor | Channel |
| --- | --- |
| `""` (public) | GitHub Releases API — byte-identical to today |
| `dev` | updates disabled (today's behavior) |
| anything else (`corp`, `b2`, …) | gated channel, if channel keys are present |

A flavored build carries three additional Info.plist keys, stamped by
`build-app.sh` from the build profile (same mechanism as `WTBuildFlavor`, values
live only in the gitignored `.env.*` profiles on the build machine — the feed
URL never appears in this repo):

- `WTUpdateFeedURL` — base URL of the gated space
- `WTUpdateClientID` / `WTUpdateClientSecret` — a Cloudflare Access **service
  token**, one token per flavor (revoking one flavor's token never affects
  another)

If any of the three keys is absent on a flavored build (old profile), updates
stay disabled exactly as today — fail closed, never fall back to the public
feed.

## Gated Channel Protocol

The publish script (private distribution repo) uploads per release:

1. `Watchtower-<version>-<flavor>-arm64.zip` (the updater installs from ZIP;
   the DMG stays for humans), and
2. overwrites `manifest/<flavor>.json`:

```json
{
  "version": "0.8.0",
  "zip_key": "Watchtower-0.8.0-corp-arm64.zip",
  "sha256": "<hex of the zip>",
  "size": 123456789,
  "published_at": "2026-08-16T12:00:00Z",
  "notes": "optional release notes"
}
```

Updater flow:

1. `GET <feed>/dl/manifest/<flavor>.json` with `CF-Access-Client-Id` /
   `CF-Access-Client-Secret` headers. The request **must not follow
   redirects** — a redirect means Cloudflare Access rejected the token
   (revoked/expired) and is bouncing to the login page; surface it as an auth
   error, never as "no updates available". Non-200 or undecodable JSON is also
   an error.
2. Compare `version` against the running version (reuse `isNewer`).
3. Sanity-check `zip_key` contains the build's own flavor token — a wrong or
   swapped manifest must not cross flavors.
4. Download `<feed>/dl/<zip_key>` with the same headers, verify `sha256`
   (CryptoKit) over the downloaded bytes.
5. Hand off to the **existing** extract/install path unchanged: ditto → helper
   script → codesign verify pinned to the running app's Team ID. The pin is
   what protects install integrity; the sha256 only guards download corruption.

Security note: the service token is extractable from the flavored binary. That
is accepted — the binary is only distributed to gated users, already carries
baked-in OAuth credentials of similar sensitivity, and a leaked token only
grants downloads; it cannot make the app install a foreign build (Team-ID pin).

## Public Channel Tightening (PR #96 follow-up)

While here, the GitHub channel's asset selection moves from "first `.zip`
asset" to an exact expected asset name, closing the "exact-name updater asset
match" follow-up. The expected name is derived from the release's actual asset
naming convention (verified against a live release during implementation).

## Server Side (private distribution repo)

- The worker's Access-JWT verification checks iss/aud/exp/signature only, so a
  service-token-minted JWT (signed by the same team keys, same AUD) passes with
  **no code change**. Required config change: add a Service Auth policy with
  the per-flavor tokens to the existing Access application (the human email-OTP
  policy stays).
- Cosmetic: hide `manifest/` keys from the HTML listing page.
- `publish-build.sh` grows the manifest step: takes `--version` and `--flavor`,
  uploads the DMG + ZIP under versioned keys, computes the zip's sha256, writes
  `manifest/<flavor>.json`.

## Settings UI

The Update section in Settings stays the single surface. For builds where
updates are genuinely unavailable (`dev`, or a flavored build without channel
keys), the inert "Check for Updates" button is replaced by an explanatory
"Updates for this build are distributed out of band" line — closing the inert
button follow-up from PR #96. For flavored builds with keys, the existing
states (checking / available / downloading / ready / error) work as-is on top
of the gated channel.

## Error Handling

- Access rejection (redirect or 403) → `state = .error` naming the auth
  failure; never masquerades as "no updates".
- Missing manifest (404) → error state (the channel is expected to have a
  manifest once this ships).
- sha256 mismatch → error, downloaded archive discarded.
- Network failures → same error surface as the GitHub channel today.

## Testing

- Swift unit tests (extend `UpdateServiceTests`): channel routing matrix
  (public → GitHub; `dev` → disabled; flavored without keys → disabled;
  flavored with keys → gated), manifest decoding, `zip_key` flavor
  sanity-check, sha256 verification, redirect-means-auth-error.
- Existing helper-script / Team-ID pin tests untouched.
- Manual gate: a live flavored build against the real gated space — check,
  download, install, relaunch.
