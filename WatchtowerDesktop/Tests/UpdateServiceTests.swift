import Foundation
import Security
import Testing
@testable import WatchtowerDesktop

/// Collects a launch step's log lines across threads.
private final class LockedReports: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var items: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}

/// The channel of an install the company bridge has not migrated.
private func unmigrated(
    flavor: String, feedURL: String?, clientID: String?, clientSecret: String?
) -> UpdateService.UpdateChannel {
    UpdateService.resolveChannel(
        flavor: flavor, feedURL: feedURL, clientID: clientID, clientSecret: clientSecret, companyMigrated: false
    )
}

@Suite("UpdateService Pure Helpers")
struct UpdateServicePureTests {
    @Test("isNewer compares semantic versions")
    func isNewerBasic() {
        #expect(UpdateService.isNewer("1.0.1", than: "1.0.0"))
        #expect(UpdateService.isNewer("2.0.0", than: "1.99.99"))
        #expect(UpdateService.isNewer("1.10.0", than: "1.9.0"))
        #expect(!UpdateService.isNewer("1.0.0", than: "1.0.0"))
        #expect(!UpdateService.isNewer("1.0.0", than: "1.0.1"))
    }

    @Test("isNewer strips leading v")
    func isNewerStripsV() {
        #expect(UpdateService.isNewer("v1.2.0", than: "v1.1.0"))
        #expect(UpdateService.isNewer("v1.0.1", than: "1.0.0"))
        #expect(!UpdateService.isNewer("v1.0.0", than: "v1.0.0"))
    }

    @Test("isNewer handles missing patch component")
    func isNewerMissingComponent() {
        #expect(UpdateService.isNewer("1.1", than: "1.0.5"))
        #expect(!UpdateService.isNewer("1.0", than: "1.0.0"))
    }

    @Test("isNewer ignores garbage and treats it as zero")
    func isNewerGarbage() {
        // Non-numeric components are dropped by compactMap(Int.init).
        #expect(!UpdateService.isNewer("not-a-version", than: "1.0.0"))
    }

    @Test("UpdateState equality")
    func stateEquality() {
        let a = UpdateService.UpdateState.idle
        let b = UpdateService.UpdateState.idle
        #expect(a == b)

        let url = URL(string: "https://example.com")!
        let c = UpdateService.UpdateState.available(version: "1.0", notes: "x", downloadURL: url)
        let d = UpdateService.UpdateState.available(version: "1.0", notes: "x", downloadURL: url)
        #expect(c == d)

        let e = UpdateService.UpdateState.error("boom")
        let f = UpdateService.UpdateState.error("other")
        #expect(e != f)
    }

    @Test("flavored build never consults the public release feed")
    func flavoredBuildSkipsUpdateCheck() async {
        // A flavored build carries a different baked-in credential set; picking
        // up a public-feed release would silently swap it for the default one.
        let svc = await UpdateService()
        await MainActor.run { svc.buildFlavor = "b2" }
        await svc.checkForUpdates()
        await MainActor.run { #expect(svc.state == .idle) }
    }

    @Test("isUpdateAvailable reflects state")
    func updateAvailable() async {
        await MainActor.run {
            let svc = UpdateService()
            #expect(!svc.isUpdateAvailable)

            svc.state = .available(version: "1.0", notes: "", downloadURL: URL(string: "https://x")!)
            #expect(svc.isUpdateAvailable)

            svc.state = .readyToInstall(appPath: URL(fileURLWithPath: "/tmp/x"))
            #expect(svc.isUpdateAvailable)

            svc.state = .checking
            #expect(!svc.isUpdateAvailable)

            svc.state = .error("nope")
            #expect(!svc.isUpdateAvailable)
        }
    }

    @Test("GitHubRelease decodes snake_case keys")
    func decodeRelease() throws {
        let json = Data("""
        {
            "tag_name": "v1.2.3",
            "name": "Release 1.2.3",
            "body": "## Notes\\n- bugfix",
            "assets": [
                {"name":"Watchtower.app.zip","browser_download_url":"https://gh/x.zip","size":12345}
            ]
        }
        """.utf8)

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        #expect(release.tagName == "v1.2.3")
        #expect(release.name == "Release 1.2.3")
        #expect(release.body?.contains("bugfix") == true)
        #expect(release.assets.count == 1)
        #expect(release.assets[0].name == "Watchtower.app.zip")
        #expect(release.assets[0].browserDownloadURL == "https://gh/x.zip")
        #expect(release.assets[0].size == 12345)
    }

    @Test("GitHubRelease tolerates missing optional fields")
    func decodeReleaseMinimal() throws {
        let json = Data("""
        {"tag_name":"v0.1.0","assets":[]}
        """.utf8)

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        #expect(release.tagName == "v0.1.0")
        #expect(release.name == nil)
        #expect(release.body == nil)
        #expect(release.assets.isEmpty)
    }

    @Test("UpdateError httpError surfaces status code")
    func updateErrorMessage() {
        let err = UpdateError.httpError(503)
        #expect(err.errorDescription?.contains("503") == true)
        #expect(err.errorDescription?.contains("GitHub API") == true)
    }

    @Test("designatedRequirement embeds the Team ID")
    func designatedRequirementFormat() {
        let req = UpdateService.designatedRequirement(forTeamID: "ABCDE12345")
        #expect(req == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }

    @Test("validTeamIdentifier accepts exactly ten alphanumerics")
    func validTeamIdentifierAccepts() {
        #expect(UpdateService.validTeamIdentifier("ABCDE12345") == "ABCDE12345")
    }

    @Test("validTeamIdentifier rejects absent, unset and malformed values")
    func validTeamIdentifierRejects() {
        // Guards against embedding unexpected characters into the requirement.
        #expect(UpdateService.validTeamIdentifier(nil) == nil)
        #expect(UpdateService.validTeamIdentifier("") == nil)
        #expect(UpdateService.validTeamIdentifier("not set") == nil)
        #expect(UpdateService.validTeamIdentifier("abc") == nil)
        #expect(UpdateService.validTeamIdentifier("ABCDE123456") == nil)
        #expect(UpdateService.validTeamIdentifier("ABCDE\"1234") == nil)
    }
}

@Suite("UpdateService Channel Routing")
struct UpdateChannelTests {
    @Test("public flavor routes to GitHub")
    func publicChannel() {
        #expect(unmigrated(flavor: "", feedURL: nil, clientID: nil, clientSecret: nil) == .publicGitHub)
        // Even with stray keys present, a flavorless build stays on GitHub.
        #expect(unmigrated(flavor: "", feedURL: "https://x", clientID: "a", clientSecret: "b") == .publicGitHub)
    }

    @Test("dev flavor never updates, keys or not")
    func devDisabled() {
        #expect(unmigrated(flavor: "dev", feedURL: nil, clientID: nil, clientSecret: nil) == .disabled)
        #expect(unmigrated(flavor: "dev", feedURL: "https://feed.example", clientID: "a", clientSecret: "b") == .disabled)
    }

    @Test("flavored build without complete keys is disabled — never falls back to public")
    func flavoredMissingKeys() {
        #expect(unmigrated(flavor: "corp", feedURL: nil, clientID: nil, clientSecret: nil) == .disabled)
        #expect(unmigrated(flavor: "corp", feedURL: "https://feed.example", clientID: "a", clientSecret: nil) == .disabled)
        #expect(unmigrated(flavor: "corp", feedURL: "https://feed.example", clientID: "", clientSecret: "b") == .disabled)
        #expect(unmigrated(flavor: "corp", feedURL: nil, clientID: "a", clientSecret: "b") == .disabled)
    }

    @Test("flavored build with full keys gets the gated channel")
    func flavoredGated() {
        let ch = unmigrated(flavor: "corp", feedURL: "https://feed.example/p", clientID: "id", clientSecret: "sec")
        #expect(ch == .gated(feedURL: URL(string: "https://feed.example/p")!, clientID: "id", clientSecret: "sec"))
    }

    @Test("corp build stays gated until the company bridge has migrated it (#1887 §5)")
    func corpStaysGatedUntilMigrated() {
        let gated = UpdateService.resolveChannel(
            flavor: "corp", feedURL: "https://feed.example/p", clientID: "id", clientSecret: "sec", companyMigrated: false
        )
        #expect(gated == .gated(feedURL: URL(string: "https://feed.example/p")!, clientID: "id", clientSecret: "sec"))
        #expect(UpdateService.resolveChannel(
            flavor: "corp", feedURL: nil, clientID: nil, clientSecret: nil, companyMigrated: false
        ) == .disabled)
    }

