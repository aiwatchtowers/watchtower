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

/// The install steps run off the main actor, so the recorder guards its
/// state with a lock. The failure flags are set before the steps run.
private final class InstallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var recordedTeamID: String?
    var failStage = false
    var failVerify = false
    var failReplace = false
    var writable = true

    var calls: [String] { lock.withLock { recorded } }
    var verifiedTeamID: String? { lock.withLock { recordedTeamID } }

    private func record(_ call: String, teamID: String? = nil) {
        lock.withLock {
            recorded.append(call)
            if let teamID { recordedTeamID = teamID }
        }
    }

    struct Boom: LocalizedError {
        let what: String
        var errorDescription: String? { "\(what) boom" }
    }

    var steps: UpdateService.InstallSteps {
        UpdateService.InstallSteps(
            canWrite: { _ in
                self.record("canWrite")
                return self.writable
            },
            stage: { _, _ in
                self.record("stage")
                if self.failStage { throw Boom(what: "stage") }
                return URL(fileURLWithPath: "/staged/Watchtower.app")
            },
            verify: { _, team in
                self.record("verify", teamID: team)
                if self.failVerify { throw Boom(what: "verify") }
            },
            replace: { _, _ in
                self.record("replace")
                if self.failReplace { throw Boom(what: "replace") }
            },
            discard: { _ in self.record("discard") }
        )
    }
}

@Suite("UpdateService In-Process Install")
@MainActor
struct UpdateServiceInstallTests {
    private let newApp = URL(fileURLWithPath: "/downloads/Watchtower.app")
    private let currentApp = URL(fileURLWithPath: "/Applications/Watchtower.app")

    private func run(_ rec: InstallRecorder, teamID: String? = "ABCDE12345") -> UpdateService.InstallOutcome {
        UpdateService.performInstall(newApp: newApp, currentApp: currentApp, teamID: teamID, steps: rec.steps)
    }

    @Test("happy path: writability, stage, verify against our Team ID, then swap with nothing in between")
    func happyPathOrder() async {
        let rec = InstallRecorder()
        #expect(run(rec) == .installed)
        // verify -> replace back to back: no step (and no daemon stop) may sit
        // between the check and the use of the staged bundle.
        #expect(rec.calls == ["canWrite", "stage", "verify", "replace", "discard"])
        #expect(rec.verifiedTeamID == "ABCDE12345")
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

    @Test("staging failure surfaces an error and stops nothing")
    func stageFailure() async {
        let rec = InstallRecorder()
        rec.failStage = true
        let outcome = run(rec)
        guard case .failed(let message) = outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("stage boom"))
        #expect(rec.calls == ["canWrite", "stage"])
    }

    @Test("signature failure discards the staged app and never swaps")
    func verifyFailure() async {
        let rec = InstallRecorder()
        rec.failVerify = true
        let outcome = run(rec)
        guard case .failed(let message) = outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("verify boom"))
        #expect(rec.calls == ["canWrite", "stage", "verify", "discard"])
    }

    @Test("swap failure surfaces an error and discards the staged app")
    func replaceFailure() async {
        let rec = InstallRecorder()
        rec.failReplace = true
        let outcome = run(rec)
        guard case .failed(let message) = outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("replace boom"))
        #expect(rec.calls == ["canWrite", "stage", "verify", "replace", "discard"])
    }

    @Test("install refuses while a recording or transcription is busy, before any step")
    func installRefusesWhileBusy() async {
        let rec = InstallRecorder()
        let svc = UpdateService()
        svc.isBusy = { true }
        svc.installSteps = rec.steps
        svc.state = .readyToInstall(appPath: URL(fileURLWithPath: "/downloads/Watchtower.app"))
        await svc.install()
        #expect(svc.state == .error(UpdateService.busyMessage))
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
            try UpdateService.verifySignature(of: app, teamID: "ABCDE12345")
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
            try UpdateService.verifySignature(of: calculator, teamID: "ABCDE12345")
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
        await svc.relaunch()
        #expect(rec.spawned.count == 1)
        #expect(rec.spawned.first?.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(rec.spawned.first?.path == appURL.path)
        #expect(rec.quits == 1)
        #expect(rec.sleeps == [UpdateService.quitGrace])
        #expect(svc.state == .restartRequired)
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
        svc.installSteps = install.steps
        svc.state = .readyToInstall(appPath: URL(fileURLWithPath: "/downloads/Watchtower.app"))
        await svc.install()
        guard case .error(let message) = svc.state else {
            Issue.record("expected .error, got \(svc.state)")
            return
        }
        #expect(message.contains("verify boom"))
        #expect(install.calls == ["canWrite", "stage", "verify", "discard"])
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
}

@Suite("UpdateService Periodic Checks")
@MainActor
struct UpdateServicePeriodicTests {
    private func isolatedDefaults() -> UserDefaults {
        let name = "wt-update-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
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
        #expect(!UpdateService.shouldAutoCheck(state: .restartRequired))
    }

