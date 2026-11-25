# Release Watchtower

You are creating a new GitHub Release for Watchtower. Follow these steps precisely.

A release ships two things: the public Mac app (GitHub release, which also bumps the Homebrew cask) and the iPhone app (TestFlight). There is **no corp build any more** (company setup D3, ask #1442): 0.29.0 is the bridge release and 0.29.1 the last corp build published — a corp install whose bridge ran takes the public feed, and one whose bridge has not run yet keeps retrying it on its current build. Do not build or publish a corp flavor unless the user asks for it explicitly.

Before Step 1, check that `main`'s latest CI run is green (`gh run list --branch main --workflow ci.yml --limit 1`); a red `main` is fixed first, never tagged.

## Step 1: Collect the changes and determine the version

1. Get the current version from `cmd/version.go` (the `Version` variable) and the latest tag: `prev=$(git tag -l 'v*' --sort=-v:refname | head -1)`.
2. List what landed on `main` since the tag: `git log $prev..HEAD --first-parent --format='%h %s'`. `main` is squash-merged, so each PR is one commit whose subject ends in `(#N)`; read each PR's body with `gh pr view N --json number,title,body`. A commit without `(#N)` was made on `main` directly: classify it from its subject and diff — the previous release's own commits (`release: vX.Y.Z`, `docs(guide): stamp … Learn cards`) are `internal`.
3. Read each PR's `Changelog:` lines (the "Changelog" section of `.github/pull_request_template.md`), ignoring text inside `<!-- … -->`: `Changelog: <category> [<area>] — <line for users>`, one line per user-visible change, several allowed; the area is optional and written without brackets (`Changelog: fixed mac — The tray icon no longer flickers after sleep.`). A PR with no line, or only the template's unfilled placeholder (`Changelog: <category> — …`), gets its category guessed from its title and diff; mark every guessed line `(guessed)` in the ask. An umbrella PR carries one line per change of all its targets.
4. Categories, in the order the ask and the notes use (the keys are fixed — the PR template, this file and the notes use the same ones):

   | Key | Badge in the notes | What belongs here | Bump |
   |---|---|---|---|
   | `requirements` | ⚠️ Requirements | A new minimum macOS/iOS, a new permission, a one-way data migration (no downgrade after it) | patch, ⚠️ |
   | `new` | ✨ New | A new entry point: a screen, tab, CLI command, connector or integration | minor |
   | `extended` | ➕ Extended | Inside an existing entry point, the user can now do something they could not before | patch |
   | `improved` | 💅 Improved | The same thing, done better: faster, clearer text, fewer clicks | patch |
   | `changed` | 🔀 Changed | Doing what they did before, the user gets a different result: a new default, a move, a rename, a reworked flow | patch, ⚠️ |
   | `removed` | 🗑 Removed | A feature, setting or command is gone | minor |
   | `security` | 🔒 Security | A security fix | patch |
   | `fixed` | 🐞 Fixed | It did not behave as designed or documented | patch |
   | `internal` | — (not in the notes) | Refactors, tests, CI, build, developer docs: nothing a user sees | none |

   `area` is optional: `mac`, `iphone`, `cli`; a connector-specific change names the connector (`slack`, `jira`, …). Tie-breaks: if a returning user would look for the thing in its old place or under its old name, it is `changed`, not `improved`; a security bug is `security`, not `fixed`. A change in several categories takes the line under its main category; the version follows the heaviest one.
5. The version:
   - **No release** if every change is `internal`: tell the user there is nothing to release and stop.
   - **MAJOR** only when the user asks for it.
   - **MINOR** (`0.x.0`, patch reset) when any change is `new` or `removed`.
   - **PATCH** otherwise.
6. Ask the user (one ask): the suggested version and why, then the changes grouped by category in the table's order, each line `#<PR> <line>` (plus `(guessed)`), with `internal` collapsed to a count. Put a ⚠️ line at the top when there are `changed`, `requirements` or `removed` entries ("changes users' habits / cannot be undone — consider a bigger bump"). The user may move a line to another category or edit it; recompute the version after their edits.

## Step 2: Generate Release Notes

Build the notes from the confirmed lines, one section per non-empty category, in the table's order (requirements first — they decide whether a user can update at all; `internal` never appears). Nothing else goes into the notes: the Mac app's Software Update window reads these headings to draw its badges.

```
## What's New

### ⚠️ Requirements
- [line] (Mac)

### ✨ New
- [line] (iPhone)

### ➕ Extended
### 💅 Improved
### 🔀 Changed
### 🗑 Removed
### 🔒 Security
### 🐞 Fixed

**Full Changelog**: [previous_tag]...[new_tag]
```

Write in English, one line per change, in user words (what they can do or notice, not the code). The area, when set, goes at the end in parentheses (`Mac`, `iPhone`, `CLI`, `Slack`, …). **Security lines stay vague** — this repository is public and users update later: say what area was hardened ("Tightened how shared links are validated"), never the attack, the input or the file; the details stay in the private triage.

Show the release notes to the user and ask for confirmation.

## Step 3: Check the user guide is current

Find PRs merged since the previous tag that changed user-facing code but not the guide:

```bash
prev=$(git tag -l 'v*' --sort=-v:refname | head -1)
for n in $(gh pr list --state merged --base main --limit 200 \
    --search "merged:>=$(git log -1 --format=%cI $prev)" --json number --jq '.[].number'); do
  files=$(gh pr view $n --json files --jq '.files[].path')
  echo "$files" | grep -qE '^(WatchtowerDesktop/Sources/Views/|cmd/|.*[Ss]ettings)' || continue
  echo "$files" | grep -q '^docs/guide/' && continue
  gh pr view $n --json number,title --jq '"#\(.number) \(.title)"'
done
```

Show the list to the user with a one-line "does the guide need an update?" for each PR (what changed on screen, which page would cover it). For the ones the user marks, propose guide edits following `docs/guide/WRITING.md` and apply them in a separate commit before the version bump. This step never blocks the release: if the user says skip, or the list is empty, continue.

Then stamp the new Learn cards (Home's Learn zone, `docs/guide/WRITING.md` "Learn cards") with the version being released, and list new feature sections that have no card:

```bash
grep -rl --exclude=WRITING.md '^since: next$' docs/guide | xargs -r sed -i '' 's/^since: next$/since: <version>/'
git diff --unified=0 "$prev" -- docs/guide/features | grep -E '^\+##' || true
```

The stamp always runs and goes into the guide commit. For each new `##` heading the second command prints, check that a `<!-- learn` card or `<!-- learn: none -->` sits under it; list the ones without as a **warning** in the release report (this never blocks the release).

Then run `go test ./docs/guide/ ./internal/learn/ ./internal/kb/ ./internal/chat/` (guide links, catalogue, page size, the guide knowledge source, the prompt golden). If the guide's catalogue changed (a page added, renamed or re-titled), regenerate the chat prompt golden with `go test ./internal/chat -run TestBuildSystemPrompt_Golden -update` and commit it with the guide edits. Any other failure halts the release.

Then check the IT page's key list: if `docs/mdm/keys.json` changed since the previous tag (`git diff --quiet "$prev" -- docs/mdm/keys.json || echo changed`), tell the user the website needs a rebuild — in the website repository, `python3 scripts/sync-mdm.py v<version>` after the tag is pushed (or `main`), then `python3 scripts/build-guide.py`, a PR, and a deploy — so https://aiwatchtowers.com/guide/mdm/ lists the same keys as the release. This never blocks the release.

## Step 4: Update Version in Code

Update the `Version` variable in `cmd/version.go` to the new version.

## Step 5: Pre-release gate

Run the pre-release checks. This runs the periphery dead-code check (vs
baseline), Go tests, and Swift tests.
Any failure halts the release.

```bash
make release-check
```

If `periphery-check` fails (dead-code count above baseline), either clean up
the new dead code or — only after a deliberate review — refresh the baseline
with `make periphery-baseline` and explain why in the release commit message (not in the public notes).

## Step 6: Build

First check the build profile: a public release must not set `WATCHTOWER_JIRA_CLIENT_ID/SECRET` (our shared Atlassian app is retired, company setup D4, D15 amended, ask #1600). `scripts/build-app.sh` refuses such a release (`shared-jira-check`); remove the two values from `.env` (keep them only for `--dev` builds).

Run the build via Makefile (this ensures `.env` is loaded and OAuth credentials are injected via ldflags):
```bash
make app VERSION=<version>
```

Wait for it to complete. If it fails, show the error and stop.

## Step 7: Commit & Tag

1. Stage and commit the version bump: `git add cmd/version.go && git commit -m "release: v<version>"`
2. Verify build artifacts exist:
   - `build/Watchtower-arm64.dmg` (install — new users, stable URL)
   - `build/Watchtower-<version>-arm64.zip` (auto-update)
   - `build/checksums.txt` (SHA-256 verification)

## Step 8: Push & Create Release

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
3. **Headless hub artifacts — only from the Go hub's launch release on**
   (before it, skip this step): the release build also wrote
   `build/Watchtower-CLI-<version><flavor suffix>-arm64.zip` (the signed CLI
   for a CLI-only Mac, already in `checksums.txt`; the flavor suffix is
   `-<BUILD_FLAVOR>`, empty for the default build), and the tag's push started
   the `linux-build` workflow, which builds the two Linux tarballs. The tag
   build needs the repository variable `RELAY_ORIGIN` and `.env`'s
   `WATCHTOWER_RELAY_ORIGIN_DEFAULT`; without them both builds refuse. Wait
   for that run, download its artifacts and attach them (`gh run list
   --branch` takes the tag name, `v<version>`, for a tag-triggered run):
```bash
run_id=$(gh run list --workflow linux-build.yml --branch "v<version>" --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$run_id" --exit-status
gh run download "$run_id" --dir build/linux
gh release upload "v<version>" \
    "build/Watchtower-CLI-<version><flavor suffix>-arm64.zip" \
    build/linux/*/watchtower-v<version>-linux-*.tar.gz \
    build/linux/*/watchtower-v<version>-linux-*.tar.gz.sha256
```
4. Show the release URL to the user.

### Requiring a minimum version (only when asked)

A release can force every older app to update first — for a one-way
server-side change. Do this only when the user asks for it for this release;
never by default. Builds before the one that shipped this feature ignore it.

- **Public channel:** put the marker on its own line in the release notes
  (`--notes`, or `gh release edit "v<version>" --notes-file …` afterwards):
  `<!-- min_version: X.Y.Z -->`. GitHub hides it; the app strips it from the
  notes it shows. Running builds older than `X.Y.Z` get the **Software
  Update** window with no Later at their next check (within 6 h, or at launch).
- **Corp (gated) channel:** no corp build is published any more (see the
  top). A corp install that has not bridged yet reads only
  `manifest/corp.json` in the gated feed; to require a minimum there, add
  `"min_version": "X.Y.Z"` to that manifest by hand (the key wins over the
  marker) — only when the user asks.
- Format: `X`, `X.Y` or `X.Y.Z`, digits only, optional leading `v`; it must
  not be newer than the release being published. Anything else is ignored
  (the app logs it and requires nothing).
- The app reads the minimum from the **latest** release only. Every later
  release must carry the same marker (or key) for as long as the minimum
  should hold — a release published without it lifts the requirement for
  every old build at its next check. To lift it on purpose, remove the marker
  (or the key) from the latest release.

## Step 9: Publish the iPhone app to TestFlight

Every release also ships the iPhone app (`WatchtowerMobile`) to TestFlight
under the same version as the Mac app:

```bash
make testflight VERSION=<version>
```

It first runs `cloudkit-check` (CloudKit Production must carry every record
type and field Development has — a TestFlight phone talks to Production — and
the owner must have recorded the query subscription types as deployed, which
cktool cannot read: `make cloudkit-subscriptions-deployed` after deploying
them, #1749), then
archives a Release build, stamps `MARKETING_VERSION=<version>` and a fresh
build number (Unix time), and uploads it to App Store Connect.

Before running it, check the prerequisites on this machine (all live outside
the repo — never commit them):
- `WatchtowerMobile/Signing.xcconfig` with a real `DEVELOPMENT_TEAM`
  (from `Signing.xcconfig.template`)
- `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` and
  `~/.appstoreconnect/watchtower.mk` with `ASC_KEY_ID` / `ASC_ISSUER_ID`
- a CloudKit management token (`xcrun cktool save-token --type management`)
- the subscription-types stamp
  `~/.config/watchtower/cloudkit-subscription-types.<container>`, written by
  `make cloudkit-subscriptions-deployed` once the owner has deployed the
  listed query subscription types (the check prints the steps)
- the staging relay's origin in `~/.config/watchtower/relay-testflight-origin`
  (one `https://host[:port]` line; `RELAY_TESTFLIGHT_ORIGIN_FILE=<path>`
  points elsewhere). Every TestFlight build talks to the staging relay
  (ask #1156); a missing file fails the upload. Never pass
  `RELAY_TESTFLIGHT_DARK=1` without the user's go-ahead.

**A TestFlight build is never the App Store build.** It carries the staging
relay origin, so never promote it to App Store review: a submission for review
gets its own, dark `make mobile-archive` build.

If a prerequisite is missing, or `cloudkit-check` reports a schema gap
(deploy it to Production by hand in the CloudKit Console) or a missing
subscription-types stamp (only the user can confirm the deploy; never write
the stamp yourself), stop this step and
tell the user exactly what is missing — the Mac release is already published
and stays as is. Never pass `SKIP_CLOUDKIT_CHECK=1` without the user's go-ahead.

On success, tell the user the uploaded version and build number; the build
appears in TestFlight after Apple finishes processing it.

## Step 10: Reply on the GitHub issues this release ships

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
- The iPhone app goes to TestFlight with the same version (Step 9); a failure
  there does not undo the Mac release — report it and leave the rest as is
- Issues shipped in the release get a reply and are closed (Step 10); post
  only after the user confirms the drafts