    @Test("a migrated corp build may take the public feed; dev never updates")
    func corpMayTakePublicFeedAfterMigrated() {
        #expect(UpdateService.resolveChannel(
            flavor: "corp", feedURL: "https://feed.example/p", clientID: "id", clientSecret: "sec", companyMigrated: true
        ) == .publicGitHub)
        #expect(UpdateService.resolveChannel(
            flavor: "corp", feedURL: nil, clientID: nil, clientSecret: nil, companyMigrated: true
        ) == .publicGitHub)
        #expect(UpdateService.resolveChannel(
            flavor: "dev", feedURL: nil, clientID: nil, clientSecret: nil, companyMigrated: true
        ) == .disabled)
    }

    @Test("the service reads the marker only for a flavored build")
    func serviceReadsMarker() async {
        await MainActor.run {
            let svc = UpdateService()
            var reads = 0
            svc.companyMigrated = { reads += 1; return true }
            svc.buildFlavor = ""
            #expect(svc.channel == .publicGitHub)
            svc.buildFlavor = "dev"
            #expect(svc.channel == .disabled)
            #expect(reads == 0)
            svc.buildFlavor = "corp"
            #expect(svc.channel == .publicGitHub)
            #expect(reads == 1)
            svc.companyMigrated = { false }
            #expect(svc.channel == .disabled, "no gated keys and not migrated")
        }
    }

    @Test("the bridge runs only on a flavored build other than dev")
    func bridgeAppliesToCorpOnly() throws {
        #expect(!CompanyBridgeLaunch.applies(flavor: ""))
        #expect(!CompanyBridgeLaunch.applies(flavor: "dev"))
        #expect(CompanyBridgeLaunch.applies(flavor: "corp"))
        var ran = false
        let tracked = CompanyBridgeLaunch.launchStep(cliPath: { ran = true; return nil }()) { _ in }
        #expect(CompanyBridgeLaunch.runActive(flavor: "", step: tracked))
        #expect(CompanyBridgeLaunch.runAll(flavor: "dev", step: tracked))
        #expect(!ran, "the public and dev builds never resolve the CLI")

        let reports = LockedReports()
        let missing = CompanyBridgeLaunch.launchStep(cliPath: nil) { reports.append($0) }
        #expect(!CompanyBridgeLaunch.runActive(flavor: "corp", step: missing))
        #expect(reports.items == ["Company bridge skipped: the watchtower CLI was not found"])
    }

    @Test("the launch bridges the active workspace in 30 s, the others after it in 300 s, the install all of them")
    func bridgeRunsForEveryWorkspace() throws {
        let base = try makeWorkspaces(["alpha", "beta", "gamma"])
        defer { try? FileManager.default.removeItem(atPath: base) }
        // A directory without a database is not a workspace to bridge.
        try FileManager.default.createDirectory(atPath: "\(base)/empty", withIntermediateDirectories: true)
        var calls: [[String]] = []
        var timeouts: [Int] = []
        var alphaFails = true
        // The fake writes the marker the way `company bridge` does on success;
        // the flag-less run is the active workspace, beta here.
        let step: CompanyBridgeLaunch.LaunchStep = { args, _, timeout in
            calls.append(args)
            timeouts.append(timeout)
            let name = args.contains("--workspace") ? args.last ?? "" : "beta"
            if name == "alpha" && alphaFails { return false }
            FileManager.default.createFile(atPath: "\(base)/\(name)/\(CompanyBridgeLaunch.markerName)", contents: Data())
            return true
        }

        // Launch: the active one inside the launch steps, untouched by the others' failure.
        CompanyBridgeLaunch.migrateThenBridge(migrate: {}, bridge: {
            #expect(CompanyBridgeLaunch.runActive(flavor: "corp", step: step))
        })
        #expect(calls == [["company", "bridge", "--json"]])
        #expect(timeouts == [30])

        // After the open: every other workspace, alpha failing.
        calls = []
        timeouts = []
        #expect(!CompanyBridgeLaunch.runOthers(than: "beta", flavor: "corp", basePath: base, step: step))
        #expect(calls == [["company", "bridge", "--json", "--workspace", "alpha"],
                          ["company", "bridge", "--json", "--workspace", "gamma"]])
        #expect(timeouts == [300, 300])
        #expect(FileManager.default.fileExists(atPath: "\(base)/gamma/\(CompanyBridgeLaunch.markerName)"))
        #expect(!CompanyBridgeLaunch.workspacesMigrated(basePath: base), "alpha's failure keeps the feed gated")

        // Before an install: all of them; alpha now succeeds.
        alphaFails = false
        calls = []
        #expect(CompanyBridgeLaunch.runAll(flavor: "corp", basePath: base, step: step))
        #expect(calls.map { $0.last } == ["alpha", "beta", "gamma"], "every rerun is idempotent")
        #expect(CompanyBridgeLaunch.workspacesMigrated(basePath: base))

        calls = []
        #expect(CompanyBridgeLaunch.runOthers(than: "beta", flavor: "", basePath: base, step: step))
        #expect(CompanyBridgeLaunch.runAll(flavor: "", basePath: base, step: step))
        #expect(calls.isEmpty, "the public build bridges no workspace")
    }

    /// A temporary data root holding `names`, each with a `watchtower.db`.
    private func makeWorkspaces(_ names: [String]) throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wt-bridge-\(UUID().uuidString)").path
        for name in names {
            try FileManager.default.createDirectory(atPath: "\(base)/\(name)", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: "\(base)/\(name)/watchtower.db", contents: Data())
        }
        return base
    }

    @Test("migrated means every workspace with a database carries the marker")
    func everyWorkspaceMigrated() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("wt-bridge-\(UUID().uuidString)").path
        #expect(!CompanyBridgeLaunch.workspacesMigrated(basePath: empty), "no workspace is not migrated")
        let base = try makeWorkspaces(["alpha", "beta"])
        defer { try? FileManager.default.removeItem(atPath: base) }
        FileManager.default.createFile(atPath: "\(base)/alpha/\(CompanyBridgeLaunch.markerName)", contents: Data())
        #expect(!CompanyBridgeLaunch.workspacesMigrated(basePath: base))
        FileManager.default.createFile(atPath: "\(base)/beta/\(CompanyBridgeLaunch.markerName)", contents: Data())
        #expect(CompanyBridgeLaunch.workspacesMigrated(basePath: base))
    }

    @Test("the launch migrates first, then bridges (the bridge needs the company columns)")
    func migrateThenBridgeOrder() {
        var steps: [String] = []
        CompanyBridgeLaunch.migrateThenBridge(migrate: { steps.append("migrate") }, bridge: { steps.append("bridge") })
        #expect(steps == ["migrate", "bridge"])
    }

    @Test("non-https or malformed feed URL is disabled")
    func badFeedURL() {
        #expect(UpdateService.resolveChannel(
            flavor: "corp", feedURL: "http://feed.example", clientID: "a", clientSecret: "b", companyMigrated: false
        ) == .disabled)
        #expect(UpdateService.resolveChannel(
            flavor: "corp", feedURL: "not a url", clientID: "a", clientSecret: "b", companyMigrated: false
        ) == .disabled)
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
        let full = Data("""
        {"version":"0.8.0","zip_key":"Watchtower-0.8.0-corp-arm64.zip","sha256":"abc123","size":42,"published_at":"2026-08-16T12:00:00Z","notes":"n"}
        """.utf8)
        let m = try JSONDecoder().decode(GatedManifest.self, from: full)
        #expect(m.version == "0.8.0")
        #expect(m.zipKey == "Watchtower-0.8.0-corp-arm64.zip")
        #expect(m.sha256 == "abc123")
        #expect(m.size == 42)
        #expect(m.publishedAt == "2026-08-16T12:00:00Z")
        #expect(m.notes == "n")

        let minimal = Data("""
        {"version":"0.8.0","zip_key":"k.zip","sha256":"x"}
        """.utf8)
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
}

/// The install steps run off the main actor, so the recorder guards its
/// state with a lock. The failure flags are set before the steps run.
private final class InstallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var recordedRequirement: String?
    var failStage = false
    var failVerify = false
    var failReplace = false
    var writable = true
    /// Only the app bundle itself is unwritable (its folder is fine).
    var appUnwritable = false
    /// The recorder turns busy during the install (after the first gate).
    var busyBeforeSwap = false

    var calls: [String] { lock.withLock { recorded } }
    var verifiedRequirement: String? { lock.withLock { recordedRequirement } }

    private func record(_ call: String, requirement: String? = nil) {
        lock.withLock {
            recorded.append(call)
            if let requirement { recordedRequirement = requirement }
        }
    }

    struct Boom: LocalizedError {
        let what: String
        var errorDescription: String? { "\(what) boom" }
    }

    var steps: UpdateService.InstallSteps {
        UpdateService.InstallSteps(
            canWrite: { url in
                self.record("canWrite")
                if url.pathExtension == "app" && self.appUnwritable { return false }
                return self.writable
            },
            stage: { _, _ in
                self.record("stage")
                if self.failStage { throw Boom(what: "stage") }
                return URL(fileURLWithPath: "/staged/Watchtower.app")
            },
            verify: { _, requirement in
                self.record("verify", requirement: requirement)
                if self.failVerify { throw Boom(what: "verify") }
            },
            replace: { _, _ in
                self.record("replace")
                if self.failReplace { throw Boom(what: "replace") }
            },
            discard: { _ in self.record("discard") },
            isBusy: {
                self.record("isBusy")
                return self.busyBeforeSwap
            }
        )
    }
}

