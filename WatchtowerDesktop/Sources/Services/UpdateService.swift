import Foundation
import AppKit
import CryptoKit
import Security
import WatchtowerCore

/// Handles checking for updates via GitHub Releases API, downloading, and installing.
@MainActor
@Observable
final class UpdateService {
    enum UpdateState: Equatable {
        case idle
        case checking
        case available(version: String, notes: String, downloadURL: URL)
        case downloading(progress: Double)
        case readyToInstall(appPath: URL)
        case installing
        /// The bundle was replaced but the app did not quit (the quit was
        /// cancelled or is stuck): a manual restart finishes the update.
        case restartRequired
        case error(String)
    }

    /// Which feed this build updates from. Resolved from the build flavor and
    /// the channel keys stamped into Info.plist by build-app.sh. `disabled`
    /// covers dev builds and flavored builds whose profile carried no channel
    /// keys — those must fail closed, never fall back to the public feed.
    enum UpdateChannel: Equatable {
        case publicGitHub
        case gated(feedURL: URL, clientID: String, clientSecret: String)
        case disabled
    }

    var state: UpdateState = .idle

    var isUpdateAvailable: Bool {
        if case .available = state { return true }
        if case .readyToInstall = state { return true }
        return false
    }

    // MARK: - Channel Routing & Helpers

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

    private static let repo = "aiwatchtowers/watchtower"

    /// Build flavor stamped into Info.plist by build-app.sh (WTBuildFlavor;
    /// absent on default builds). A flavored build carries a different baked-in
    /// credential set and is distributed out-of-band, so it must never update
    /// from the public release feed — every public release would silently
    /// replace it with the default-credential build (same signer, so the
    /// Team-ID pin would pass). Gated-channel keys route flavored builds to
    /// their own update feed instead of disabling updates outright.
    /// Instance property so tests can inject a flavor.
    var buildFlavor: String =
        (Bundle.main.object(forInfoDictionaryKey: "WTBuildFlavor") as? String) ?? ""

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
    struct GatedDownloadContext: Equatable {
        let sha256: String
        let clientID: String
        let clientSecret: String
    }
    private var gatedDownload: GatedDownloadContext?