    @Test("the loop skips the check while busy, re-arms on the interval, and clears itself on exit")
    func loopSleepsOnInterval() async {
        let svc = UpdateService()
        svc.buildFlavor = ""
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
    func loopChecksImmediately() async {
        let defaults = isolatedDefaults()
        let svc = UpdateService()
        svc.buildFlavor = ""
        svc.defaults = defaults
        var announced: [String] = []
        svc.announce = { announced.append($0) }
        let url = URL(fileURLWithPath: "/tmp/new.zip")
        svc.fetchCheck = { .found(version: "v99.0.0", notes: "n", downloadURL: url, gated: nil) }
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
            return .found(version: "v99.0.0", notes: "", downloadURL: url, gated: nil)
        }
        await svc.checkForUpdates()
        #expect(svc.state == .downloading(progress: 0.1))
    }

    @Test("an update is announced once per version, across service instances")
    func announceOncePerVersion() {
        let defaults = isolatedDefaults()
        var announced: [String] = []

        let first = UpdateService()
        first.defaults = defaults
        first.announce = { announced.append($0) }
        first.noteAvailable(version: "v1.1.0")
        first.noteAvailable(version: "v1.1.0")
        #expect(first.availableVersion == "v1.1.0")

        // A relaunch (new instance, same defaults) finds the same version again.
        let relaunched = UpdateService()
        relaunched.defaults = defaults
        relaunched.announce = { announced.append($0) }
        relaunched.noteAvailable(version: "v1.1.0")
        relaunched.noteAvailable(version: "v1.2.0")

        #expect(announced == ["v1.1.0", "v1.2.0"])
    }

    @Test("shouldAnnounce compares against the last announced version")
    func shouldAnnounceDecision() {
        #expect(UpdateService.shouldAnnounce(version: "v1.0.0", lastAnnounced: nil))
        #expect(UpdateService.shouldAnnounce(version: "v1.0.1", lastAnnounced: "v1.0.0"))
        #expect(!UpdateService.shouldAnnounce(version: "v1.0.0", lastAnnounced: "v1.0.0"))
    }
}

@Suite("UpdateService Check Results")
@MainActor
struct UpdateServiceCheckResultTests {
    private let oldURL = URL(fileURLWithPath: "/tmp/old.zip")
    private let newURL = URL(fileURLWithPath: "/tmp/new.zip")

    /// A service with an isolated announce memo and a recorder for pushes.
    private func service(announced: @escaping (String) -> Void) -> UpdateService {
        let svc = UpdateService()
        let name = "wt-update-check-tests-\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: name) { svc.defaults = defaults }
        svc.announce = announced
        return svc
    }

    @Test("a found version goes on offer and is noted (tray version + announcement)")
    func foundFromIdle() {
        var announced: [String] = []
        let svc = service { announced.append($0) }
        svc.applyCheckResult(.found(version: "v2.0.0", notes: "n", downloadURL: newURL, gated: nil),
                             previous: .idle, background: true)
        #expect(svc.state == .available(version: "v2.0.0", notes: "n", downloadURL: newURL))
        #expect(svc.availableVersion == "v2.0.0")
        #expect(announced == ["v2.0.0"])
    }

    @Test("up to date clears the known version")
    func upToDateClears() {
        let svc = service { _ in }
        svc.applyCheckResult(.found(version: "v2.0.0", notes: "", downloadURL: newURL, gated: nil),
                             previous: .idle, background: false)
        svc.applyCheckResult(.upToDate, previous: .idle, background: false)
        #expect(svc.state == .idle)
        #expect(svc.availableVersion == nil)
    }

    @Test("an offer is replaced only by a strictly newer version")
    func offerReplacedOnlyByNewer() {
        var announced: [String] = []
        let svc = service { announced.append($0) }
        let offered = UpdateService.UpdateState.available(version: "v2.0.0", notes: "", downloadURL: oldURL)

        svc.applyCheckResult(.found(version: "v2.0.0", notes: "", downloadURL: newURL, gated: nil),
                             previous: offered, background: true)
        #expect(svc.state == offered)

        svc.applyCheckResult(.found(version: "v1.9.0", notes: "", downloadURL: newURL, gated: nil),
                             previous: offered, background: true)
        #expect(svc.state == offered)

        svc.applyCheckResult(.found(version: "v2.1.0", notes: "", downloadURL: newURL, gated: nil),
                             previous: offered, background: true)
        #expect(svc.state == .available(version: "v2.1.0", notes: "", downloadURL: newURL))
        #expect(announced == ["v2.1.0"])
    }

    @Test("a failure or 'up to date' never hides an offer")
    func offerSurvivesFailure() {
        let svc = service { _ in }
        let offered = UpdateService.UpdateState.available(version: "v2.0.0", notes: "", downloadURL: oldURL)
        svc.applyCheckResult(.failed("offline"), previous: offered, background: true)
        #expect(svc.state == offered)
        svc.applyCheckResult(.failed("offline"), previous: offered, background: false)
        #expect(svc.state == offered)
        svc.applyCheckResult(.upToDate, previous: offered, background: true)
        #expect(svc.state == offered)
    }

    @Test("an unattended failure stays idle; a manual one shows the error")
    func failureVisibility() {
        let svc = service { _ in }
        svc.applyCheckResult(.failed("offline"), previous: .idle, background: true)
        #expect(svc.state == .idle)
        svc.applyCheckResult(.failed("offline"), previous: .idle, background: false)
        #expect(svc.state == .error("offline"))
    }
}
