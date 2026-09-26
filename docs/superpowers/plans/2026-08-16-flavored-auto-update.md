# Flavored Auto-Update Channel Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each build updates from the channel it was installed from — public builds from GitHub Releases (unchanged), flavored builds (`corp`, `b2`) from the gated distribution space via a per-flavor Cloudflare Access service token; `dev` builds never update.

**Architecture:** `UpdateService` gains a pure `resolveChannel` router (public / gated / disabled) driven by `WTBuildFlavor` plus three new Info.plist keys stamped by `build-app.sh` from the build profile. The gated channel polls `manifest/<flavor>.json` on the distribution space with `CF-Access-Client-Id/Secret` headers (redirects = auth error), verifies sha256, then reuses the existing extract/install path (Team-ID pin untouched). The publish script in the private distribution repo writes the manifest.

**Tech Stack:** Swift 5.10 / swift-testing, CryptoKit (SHA256), URLSession, bash, Cloudflare Workers (R2), Cloudflare Access service tokens.

**Spec:** `docs/superpowers/specs/2026-08-16-flavored-auto-update-design.md`

## Global Constraints

- Secrecy: the gated space URL, the partner identity, and any token values must NEVER appear in the watchtower repo (it is public). The feed URL lives only in gitignored `.env.*` profiles; the codename `b2` is the only allowed partner reference.
- Everything committed to either repo is in English.
- watchtower commits go to the current branch `fix/ui-quick-fixes`; wt-lending commits go to its `main`.
- Swift tests: always filtered — `cd WatchtowerDesktop && swift test --filter UpdateServicePureTests` (never unfiltered `swift test`).
- The PR #96 invariant must survive: a flavored build must never consult the public GitHub feed under any configuration.
- The install path (helper script, Team-ID codesign pin, `generateHelperScript`, `parseTeamIdentifier`) is out of scope — do not touch it.
- macOS 14+ APIs are fine (`URLSession.data(for:delegate:)` needs 12+).

---

### Task 1: UpdateService pure helpers — channel routing, manifest model, checksums

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/UpdateService.swift`
- Test: `WatchtowerDesktop/Tests/UpdateServiceTests.swift`

**Interfaces:**
- Produces (Task 2 consumes all of these, exact signatures):
  - `enum UpdateService.UpdateChannel: Equatable { case publicGitHub; case gated(feedURL: URL, clientID: String, clientSecret: String); case disabled }`
  - `nonisolated static func UpdateService.resolveChannel(flavor: String, feedURL: String?, clientID: String?, clientSecret: String?) -> UpdateChannel`
  - `nonisolated static func UpdateService.expectedPublicAssetName(forTag: String) -> String`
  - `nonisolated static func UpdateService.zipKeyMatchesFlavor(_ zipKey: String, flavor: String) -> Bool`
  - `nonisolated static func UpdateService.classifyGatedStatus(_ status: Int) -> GatedChannelError?`
  - `nonisolated static func UpdateService.sha256Hex(ofFileAt url: URL) throws -> String`
  - `struct GatedManifest: Decodable` (top-level in UpdateService.swift, next to `GitHubRelease`) with `version: String`, `zipKey: String`, `sha256: String`, `size: Int?`, `publishedAt: String?`, `notes: String?` (snake_case JSON keys `zip_key`, `published_at`)
  - `enum GatedChannelError: LocalizedError, Equatable { case authRejected; case httpError(Int); case checksumMismatch }`

- [ ] **Step 1: Write the failing tests**

Append to `WatchtowerDesktop/Tests/UpdateServiceTests.swift` (inside the file, as a new suite below `UpdateServicePureTests`):

```swift
@Suite("UpdateService Channel Routing")
struct UpdateChannelTests {
    @Test("public flavor routes to GitHub")
    func publicChannel() {
        #expect(UpdateService.resolveChannel(flavor: "", feedURL: nil, clientID: nil, clientSecret: nil) == .publicGitHub)
        // Even with stray keys present, a flavorless build stays on GitHub.
        #expect(UpdateService.resolveChannel(flavor: "", feedURL: "https://x", clientID: "a", clientSecret: "b") == .publicGitHub)
    }

