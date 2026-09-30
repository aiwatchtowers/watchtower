import Foundation
import Security
import Testing
@testable import WatchtowerDesktop

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

/// Records the order of install steps; each step can be made to fail.
@MainActor
private final class InstallRecorder {
    var calls: [String] = []
    var failStage = false
    var failVerify = false
    var failReplace = false
    var verifiedTeamID: String?

    struct Boom: LocalizedError {
        let what: String
        var errorDescription: String? { "\(what) boom" }
    }

    var steps: UpdateService.InstallSteps {
        UpdateService.InstallSteps(
            stage: { [unowned self] _, _ in
                calls.append("stage")
                if failStage { throw Boom(what: "stage") }
                return URL(fileURLWithPath: "/staged/Watchtower.app")
            },
            verify: { [unowned self] _, team in
                calls.append("verify")
                verifiedTeamID = team
                if failVerify { throw Boom(what: "verify") }
            },
            stopDaemon: { [unowned self] in calls.append("stopDaemon") },
            replace: { [unowned self] _, _ in
                calls.append("replace")
                if failReplace { throw Boom(what: "replace") }
            },
            discard: { [unowned self] _ in calls.append("discard") }
        )
    }
}

@Suite("UpdateService In-Process Install")
@MainActor
struct UpdateServiceInstallTests {
    private let newApp = URL(fileURLWithPath: "/downloads/Watchtower.app")
    private let currentApp = URL(fileURLWithPath: "/Applications/Watchtower.app")

    private func run(_ rec: InstallRecorder, teamID: String? = "ABCDE12345") async -> UpdateService.InstallOutcome {
        await UpdateService.performInstall(newApp: newApp, currentApp: currentApp, teamID: teamID, steps: rec.steps)
    }

    @Test("happy path: stage, verify against our Team ID, stop daemon, swap")
    func happyPath() async {
        let rec = InstallRecorder()
        #expect(await run(rec) == .installed)
        #expect(rec.calls == ["stage", "verify", "stopDaemon", "replace", "discard"])
        #expect(rec.verifiedTeamID == "ABCDE12345")
    }

    @Test("no Team ID for the running app refuses before touching anything")
    func noTeamIDFailsClosed() async {
        let rec = InstallRecorder()
        let outcome = await run(rec, teamID: nil)
        guard case .failed(let message) = outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("Team ID"))
        #expect(rec.calls.isEmpty)
    }

    @Test("malformed Team ID is treated as no Team ID")
    func malformedTeamIDFailsClosed() async {
        let rec = InstallRecorder()
        #expect(await run(rec, teamID: "not set") != .installed)
        #expect(rec.calls.isEmpty)
    }

    @Test("staging failure surfaces an error and stops nothing")
    func stageFailure() async {
        let rec = InstallRecorder()
        rec.failStage = true
        let outcome = await run(rec)
        guard case .failed(let message) = outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("stage boom"))
        #expect(rec.calls == ["stage"])
    }

    @Test("signature failure discards the staged app and never stops the daemon or swaps")
    func verifyFailure() async {
        let rec = InstallRecorder()
        rec.failVerify = true
        let outcome = await run(rec)
        guard case .failed(let message) = outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("verify boom"))
        #expect(rec.calls == ["stage", "verify", "discard"])
    }

    @Test("swap failure surfaces an error and discards the staged app")
    func replaceFailure() async {
        let rec = InstallRecorder()
        rec.failReplace = true
        let outcome = await run(rec)
        guard case .failed(let message) = outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("replace boom"))
        #expect(rec.calls == ["stage", "verify", "stopDaemon", "replace", "discard"])
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
            setxattr(path!, Self.quarantine, value, value.count, 0, XATTR_NOFOLLOW)
        }
        #expect(status == 0)
    }

    private func hasQuarantine(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            getxattr(path!, Self.quarantine, nil, 0, 0, XATTR_NOFOLLOW) >= 0
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
            try UpdateService.verifySignature(of: app, teamID: "ABCDE12345")
        }
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
        #expect(script.hasSuffix(#"/usr/bin/open "/Apps/We\"ird \$App\`.app""#))
        // Never touches files: the waiter only waits and opens.
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
}
