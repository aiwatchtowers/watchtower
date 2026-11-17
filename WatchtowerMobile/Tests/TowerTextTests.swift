import ChatUI
import Foundation
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The hub is a tower (#1783): its name where the phone has one, "your
/// tower" where it has none, and the Mac app's menus only for a Mac hub — a
/// server hub gets `watchtower hub allow`. An older hub (no kind) is a Mac; a
/// kind this build does not know is not.
final class TowerTextTests: XCTestCase {
    private func heartbeat(_ kind: HubKind?) -> HeartbeatPayload {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        return HeartbeatPayload(
            updatedAt: at, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: nil, lastRelayAt: nil, relayBacklog: 0, accounts: [],
            enabledAt: at, ownerUser: "", sharing: .none, hubKind: kind
        )
    }

    func testTheHostComesFromTheHeartbeatKind() {
        let id = "aaaaaaaa-0000-4000-8000-000000000001"
        XCTAssertEqual(TowerHost(nil, device: id), .mac, "before the first heartbeat: today's Mac wording")
        XCTAssertEqual(TowerHost(heartbeat(nil), device: id), .mac, "an older hub sends no kind")
        XCTAssertEqual(TowerHost(heartbeat(.mac), device: id), .mac)
        XCTAssertEqual(
            TowerHost(heartbeat(.server), device: id), .server(device: id.uppercased()), "as `watchtower hub phones` prints it"
        )
        XCTAssertEqual(
            TowerHost(heartbeat(HubKind(rawValue: "appliance")), device: nil), .server(device: nil), "an unknown kind gets no Mac menus"
        )
    }

    func testOnlyAMacHostPointsIntoTheMacApp() {
        let mac = TowerHost.mac
        let id = "AAAAAAAA-0000-4000-8000-000000000001"
        let server = TowerHost.server(device: id)
        for text in [mac.typingWait, mac.permissionsWait, mac.startSessionsAllow, mac.notAllowed("start sessions")] {
            XCTAssertTrue(text.contains("Watchtower → Settings → Mobile"), text)
        }
        for text in [server.typingWait, server.permissionsWait, server.startSessionsAllow, server.notAllowed("run automations")] {
            XCTAssertFalse(text.contains("Settings → Mobile"), text)
            XCTAssertFalse(text.contains("Mac"), text)
            XCTAssertTrue(text.contains("watchtower hub allow \(id) "), text)
            XCTAssertFalse(text.contains("<"), "no placeholder when the phone knows its id: \(text)")
        }
        XCTAssertEqual(mac.bringForwardTitle, "Bring the window forward on the Mac")
        XCTAssertNil(server.bringForwardTitle, "a server has no window to bring forward")
        XCTAssertEqual(server.typingWait, "Waiting for your tower to allow typing. On it, run:\nwatchtower hub allow \(id) typing")
        XCTAssertEqual(
            server.notAllowed("start sessions"),
            "Your tower has not allowed this phone to start sessions. On it, run:\n"
                + "watchtower hub allow \(id) typing\nwatchtower hub allow \(id) start_sessions"
        )
        // Before the grant reached the phone it has no id: the command says where to find it.
        XCTAssertEqual(
            TowerHost.server(device: nil).permissionsWait,
            "Allow answering permission prompts on your tower. On it, run:\n"
                + "watchtower hub phones (find this iPhone's id), then watchtower hub allow <id> permissions"
        )
    }

    func testTheNameWinsOverTheWord() {
        XCTAssertEqual(TowerText.name("Acme Mac"), "Acme Mac")
        XCTAssertEqual(TowerText.name(""), "your tower")
        XCTAssertEqual(TowerText.sentenceName(""), "Your tower")
        XCTAssertEqual(TowerText.label(""), "Tower")
        XCTAssertEqual(MacAwayBanner(.asleep(lastSeen: Date()), name: "Acme Mac", now: Date())?.title, "Acme Mac is asleep")
        XCTAssertEqual(MacAwayBanner(.offline, name: "", now: Date())?.title, "Your tower is offline")
    }

    func testTheSharedChatLinesNameTheTower() {
        let named = ChatHostText.phone("Acme Mac")
        XCTAssertEqual(named.messageCut, "This message is cut here; the whole text is on Acme Mac.")
        XCTAssertEqual(named.artifactCut, "This artifact is cut here; the whole text is on Acme Mac.")
        XCTAssertEqual(named.chooseSlackWorkspace, "Choose a workspace on Acme Mac before approving")
        let unnamed = ChatHostText.phone("")
        XCTAssertEqual(unnamed.messageCut, "This message is cut here; the whole text is on your tower.")
        XCTAssertEqual(unnamed.artifactCut, "This artifact is cut here; the whole text is on your tower.")
        XCTAssertEqual(unnamed.chooseSlackWorkspace, "Choose a workspace on your tower before approving")
    }

    func testPairingExplainsTheWordOnceAndCoversBothKinds() {
        XCTAssertEqual(
            PairingText.welcomeTagline,
            "Asks, sessions, the board and your meetings from your tower — your Mac or server running Watchtower."
        )
        XCTAssertTrue(PairingText.welcomeSteps.contains("Settings → Mobile"))
        XCTAssertTrue(PairingText.welcomeSteps.contains("watchtower hub pair"))
        XCTAssertEqual(PairingText.notShowingLink, "The tower doesn't show up")
        XCTAssertTrue(PairingText.serverFooter.contains("watchtower hub pair"))
    }
}

/// A new user-facing "Mac" fails here (#1783): every string literal under
/// Sources, and under the shared chat views the phone draws
/// (`WatchtowerChat/Sources/ChatUI`, all but its Mac-only `Platform/macOS`),
/// that says Mac or Macs, outside comments and log lines, must be on the
/// allowlist. TowerText.swift holds the Mac-only instructions and the
/// pairing explanation; the rest are named one by one. ChatUI names the
/// machine through `ChatHostText`, which the phone fills with the tower's name.
final class TowerWordGuardTests: XCTestCase {
    /// Files whose "Mac" strings are deliberate: the Mac-app instructions (shown only for a Mac hub) and pairing.
    static let allowedFiles: Set<String> = ["Features/Hubs/TowerText.swift"]
    /// Literals allowed anywhere: the demo hubs' names, and an internal precondition/decoding message.
    static let allowedLiterals: Set<String> = [
        "Acme Mac",
        "Home Mac",
        "Work Mac",
        "a relay link without its Mac's relay device id"
    ]
    /// The shared chat views' folder that only the Mac app compiles.
    static let chatUIMacOnly = "Platform/macOS/"

    private static var tests: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }

    private func swiftFiles(_ root: URL) throws -> [URL] {
        try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    func testNoNewMacInUserFacingStrings() throws {
        let sources = Self.tests.deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try swiftFiles(sources)
        XCTAssertGreaterThan(files.count, 50, "Sources is out of reach: \(sources.path)")
        let found = try macLiterals(files, root: sources, skip: { Self.allowedFiles.contains($0) })
        XCTAssertEqual(found, [], "Say tower or the hub's name (TowerText); a Mac-only instruction goes in TowerText.swift")
    }

    func testNoMacInTheSharedChatViewsThePhoneDraws() throws {
        let chatUI = Self.tests.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WatchtowerChat/Sources/ChatUI")
        let files = try swiftFiles(chatUI)
        XCTAssertGreaterThan(files.count, 30, "ChatUI is out of reach: \(chatUI.path)")
        let found = try macLiterals(files, root: chatUI, skip: { $0.hasPrefix(Self.chatUIMacOnly) })
        XCTAssertEqual(found, [], "Say tower or the hub's name: a line that names the machine goes through ChatHostText")
    }

    /// Every "Mac"/"Macs" string literal in `files`, outside comments and log lines, that is not allowed anywhere.
    private func macLiterals(_ files: [URL], root: URL, skip: (String) -> Bool) throws -> [String] {
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        let mac = try NSRegularExpression(pattern: #"\bMacs?\b"#)
        let log = try NSRegularExpression(pattern: #"(?i)logger|\.(notice|error|fault|debug|info)\("#)
        var found: [String] = []
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if skip(relative) { continue }
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let whole = NSRange(line.startIndex..., in: line)
                if trimmed.hasPrefix("//") || log.firstMatch(in: line, range: whole) != nil { continue }
                for match in literal.matches(in: line, range: whole) {
                    guard let range = Range(match.range(at: 1), in: line) else { continue }
                    let text = String(line[range])
                    if mac.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
                       !Self.allowedLiterals.contains(text) {
                        found.append("\(relative):\(index + 1): \(text)")
                    }
                }
            }
        }
        return found
    }
}
