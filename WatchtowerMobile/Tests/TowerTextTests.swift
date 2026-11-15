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
        XCTAssertEqual(TowerHost(nil), .mac, "before the first heartbeat: today's Mac wording")
        XCTAssertEqual(TowerHost(heartbeat(nil)), .mac, "an older hub sends no kind")
        XCTAssertEqual(TowerHost(heartbeat(.mac)), .mac)
        XCTAssertEqual(TowerHost(heartbeat(.server)), .server)
        XCTAssertEqual(TowerHost(heartbeat(HubKind(rawValue: "appliance"))), .server, "an unknown kind gets no Mac menus")
    }

    func testOnlyAMacHostPointsIntoTheMacApp() {
        let mac = TowerHost.mac
        let server = TowerHost.server
        for text in [mac.typingWait, mac.permissionsWait, mac.startSessionsAllow, mac.notAllowed("start sessions")] {
            XCTAssertTrue(text.contains("Watchtower → Settings → Mobile"), text)
        }
        for text in [server.typingWait, server.permissionsWait, server.startSessionsAllow, server.notAllowed("run automations")] {
            XCTAssertFalse(text.contains("Settings → Mobile"), text)
            XCTAssertFalse(text.contains("Mac"), text)
            XCTAssertTrue(text.contains("watchtower hub allow <phone>"), text)
        }
        XCTAssertEqual(mac.bringForwardTitle, "Bring the window forward on the Mac")
        XCTAssertNil(server.bringForwardTitle, "a server has no window to bring forward")
        XCTAssertEqual(server.typingWait, "Waiting for your tower to allow typing: run watchtower hub allow <phone> typing on it.")
        XCTAssertEqual(
            server.notAllowed("start sessions"),
            "Your tower has not allowed this phone to start sessions. On it: watchtower hub allow <phone> typing, then start_sessions."
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
/// Sources that says Mac or Macs, outside comments and log lines, must be on
/// the allowlist. TowerText.swift holds the Mac-only instructions and the
/// pairing explanation; the rest are named one by one.
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

    func testNoNewMacInUserFacingStrings() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "Sources is out of reach: \(sources.path)")
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        let mac = try NSRegularExpression(pattern: #"\bMacs?\b"#)
        let log = try NSRegularExpression(pattern: #"(?i)logger|\.(notice|error|fault|debug|info)\("#)
        var found: [String] = []
        for file in files {
            let relative = String(file.path.dropFirst(sources.path.count + 1))
            if Self.allowedFiles.contains(relative) { continue }
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
        XCTAssertEqual(found, [], "Say tower or the hub's name (TowerText); a Mac-only instruction goes in TowerText.swift")
    }
}
