import Foundation
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
        let json = """
        {
            "tag_name": "v1.2.3",
            "name": "Release 1.2.3",
            "body": "## Notes\\n- bugfix",
            "assets": [
                {"name":"Watchtower.app.zip","browser_download_url":"https://gh/x.zip","size":12345}
            ]
        }
        """.data(using: .utf8)!

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
        let json = """
        {"tag_name":"v0.1.0","assets":[]}
        """.data(using: .utf8)!

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

    @Test("parseTeamIdentifier extracts a valid Team ID from codesign -dv output")
    func parseTeamIdentifierValid() {
        let output = """
        Executable=/Applications/Watchtower.app/Contents/MacOS/Watchtower
        Identifier=com.watchtower.desktop
        Format=app bundle with Mach-O universal (x86_64 arm64)
        CodeDirectory v=20500 size=1234 flags=0x10000(runtime) hashes=1+7 location=embedded
        Signature size=4681
        Authority=Apple Development: Someone (ABCDE12345)
        Authority=Apple Worldwide Developer Relations Certification Authority
        Authority=Apple Root CA
        TeamIdentifier=ABCDE12345
        Sealed Resources version=2 rules=13 files=42
        Internal requirements count=1 size=180
        """
        #expect(UpdateService.parseTeamIdentifier(from: output) == "ABCDE12345")
    }

    @Test("parseTeamIdentifier returns nil when Team ID is not set (ad-hoc signature)")
    func parseTeamIdentifierNotSet() {
        let output = """
        Executable=/Applications/Watchtower.app/Contents/MacOS/Watchtower
        Identifier=com.watchtower.desktop
        Format=app bundle with Mach-O universal (x86_64 arm64)
        Signature=adhoc
        TeamIdentifier=not set
        """
        #expect(UpdateService.parseTeamIdentifier(from: output) == nil)
    }

    @Test("parseTeamIdentifier returns nil when there is no TeamIdentifier line at all")
    func parseTeamIdentifierMissing() {
        let output = "Executable=/tmp/x\nIdentifier=com.example\n"
        #expect(UpdateService.parseTeamIdentifier(from: output) == nil)
    }

    @Test("parseTeamIdentifier rejects malformed values instead of passing them through")
    func parseTeamIdentifierMalformed() {
        // Guards against embedding unexpected characters into a shell command.
        #expect(UpdateService.parseTeamIdentifier(from: "TeamIdentifier=abc\n") == nil)
        #expect(UpdateService.parseTeamIdentifier(from: "TeamIdentifier=ABCDE123456\n") == nil)
        #expect(UpdateService.parseTeamIdentifier(from: "TeamIdentifier=ABCDE\"1234\n") == nil)
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