    private static let cacheDir: URL = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("com.watchtower.desktop/updates", isDirectory: true)
        }
        return caches.appendingPathComponent("com.watchtower.desktop/updates", isDirectory: true)
    }()

    // MARK: - Check for Updates

    /// What one check of the channel found, before it touches any state.
    enum CheckResult: Equatable {
        case upToDate
        case found(version: String, notes: String, downloadURL: URL, gated: GatedDownloadContext?)
        case failed(String)
    }

    /// Fetches what the channel offers. Nil = the real network fetch; tests
    /// inject a canned result.
    var fetchCheck: (() async -> CheckResult)?

    /// Check the channel. `background` marks the unattended periodic check:
    /// its failures are logged but leave Settings idle instead of red (a
    /// manual "Check for Updates" still shows the error), and it keeps an
    /// already-found update visible while it runs.
    func checkForUpdates(background: Bool = false) async {
        guard channel != .disabled else {
            state = .idle
            return
        }
        let previous = state
        if case .available = previous, background {
            // Keep offering the known update while the re-check runs.
        } else {
            state = .checking
        }
        let inFlight = state
        let result: CheckResult
        if let fetchCheck {
            result = await fetchCheck()
        } else {
            result = await fetchFromChannel()
        }
        // The user moved on meanwhile (e.g. started the download): a late
        // result must not overwrite that.
        guard state == inFlight else { return }
        applyCheckResult(result, previous: previous, background: background)
    }

    /// Fold a check result into the state. An update already on offer is only
    /// replaced by a strictly newer one, and never by an error or an
    /// "up to date" — a transient failure must not hide a found update.
    func applyCheckResult(_ result: CheckResult, previous: UpdateState, background: Bool) {
        switch result {
        case .upToDate:
            if case .available = previous {
                state = previous
                return
            }
            state = .idle
            availableVersion = nil
        case let .found(version, notes, downloadURL, gated):
            if case .available(let known, _, _) = previous, !Self.isNewer(version, than: known) {
                state = previous
                return
            }
            gatedDownload = gated
            state = .available(version: version, notes: notes, downloadURL: downloadURL)
            noteAvailable(version: version)
        case .failed(let message):
            NSLog("UpdateService: %@ update check failed: %@", background ? "background" : "manual", message)
            if case .available = previous {
                state = previous
                return
            }
            state = background ? .idle : .error(message)
        }
    }

    private func fetchFromChannel() async -> CheckResult {
        switch channel {
        case .disabled:
            return .upToDate
        case .publicGitHub:
            return await fetchPublic()
        case let .gated(feedURL, clientID, clientSecret):
            return await fetchGated(feedURL: feedURL, clientID: clientID, clientSecret: clientSecret)
        }
    }

    private func fetchPublic() async -> CheckResult {
        do {
            let release = try await fetchLatestRelease()
            guard Self.isNewer(release.tagName, than: Constants.appVersion) else { return .upToDate }

            let expected = Self.expectedPublicAssetName(forTag: release.tagName)
            guard let asset = release.assets.first(where: { $0.name == expected }) else {
                return .failed("No asset named \(expected) in release \(release.tagName)")
            }
            guard let url = URL(string: asset.browserDownloadURL) else {
                return .failed("Invalid download URL")
            }
            return .found(version: release.tagName, notes: release.body ?? "", downloadURL: url, gated: nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func fetchGated(feedURL: URL, clientID: String, clientSecret: String) async -> CheckResult {
        do {
            let manifestURL = feedURL.appendingPathComponent("dl/manifest/\(buildFlavor).json")
            let data = try await gatedGET(manifestURL, clientID: clientID, clientSecret: clientSecret)
            guard let manifest = try? JSONDecoder().decode(GatedManifest.self, from: data) else {
                return .failed("Update manifest is malformed")
            }
            guard Self.zipKeyMatchesFlavor(manifest.zipKey, flavor: buildFlavor) else {
                return .failed("Update manifest points at a different build flavor (\(manifest.zipKey))")
            }
            guard Self.isNewer(manifest.version, than: Constants.appVersion) else { return .upToDate }

            let context = GatedDownloadContext(
                sha256: manifest.sha256, clientID: clientID, clientSecret: clientSecret
            )
            return .found(
                version: manifest.version,
                notes: manifest.notes ?? "",
                downloadURL: feedURL.appendingPathComponent("dl/\(manifest.zipKey)"),
                gated: context
            )
        } catch {
            return .failed(error.localizedDescription)
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

    // MARK: - Periodic Checks

    /// How often a running app re-checks its channel. The app lives in the
    /// tray for weeks (login item), so a launch-only check never announces
    /// anything. 6 h, not hourly: the public channel hits the unauthenticated
    /// GitHub API (60 requests/hour per IP, shared behind an office NAT).
    nonisolated static let checkInterval: Duration = .seconds(6 * 60 * 60)

    private static let lastAnnouncedVersionKey = "lastAnnouncedUpdateVersion"

    /// Where the announced-version memo lives. Instance property so tests can
    /// inject an isolated suite.
    var defaults: UserDefaults = .standard

    /// Posts the one "update available" notification for a version.
    /// Instance property so tests can record instead of posting.
    var announce: (String) -> Void = { NotificationService.shared.sendUpdateAvailableNotification(version: $0) }

    /// Version of the update the last check found; nil when none. Survives
    /// `.downloading`/`.readyToInstall`, which carry no version of their own.
    private(set) var availableVersion: String?

    /// The periodic-check loop; nil once it has ended. Readable so tests can
    /// await it.
    private(set) var periodicTask: Task<Void, Never>?

    var isPeriodicCheckRunning: Bool { periodicTask != nil }

    /// Check now (every launch — no throttle), then every `checkInterval`
    /// while the app runs. Idempotent. A build without an update channel
    /// starts nothing at all.
    func startPeriodicChecks(
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        guard updatesSupported, periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                // `self?` per call: no strong reference is held across the sleep.
                await self?.runBackgroundCheck()
                do { try await sleep(Self.checkInterval) } catch { break }
            }
            self?.periodicTask = nil
        }
    }

    private func runBackgroundCheck() async {
        guard Self.shouldAutoCheck(state: state) else { return }
        await checkForUpdates(background: true)
    }

    /// Whether a background check may run now. Never while a check, download
    /// or install is in flight (the check would overwrite that state). It
    /// does run while an update is on offer, so a newer release replaces a
    /// stale one (`applyCheckResult` keeps the offer on anything else).
    nonisolated static func shouldAutoCheck(state: UpdateState) -> Bool {
        switch state {
        case .idle, .error, .available: true
        case .checking, .downloading, .readyToInstall, .installing, .restartRequired: false
        }
    }

    /// One notification per version, ever: the memo outlives relaunches so a
    /// check every launch does not repeat the same push.
    nonisolated static func shouldAnnounce(version: String, lastAnnounced: String?) -> Bool {
        version != lastAnnounced
    }

    /// Record a found update and announce it once per version.
    func noteAvailable(version: String) {
        availableVersion = version
        let last = defaults.string(forKey: Self.lastAnnouncedVersionKey)
        guard Self.shouldAnnounce(version: version, lastAnnounced: last) else { return }
        defaults.set(version, forKey: Self.lastAnnouncedVersionKey)
        announce(version)
    }

    // MARK: - Download

    func downloadUpdate() async {
        guard case .available(_, _, let downloadURL) = state else { return }

        state = .downloading(progress: 0)

        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)

            // Clean previous downloads
            let zipPath = Self.cacheDir.appendingPathComponent("update.zip")
            let extractDir = Self.cacheDir.appendingPathComponent("extracted")
            try? fm.removeItem(at: zipPath)
            try? fm.removeItem(at: extractDir)

            // Download with progress
            let (localURL, _) = try await downloadWithProgress(from: downloadURL)

            try fm.moveItem(at: localURL, to: zipPath)

            if let ctx = gatedDownload {
                let actual = try Self.sha256Hex(ofFileAt: zipPath)
                guard actual.caseInsensitiveCompare(ctx.sha256) == .orderedSame else {
                    try? fm.removeItem(at: zipPath)
                    state = .error(GatedChannelError.checksumMismatch.localizedDescription)
                    return
                }
            }

            state = .downloading(progress: 0.9)

            // Extract using ditto (handles macOS resource forks correctly)
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
            let exitCode = try await runProcess(
                path: "/usr/bin/ditto",
                arguments: ["-xk", zipPath.path, extractDir.path]
            )
            guard exitCode == 0 else {
                state = .error("Failed to extract update (exit \(exitCode))")
                return
            }

            // Find the .app inside extracted directory
            guard let appName = try fm.contentsOfDirectory(atPath: extractDir.path)
                .first(where: { $0.hasSuffix(".app") }) else {
                state = .error("No .app found in downloaded archive")
                return
            }

            let appPath = extractDir.appendingPathComponent(appName)
            state = .readyToInstall(appPath: appPath)
        } catch {
            state = .error("Download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Install

    /// How the install ended, before the relaunch. Split out of `install()` so
    /// the failure mapping is pinned by tests without touching a real bundle.
    enum InstallOutcome: Equatable {
        case installed
        case failed(String)
    }

    /// The side-effecting steps of an install, injectable for tests. `live`
    /// is the only production value. Sendable: they run off the main actor.
    struct InstallSteps: Sendable {
        /// Whether the folder holding the current app can be written to.
        var canWrite: @Sendable (_ folder: URL) -> Bool
        /// Move the downloaded app next to the current one (same volume, so
        /// the swap is a rename); returns the staged app's URL.
        var stage: @Sendable (_ newApp: URL, _ currentApp: URL) throws -> URL
        /// Throws when the staged app's signature is invalid or not ours.
        var verify: @Sendable (_ app: URL, _ teamID: String) throws -> Void
        /// Atomically swap the staged app in for the current one.
        var replace: @Sendable (_ currentApp: URL, _ stagedApp: URL) throws -> Void
        /// Best-effort removal of whatever is left of the staged app.
        var discard: @Sendable (_ stagedApp: URL) -> Void

        static var live: Self {
            Self(
                canWrite: { FileManager.default.isWritableFile(atPath: $0.path) },
                stage: { try UpdateService.stageForReplacement(newApp: $0, currentApp: $1) },
                verify: { try UpdateService.verifySignature(of: $0, teamID: $1) },
                replace: { current, staged in
                    _ = try FileManager.default.replaceItemAt(current, withItemAt: staged, backupItemName: nil, options: [])
                },
                // The staged app sits alone in its item-replacement directory.
                discard: { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
            )
        }
    }

    /// Replace the running app's bundle with the downloaded one, entirely
    /// in-process. The old flow handed the swap to a `/bin/sh` script that ran
    /// after Watchtower exited; macOS App Management then saw an unrelated
    /// process modifying an app bundle, blocked it with a TCC prompt, and the
    /// UI sat on "Installing…" forever. Done here, the modifier is Watchtower
    /// itself — signed by the same Team ID as the bundle it replaces — which
    /// App Management allows. Every failure lands in `.error` and leaves the
    /// current app untouched.
    func install() async {
        guard case .readyToInstall(let newAppPath) = state else { return }
        // Same gate as the quit path's "recording in progress" confirmation,
        // but before the swap: once the bundle is replaced, cancelling that
        // dialog can no longer cancel the update, and the still-running old
        // app would spawn the new bundle's CLI.
        guard !isBusy() else {
            NSLog("UpdateService: install refused: a recording or transcription is busy")
            state = .error(Self.busyMessage)
            return
        }
        guard let currentApp = currentAppURL() else {
            NSLog("UpdateService: install refused: not running from an app bundle")
            state = .error("Cannot determine current app location")
            return
        }

        state = .installing
        // Staging, the deep signature check (it hashes the whole bundle) and
        // the swap are file-system work: run them off the main actor so the
        // "Installing…" spinner keeps spinning.
        let teamID = teamIdentifier()
        let steps = installSteps
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.performInstall(newApp: newAppPath, currentApp: currentApp, teamID: teamID, steps: steps)
        }.value
        guard outcome == .installed else {
            if case .failed(let message) = outcome {
                NSLog("UpdateService: install failed: %@", message)
                state = .error(message)
            }
            return
        }
        try? FileManager.default.removeItem(at: Self.cacheDir)
        await relaunch()
    }

    /// Relaunch into the freshly installed bundle: a detached waiter reopens
    /// the app once this process has exited, then the app quits through the
    /// normal quit path. The quit can be refused (the recording-in-progress
    /// confirmation) — past `quitGrace` the bundle is already replaced, so the
    /// UI says so instead of spinning on "Installing…".
    func relaunch() async {
        guard let currentApp = currentAppURL() else {
            NSLog("UpdateService: no app bundle to relaunch; a manual restart finishes the update")
            state = .restartRequired
            return
        }
        do {
            try relaunchSteps.spawn(ProcessInfo.processInfo.processIdentifier, currentApp.path)
        } catch {
            // Never quit without a waiter: the app would close and not come back.
            NSLog("UpdateService: could not start the relaunch waiter: %@", error.localizedDescription)
            state = .restartRequired
            return
        }
        state = .installing
        relaunchSteps.requestQuit()
        await relaunchSteps.sleep(Self.quitGrace)
        // Still alive: the quit was cancelled or is still stuck.
        NSLog("UpdateService: app did not quit within %ld s of the update; a manual restart finishes it",
              Int(Self.quitGrace.components.seconds))
        state = .restartRequired
    }

    /// The relaunch's side effects, injectable for tests.
    @MainActor
    struct RelaunchSteps {
        /// Start the detached waiter that reopens the app after `pid` exits.
        var spawn: (_ pid: pid_t, _ appPath: String) throws -> Void
        /// Quit through the app's normal quit path.
        var requestQuit: () -> Void
        /// Wait up to `quitGrace` for the quit to take effect.
        var sleep: (Duration) async -> Void

        static var live: Self {
            Self(
                spawn: { try UpdateService.spawnRelaunchWaiter(pid: $0, appPath: $1) },
                requestQuit: { TrayAppDelegate.requestQuit() },
                sleep: { try? await Task.sleep(for: $0) }
            )
        }
    }

    var relaunchSteps: RelaunchSteps = .live

    /// The running app's bundle; nil outside a `.app` (e.g. `swift test`).
    var currentAppURL: () -> URL? = { UpdateService.currentAppBundleURL() }

    /// The running app's Team ID, read from its own signature.
    var teamIdentifier: () -> String? = { UpdateService.currentTeamIdentifier() }

    nonisolated static let busyMessage =
        "Finish the recording or transcription in progress, then install the update."

    /// True while a meeting capture or transcription job is running. Installs
    /// wait for it. Instance property so tests can inject it.
    var isBusy: () -> Bool = { AppState.shared.meetingRecorderCenter.isBusy }

    /// The install's side-effecting steps; tests inject recorders.
    var installSteps: InstallSteps = .live

    /// How long `relaunch` waits for the app to actually quit before telling
    /// the user to restart by hand. Covers the quit path's own bounded work
    /// (chat sessions, terminals, the 12 s daemon stop).
    nonisolated static let quitGrace: Duration = .seconds(30)

    /// How long the relaunch waiter keeps waiting for this process to exit
    /// (in 0.2 s ticks). Bounded so a quit the user cancelled does not
    /// reopen the app out of the blue hours later.
    nonisolated static let relaunchWaiterTicks = 600

    /// The install sequence over injectable steps: pin the signer, check the
    /// destination is writable, stage, verify, swap. Nothing destructive
    /// happens before the staged app has passed verification, and a failure
    /// at any step leaves the current bundle as it was.
    ///
    /// The daemon is deliberately not stopped here: it runs from the
    /// `CLIBinaryStore` copy, not from the bundle, and the relaunch's quit
    /// path (then the new app's store sync) stops it. Stopping it here would
    /// leave sync dead for the session whenever the swap then failed, and
    /// would put an `await` between verify and swap, the window in which a
    /// verified staged bundle could be exchanged before this trusted process
    /// moves it into place. Verify and replace run back to back.
    nonisolated static func performInstall(
        newApp: URL,
        currentApp: URL,
        teamID: String?,
        steps: InstallSteps
    ) -> InstallOutcome {
        // Pin the replacement's signature to the Team ID of the running app.
        // Without it, verification only proves that *some* signature is valid
        // — an ad-hoc or third-party signed download would pass too. Fail
        // closed: no Team ID (ad-hoc-signed build) → refuse.
        guard let teamID = validTeamIdentifier(teamID) else {
            return .failed("Update aborted: could not determine the running app's Team ID (ad-hoc-signed build). "
                + "Refusing to install an update that can't be verified against a known signer.")
        }

        let folder = currentApp.deletingLastPathComponent()
        guard steps.canWrite(folder) else {
            return .failed("Watchtower can't replace itself in “\(folder.path)” (no write permission). "
                + "Move Watchtower to a folder you can write to, or install the update manually from the DMG.")
        }

        let staged: URL
        do {
            staged = try steps.stage(newApp, currentApp)
        } catch {
            return .failed("Could not prepare the update: \(error.localizedDescription)")
        }

        do {
            try steps.verify(staged, teamID)
        } catch {
            steps.discard(staged)
            return .failed("Update aborted: \(error.localizedDescription)")
        }

        do {
            try steps.replace(currentApp, staged)
        } catch {
            steps.discard(staged)
            return .failed("Could not replace the app: \(error.localizedDescription)")
        }
        steps.discard(staged)
        return .installed
    }

    /// Move the downloaded app into an item-replacement directory on the
    /// current bundle's volume (so `replaceItemAt` is a same-volume swap) and
    /// strip its download quarantine. Returns the staged app's URL.
    nonisolated static func stageForReplacement(newApp: URL, currentApp: URL) throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                             appropriateFor: currentApp, create: true)
        let staged = dir.appendingPathComponent(currentApp.lastPathComponent, isDirectory: true)
        do {
            try fm.moveItem(at: newApp, to: staged)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        stripQuarantine(at: staged)
        return staged
    }

    /// Recursively remove `com.apple.quarantine` (what the old script's
    /// `xattr -dr` did). Best-effort: a file without the attribute is the
    /// normal case, and a leftover attribute only costs a Gatekeeper check.
    nonisolated static func stripQuarantine(at root: URL) {
        let name = "com.apple.quarantine"
        let remove: (URL) -> Void = { url in
            _ = url.withUnsafeFileSystemRepresentation { path in
                path.map { removexattr($0, name, XATTR_NOFOLLOW) }
            }
        }
        remove(root)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker { remove(url) }
    }

    /// Code-signing checks for the replacement bundle — the in-process
    /// equivalent of `codesign --verify --deep --strict`.
    nonisolated static let signatureValidationFlags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode
    )

    struct SignatureError: LocalizedError, Equatable {
        let step: String
        let status: OSStatus
        var errorDescription: String? {
            "code signature check failed (\(step), OSStatus \(status)) — invalid signature or a different signer"
        }
    }

    /// Throws unless `app` carries a valid signature satisfying the Team-ID
    /// designated requirement for `teamID`.
    nonisolated static func verifySignature(of app: URL, teamID: String) throws {
        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(designatedRequirement(forTeamID: teamID) as CFString, [], &requirement)
        guard reqStatus == errSecSuccess, let requirement else {
            throw SignatureError(step: "requirement", status: reqStatus)
        }
        var staticCode: SecStaticCode?
        let codeStatus = SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode)
        guard codeStatus == errSecSuccess, let staticCode else {
            throw SignatureError(step: "read", status: codeStatus)
        }
        let status = SecStaticCodeCheckValidity(staticCode, signatureValidationFlags, requirement)
        guard status == errSecSuccess else { throw SignatureError(step: "validate", status: status) }
    }

    /// Detached waiter that reopens the app once `pid` has exited. It only
    /// runs `open` — it never touches files, so no App Management prompt.
    nonisolated static func spawnRelaunchWaiter(pid: pid_t, appPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = relaunchWaiterArguments(pid: pid, appPath: appPath)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// `/bin/sh` arguments for the relaunch waiter: poll for `pid`'s exit (at
    /// most `relaunchWaiterTicks` × 0.2 s), then `open` the app. The app has
    /// exited by the time anything goes wrong here, so a timeout or a failed
    /// `open` goes to the system log (`log show --predicate 'senderImagePath
    /// ENDSWITH "logger"'`, tag `watchtower-update`) instead of /dev/null.
    nonisolated static func relaunchWaiterArguments(pid: pid_t, appPath: String) -> [String] {
        let log = "/usr/bin/logger -t \(relaunchLogTag)"
        let script = "i=0; while kill -0 \(pid) 2>/dev/null; do "
            + "i=$((i+1)); if [ \"$i\" -ge \(relaunchWaiterTicks) ]; then "
            + "\(log) \"relaunch waiter gave up: the app did not quit\"; exit 0; fi; sleep 0.2; done; "
            + "/usr/bin/open \"\(shellEscape(appPath))\" || \(log) \"relaunch failed: open exited $?\""
        return ["-c", script]
    }

    nonisolated static let relaunchLogTag = "watchtower-update"

    /// Escape a string for safe use inside double-quoted shell strings.
    /// Only the four characters special inside double quotes need escaping: " \ ` $
    nonisolated static func shellEscape(_ s: String) -> String {
        var result = ""
        for ch in s {
            switch ch {
            case "\"", "\\", "`", "$":
                result.append("\\")
                result.append(ch)
            default:
                result.append(ch)
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func currentAppBundleURL() -> URL? {
        // Bundle.main.bundleURL points to Watchtower.app/
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return nil }
        return bundleURL
    }

    /// A Team ID usable in a designated requirement: exactly 10 alphanumeric
    /// characters (Apple's format). Anything else — nil, empty, "not set",
    /// stray quotes — is rejected, so no unexpected character ever reaches
    /// the requirement string.
    nonisolated static func validTeamIdentifier(_ value: String?) -> String? {
        guard let value, value.range(of: "^[A-Za-z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    /// Build a code-signing designated-requirement string pinning
    /// verification to a specific Team ID.
    nonisolated static func designatedRequirement(forTeamID teamID: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Team ID of the running app, read in-process from its own code
    /// signature. Nil for ad-hoc-signed builds with no Team ID.
    private static func currentTeamIdentifier() -> String? {
        CLIBinaryStore.runningTeamIdentifier()
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let urlString = "https://api.github.com/repos/\(Self.repo)/releases/latest"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Watchtower/\(Constants.appVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UpdateError.httpError(code)
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

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
            if let err = Self.classifyGatedStatus(status) {
                try? FileManager.default.removeItem(at: localURL)
                throw err
            }
        }
        await MainActor.run { state = .downloading(progress: 0.8) }
        return (localURL, response)
    }

    nonisolated private func runProcess(path: String, arguments: [String]) async throws -> Int32 {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }

    /// Compare semantic versions. Returns true if `new` is strictly greater than `current`.
    nonisolated static func isNewer(_ new: String, than current: String) -> Bool {
        let parse: (String) -> [Int] = { version in
            let cleaned = version.hasPrefix("v") ? String(version.dropFirst()) : version
            return cleaned.split(separator: ".").compactMap { Int($0) }
        }
        let newParts = parse(new)
        let currentParts = parse(current)

        for i in 0..<max(newParts.count, currentParts.count) {
            let nv = i < newParts.count ? newParts[i] : 0
            let cv = i < currentParts.count ? currentParts[i] : 0
            if nv > cv { return true }
            if nv < cv { return false }
        }
        return false
    }
}

// MARK: - Models

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
    }
}

struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

enum UpdateError: LocalizedError {
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            "GitHub API returned status \(code)"
        }
    }
}

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

// MARK: - Redirect Blocker

/// Refuses HTTP redirects so a Cloudflare Access login bounce surfaces as its
/// 3xx status instead of the login page's HTML.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}