@Suite("UpdateService In-Process Install")
@MainActor
struct UpdateServiceInstallTests {
    private let newApp = URL(fileURLWithPath: "/downloads/Watchtower.app")
    private let currentApp = URL(fileURLWithPath: "/Applications/Watchtower.app")

    private func run(
        _ rec: InstallRecorder,
        teamID: String? = "ABCDE12345",
        bundleIdentifier: String? = "com.example.app"
    ) -> UpdateService.InstallOutcome {
        UpdateService.performInstall(newApp: newApp, currentApp: currentApp, teamID: teamID,
                                     bundleIdentifier: bundleIdentifier, steps: rec.steps)
    }

    @Test("happy path: writability, stage, verify against our Team ID and identifier, then swap with nothing in between")
    func happyPathOrder() async {
        let rec = InstallRecorder()
        #expect(run(rec) == .installed)
        // verify -> replace back to back: only the synchronous busy re-check
        // (no await, no daemon stop) sits between the check and the use of
        // the staged bundle.
        #expect(rec.calls == ["canWrite", "canWrite", "stage", "verify", "isBusy", "replace", "discard"])
        #expect(rec.verifiedRequirement
            == #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" and identifier "com.example.app""#)
    }

    @Test("no bundle identifier for the running app refuses before touching anything")
    func noBundleIdentifierFailsClosed() async {
        for bundleIdentifier in [nil, "", #"com.example"evil"#] {
            let rec = InstallRecorder()
            let outcome = run(rec, bundleIdentifier: bundleIdentifier)
            guard case .failed(let message) = outcome else { Issue.record("expected failure"); return }
            #expect(message.contains("bundle identifier"))
            #expect(rec.calls.isEmpty)
        }
    }

    @Test("no Team ID for the running app refuses before touching anything")
    func noTeamIDFailsClosed() async {
        let rec = InstallRecorder()
        let outcome = run(rec, teamID: nil)
        guard case .failed(let message) = outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("Team ID"))
        #expect(rec.calls.isEmpty)
    }

    @Test("malformed Team ID is treated as no Team ID")
    func malformedTeamIDFailsClosed() async {
        let rec = InstallRecorder()
        #expect(run(rec, teamID: "not set") != .installed)
        #expect(rec.calls.isEmpty)
    }

    @Test("an unwritable app folder is refused before anything is staged")
    func unwritableFolder() async {
        let rec = InstallRecorder()
        rec.writable = false
        let outcome = run(rec)
        guard case .failed(let message) = outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("/Applications"))
        #expect(message.contains("DMG"))
        #expect(rec.calls == ["canWrite"])
    }

    @Test("an unwritable app bundle in a writable folder is refused before anything is staged")
    func unwritableBundle() async {
        let rec = InstallRecorder()
        rec.appUnwritable = true
        let outcome = run(rec)
        guard case .failed(let message) = outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("DMG"))
        #expect(rec.calls == ["canWrite", "canWrite"])
    }

    @Test("a recording that starts during the verify still wins: the swap never happens")
    func busyAfterVerifyNeverSwaps() async {
        let rec = InstallRecorder()
        rec.busyBeforeSwap = true
        let outcome = run(rec)
        #expect(outcome == .failed(UpdateService.lateBusyMessage))
        #expect(rec.calls == ["canWrite", "canWrite", "stage", "verify", "isBusy", "discard"])
    }

    @Test("staging failure surfaces an error and stops nothing")
    func stageFailure() async {
        let rec = InstallRecorder()
        rec.failStage = true
        let outcome = run(rec)
        guard case .failed(let message) = outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("stage boom"))
        #expect(rec.calls == ["canWrite", "canWrite", "stage"])
    }

    @Test("signature failure discards the staged app and never swaps")
    func verifyFailure() async {
        let rec = InstallRecorder()
        rec.failVerify = true
        let outcome = run(rec)
        guard case .failed(let message) = outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("verify boom"))
        #expect(rec.calls == ["canWrite", "canWrite", "stage", "verify", "discard"])
    }

    @Test("swap failure surfaces an error and discards the staged app")
    func replaceFailure() async {
        let rec = InstallRecorder()
        rec.failReplace = true
        let outcome = run(rec)
        guard case .failed(let message) = outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("replace boom"))
        #expect(rec.calls == ["canWrite", "canWrite", "stage", "verify", "isBusy", "replace", "discard"])
    }

    @Test("install refuses while a recording or transcription is busy, before any step")
    func installRefusesWhileBusy() async {
        let rec = InstallRecorder()
        let svc = UpdateService()
        svc.isBusy = { true }
        svc.installSteps = rec.steps
        svc.state = .readyToInstall(appPath: URL(fileURLWithPath: "/downloads/Watchtower.app"))
        let ready = svc.state
        await svc.install()
        // Stays installable: the Settings caption explains the wait.
        #expect(svc.state == ready)
        #expect(rec.calls.isEmpty)
    }

    @Test("install outside a ready state is a no-op")
    func installRequiresReadyState() async {
        let svc = UpdateService()
        svc.state = .idle
        await svc.install()
        #expect(svc.state == .idle)
    }
}

@Suite("UpdateService Install Mechanics")
struct UpdateServiceInstallMechanicsTests {
    private static let quarantine = "com.apple.quarantine"

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-update-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeApp(at url: URL, marker: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
    }

    private func setQuarantine(_ url: URL) {
        let value = Array("0081;00000000;Test;".utf8)
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { setxattr($0, Self.quarantine, value, value.count, 0, XATTR_NOFOLLOW) } ?? -1
        }
        #expect(status == 0)
    }

    private func hasQuarantine(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            path.map { getxattr($0, Self.quarantine, nil, 0, 0, XATTR_NOFOLLOW) >= 0 } ?? false
        }
    }

    @Test("stage + swap replaces the bundle in place and strips quarantine")
    func stageAndSwap() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("installed/Watchtower.app", isDirectory: true)
        let download = root.appendingPathComponent("download/Watchtower.app", isDirectory: true)
        try makeApp(at: current, marker: "old")
        try makeApp(at: download, marker: "new")
        setQuarantine(download)
        setQuarantine(download.appendingPathComponent("Contents/marker"))
        #expect(hasQuarantine(download))

        let staged = try UpdateService.stageForReplacement(newApp: download, currentApp: current)
        #expect(!FileManager.default.fileExists(atPath: download.path))
        #expect(!hasQuarantine(staged))
        #expect(!hasQuarantine(staged.appendingPathComponent("Contents/marker")))

        let steps = UpdateService.InstallSteps.live
        try steps.replace(current, staged)
        steps.discard(staged)

        let marker = try String(contentsOf: current.appendingPathComponent("Contents/marker"), encoding: .utf8)
        #expect(marker == "new")
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    @Test("an unsigned bundle fails signature verification")
    func unsignedBundleFailsVerify() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Watchtower.app", isDirectory: true)
        try makeApp(at: app, marker: "x")
        #expect(throws: UpdateService.SignatureError.self) {
            try UpdateService.verifySignature(of: app, requirement: UpdateService.designatedRequirement(forTeamID: "ABCDE12345"))
        }
    }

    /// The Team-ID pin is the security core of the verify: a bundle with a
    /// perfectly valid signature from a different signer must be refused at
    /// the requirement check. Calculator.app ships on every macOS, Apple-signed
    /// with no Team ID, so it can never satisfy our leaf-OU requirement.
    @Test("a validly signed bundle from another signer fails the Team-ID pin")
    func foreignSignerFailsTeamPin() {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        do {
            // Identifier matches, so only the Team-ID pin can fail.
            let requirement = UpdateService.updateRequirement(teamID: "ABCDE12345", bundleIdentifier: "com.apple.calculator")
            try UpdateService.verifySignature(of: calculator, requirement: requirement ?? "")
            Issue.record("a foreign signer passed the Team-ID pin")
        } catch let error as UpdateService.SignatureError {
            #expect(error.step == "validate")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// Control for the test above: the same bundle passes the same strict
    /// validation under a requirement it does satisfy, so the failure above is
    /// the pin, not the flags or a broken read.
    @Test("the same bundle passes strict validation under a requirement it satisfies")
    func strictValidationPassesForMatchingRequirement() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        var staticCode: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(calculator as CFURL, [], &staticCode) == errSecSuccess)
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess)
        let code = try #require(staticCode)
        #expect(SecStaticCodeCheckValidity(code, UpdateService.signatureValidationFlags, requirement) == errSecSuccess)
    }

    @Test("the update requirement adds this app's identifier to the Team-ID pin")
    func updateRequirementShape() {
        #expect(UpdateService.updateRequirement(teamID: "ABCDE12345", bundleIdentifier: "com.example.app")
            == #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" and identifier "com.example.app""#)
        #expect(UpdateService.updateRequirement(teamID: "ABCDE12345", bundleIdentifier: nil) == nil)
        #expect(UpdateService.updateRequirement(teamID: "ABCDE12345", bundleIdentifier: "") == nil)
        #expect(UpdateService.updateRequirement(teamID: "ABCDE12345", bundleIdentifier: #"a" or "b"#) == nil)
    }

    @Test("a signature error explains itself and points at a manual install")
    func signatureErrorMessage() {
        let message = UpdateService.SignatureError(step: "validate", status: errSecCSReqFailed).localizedDescription
        #expect(message.contains("validate"))
        #expect(message.contains("DMG"))
        #expect(!message.contains("OSStatus"))  // the system's own description is used when it has one
    }

    @Test("signature validation uses the strict, deep, all-architectures flags")
    func validationFlags() {
        let flags = UpdateService.signatureValidationFlags.rawValue
        #expect(flags & kSecCSCheckAllArchitectures != 0)
        #expect(flags & kSecCSStrictValidate != 0)
        #expect(flags & kSecCSCheckNestedCode != 0)
    }

    @Test("relaunch waiter only waits and opens, with the path shell-escaped")
    func waiterArguments() {
        let args = UpdateService.relaunchWaiterArguments(pid: 4242, appPath: #"/Apps/We"ird $App`.app"#)
        #expect(args.count == 2)
        #expect(args[0] == "-c")
        let script = args[1]
        #expect(script.contains("kill -0 4242"))
        #expect(script.contains("-ge \(UpdateService.relaunchWaiterTicks) ]"))
        #expect(script.contains(#"/usr/bin/open "/Apps/We\"ird \$App\`.app" || /usr/bin/logger -t watchtower-update"#))
        #expect(script.contains("/usr/bin/logger -t watchtower-update \"relaunch waiter gave up"))
        // Never touches files: the waiter only waits, opens and logs.
        for forbidden in ["rm ", "mv ", "cp ", "xattr", "codesign"] {
            #expect(!script.contains(forbidden))
        }
    }

    @Test("relaunch waiter script is valid sh and reaches open once the pid is gone")
    func waiterRunsToOpenOnDeadPid() throws {
        // `open` swapped for `echo` so the test launches nothing; the pid never exists.
        let args = UpdateService.relaunchWaiterArguments(pid: 0x7fff_fffe, appPath: "/nonexistent/X.app")
        let script = args[1].replacingOccurrences(of: "/usr/bin/open", with: "echo")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(data: data, encoding: .utf8) == "/nonexistent/X.app\n")
    }

    @Test("a failed open is logged, not swallowed")
    func waiterLogsFailedOpen() throws {
        // `open` swapped for `false` (always fails), `logger` for `echo` so the
        // log line lands on stdout.
        let args = UpdateService.relaunchWaiterArguments(pid: 0x7fff_fffe, appPath: "/nonexistent/X.app")
        let script = args[1]
            .replacingOccurrences(of: "/usr/bin/open", with: "false")
            .replacingOccurrences(of: "/usr/bin/logger", with: "echo")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(String(data: data, encoding: .utf8) == "-t watchtower-update relaunch failed: open exited 1\n")
    }
}

