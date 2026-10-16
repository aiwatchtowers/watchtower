# Release Watchtower

You are creating a new GitHub Release for Watchtower. Follow these steps precisely.

## Step 1: Determine Version

1. Get the current version from `cmd/version.go` (the `Version` variable)
2. Get the latest git tag: `git tag -l 'v*' --sort=-v:refname | head -1`
3. Get commits since last tag (or last 20 if no tags): `git log $(git tag -l 'v*' --sort=-v:refname | head -1)..HEAD --oneline` (if no tags, use `git log --oneline -20`)
4. Based on the changes, suggest a version following semver:
   - PATCH (0.2.x): bug fixes, minor tweaks
   - MINOR (0.x.0): new features, new commands
   - MAJOR (x.0.0): breaking changes
5. Present the suggestion to the user and ask for confirmation. Show the commits that will be included.

## Step 2: Generate Release Notes

Based on the commits since last release, generate release notes in this format:

```
## What's New

### Features
- [list new features, if any]

### Improvements
- [list improvements, if any]

### Bug Fixes
- [list fixes, if any]

**Full Changelog**: [previous_tag]...[new_tag]
```

Group commits by type. Skip merge commits. Write in English. Be concise — one line per change.

Show the release notes to the user and ask for confirmation.

## Step 3: Update Version in Code

Update the `Version` variable in `cmd/version.go` to the new version.

## Step 3b: Docs check

The user guide (`docs/guide/`) is what the in-app assistant answers from, so a
user-visible change must reach it before the release.

1. List the PRs merged since the last tag that touched `WatchtowerDesktop/`,
   `cmd/` or `internal/` but not `docs/guide/`:

   ```bash
   git log --merges --format='%s' <last-tag>..HEAD
   gh pr view <N> --json files --jq '.files[].path'
   ```

2. For each one that changes something a user sees, update its guide page per
   `docs/guide/WRITING.md`, or name in the release notes why none was needed.
3. Run `go test ./docs/guide/` (links, catalogue, page size). Any failure halts
   the release.

## Step 4: Pre-release gate

Run the pre-release checks. This runs sentrux quality (rules + structural
regression), periphery dead-code check (vs baseline), Go tests, and Swift tests.
Any failure halts the release.

```bash
make release-check
```

If `periphery-check` fails (dead-code count above baseline), either clean up
the new dead code or — only after a deliberate review — refresh the baseline
with `make periphery-baseline` and explain in the release notes why.

## Step 5: Build

Run the build via Makefile (this ensures `.env` is loaded and OAuth credentials are injected via ldflags):
```bash
make app VERSION=<version>
```

Wait for it to complete. If it fails, show the error and stop.

## Step 6: Commit & Tag

1. Stage and commit the version bump: `git add cmd/version.go && git commit -m "release: v<version>"`
2. Verify build artifacts exist:
   - `build/Watchtower-arm64.dmg` (install — new users, stable URL)
   - `build/Watchtower-<version>-arm64.zip` (auto-update)
   - `build/checksums.txt` (SHA-256 verification)

## Step 7: Push & Create Release

1. Push the commit and let gh create the tag: `git push origin`
2. Create the GitHub release with all artifacts attached:
```bash
gh release create "v<version>" \
    "build/Watchtower-arm64.dmg" \
    "build/Watchtower-<version>-arm64.zip" \
    "build/checksums.txt" \
    --title "Watchtower v<version>" \
    --notes "<release_notes>"
```
3. Show the release URL to the user.

## Step 8: Publish the iPhone app to TestFlight

Every release also ships the iPhone app (`WatchtowerMobile`) to TestFlight
under the same version as the Mac app:

```bash
make testflight VERSION=<version>
```

It first runs `cloudkit-check` (CloudKit Production must carry every record
type and field Development has — a TestFlight phone talks to Production), then
archives a Release build, stamps `MARKETING_VERSION=<version>` and a fresh
build number (Unix time), and uploads it to App Store Connect.

Before running it, check the prerequisites on this machine (all live outside
the repo — never commit them):
- `WatchtowerMobile/Signing.xcconfig` with a real `DEVELOPMENT_TEAM`
  (from `Signing.xcconfig.template`)
- `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` and
  `~/.appstoreconnect/watchtower.mk` with `ASC_KEY_ID` / `ASC_ISSUER_ID`
- a CloudKit management token (`xcrun cktool save-token --type management`)

If a prerequisite is missing, or `cloudkit-check` reports a schema gap
(deploy it to Production by hand in the CloudKit Console), stop this step and
tell the user exactly what is missing — the Mac release is already published
and stays as is. Never pass `SKIP_CLOUDKIT_CHECK=1` without the user's go-ahead.

On success, tell the user the uploaded version and build number; the build
appears in TestFlight after Apple finishes processing it.

## Step 9: Reply on the GitHub issues this release ships

Issue fixes reference their issue with `Refs #N` (not `Closes`), so the
issue stays open until the fix reaches a release. Close the loop here:

1. List the PRs merged since the previous tag and the issues they name:
   ```bash
   gh pr list --state merged --base main --limit 200 \
       --search "merged:>=$(git log -1 --format=%cI <previous_tag>)" \
       --json number,title,body \
       --jq '.[] | select(.body | test("(?i)(refs|closes|fixes) #[0-9]+")) | "\(.number) \(.title)"'
   ```
   Pull the `#N` numbers out of each body. Keep only issues that are still
   open, and skip PR numbers.
2. For each issue, read its thread (`gh issue view N --comments`) — the triage
   comment says what was accepted — and every PR in this release that names it.
   Decide:
   - **Done:** everything the triage comment accepted has shipped → reply and
     close.
   - **Partly done:** some accepted parts are still pending → reply with what
     shipped and what is still coming, and leave it open.
3. Draft each reply in English, short, addressed to the author: what shipped
   in `v<version>`, with the PR links, and a thank-you. Show all drafts with
   the close / keep-open decision to the user and wait for confirmation —
   these comments are public.
4. Post them: `gh issue comment N --body "..."`, then for the done ones
   `gh issue close N --reason completed`. List the issue URLs to the user.

If no PR in the range names an issue, say so and skip this step.

## Important

- Always confirm version and release notes with user before proceeding
- If any step fails, stop and report — do not continue
- The build script handles code signing automatically
- **DMG** = for new users (drag to Applications)
- **ZIP** = required for in-app auto-update (`UpdateService` looks for `.zip` asset)
- **checksums.txt** = SHA-256 verification for install script
- All three artifacts MUST be attached to every release
- The iPhone app goes to TestFlight with the same version (Step 8); a failure
  there does not undo the Mac release — report it and leave the rest as is
- Issues shipped in the release get a reply and are closed (Step 9); post
  only after the user confirms the drafts