    @Test("dev flavor never updates, keys or not")
    func devDisabled() {
        #expect(UpdateService.resolveChannel(flavor: "dev", feedURL: nil, clientID: nil, clientSecret: nil) == .disabled)
        #expect(UpdateService.resolveChannel(flavor: "dev", feedURL: "https://feed.example", clientID: "a", clientSecret: "b") == .disabled)
    }

    @Test("flavored build without complete keys is disabled — never falls back to public")
    func flavoredMissingKeys() {
        #expect(UpdateService.resolveChannel(flavor: "corp", feedURL: nil, clientID: nil, clientSecret: nil) == .disabled)
        #expect(UpdateService.resolveChannel(flavor: "corp", feedURL: "https://feed.example", clientID: "a", clientSecret: nil) == .disabled)
        #expect(UpdateService.resolveChannel(flavor: "corp", feedURL: "https://feed.example", clientID: "", clientSecret: "b") == .disabled)
        #expect(UpdateService.resolveChannel(flavor: "corp", feedURL: nil, clientID: "a", clientSecret: "b") == .disabled)
    }

    @Test("flavored build with full keys gets the gated channel")
    func flavoredGated() {
        let ch = UpdateService.resolveChannel(flavor: "corp", feedURL: "https://feed.example/p", clientID: "id", clientSecret: "sec")
        #expect(ch == .gated(feedURL: URL(string: "https://feed.example/p")!, clientID: "id", clientSecret: "sec"))
    }

    @Test("non-https or malformed feed URL is disabled")
    func badFeedURL() {
        #expect(UpdateService.resolveChannel(flavor: "corp", feedURL: "http://feed.example", clientID: "a", clientSecret: "b") == .disabled)
        #expect(UpdateService.resolveChannel(flavor: "corp", feedURL: "not a url", clientID: "a", clientSecret: "b") == .disabled)
    }

    @Test("expected public asset name derives from the release tag")
    func publicAssetName() {
        #expect(UpdateService.expectedPublicAssetName(forTag: "v0.7.0") == "Watchtower-0.7.0-arm64.zip")
        #expect(UpdateService.expectedPublicAssetName(forTag: "0.8.1") == "Watchtower-0.8.1-arm64.zip")
    }

    @Test("zip key must carry this build's own flavor token")
    func zipKeyFlavorCheck() {
        #expect(UpdateService.zipKeyMatchesFlavor("Watchtower-0.8.0-corp-arm64.zip", flavor: "corp"))
        #expect(!UpdateService.zipKeyMatchesFlavor("Watchtower-0.8.0-b2-arm64.zip", flavor: "corp"))
        #expect(!UpdateService.zipKeyMatchesFlavor("Watchtower-0.8.0-arm64.zip", flavor: "corp"))
        #expect(!UpdateService.zipKeyMatchesFlavor("Watchtower-0.8.0-corp2-arm64.zip", flavor: "corp"))
    }

    @Test("gated status classification: redirects and auth failures are auth errors, not silence")
    func gatedStatus() {
        #expect(UpdateService.classifyGatedStatus(200) == nil)
        #expect(UpdateService.classifyGatedStatus(302) == .authRejected)
        #expect(UpdateService.classifyGatedStatus(401) == .authRejected)
        #expect(UpdateService.classifyGatedStatus(403) == .authRejected)
        #expect(UpdateService.classifyGatedStatus(404) == .httpError(404))
        #expect(UpdateService.classifyGatedStatus(500) == .httpError(500))
    }