/// Records the relaunch's side effects.
@MainActor
private final class RelaunchRecorder {
    var spawned: [(pid: pid_t, path: String)] = []
    var quits = 0
    var sleeps: [Duration] = []
    var failSpawn = false

    var steps: UpdateService.RelaunchSteps {
        UpdateService.RelaunchSteps(
            spawn: { pid, path in
                self.spawned.append((pid, path))
                if self.failSpawn { throw InstallRecorder.Boom(what: "spawn") }
            },
            requestQuit: { self.quits += 1 },
            sleep: { self.sleeps.append($0) }
        )
    }
}

@Suite("UpdateService Relaunch")
@MainActor
struct UpdateServiceRelaunchTests {
    private let appURL = URL(fileURLWithPath: "/Applications/Watchtower.app")

    private func service(_ rec: RelaunchRecorder, appURL: URL?) -> UpdateService {
        let svc = UpdateService()
        svc.relaunchSteps = rec.steps
        svc.currentAppURL = { appURL }
        return svc
    }

    @Test("a waiter that cannot start never quits the app")
    func spawnFailureNeverQuits() async {
        let rec = RelaunchRecorder()
        rec.failSpawn = true
        let svc = service(rec, appURL: appURL)
        await svc.relaunch()
        #expect(svc.state == .restartRequired)
        #expect(rec.quits == 0)
        #expect(rec.sleeps.isEmpty)
    }

    @Test("a quit that does not happen ends in restartRequired after the grace")
    func quitNotHappeningEndsInRestartRequired() async {
        let rec = RelaunchRecorder()
        let svc = service(rec, appURL: appURL)
        var stateDuringGrace: UpdateService.UpdateState?
        let recordSleep = svc.relaunchSteps.sleep
        svc.relaunchSteps.sleep = { duration in
            stateDuringGrace = svc.state
            await recordSleep(duration)
        }
        await svc.relaunch()
        // "Restart Now" must not claim to be installing while it waits.
        #expect(stateDuringGrace == .restarting)
        #expect(rec.spawned.count == 1)
        #expect(rec.spawned.first?.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(rec.spawned.first?.path == appURL.path)
        #expect(rec.quits == 1)
        #expect(rec.sleeps == [UpdateService.quitGrace])
        #expect(svc.state == .restartRequired)
    }

    @Test("the live quit runs from the run loop, never inside the calling task")
    func liveQuitIsDeferredToRunLoop() {
        var ran = false
        UpdateService.performOnRunLoop { ran = true }
        // Called synchronously, NSApp.terminate's .terminateLater loop would
        // starve the main queue and hang the relaunch on "Restarting…".
        #expect(!ran)
        let deadline = Date().addingTimeInterval(2)
        while !ran, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        #expect(ran)
    }

    @Test("no app bundle: restartRequired, nothing spawned or quit")
    func noBundle() async {
        let rec = RelaunchRecorder()
        let svc = service(rec, appURL: nil)
        await svc.relaunch()
        #expect(svc.state == .restartRequired)
        #expect(rec.spawned.isEmpty)
        #expect(rec.quits == 0)
    }

    @Test("install maps a real step failure onto .error and never relaunches")
    func installFailureMapsToError() async {
        let install = InstallRecorder()
        install.failVerify = true
        let relaunch = RelaunchRecorder()
        let svc = service(relaunch, appURL: appURL)
        svc.isBusy = { false }
        svc.teamIdentifier = { "ABCDE12345" }
        svc.bundleIdentifier = { "com.example.app" }
        svc.installSteps = install.steps
        svc.state = .readyToInstall(appPath: URL(fileURLWithPath: "/downloads/Watchtower.app"))
        await svc.install()
        guard case .error(let message) = svc.state else {
            Issue.record("expected .error, got \(svc.state)")
            return
        }
        #expect(message.contains("verify boom"))
        #expect(install.calls == ["canWrite", "canWrite", "stage", "verify", "discard"])
        #expect(relaunch.spawned.isEmpty && relaunch.quits == 0)
    }

    @Test("install without a Team ID fails closed through the real mapping")
    func installWithoutTeamID() async {
        let install = InstallRecorder()
        let svc = service(RelaunchRecorder(), appURL: appURL)
        svc.isBusy = { false }
        svc.teamIdentifier = { nil }
        svc.installSteps = install.steps
        svc.state = .readyToInstall(appPath: URL(fileURLWithPath: "/downloads/Watchtower.app"))
        await svc.install()
        guard case .error(let message) = svc.state else {
            Issue.record("expected .error, got \(svc.state)")
            return
        }
        #expect(message.contains("Team ID"))
        #expect(install.calls.isEmpty)
    }

    @Test("install outside an app bundle reports it and touches nothing")
    func installWithoutBundle() async {
        let install = InstallRecorder()
        let svc = service(RelaunchRecorder(), appURL: nil)
        svc.isBusy = { false }
        svc.installSteps = install.steps
        svc.state = .readyToInstall(appPath: URL(fileURLWithPath: "/downloads/Watchtower.app"))
        await svc.install()
        #expect(svc.state == .error("Cannot determine current app location"))
        #expect(install.calls.isEmpty)
    }

