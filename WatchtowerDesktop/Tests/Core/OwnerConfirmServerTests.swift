import Foundation
import XCTest
@testable import WatchtowerCore

/// AGENT-07 (board #568): the Desktop's side of the owner's confirmation.
@MainActor
final class OwnerConfirmServerTests: XCTestCase {
    private var dir: String = ""
    private var server: OwnerConfirmServer?
    private var prompts: [OwnerConfirmPrompt] = []

    override func setUp() async throws {
        // sun_path is 104 bytes: NSTemporaryDirectory() is too long on macOS.
        dir = "/tmp/occ-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        server?.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func start(grants: OwnerConfirmGrants = OwnerConfirmGrants(), timeout: Duration = .seconds(30)) throws {
        let server = OwnerConfirmServer(path: dir + "/s.sock", grants: grants, timeout: timeout) { [weak self] in
            self?.prompts.append($0)
        }
        try server.start()
        self.server = server
    }

    /// One CLI round trip on a background thread; the reply line, or nil
    /// when the connection closed without one.
    private func ask(_ request: OwnerConfirmRequest, hangUpAfter: TimeInterval? = nil) -> Task<OwnerConfirmReply?, Never> {
        let path = dir + "/s.sock"
        return Task.detached {
            UnixLineClient.roundTrip(path: path, line: try? JSONEncoder().encode(request), hangUpAfter: hangUpAfter)
                .flatMap { try? JSONDecoder().decode(OwnerConfirmReply.self, from: $0) }
        }
    }

    private func waitForPrompt(count: Int = 1) async throws {
        for _ in 0..<200 where prompts.count < count {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(prompts.count, count)
    }

    func testTheDesktopsOwnLaunchIsConfirmedWithoutAWindow() async throws {
        let grants = OwnerConfirmGrants()
        grants.register(["actions", "approve", "5", "--json"])
        try start(grants: grants)
        let reply = await ask(OwnerConfirmRequest(verb: "approve an action", args: ["actions", "approve", "5", "--json"])).value
        XCTAssertEqual(reply?.decision, OwnerConfirmReply.confirmed)
        XCTAssertTrue(prompts.isEmpty)
    }

    func testAnotherCommandOpensAWindowAndTheClickAnswers() async throws {
        try start()
        let confirmed = ask(OwnerConfirmRequest(verb: "approve an action", args: ["actions", "approve", "5"], agent: "CLAUDECODE"))
        try await waitForPrompt()
        XCTAssertEqual(prompts[0].request.agent, "CLAUDECODE")
        prompts[0].answer(true)
        let reply = await confirmed.value
        XCTAssertEqual(reply?.decision, OwnerConfirmReply.confirmed)

        let denied = ask(OwnerConfirmRequest(verb: "confirm an automation", args: ["automations", "confirm", "1"]))
        try await waitForPrompt(count: 2)
        prompts[1].answer(false)
        let deniedReply = await denied.value
        XCTAssertEqual(deniedReply?.decision, OwnerConfirmReply.denied)
    }

    func testOneWindowAtATime() async throws {
        try start()
        let first = ask(OwnerConfirmRequest(verb: "a", args: ["actions", "approve", "1"]))
        try await waitForPrompt()
        let second = await ask(OwnerConfirmRequest(verb: "b", args: ["actions", "approve", "2"])).value
        XCTAssertEqual(second?.decision, OwnerConfirmReply.denied)
        XCTAssertEqual(second?.reason, "another confirmation is already open")
        XCTAssertEqual(prompts.count, 1)
        prompts[0].answer(true)
        _ = await first.value
    }

    func testAHangUpWithdrawsTheWindow() async throws {
        try start()
        let gone = ask(OwnerConfirmRequest(verb: "a", args: ["actions", "approve", "1"]), hangUpAfter: 0.3)
        try await waitForPrompt()
        var withdrawn = false
        prompts[0].onWithdraw = { withdrawn = true }
        _ = await gone.value
        for _ in 0..<100 where !withdrawn { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(withdrawn)
        // The slot is free again.
        let next = ask(OwnerConfirmRequest(verb: "b", args: ["actions", "approve", "2"]))
        try await waitForPrompt(count: 2)
        prompts[1].answer(false)
        _ = await next.value
    }

    func testTheWaitRunsOut() async throws {
        try start(timeout: .milliseconds(200))
        let reply = await ask(OwnerConfirmRequest(verb: "a", args: ["actions", "approve", "1"])).value
        XCTAssertEqual(reply?.decision, OwnerConfirmReply.denied)
    }

    func testGrantsAreSingleUseAndExpire() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let grants = OwnerConfirmGrants { clock.now }
        grants.register(["a"])
        XCTAssertFalse(grants.consume(["b"]))
        XCTAssertTrue(grants.consume(["a"]))
        XCTAssertFalse(grants.consume(["a"]), "used once")
        grants.register(["a"])
        clock.now = clock.now.addingTimeInterval(OwnerConfirmGrants.lifetime + 1)
        XCTAssertFalse(grants.consume(["a"]), "expired")
    }

    func testTheWindowTextCannotBeSpoofed() {
        let request = OwnerConfirmRequest(verb: "v", detail: "a\u{202E}cba\u{200B}", args: ["actions", "approve", "1 2", "\u{0007}"])
        XCTAssertEqual(request.commandLine, "watchtower actions approve \"1 2\" \u{FFFD}")
        XCTAssertEqual(request.displayDetail, "a\u{FFFD}cba\u{FFFD}")
        XCTAssertEqual(OwnerConfirmServer.socketPath(databasePath: "/w/ws/watchtower.db"), "/w/ws/owner-confirm.sock")
    }

    func testAPathTooLongIsRefused() {
        let server = OwnerConfirmServer(path: "/" + String(repeating: "x", count: 120)) { _ in }
        XCTAssertThrowsError(try server.start())
    }
}

/// A blocking unix-socket client: sends `line` + "\n", reads one reply line.
/// With `hangUpAfter`, closes after that many seconds instead of waiting.
private enum UnixLineClient {
    static func roundTrip(path: String, line: Data?, hangUpAfter: TimeInterval?) -> Data? {
        guard let line else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() where i < raw.count - 1 { raw[i] = b }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        // The listener binds asynchronously after start().
        var ok = false
        for _ in 0..<100 where !ok {
            ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) == 0 }
            }
            if !ok { Thread.sleep(forTimeInterval: 0.02) }
        }
        guard ok else { return nil }
        let payload = line + Data([UInt8(ascii: "\n")])
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, payload.count) }
        if let hangUpAfter {
            Thread.sleep(forTimeInterval: hangUpAfter)
            return nil
        }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
            if out.contains(UInt8(ascii: "\n")) { break }
        }
        guard let end = out.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        return out[..<end]
    }
}