    @Test("GatedManifest decodes snake_case keys and tolerates missing optionals")
    func manifestDecode() throws {
        let full = """
        {"version":"0.8.0","zip_key":"Watchtower-0.8.0-corp-arm64.zip","sha256":"abc123","size":42,"published_at":"2026-08-16T12:00:00Z","notes":"n"}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(GatedManifest.self, from: full)
        #expect(m.version == "0.8.0")
        #expect(m.zipKey == "Watchtower-0.8.0-corp-arm64.zip")
        #expect(m.sha256 == "abc123")
        #expect(m.size == 42)
        #expect(m.publishedAt == "2026-08-16T12:00:00Z")
        #expect(m.notes == "n")

        let minimal = """
        {"version":"0.8.0","zip_key":"k.zip","sha256":"x"}
        """.data(using: .utf8)!
        let m2 = try JSONDecoder().decode(GatedManifest.self, from: minimal)
        #expect(m2.size == nil && m2.publishedAt == nil && m2.notes == nil)
    }

    @Test("sha256Hex streams a file to the known digest")
    func sha256File() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-sha-test-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let hex = try UpdateService.sha256Hex(ofFileAt: tmp)
        #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter UpdateChannelTests 2>&1 | tail -20`
Expected: compile FAILURE — `resolveChannel`, `UpdateChannel`, `GatedManifest` etc. do not exist. (Capture the real exit code; do not pipe through `tail` alone without checking `$?` — redirect to a log file if needed.)

- [ ] **Step 3: Implement the helpers**

In `WatchtowerDesktop/Sources/Services/UpdateService.swift`:

Add `import CryptoKit` at the top (next to `import Foundation`).

Add inside `final class UpdateService` (e.g. after the `UpdateState` enum):

```swift
    /// Which feed this build updates from. Resolved from the build flavor and
    /// the channel keys stamped into Info.plist by build-app.sh. `disabled`
    /// covers dev builds and flavored builds whose profile carried no channel
    /// keys — those must fail closed, never fall back to the public feed.
    enum UpdateChannel: Equatable {
        case publicGitHub
        case gated(feedURL: URL, clientID: String, clientSecret: String)
        case disabled
    }

    nonisolated static func resolveChannel(
        flavor: String, feedURL: String?, clientID: String?, clientSecret: String?
    ) -> UpdateChannel {
        if flavor.isEmpty { return .publicGitHub }
        if flavor == "dev" { return .disabled }
        guard let feedURL, let url = URL(string: feedURL), url.scheme == "https",
              let clientID, !clientID.isEmpty,
              let clientSecret, !clientSecret.isEmpty else { return .disabled }
        return .gated(feedURL: url, clientID: clientID, clientSecret: clientSecret)
    }

    /// Release assets are produced by build-app.sh as
    /// "Watchtower-<version>-arm64.zip"; match exactly, never "first .zip".
    nonisolated static func expectedPublicAssetName(forTag tag: String) -> String {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return "Watchtower-\(version)-arm64.zip"
    }

    /// A manifest for the wrong flavor must never cross over — the zip key
    /// carries the flavor as a "-<flavor>-" token (build-app.sh naming).
    nonisolated static func zipKeyMatchesFlavor(_ zipKey: String, flavor: String) -> Bool {
        zipKey.contains("-\(flavor)-")
    }

    /// Cloudflare Access answers a rejected service token with a redirect to
    /// the login page (or 401/403) — surface that as an auth error so a
    /// revoked token never masquerades as "no updates available".
    nonisolated static func classifyGatedStatus(_ status: Int) -> GatedChannelError? {
        if status == 200 { return nil }
        if (300...399).contains(status) || status == 401 || status == 403 { return .authRejected }
        return .httpError(status)
    }

    nonisolated static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
```

Add at file scope, next to `GitHubRelease`/`GitHubAsset`:

```swift
struct GatedManifest: Decodable {
    let version: String
    let zipKey: String
    let sha256: String
    let size: Int?
    let publishedAt: String?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case version, sha256, size, notes
        case zipKey = "zip_key"
        case publishedAt = "published_at"
    }
}

enum GatedChannelError: LocalizedError, Equatable {
    case authRejected
    case httpError(Int)
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .authRejected:
            "Update channel rejected this build's access credentials — the update token may have been revoked."
        case .httpError(let code):
            "Update channel returned status \(code)"
        case .checksumMismatch:
            "Downloaded update failed checksum verification"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd WatchtowerDesktop && swift test --filter UpdateChannelTests 2>&1 | tail -5; echo "exit=$?"`
Expected: all tests PASS. Also run the pre-existing suite: `swift test --filter UpdateServicePureTests` — must stay green.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/UpdateService.swift WatchtowerDesktop/Tests/UpdateServiceTests.swift
git commit -m "feat(desktop): update-channel routing helpers for flavored builds"
```

---

### Task 2: UpdateService gated channel — check, download with headers, sha256 verify

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/UpdateService.swift`
- Test: `WatchtowerDesktop/Tests/UpdateServiceTests.swift`

**Interfaces:**
- Consumes: everything from Task 1.
- Produces (Task 3 consumes): `var updatesSupported: Bool` on `UpdateService`; instance properties `updateFeedURL`, `updateClientID`, `updateClientSecret` (all `String?`, test-injectable like `buildFlavor`).

- [ ] **Step 1: Write the failing tests**

Append to the `UpdateChannelTests` suite:

```swift
    @Test("updatesSupported reflects the resolved channel")
    func updatesSupportedFlag() async {
        await MainActor.run {
            let svc = UpdateService()
            svc.buildFlavor = ""
            #expect(svc.updatesSupported)

            svc.buildFlavor = "dev"
            #expect(!svc.updatesSupported)

            svc.buildFlavor = "corp"  // no keys injected
            #expect(!svc.updatesSupported)

            svc.updateFeedURL = "https://feed.example/p"
            svc.updateClientID = "id"
            svc.updateClientSecret = "sec"
            #expect(svc.updatesSupported)
        }
    }

    @Test("flavored build without channel keys stays idle on check")
    func flavoredNoKeysIdle() async {
        let svc = await UpdateService()
        await MainActor.run {
            svc.buildFlavor = "corp"
            svc.updateFeedURL = nil
            svc.updateClientID = nil
            svc.updateClientSecret = nil
        }
        await svc.checkForUpdates()
        await MainActor.run { #expect(svc.state == .idle) }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter UpdateChannelTests 2>&1 | tail -20`
Expected: compile FAILURE — `updatesSupported` / `updateFeedURL` do not exist.

- [ ] **Step 3: Implement the wiring**

In `UpdateService.swift`:

1. Add instance properties next to `buildFlavor` (same test-injection pattern):

```swift
    /// Gated-channel keys stamped into Info.plist by build-app.sh (absent on
    /// default and dev builds). Instance properties so tests can inject them.
    var updateFeedURL: String? =
        Bundle.main.object(forInfoDictionaryKey: "WTUpdateFeedURL") as? String
    var updateClientID: String? =
        Bundle.main.object(forInfoDictionaryKey: "WTUpdateClientID") as? String
    var updateClientSecret: String? =
        Bundle.main.object(forInfoDictionaryKey: "WTUpdateClientSecret") as? String

    var channel: UpdateChannel {
        Self.resolveChannel(flavor: buildFlavor, feedURL: updateFeedURL,
                            clientID: updateClientID, clientSecret: updateClientSecret)
    }

    /// False when this build has no update channel at all (dev, or a flavored
    /// build whose profile carried no channel keys). Settings uses this to
    /// swap the check button for an "out of band" note.
    var updatesSupported: Bool { channel != .disabled }

    /// Set when the current `.available` state came from the gated channel;
    /// carries what the download step needs (headers + expected checksum).
    private struct GatedDownloadContext {
        let sha256: String
        let clientID: String
        let clientSecret: String
    }
    private var gatedDownload: GatedDownloadContext?
```

2. Replace the body of `checkForUpdates()` — the old `guard buildFlavor.isEmpty` block and the rest move into `checkPublic()`:

```swift
    func checkForUpdates() async {
        gatedDownload = nil
        switch channel {
        case .disabled:
            state = .idle
        case .publicGitHub:
            await checkPublic()
        case .gated(let feedURL, let clientID, let clientSecret):
            await checkGated(feedURL: feedURL, clientID: clientID, clientSecret: clientSecret)
        }
    }
```

3. `checkPublic()` is the old `checkForUpdates` body minus the flavor guard, with the asset selection tightened from "first `.zip`" to the exact expected name:

```swift
    private func checkPublic() async {
        state = .checking
        do {
            let release = try await fetchLatestRelease()
            let current = Constants.appVersion
            guard Self.isNewer(release.tagName, than: current) else {
                state = .idle
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                return
            }

            let expected = Self.expectedPublicAssetName(forTag: release.tagName)
            guard let asset = release.assets.first(where: { $0.name == expected }) else {
                state = .error("No asset named \(expected) in release \(release.tagName)")
                return
            }

            guard let url = URL(string: asset.browserDownloadURL) else {
                state = .error("Invalid download URL")
                return
            }

            state = .available(
                version: release.tagName,
                notes: release.body ?? "",
                downloadURL: url
            )
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
```

4. Add the gated check + fetch:

```swift
    private func checkGated(feedURL: URL, clientID: String, clientSecret: String) async {
        state = .checking
        do {
            let manifestURL = feedURL.appendingPathComponent("dl/manifest/\(buildFlavor).json")
            let data = try await gatedGET(manifestURL, clientID: clientID, clientSecret: clientSecret)
            let manifest = try JSONDecoder().decode(GatedManifest.self, from: data)

            guard Self.zipKeyMatchesFlavor(manifest.zipKey, flavor: buildFlavor) else {
                state = .error("Update manifest points at a different build flavor (\(manifest.zipKey))")
                return
            }

            guard Self.isNewer(manifest.version, than: Constants.appVersion) else {
                state = .idle
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                return
            }

            let downloadURL = feedURL.appendingPathComponent("dl/\(manifest.zipKey)")
            gatedDownload = GatedDownloadContext(
                sha256: manifest.sha256, clientID: clientID, clientSecret: clientSecret
            )
            state = .available(
                version: manifest.version,
                notes: manifest.notes ?? "",
                downloadURL: downloadURL
            )
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// GET on the gated channel. Redirects are never followed — Cloudflare
    /// Access answers a bad/revoked service token with a 302 to its login
    /// page, and following it would hand back HTML that only fails later as
    /// a confusing decode error.
    private func gatedGET(_ url: URL, clientID: String, clientSecret: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        request.setValue("Watchtower/\(Constants.appVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request, delegate: RedirectBlocker())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let err = Self.classifyGatedStatus(status) { throw err }
        return data
    }
```

Add at file scope (below the class):

```swift
/// Refuses HTTP redirects so a Cloudflare Access login bounce surfaces as its
/// 3xx status instead of the login page's HTML.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}
```

5. Teach the download step about the gated context. Replace `downloadWithProgress(from:)`:

```swift
    private func downloadWithProgress(from url: URL) async throws -> (URL, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Watchtower/\(Constants.appVersion)", forHTTPHeaderField: "User-Agent")
        var delegate: URLSessionTaskDelegate?
        if let ctx = gatedDownload {
            request.setValue(ctx.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(ctx.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
            delegate = RedirectBlocker()
        }
        let (localURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        if gatedDownload != nil {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let err = Self.classifyGatedStatus(status) { throw err }
        }
        await MainActor.run { state = .downloading(progress: 0.8) }
        return (localURL, response)
    }
```

6. In `downloadUpdate()`, right after `try fm.moveItem(at: localURL, to: zipPath)`, add the checksum gate:

```swift
            if let ctx = gatedDownload {
                let actual = try Self.sha256Hex(ofFileAt: zipPath)
                guard actual.caseInsensitiveCompare(ctx.sha256) == .orderedSame else {
                    try? fm.removeItem(at: zipPath)
                    state = .error(GatedChannelError.checksumMismatch.localizedDescription)
                    return
                }
            }
```

7. Update the stale comment on `buildFlavor` (it says flavored builds "must never update from the public release feed" — still true; extend it to mention the gated channel keys route flavored builds instead of disabling updates outright).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd WatchtowerDesktop && swift test --filter UpdateChannelTests 2>&1 | tail -5; echo "exit=$?"`
Then the guard suite: `swift test --filter UpdateServicePureTests 2>&1 | tail -5; echo "exit=$?"`
Expected: all PASS — including the pre-existing "flavored build never consults the public release feed" test (a keyless flavored build now resolves to `.disabled` → `.idle`, same observable behavior).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/UpdateService.swift WatchtowerDesktop/Tests/UpdateServiceTests.swift
git commit -m "feat(desktop): gated update channel for flavored builds"
```

---

### Task 3: Settings UI — replace the inert check button with an out-of-band note

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SystemSettings.swift` (the `updateSection` computed view, `.idle` case)

**Interfaces:**
- Consumes: `UpdateService.updatesSupported` (Task 2).

- [ ] **Step 1: Implement the UI change**

In `updateSection`, replace the `.idle` case body:

```swift
            case .idle:
                if service.updatesSupported {
                    HStack {
                        Text("No updates available")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Check for Updates") {
                            Task { await service.checkForUpdates() }
                        }
                    }
                } else {
                    Text("Updates for this build are distributed out of band")
                        .foregroundStyle(.secondary)
                }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tail -5; echo "exit=$?"`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Settings/SystemSettings.swift
git commit -m "fix(desktop): Settings shows out-of-band note when a build has no update channel"
```

---

### Task 4: build-app.sh — stamp the gated channel keys into Info.plist

**Files:**
- Modify: `scripts/build-app.sh` (the `WTBuildFlavor` PlistBuddy block, around line 255)

**Interfaces:**
- Consumes: profile env vars `WATCHTOWER_UPDATE_FEED_URL`, `WATCHTOWER_UPDATE_CLIENT_ID`, `WATCHTOWER_UPDATE_CLIENT_SECRET` (set only in gitignored `.env.corp` / future `.env.b2`; never in the repo).
- Produces: Info.plist keys `WTUpdateFeedURL`, `WTUpdateClientID`, `WTUpdateClientSecret` (read by Task 2's `UpdateService` properties).

- [ ] **Step 1: Extend the flavor stamping block**

The current block:

```bash
if [ -n "$FLAVOR" ]; then
    /usr/libexec/PlistBuddy -c "Add :WTBuildFlavor string $FLAVOR" "$APP_BUNDLE/Contents/Info.plist"
fi
```

becomes:

```bash
if [ -n "$FLAVOR" ]; then
    /usr/libexec/PlistBuddy -c "Add :WTBuildFlavor string $FLAVOR" "$APP_BUNDLE/Contents/Info.plist"
    # Gated update channel keys (flavored builds only; dev never updates —
    # UpdateService also enforces that, this just avoids shipping dead keys).
    # All three or none: a partial set would be a build that can locate the
    # feed but not authenticate, or vice versa. UpdateService fails closed on
    # a partial set anyway; erroring here catches the profile typo at build
    # time instead of shipping a silently non-updating artifact.
    _upd_set=0
    [ -n "${WATCHTOWER_UPDATE_FEED_URL:-}" ] && _upd_set=$((_upd_set+1))
    [ -n "${WATCHTOWER_UPDATE_CLIENT_ID:-}" ] && _upd_set=$((_upd_set+1))
    [ -n "${WATCHTOWER_UPDATE_CLIENT_SECRET:-}" ] && _upd_set=$((_upd_set+1))
    if [ "$FLAVOR" != "dev" ] && [ "$_upd_set" -eq 3 ]; then
        /usr/libexec/PlistBuddy -c "Add :WTUpdateFeedURL string $WATCHTOWER_UPDATE_FEED_URL" "$APP_BUNDLE/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Add :WTUpdateClientID string $WATCHTOWER_UPDATE_CLIENT_ID" "$APP_BUNDLE/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Add :WTUpdateClientSecret string $WATCHTOWER_UPDATE_CLIENT_SECRET" "$APP_BUNDLE/Contents/Info.plist"
    elif [ "$FLAVOR" != "dev" ] && [ "$_upd_set" -ne 0 ]; then
        echo "ERROR: partial update-channel config — set all three WATCHTOWER_UPDATE_* vars or none" >&2
        exit 1
    fi
fi
```

- [ ] **Step 2: Syntax-check the script**

Run: `bash -n scripts/build-app.sh; echo "exit=$?"`
Expected: exit 0. (A full flavored build is exercised in Task 7's live gate.)

- [ ] **Step 3: Commit**

```bash
git add scripts/build-app.sh
git commit -m "feat(build): stamp gated update-channel keys into flavored Info.plist"
```

---

### Task 5: Distribution repo — publish-build.sh writes the update manifest

**Files (in `~/PhpstormProjects/wt-lending`, commits to its `main`):**
- Modify: `scripts/publish-build.sh`

**Interfaces:**
- Produces: R2 objects `Watchtower-<version>-<flavor>-arm64.{dmg,zip}` and `manifest/<flavor>.json` in the exact `GatedManifest` shape Task 1 decodes (`version`, `zip_key`, `sha256`, `size`, `published_at`).

- [ ] **Step 1: Rewrite the script**

Replace `scripts/publish-build.sh` with:

```bash
#!/bin/bash
# Upload a release (DMG + ZIP + update manifest) to the gated distribution
# bucket served at /p/. The manifest is what flavored builds' auto-update
# polls; uploading files without refreshing the manifest means clients keep
# seeing the previous version.
# Usage: scripts/publish-build.sh --version 0.8.0 --flavor corp <dmg> <zip>
set -euo pipefail

VERSION="" FLAVOR="" FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --flavor)  FLAVOR="$2";  shift 2 ;;
        *)         FILES+=("$1"); shift ;;
    esac
done

usage() { echo "usage: publish-build.sh --version X.Y.Z --flavor F <dmg> <zip>" >&2; exit 1; }
[ -n "$VERSION" ] && [ -n "$FLAVOR" ] || usage
[ "${#FILES[@]}" -eq 2 ] || usage
DMG="${FILES[0]}"; ZIP="${FILES[1]}"
case "$DMG" in *.dmg) ;; *) usage ;; esac
case "$ZIP" in *.zip) ;; *) usage ;; esac
[ -f "$DMG" ] || { echo "not a file: $DMG" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "not a file: $ZIP" >&2; exit 1; }

BUCKET="wt-dist-b2"
DMG_KEY="Watchtower-$VERSION-$FLAVOR-arm64.dmg"
ZIP_KEY="Watchtower-$VERSION-$FLAVOR-arm64.zip"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
SIZE=$(stat -f%z "$ZIP")

cd "$(dirname "$0")/.."
npx wrangler r2 object put "$BUCKET/$DMG_KEY" --file "$DMG" --remote
npx wrangler r2 object put "$BUCKET/$ZIP_KEY" --file "$ZIP" --remote

MANIFEST=$(mktemp)
trap 'rm -f "$MANIFEST"' EXIT
cat > "$MANIFEST" <<EOF
{
  "version": "$VERSION",
  "zip_key": "$ZIP_KEY",
  "sha256": "$SHA",
  "size": $SIZE,
  "published_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
npx wrangler r2 object put "$BUCKET/manifest/$FLAVOR.json" \
    --file "$MANIFEST" --content-type application/json --remote

echo "Published: $DMG_KEY, $ZIP_KEY, manifest/$FLAVOR.json"
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n scripts/publish-build.sh; echo "exit=$?"`
Expected: exit 0.

- [ ] **Step 3: Commit (in wt-lending)**

```bash
cd ~/PhpstormProjects/wt-lending
git add scripts/publish-build.sh
git commit -m "feat: publish-build.sh writes the per-flavor update manifest"
```

---

### Task 6: Distribution repo — hide manifest keys from the listing page

**Files (in `~/PhpstormProjects/wt-lending`):**
- Modify: `src/worker.js` (`listPage`, ~line 105)

**Interfaces:**
- Consumes: nothing new. The worker's Access-JWT verification (iss/aud/exp/signature) already passes service-token-minted JWTs — no auth change.

- [ ] **Step 1: Filter the listing**

In `listPage`, change:

```js
    const listed = await env.DIST.list();
    const objects = listed.objects.sort((a, b) => b.uploaded.getTime() - a.uploaded.getTime());
```

to:

```js
    const listed = await env.DIST.list();
    // manifest/* are machine-read by the auto-updater, not human downloads.
    const objects = listed.objects
        .filter((o) => !o.key.startsWith("manifest/"))
        .sort((a, b) => b.uploaded.getTime() - a.uploaded.getTime());
```

- [ ] **Step 2: Syntax-check**

Run: `node --check src/worker.js; echo "exit=$?"`
Expected: exit 0.

- [ ] **Step 3: Commit (in wt-lending); deploy together with Task 7's live gate**

```bash
cd ~/PhpstormProjects/wt-lending
git add src/worker.js
git commit -m "feat: hide manifest/ keys from the /p/ listing page"
```

---

### Task 7: Manual gate — Cloudflare service token, profile keys, live validation

Owner-run checklist (nothing here lands in any repo; `.env.corp` is gitignored on the build machine). Preserve the `assets.run_worker_first: ["/p", "/p/*"]` key if `wrangler.jsonc` is touched — removing it re-pins the edge-cached 404.

- [ ] **Step 1: Create the service token.** Cloudflare Zero Trust dashboard → Access → Service Auth → Service Tokens → Create: name `wt-update-corp`, longest available duration. Record Client ID + Client Secret (secret is shown once). NOTE: service tokens expire — put a calendar reminder to extend it before expiry; an expired token = corp builds silently stop updating (they will show the auth error state).
- [ ] **Step 2: Allow the token on the /p/ Access app.** Zero Trust → Access → Applications → the /p/ app → add a policy: action **Service Auth**, include → Service Token → `wt-update-corp`. Keep the existing email-OTP Allow policy for humans.
- [ ] **Step 3: Verify the gate from curl.**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "CF-Access-Client-Id: <id>" -H "CF-Access-Client-Secret: <secret>" \
  https://<gated-host>/p/dl/manifest/corp.json
# Expected: 404 until the first manifest is published (worker fail-closed serves
# real 404 only AFTER auth passes; a 302 here means the policy isn't matching).
```

- [ ] **Step 4: Deploy the worker** (Task 6): `cd ~/PhpstormProjects/wt-lending && npx wrangler deploy`.
- [ ] **Step 5: Add the three keys to `.env.corp`** on the build machine: `WATCHTOWER_UPDATE_FEED_URL=https://<gated-host>/p`, `WATCHTOWER_UPDATE_CLIENT_ID=…`, `WATCHTOWER_UPDATE_CLIENT_SECRET=…`.
- [ ] **Step 6: Build + publish a corp release.** Back up any previous flavor artifacts in `build/` first (each `make app` run wipes `build/`). `ENV_FILE=.env.corp make app`, then `cd ~/PhpstormProjects/wt-lending && scripts/publish-build.sh --version <V> --flavor corp <dmg> <zip>` with the artifacts from `watchtower/build/`.
- [ ] **Step 7: Live validation on the installed corp app** (must be an older version than the published one): Settings → Update → Check for Updates → Download → Install & Restart. Verify: the app relaunches on the new version; `codesign -dv` still shows the Team ID; the /p/ listing shows no `manifest/` rows; an anonymous browser still gets 404 on /p/.

---

## Final gate (watchtower repo, before PR)

- [ ] `make test-swift FILTER=UpdateChannelTests` and `FILTER=UpdateServicePureTests` — green.
- [ ] `make lint-diff` — clean.
- [ ] Full pre-PR gate (`make test`, `make test-swift`, `make lint-all`) per CLAUDE.md before opening the PR.