    @Test("a migrated corp build bridges again before a public install; a failed bridge installs nothing")
    func corpBridgesBeforePublicInstall() async {
        let install = InstallRecorder()
        let svc = service(RelaunchRecorder(), appURL: appURL)
        svc.isBusy = { false }
        svc.teamIdentifier = { nil } // the step right after the bridge fails visibly
        svc.installSteps = install.steps
        svc.buildFlavor = "corp"
        svc.companyMigrated = { true }
        let runs = LockedReports()
        svc.bridgeBeforeInstall = { runs.append("bridge"); return false }
        svc.state = .readyToInstall(appPath: URL(fileURLWithPath: "/downloads/Watchtower.app"))
        await svc.install()
        #expect(svc.state == .error(UpdateService.bridgeFailedMessage))
        #expect(runs.items == ["bridge"])
        #expect(install.calls.isEmpty)

        svc.bridgeBeforeInstall = { runs.append("bridge"); return true }
        svc.state = .readyToInstall(appPath: URL(fileURLWithPath: "/downloads/Watchtower.app"))
        await svc.install()
        guard case .error(let message) = svc.state else {
            Issue.record("expected the Team ID error past the bridge, got \(svc.state)")
            return
        }
        #expect(message.contains("Team ID"))
        #expect(runs.items == ["bridge", "bridge"])

        // A workspace without the marker by install time stops it too, even
        // when the bridge itself succeeded.
        svc.companyMigrated = { false }
        svc.state = .readyToInstall(appPath: URL(fileURLWithPath: "/downloads/Watchtower.app"))
        await svc.install()
        #expect(svc.state == .error(UpdateService.bridgeFailedMessage))
        #expect(runs.items == ["bridge", "bridge", "bridge"])
        #expect(install.calls.isEmpty)

        // The public build never runs it.
        svc.buildFlavor = ""
        svc.state = .readyToInstall(appPath: URL(fileURLWithPath: "/downloads/Watchtower.app"))
        await svc.install()
        #expect(runs.items == ["bridge", "bridge", "bridge"])
    }
}

@Suite("UpdateService Periodic Checks")
@MainActor
struct UpdateServicePeriodicTests {
    /// A fresh UserDefaults suite; the caller removes it with the returned name.
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "wt-update-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    @Test("check interval is six hours")
    func interval() {
        #expect(UpdateService.checkInterval == .seconds(6 * 60 * 60))
    }

    @Test("background checks run when idle, failed or offering an update, never mid-flight")
    func autoCheckDecision() {
        let url = URL(fileURLWithPath: "/tmp/x.zip")
        #expect(UpdateService.shouldAutoCheck(state: .idle))
        #expect(UpdateService.shouldAutoCheck(state: .error("offline")))
        #expect(UpdateService.shouldAutoCheck(state: .available(version: "1", notes: "", downloadURL: url)))
        #expect(!UpdateService.shouldAutoCheck(state: .checking))
        #expect(!UpdateService.shouldAutoCheck(state: .downloading(progress: 0.5)))
        #expect(!UpdateService.shouldAutoCheck(state: .readyToInstall(appPath: URL(fileURLWithPath: "/tmp/x"))))
        #expect(!UpdateService.shouldAutoCheck(state: .installing))
        #expect(!UpdateService.shouldAutoCheck(state: .restarting))
        #expect(!UpdateService.shouldAutoCheck(state: .restartRequired))
    }

    @Test("the loop skips the check while busy, re-arms on the interval, and clears itself on exit")
    func loopSleepsOnInterval() async {
        let svc = UpdateService()
        svc.buildFlavor = ""
        // Each pass starts with What's New; never the network here.
        svc.fetchInstalledNotes = { _ in "" }
        var fetches = 0
        svc.fetchCheck = {
            fetches += 1
            return .upToDate
        }
        // Busy state: the loop must not start a check.
        svc.state = .downloading(progress: 0.3)
        var sleeps: [Duration] = []
        svc.startPeriodicChecks { duration in
            sleeps.append(duration)
            if sleeps.count == 2 { throw CancellationError() }
        }
        let loop = svc.periodicTask
        #expect(loop != nil)
        await loop?.value
        #expect(sleeps == [UpdateService.checkInterval, UpdateService.checkInterval])
        #expect(fetches == 0)
        #expect(svc.state == .downloading(progress: 0.3))
        #expect(!svc.isPeriodicCheckRunning)
    }

    @Test("the loop's first pass checks at once and surfaces a found update")
    func loopChecksImmediately() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let svc = UpdateService()
        svc.buildFlavor = ""
        svc.defaults = defaults
        var announced: [String] = []
        svc.announce = {
            announced.append($0)
            return true
        }
        let url = URL(fileURLWithPath: "/tmp/new.zip")
        svc.fetchCheck = { .found(.init(version: "v99.0.0", notes: "n", downloadURL: url, gated: nil)) }
        svc.startPeriodicChecks { _ in throw CancellationError() }
        await svc.periodicTask?.value
        #expect(svc.state == .available(version: "v99.0.0", notes: "n", downloadURL: url))
        #expect(svc.availableVersion == "v99.0.0")
        #expect(announced == ["v99.0.0"])
    }

    @Test("a result arriving after the user moved on is dropped")
    func lateResultIsDropped() async {
        let svc = UpdateService()
        svc.buildFlavor = ""
        let url = URL(fileURLWithPath: "/tmp/new.zip")
        svc.fetchCheck = {
            svc.state = .downloading(progress: 0.1)
            return .found(.init(version: "v99.0.0", notes: "", downloadURL: url, gated: nil))
        }
        await svc.checkForUpdates()
        #expect(svc.state == .downloading(progress: 0.1))
    }

    @Test("an update is announced once per version, across service instances")
    func announceOncePerVersion() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var announced: [String] = []

        let first = UpdateService()
        first.defaults = defaults
        first.announce = {
            announced.append($0)
            return true
        }
        await first.noteAvailable(version: "v1.1.0")
        await first.noteAvailable(version: "v1.1.0")
        #expect(first.availableVersion == "v1.1.0")

        // A relaunch (new instance, same defaults) finds the same version again.
        let relaunched = UpdateService()
        relaunched.defaults = defaults
        relaunched.announce = {
            announced.append($0)
            return true
        }
        await relaunched.noteAvailable(version: "v1.1.0")
        await relaunched.noteAvailable(version: "v1.2.0")

        #expect(announced == ["v1.1.0", "v1.2.0"])
    }

    @Test("a push the system refused is not memoed, so the next check retries it")
    func refusedPushIsRetried() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var attempts: [String] = []
        let svc = UpdateService()
        svc.defaults = defaults
        svc.announce = {
            attempts.append($0)
            return attempts.count > 1
        }
        await svc.noteAvailable(version: "v1.1.0")
        await svc.noteAvailable(version: "v1.1.0")
        await svc.noteAvailable(version: "v1.1.0")
        #expect(attempts == ["v1.1.0", "v1.1.0"])
    }

    /// A service on `defaults` that records window presentations; pushes
    /// are accepted silently.
    private func presentingService(
        _ defaults: UserDefaults, busy: @escaping () -> Bool = { false }, presented: @escaping (String) -> Void
    ) -> UpdateService {
        let svc = UpdateService()
        svc.defaults = defaults
        svc.announce = { _ in true }
        svc.isBusy = busy
        svc.presentUpdateWindow = { [weak svc] in
            presented(svc?.availableVersion ?? "")
            return true
        }
        return svc
    }

    @Test("a background check presents the update window once per version, across relaunches")
    func windowPresentedOncePerVersion() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var presented: [String] = []
        let first = presentingService(defaults) { presented.append($0) }
        await first.noteAvailable(version: "v1.1.0", notes: "## Fixes")
        await first.noteAvailable(version: "v1.1.0")
        #expect(first.availableNotes.isEmpty)

        let relaunched = presentingService(defaults) { presented.append($0) }
        await relaunched.noteAvailable(version: "v1.1.0", notes: "## Fixes")
        await relaunched.noteAvailable(version: "v1.2.0", notes: "## New")
        #expect(relaunched.availableNotes == "## New")
        #expect(presented == ["v1.1.0", "v1.2.0"])
    }

    @Test("a manual check never pops the window but marks the version as seen")
    func manualCheckMarksSeen() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var presented: [String] = []
        let svc = presentingService(defaults) { presented.append($0) }
        await svc.noteAvailable(version: "v1.1.0", background: false)
        await svc.noteAvailable(version: "v1.1.0", background: true)
        #expect(presented.isEmpty)
    }

    @Test("no window over a busy recorder, and none before a scene wires it; both retry on the next check")
    func busyOrUnwiredRetries() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var presented: [String] = []
        var busy = true
        let svc = presentingService(defaults, busy: { busy }, presented: { presented.append($0) })
        let present = svc.presentUpdateWindow
        svc.presentUpdateWindow = nil
        busy = false
        await svc.noteAvailable(version: "v1.1.0")
        svc.presentUpdateWindow = present
        busy = true
        await svc.noteAvailable(version: "v1.1.0")
        #expect(presented.isEmpty)
        busy = false
        await svc.noteAvailable(version: "v1.1.0")
        #expect(presented == ["v1.1.0"])
    }

    @Test("the notes follow the offer: kept from a found update, cleared when up to date")
    func notesFollowTheOffer() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let svc = presentingService(defaults) { _ in }
        let url = URL(fileURLWithPath: "/tmp/new.zip")
        await svc.applyCheckResult(.found(.init(version: "v2.0.0", notes: "- one", downloadURL: url, gated: nil)),
                                   previous: .idle, background: true)
        #expect(svc.availableNotes == "- one")
        await svc.applyCheckResult(.upToDate, previous: .idle, background: true)
        #expect(svc.availableNotes.isEmpty)
        #expect(svc.availableVersion == nil)
    }

    @Test("shouldAnnounce compares against the last announced version")
    func shouldAnnounceDecision() {
        #expect(UpdateService.shouldAnnounce(version: "v1.0.0", lastAnnounced: nil))
        #expect(UpdateService.shouldAnnounce(version: "v1.0.1", lastAnnounced: "v1.0.0"))
        #expect(!UpdateService.shouldAnnounce(version: "v1.0.0", lastAnnounced: "v1.0.0"))
    }

    @Test("What's New shows on a newer version, or on the offered one before the memo existed")
    func whatsNewDecision() {
        #expect(UpdateService.shouldShowWhatsNew(current: "1.1.0", lastLaunched: "1.0.0", lastOffered: nil))
        #expect(!UpdateService.shouldShowWhatsNew(current: "1.1.0", lastLaunched: "1.1.0", lastOffered: "v1.1.0"))
        #expect(!UpdateService.shouldShowWhatsNew(current: "1.0.0", lastLaunched: "1.1.0", lastOffered: nil))
        // First launch of the memo: only an update this app offered counts.
        #expect(UpdateService.shouldShowWhatsNew(current: "1.1.0", lastLaunched: nil, lastOffered: "v1.1.0"))
        #expect(!UpdateService.shouldShowWhatsNew(current: "1.1.0", lastLaunched: nil, lastOffered: "v1.0.9"))
        #expect(!UpdateService.shouldShowWhatsNew(current: "1.1.0", lastLaunched: nil, lastOffered: nil))
    }

    /// A public-channel service whose notes fetch returns `notes`.
    private func whatsNewService(
        _ defaults: UserDefaults, notes: String?, presented: @escaping (String) -> Void
    ) -> UpdateService {
        let svc = UpdateService()
        svc.buildFlavor = ""
        svc.defaults = defaults
        svc.isBusy = { false }
        svc.fetchInstalledNotes = { _ in notes }
        svc.presentUpdateWindow = { [weak svc] in
            presented(svc?.installedRelease?.notes ?? "")
            return true
        }
        return svc
    }

    @Test("the first launch of a new version opens its notes once")
    func whatsNewOncePerVersion() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("1.0.0", forKey: "lastLaunchedAppVersion")
        var presented: [String] = []
        let svc = whatsNewService(defaults, notes: "## New") { presented.append($0) }
        await svc.showWhatsNewIfUpdated(currentVersion: "1.1.0")
        #expect(svc.installedRelease == .init(version: "1.1.0", notes: "## New"))
        svc.dismissInstalledRelease()
        #expect(svc.installedRelease == nil)

        let relaunched = whatsNewService(defaults, notes: "## New") { presented.append($0) }
        await relaunched.showWhatsNewIfUpdated(currentVersion: "1.1.0")
        #expect(presented == ["## New"])
    }

    @Test("What's New settles once its first pass returns; a build with no channel is settled at once")
    func whatsNewSettled() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("1.0.0", forKey: "lastLaunchedAppVersion")
        let svc = whatsNewService(defaults, notes: "## New") { _ in }
        #expect(!svc.isWhatsNewSettled, "a window may still open")
        await svc.showWhatsNewIfUpdated(currentVersion: "1.1.0")
        #expect(svc.isWhatsNewSettled)

        let seen = whatsNewService(defaults, notes: nil) { _ in }
        await seen.showWhatsNewIfUpdated(currentVersion: "1.1.0")
        #expect(seen.isWhatsNewSettled, "the memo already says seen")

        let offline = whatsNewService(defaults, notes: nil) { _ in }
        defaults.set("1.0.0", forKey: "lastLaunchedAppVersion")
        await offline.showWhatsNewIfUpdated(currentVersion: "1.1.0")
        #expect(offline.isWhatsNewSettled, "an offline pass gives up until the next one")

        let noChannel = UpdateService()
        noChannel.buildFlavor = "dev"
        #expect(!noChannel.updatesSupported)
        #expect(noChannel.isWhatsNewSettled)
    }

    @Test("a fresh install shows nothing and remembers its version")
    func whatsNewFreshInstall() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var presented: [String] = []
        let svc = whatsNewService(defaults, notes: "## New") { presented.append($0) }
        await svc.showWhatsNewIfUpdated(currentVersion: "1.1.0")
        #expect(presented.isEmpty)
        #expect(defaults.string(forKey: "lastLaunchedAppVersion") == "1.1.0")
    }

    @Test("a failed fetch retries next launch; empty notes are not shown and not retried")
    func whatsNewFetchOutcomes() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("1.0.0", forKey: "lastLaunchedAppVersion")
        var presented: [String] = []
        let offline = whatsNewService(defaults, notes: nil) { presented.append($0) }
        await offline.showWhatsNewIfUpdated(currentVersion: "1.1.0")
        #expect(defaults.string(forKey: "lastLaunchedAppVersion") == "1.0.0")

        let empty = whatsNewService(defaults, notes: "") { presented.append($0) }
        await empty.showWhatsNewIfUpdated(currentVersion: "1.1.0")
        #expect(presented.isEmpty)
        #expect(empty.installedRelease == nil)
        #expect(defaults.string(forKey: "lastLaunchedAppVersion") == "1.1.0")
    }

    @Test("a window that could not open, or a busy recorder, is retried and leaves nothing pending")
    func whatsNewUnwiredOrBusyRetries() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("1.0.0", forKey: "lastLaunchedAppVersion")
        var presented: [String] = []
        let svc = whatsNewService(defaults, notes: "## New") { presented.append($0) }
        let present = svc.presentUpdateWindow
        svc.presentUpdateWindow = nil
        await svc.showWhatsNewIfUpdated(currentVersion: "1.1.0")
        svc.presentUpdateWindow = present
        svc.isBusy = { true }
        await svc.showWhatsNewIfUpdated(currentVersion: "1.1.0")
        svc.presentUpdateWindow = { false }
        svc.isBusy = { false }
        await svc.showWhatsNewIfUpdated(currentVersion: "1.1.0")
        #expect(svc.installedRelease == nil)
        #expect(defaults.string(forKey: "lastLaunchedAppVersion") == "1.0.0")

        svc.presentUpdateWindow = present
        await svc.showWhatsNewIfUpdated(currentVersion: "1.1.0")
        #expect(presented == ["## New"])
        #expect(defaults.string(forKey: "lastLaunchedAppVersion") == "1.1.0")
    }

    @Test("a rollback launch does not move the memo back")
    func whatsNewRollbackKeepsMemo() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("1.1.0", forKey: "lastLaunchedAppVersion")
        var presented: [String] = []
        let svc = whatsNewService(defaults, notes: "## New") { presented.append($0) }
        await svc.showWhatsNewIfUpdated(currentVersion: "1.0.0")
        await svc.showWhatsNewIfUpdated(currentVersion: "1.1.0")
        #expect(presented.isEmpty)
        #expect(defaults.string(forKey: "lastLaunchedAppVersion") == "1.1.0")
    }

    @Test("the periodic loop retries a What's New the launch could not show")
    func whatsNewRetriedByTheLoop() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("0.0.1", forKey: "lastLaunchedAppVersion")
        var presented: [String] = []
        let svc = whatsNewService(defaults, notes: "## New") { presented.append($0) }
        svc.fetchCheck = { .upToDate }
        svc.startPeriodicChecks { _ in throw CancellationError() }
        await svc.periodicTask?.value
        #expect(presented == ["## New"])
    }

    @Test("the transition memo is the newer of the presented and announced versions")
    func newerMemo() {
        #expect(UpdateService.newer("v1.0.9", "v1.1.0") == "v1.1.0")
        #expect(UpdateService.newer("v1.1.0", "v1.0.9") == "v1.1.0")
        #expect(UpdateService.newer(nil, "v1.1.0") == "v1.1.0")
        #expect(UpdateService.newer("v1.1.0", nil) == "v1.1.0")
        #expect(UpdateService.newer(nil, nil) == nil)
    }

    @Test("the gated manifest gives notes only while it still holds the running version")
    func gatedNotesForRunningVersion() {
        #expect(UpdateService.gatedNotes(manifestVersion: "1.1.0", notes: "## New", running: "1.1.0") == "## New")
        #expect(UpdateService.gatedNotes(manifestVersion: "v1.1.0", notes: "## New", running: "1.1.0") == "## New")
        #expect(UpdateService.gatedNotes(manifestVersion: "1.1.0", notes: nil, running: "1.1.0").isEmpty)
        #expect(UpdateService.gatedNotes(manifestVersion: "1.2.0", notes: "## Newer", running: "1.1.0").isEmpty)
    }
}

@Suite("UpdateService Check Results")
@MainActor
final class UpdateServiceCheckResultTests {
    private let oldURL = URL(fileURLWithPath: "/tmp/old.zip")
    private let newURL = URL(fileURLWithPath: "/tmp/new.zip")
    /// One isolated announce memo per test, removed when the test ends.
    private let suiteName = "wt-update-check-tests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A service with the isolated announce memo and a recorder for pushes.
    private func service(announced: @escaping (String) -> Void) -> UpdateService {
        let svc = UpdateService()
        svc.defaults = defaults
        svc.announce = {
            announced($0)
            return true
        }
        return svc
    }

    @Test("a found version goes on offer and is noted (tray version + announcement)")
    func foundFromIdle() async {
        var announced: [String] = []
        let svc = service { announced.append($0) }
        await svc.applyCheckResult(.found(.init(version: "v2.0.0", notes: "n", downloadURL: newURL, gated: nil)),
                                   previous: .idle, background: true)
        #expect(svc.state == .available(version: "v2.0.0", notes: "n", downloadURL: newURL))
        #expect(svc.availableVersion == "v2.0.0")
        #expect(announced == ["v2.0.0"])
    }

    @Test("up to date clears the known version")
    func upToDateClears() async {
        let svc = service { _ in }
        await svc.applyCheckResult(.found(.init(version: "v2.0.0", notes: "", downloadURL: newURL, gated: nil)),
                                   previous: .idle, background: false)
        await svc.applyCheckResult(.upToDate, previous: .idle, background: false)
        #expect(svc.state == .idle)
        #expect(svc.availableVersion == nil)
    }

    @Test("an offer is replaced only by a strictly newer version")
    func offerReplacedOnlyByNewer() async {
        var announced: [String] = []
        let svc = service { announced.append($0) }
        let offered = UpdateService.UpdateState.available(version: "v2.0.0", notes: "", downloadURL: oldURL)

        await svc.applyCheckResult(.found(.init(version: "v2.0.0", notes: "", downloadURL: newURL, gated: nil)),
                                   previous: offered, background: true)
        #expect(svc.state == offered)

        await svc.applyCheckResult(.found(.init(version: "v1.9.0", notes: "", downloadURL: newURL, gated: nil)),
                                   previous: offered, background: true)
        #expect(svc.state == offered)

        await svc.applyCheckResult(.found(.init(version: "v2.1.0", notes: "", downloadURL: newURL, gated: nil)),
                                   previous: offered, background: true)
        #expect(svc.state == .available(version: "v2.1.0", notes: "", downloadURL: newURL))
        #expect(announced == ["v2.1.0"])
    }

    @Test("a failure or 'up to date' never hides an offer")
    func offerSurvivesFailure() async {
        let svc = service { _ in }
        let offered = UpdateService.UpdateState.available(version: "v2.0.0", notes: "", downloadURL: oldURL)
        await svc.applyCheckResult(.failed("offline"), previous: offered, background: true)
        #expect(svc.state == offered)
        await svc.applyCheckResult(.failed("offline"), previous: offered, background: false)
        #expect(svc.state == offered)
        await svc.applyCheckResult(.upToDate, previous: offered, background: true)
        #expect(svc.state == offered)
    }

    @Test("an unattended failure stays idle; a manual one shows the error")
    func failureVisibility() async {
        let svc = service { _ in }
        await svc.applyCheckResult(.failed("offline"), previous: .idle, background: true)
        #expect(svc.state == .idle)
        await svc.applyCheckResult(.failed("offline"), previous: .idle, background: false)
        #expect(svc.state == .error("offline"))
    }
}

@Suite("UpdateService Required Version")
@MainActor
final class UpdateServiceRequiredVersionTests {
    private let url = URL(fileURLWithPath: "/tmp/new.zip")
    private let suiteName = "wt-update-required-tests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A service running 0.29.0 on the isolated memo that records window
    /// presentations; pushes are accepted silently, logs dropped.
    private func service(presented: @escaping () -> Void = {}) -> UpdateService {
        let svc = UpdateService()
        svc.buildFlavor = ""
        svc.runningVersion = "0.29.0"
        svc.defaults = defaults
        svc.announce = { _ in true }
        svc.isBusy = { false }
        svc.log = { _ in }
        svc.fetchInstalledNotes = { _ in "" }
        svc.presentUpdateWindow = {
            presented()
            return true
        }
        return svc
    }

    private func found(_ version: String, min: String?) -> UpdateService.CheckResult {
        .found(.init(version: version, notes: "n", downloadURL: url, gated: nil, minVersion: min))
    }

    // MARK: Formats

    @Test("min_version accepts X, X.Y or X.Y.Z with an optional v; anything else is malformed")
    func parseMinVersion() {
        #expect(UpdateService.parseMinVersion(nil) == .absent)
        #expect(UpdateService.parseMinVersion("0.30.0") == .valid("0.30.0"))
        #expect(UpdateService.parseMinVersion(" v0.30 ") == .valid("0.30"))
        #expect(UpdateService.parseMinVersion("1") == .valid("1"))
        #expect(UpdateService.parseMinVersion("") == .malformed(""))
        #expect(UpdateService.parseMinVersion("soon") == .malformed("soon"))
        #expect(UpdateService.parseMinVersion("0.30.0-beta") == .malformed("0.30.0-beta"))
        #expect(UpdateService.parseMinVersion("1.2.3.4") == .malformed("1.2.3.4"))
        // A component past Int would compare as nothing; it is malformed instead.
        #expect(UpdateService.parseMinVersion("99999999999999999999") == .malformed("99999999999999999999"))
    }

    @Test("the release-notes marker is read and stripped from the notes shown")
    func markerInNotes() {
        let body = "## What's New\n<!-- min_version: 0.30.0 -->\n- fix\n"
        let split = UpdateService.splitMinVersionMarker(body)
        #expect(split.minVersion == "0.30.0")
        #expect(split.notes == "## What's New\n- fix\n")

        let none = UpdateService.splitMinVersionMarker("## Notes\n<!-- other -->\n")
        #expect(none.minVersion == nil)
        #expect(none.notes == "## Notes\n<!-- other -->\n")

        let bad = UpdateService.splitMinVersionMarker("<!--min_version:soon-->\nx")
        #expect(bad.minVersion == "soon")
        #expect(bad.notes == "x")
    }

    @Test("the gated manifest carries min_version; a non-string one is malformed, not a broken manifest")
    func manifestMinVersion() throws {
        let base = #""version":"0.31.0","zip_key":"Watchtower-0.31.0-corp-arm64.zip","sha256":"ab""#
        let with = try JSONDecoder().decode(GatedManifest.self, from: Data("{\(base),\"min_version\":\"0.30.0\"}".utf8))
        #expect(with.minVersion == "0.30.0")
        let without = try JSONDecoder().decode(GatedManifest.self, from: Data("{\(base)}".utf8))
        #expect(without.minVersion == nil)
        let number = try JSONDecoder().decode(GatedManifest.self, from: Data("{\(base),\"min_version\":30}".utf8))
        #expect(number.version == "0.31.0")
        #expect(UpdateService.parseMinVersion(number.minVersion) == .malformed("<not a string>"))
    }

    @Test("the gated manifest key wins over the marker its notes carry; the marker is the fallback")
    func gatedPrecedence() throws {
        func manifest(_ extra: String) throws -> GatedManifest {
            let json = #"{"version":"0.31.0","zip_key":"Watchtower-0.31.0-corp-arm64.zip","sha256":"ab""# + extra + "}"
            return try JSONDecoder().decode(GatedManifest.self, from: Data(json.utf8))
        }
        let notes = #","notes":"<!-- min_version: 0.29.5 -->\n- fix""#
        let both = UpdateService.gatedNotesAndMinVersion(try manifest(notes + #","min_version":"0.30.0""#))
        #expect(both.minVersion == "0.30.0")
        #expect(both.notes == "- fix")
        let markerOnly = UpdateService.gatedNotesAndMinVersion(try manifest(notes))
        #expect(markerOnly.minVersion == "0.29.5")
        #expect(markerOnly.notes == "- fix")
        #expect(UpdateService.gatedNotesAndMinVersion(try manifest("")).minVersion == nil)
    }

    @Test("required only while the running build is older than the minimum and the offer meets it")
    func verdict() {
        #expect(UpdateService.minVersionVerdict(.valid("0.30.0"), offered: "v0.31.0", running: "0.29.0")
            == .required("0.30.0"))
        #expect(UpdateService.minVersionVerdict(.valid("0.29.0"), offered: "v0.31.0", running: "0.29.0")
            == .notRequired)
        #expect(UpdateService.minVersionVerdict(.valid("0.28.0"), offered: "v0.31.0", running: "0.29.0")
            == .notRequired)
        #expect(UpdateService.minVersionVerdict(.absent, offered: "v0.31.0", running: "0.29.0") == .notRequired)
        #expect(UpdateService.minVersionVerdict(.valid("0.32.0"), offered: "v0.31.0", running: "0.29.0")
            == .ignored("min_version 0.32.0 is newer than the offered v0.31.0"))
        #expect(UpdateService.minVersionVerdict(.malformed("soon"), offered: "v0.31.0", running: "0.29.0")
            == .ignored("malformed min_version \"soon\""))
    }

    // MARK: State

    @Test("a required update opens the window on every background check, never on a manual one")
    func requiredPresentsEveryCheck() async {
        var presented = 0
        let svc = service { presented += 1 }
        await svc.applyCheckResult(found("v0.31.0", min: "0.30.0"), previous: .idle, background: true)
        #expect(svc.requiredMinVersion == "0.30.0")
        #expect(svc.isUpdateRequired)
        #expect(presented == 1)
        await svc.applyCheckResult(found("v0.31.0", min: "0.30.0"), previous: svc.state, background: true)
        await svc.applyCheckResult(found("v0.31.0", min: "0.30.0"), previous: svc.state, background: true)
        #expect(presented == 3)
        await svc.applyCheckResult(found("v0.31.0", min: "0.30.0"), previous: svc.state, background: false)
        #expect(presented == 3)
    }

    @Test("a plain update still opens its window once per version")
    func optionalPresentsOnce() async {
        var presented = 0
        let svc = service { presented += 1 }
        await svc.applyCheckResult(found("v0.31.0", min: nil), previous: .idle, background: true)
        await svc.applyCheckResult(found("v0.31.0", min: nil), previous: svc.state, background: true)
        #expect(!svc.isUpdateRequired)
        #expect(presented == 1)
    }

    @Test("a minimum published later on the same release is picked up; the offer is kept")
    func minimumAddedToKnownOffer() async {
        var presented = 0
        let svc = service { presented += 1 }
        await svc.applyCheckResult(found("v0.31.0", min: nil), previous: .idle, background: true)
        let offered = svc.state
        await svc.applyCheckResult(found("v0.31.0", min: "0.30.0"), previous: offered, background: true)
        #expect(svc.state == offered)
        #expect(svc.requiredMinVersion == "0.30.0")
        #expect(presented == 2)
        // And lifted the same way when the channel drops it.
        await svc.applyCheckResult(found("v0.31.0", min: nil), previous: offered, background: true)
        #expect(!svc.isUpdateRequired)
    }

    @Test("an unreachable channel keeps the requirement; only a successful check lifts it")
    func unreachableKeepsRequirement() async {
        let svc = service()
        await svc.applyCheckResult(found("v0.31.0", min: "0.30.0"), previous: .idle, background: true)
        let offered = svc.state
        await svc.applyCheckResult(.failed("offline"), previous: offered, background: true)
        #expect(svc.state == offered)
        #expect(svc.requiredMinVersion == "0.30.0")
        // A failed download left an error; an offline re-check keeps the requirement too.
        svc.state = .error("Download failed")
        await svc.applyCheckResult(.failed("offline"), previous: .error("Download failed"), background: true)
        #expect(svc.requiredMinVersion == "0.30.0")
        // Up to date with nothing on offer: the requirement is gone.
        await svc.applyCheckResult(.upToDate, previous: .idle, background: true)
        #expect(svc.requiredMinVersion == nil)
    }

    @Test("an unreachable channel never invents a requirement")
    func unreachableInventsNothing() async {
        let svc = service()
        await svc.applyCheckResult(.failed("offline"), previous: .idle, background: true)
        #expect(!svc.isUpdateRequired)
    }

    @Test("a malformed minimum fails open and is logged once")
    func malformedFailsOpen() async {
        var logs: [String] = []
        let svc = service()
        svc.log = { logs.append($0) }
        await svc.applyCheckResult(found("v0.31.0", min: "soon"), previous: .idle, background: true)
        await svc.applyCheckResult(found("v0.31.0", min: "soon"), previous: svc.state, background: true)
        #expect(!svc.isUpdateRequired)
        #expect(logs == ["UpdateService: ignoring malformed min_version \"soon\""])
    }

    @Test("a minimum at or below the running version requires nothing")
    func minimumAlreadyMet() async {
        let svc = service()
        await svc.applyCheckResult(found("v0.31.0", min: "0.29.0"), previous: .idle, background: true)
        #expect(!svc.isUpdateRequired)
        await svc.applyCheckResult(found("v0.31.0", min: "0.20"), previous: svc.state, background: true)
        #expect(!svc.isUpdateRequired)
    }

    @Test("no required window over a busy recorder; the next check presents it")
    func requiredWaitsForRecorder() async {
        var presented = 0
        var busy = true
        let svc = service { presented += 1 }
        svc.isBusy = { busy }
        await svc.applyCheckResult(found("v0.31.0", min: "0.30.0"), previous: .idle, background: true)
        #expect(svc.isUpdateRequired)
        #expect(presented == 0)
        busy = false
        await svc.applyCheckResult(found("v0.31.0", min: "0.30.0"), previous: svc.state, background: true)
        #expect(presented == 1)
    }

    @Test("required while a download runs: the pass leaves the download alone, keeps and re-shows the requirement")
    func requiredDuringDownload() async {
        var presented = 0
        var fetches = 0
        let svc = service { presented += 1 }
        await svc.applyCheckResult(found("v0.31.0", min: "0.30.0"), previous: .idle, background: true)
        svc.fetchCheck = {
            fetches += 1
            return .upToDate
        }
        svc.state = .downloading(progress: 0.4)
        svc.startPeriodicChecks { _ in throw CancellationError() }
        await svc.periodicTask?.value
        #expect(fetches == 0)
        #expect(svc.state == .downloading(progress: 0.4))
        #expect(svc.requiredMinVersion == "0.30.0")
        #expect(presented == 2)
    }

    @Test("ready to install: a required release the download cannot meet replaces it on offer")
    func requirementMetOnlyByNewerRelease() async {
        var presented = 0
        let svc = service { presented += 1 }
        await svc.applyCheckResult(found("v0.31.0", min: nil), previous: .idle, background: true)
        svc.state = .readyToInstall(appPath: URL(fileURLWithPath: "/tmp/W.app"))
        svc.fetchCheck = { self.found("v0.33.0", min: "0.32.0") }
        svc.startPeriodicChecks { _ in throw CancellationError() }
        await svc.periodicTask?.value
        #expect(svc.requiredMinVersion == "0.32.0")
        #expect(svc.state == .available(version: "v0.33.0", notes: "n", downloadURL: url))
        #expect(presented == 2)
    }

    @Test("ready to install: up to date lifts the requirement and keeps the download")
    func upToDateLiftsRequirementWhileReady() async {
        var presented = 0
        let svc = service { presented += 1 }
        await svc.applyCheckResult(found("v0.31.0", min: "0.30.0"), previous: .idle, background: true)
        let ready = UpdateService.UpdateState.readyToInstall(appPath: URL(fileURLWithPath: "/tmp/W.app"))
        svc.state = ready
        svc.fetchCheck = { .upToDate }
        svc.startPeriodicChecks { _ in throw CancellationError() }
        await svc.periodicTask?.value
        #expect(svc.state == ready)
        #expect(!svc.isUpdateRequired)
        #expect(presented == 1)
    }

    @Test("a kept newer offer does not make a minimum the publishing release misses required")
    func minimumJudgedAgainstPublishingRelease() async {
        var logs: [String] = []
        let svc = service()
        svc.log = { logs.append($0) }
        await svc.applyCheckResult(found("v0.32.0", min: nil), previous: .idle, background: true)
        await svc.applyCheckResult(found("v0.31.0", min: "0.32.0"), previous: svc.state, background: true)
        #expect(svc.availableVersion == "v0.32.0")
        #expect(!svc.isUpdateRequired)
        #expect(logs == ["UpdateService: ignoring min_version 0.32.0 is newer than the offered v0.31.0"])
    }

    @Test("up to date lifts the requirement even while an offer is kept")
    func upToDateLiftsRequirementOnKeptOffer() async {
        let svc = service()
        await svc.applyCheckResult(found("v0.31.0", min: "0.30.0"), previous: .idle, background: true)
        let offered = svc.state
        await svc.applyCheckResult(.upToDate, previous: offered, background: true)
        #expect(svc.state == offered)
        #expect(!svc.isUpdateRequired)
    }

    @Test("a window a busy recorder held back is shown by the next check even when it fails")
    func requiredWindowRetriedOnFailedCheck() async {
        var presented = 0
        var busy = true
        let svc = service { presented += 1 }
        svc.isBusy = { busy }
        await svc.applyCheckResult(found("v0.31.0", min: "0.30.0"), previous: .idle, background: true)
        #expect(presented == 0)
        busy = false
        await svc.applyCheckResult(.failed("offline"), previous: svc.state, background: true)
        #expect(presented == 1)
        #expect(svc.isUpdateRequired)
    }

    @Test("ready to install: a pass learns a newly published minimum without touching the download")
    func requirementLearnedWhileReadyToInstall() async {
        var presented = 0
        let svc = service { presented += 1 }
        await svc.applyCheckResult(found("v0.31.0", min: nil), previous: .idle, background: true)
        let ready = UpdateService.UpdateState.readyToInstall(appPath: URL(fileURLWithPath: "/tmp/W.app"))
        svc.state = ready
        svc.fetchCheck = { self.found("v0.31.0", min: "0.30.0") }
        svc.startPeriodicChecks { _ in throw CancellationError() }
        await svc.periodicTask?.value
        #expect(svc.state == ready)
        #expect(svc.requiredMinVersion == "0.30.0")
        #expect(presented == 2)
    }
}
