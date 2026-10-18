import Foundation
import XCTest
@testable import WatchtowerCore

/// AGENT-07 (board #568, ask #357): the Desktop's side of the owner's confirmation.
@MainActor
final class OwnerConfirmServerTests: XCTestCase {
    private var dir: String = ""
    private var server: OwnerConfirmServer?
    private var prompts: [OwnerConfirmPrompt] = []
    private var socketPath: String { dir + "/s.sock" }

    override func setUp() async throws {
        // sun_path is 104 bytes: NSTemporaryDirectory() is too long on macOS.
        dir = "/tmp/occ-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        server?.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// No cooldown by default: every request here comes from this one pid.
    private func start(
        grants: OwnerConfirmGrants = OwnerConfirmGrants(),
        timeout: Duration = .seconds(30),
        cooldown: Duration = .zero
    ) throws {
        let server = OwnerConfirmServer(path: socketPath, grants: grants, timeout: timeout,
                                        cooldown: cooldown) { [weak self] in
            self?.prompts.append($0)
        }
        try server.start()
        self.server = server
    }

    /// One CLI round trip on a background thread; the reply, or nil when the
    /// connection closed without one.
    private func ask(_ request: OwnerConfirmRequest, hangUpAfter: TimeInterval? = nil) -> Task<OwnerConfirmReply?, Never> {
        let path = socketPath
        let line = try? JSONEncoder().encode(request)
        return Task.detached {
            UnixLineClient.roundTrip(path: path, line: line, hangUpAfter: hangUpAfter)
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
        grants.register(["actions", "approve", "5", "--json"], pid: getpid())
        try start(grants: grants)
        let reply = await ask(OwnerConfirmRequest(verb: "approve an action", args: ["actions", "approve", "5", "--json"])).value
        XCTAssertEqual(reply?.decision, OwnerConfirmReply.confirmed)
        XCTAssertTrue(prompts.isEmpty)
    }

    /// F12: a grant is the Desktop's child's, by pid — the same argv from
    /// another process still gets the window.
    func testAGrantForAnotherPidDoesNotConfirm() async throws {
        let grants = OwnerConfirmGrants()
        grants.register(["actions", "approve", "5"], pid: getpid() + 1)
        try start(grants: grants)
        let pending = ask(OwnerConfirmRequest(verb: "approve an action", args: ["actions", "approve", "5"]))
        try await waitForPrompt()
        prompts[0].answer(false)
        let reply = await pending.value
        XCTAssertEqual(reply?.decision, OwnerConfirmReply.denied)
    }

    func testAnotherCommandOpensAWindowAndTheClickAnswers() async throws {
        try start()
        let confirmed = ask(OwnerConfirmRequest(verb: "approve an action", detail: "Args: {\"text\":\"hi\"}",
                                                args: ["actions", "approve", "5"]))
        try await waitForPrompt()
        XCTAssertEqual(prompts[0].request.detail, "Args: {\"text\":\"hi\"}")
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
        let gone = ask(OwnerConfirmRequest(verb: "a", args: ["actions", "approve", "1"]), hangUpAfter: 0.6)
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

    /// F11: a connection that sends no line is closed after the read timeout.
    func testASilentConnectionIsClosed() async throws {
        try start()
        let path = socketPath
        let closed = await Task.detached { UnixLineClient.closedWithoutAnswer(path: path, within: 8) }.value
        XCTAssertTrue(closed)
        XCTAssertTrue(prompts.isEmpty)
    }

    /// F10: past the cap, a connection is closed unread.
    func testConnectionsAreCapped() async throws {
        try start()
        let path = socketPath
        let fds = (0..<OwnerConfirmServer.maxConnections).compactMap { _ in UnixLineClient.connect(path: path) }
        defer { fds.forEach { close($0) } }
        XCTAssertEqual(fds.count, OwnerConfirmServer.maxConnections)
        try await Task.sleep(for: .milliseconds(200))
        let reply = await ask(OwnerConfirmRequest(verb: "a", args: ["x"])).value
        XCTAssertNil(reply, "the extra connection was closed")
        XCTAssertTrue(prompts.isEmpty)
    }

    /// F2: idle connections filling the cap do not lock the Desktop's own
    /// child out: a pid with a live grant is admitted past the cap.
    func testAGrantedPidIsAdmittedPastTheCap() async throws {
        let grants = OwnerConfirmGrants()
        try start(grants: grants)
        let path = socketPath
        let fds = (0..<OwnerConfirmServer.maxConnections).compactMap { _ in UnixLineClient.connect(path: path) }
        defer { fds.forEach { close($0) } }
        XCTAssertEqual(fds.count, OwnerConfirmServer.maxConnections)
        try await Task.sleep(for: .milliseconds(200))
        grants.register(["actions", "approve", "9"], pid: getpid())
        let reply = await ask(OwnerConfirmRequest(verb: "a", args: ["actions", "approve", "9"])).value
        XCTAssertEqual(reply?.decision, OwnerConfirmReply.confirmed)
        XCTAssertTrue(prompts.isEmpty)
    }

    /// F5/N1: after a Deny no new window opens for a while, whoever asks;
    /// the Desktop's own launch is still confirmed by its grant.
    func testADenyCoolsWindowsDownButNotGrants() async throws {
        let grants = OwnerConfirmGrants()
        try start(grants: grants, cooldown: .seconds(30))
        let first = ask(OwnerConfirmRequest(verb: "a", args: ["actions", "approve", "1"]))
        try await waitForPrompt()
        prompts[0].answer(false)
        _ = await first.value
        let other = await ask(OwnerConfirmRequest(verb: "b", args: ["automations", "confirm", "2"])).value
        XCTAssertEqual(other?.reason, OwnerConfirmServer.cooldownReason, "another command waits too")
        grants.register(["actions", "approve", "3"], pid: getpid())
        let own = await ask(OwnerConfirmRequest(verb: "c", args: ["actions", "approve", "3"])).value
        XCTAssertEqual(own?.decision, OwnerConfirmReply.confirmed, "the Desktop's own button is not held back")
        XCTAssertEqual(prompts.count, 1)
    }

    func testADenyCoolsThePidDown() async throws {
        try start(cooldown: .seconds(30))
        let first = ask(OwnerConfirmRequest(verb: "a", args: ["actions", "approve", "1"]))
        try await waitForPrompt()
        prompts[0].answer(false)
        _ = await first.value
        let again = await ask(OwnerConfirmRequest(verb: "a", args: ["actions", "approve", "1"])).value
        XCTAssertEqual(again?.decision, OwnerConfirmReply.denied)
        XCTAssertEqual(again?.reason, OwnerConfirmServer.cooldownReason)
        XCTAssertEqual(prompts.count, 1, "no second window")
    }

    func testStopRemovesTheSocketFile() throws {
        try start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        server?.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testALiveServerOnThePathIsAnotherServer() throws {
        try start()
        let second = OwnerConfirmServer(path: socketPath) { _ in }
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? OwnerConfirmServer.ServerError, .anotherServer)
        }
    }

    func testGrantsAreSingleUseAndExpire() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let grants = OwnerConfirmGrants { clock.now }
        grants.register(["a"], pid: 7)
        XCTAssertFalse(grants.consume(["b"], pid: 7))
        XCTAssertFalse(grants.consume(["a"], pid: 8))
        XCTAssertTrue(grants.consume(["a"], pid: 7))
        XCTAssertFalse(grants.consume(["a"], pid: 7), "used once")
        grants.register(["a"], pid: 7)
        clock.now = clock.now.addingTimeInterval(OwnerConfirmGrants.lifetime + 1)
        XCTAssertFalse(grants.consume(["a"], pid: 7), "expired")
        // F9: a grant goes with its child.
        grants.register(["b"], pid: 9)
        XCTAssertTrue(grants.hasLive(pid: 9))
        grants.revoke(pid: 9)
        XCTAssertFalse(grants.hasLive(pid: 9))
        XCTAssertFalse(grants.consume(["b"], pid: 9))
    }

    func testConfirmArmsAfterOneSecond() {
        let shown = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(OwnerConfirmArming.isArmed(shownAt: shown, now: shown))
        XCTAssertFalse(OwnerConfirmArming.isArmed(shownAt: shown, now: shown.addingTimeInterval(0.9)))
        XCTAssertTrue(OwnerConfirmArming.isArmed(shownAt: shown, now: shown.addingTimeInterval(1)))
    }

    func testTheWindowTextIsFullAndCannotBeSpoofed() {
        let long = String(repeating: "y", count: 5000)
        let request = OwnerConfirmRequest(verb: "v", detail: "a\u{202E}cba\u{200B}\nline2 " + long,
                                          args: ["actions", "approve", "1 2", "\u{0007}", long])
        XCTAssertEqual(request.commandLine, "watchtower actions approve '1 2' '\u{FFFD}' " + long)
        // F10: quoting leaves no doubt where an arg ends.
        let tricky = OwnerConfirmRequest(verb: "v", args: ["--patch", #"{"text":"a b"}"#, "it's", "", "a=b/c:d@e%f+g-h.i_j"])
        XCTAssertEqual(tricky.commandLine,
                       #"watchtower --patch '{"text":"a b"}' 'it'\''s' '' a=b/c:d@e%f+g-h.i_j"#)
        XCTAssertEqual(request.displayDetail, "a\u{FFFD}cba\u{FFFD}\nline2 " + long)
        XCTAssertEqual(OwnerConfirmServer.socketPath(databasePath: "/w/ws/watchtower.db"), "/w/ws/owner-confirm.sock")
    }

    func testAPathTooLongIsRefused() {
        let server = OwnerConfirmServer(path: "/" + String(repeating: "x", count: 120)) { _ in }
        XCTAssertThrowsError(try server.start())
    }
}

/// A blocking unix-socket client for the tests.
private enum UnixLineClient {
    static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        // A write to a connection the server closed must not SIGPIPE the test process.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() where i < raw.count - 1 { raw[i] = b }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) == 0 }
        }
        guard ok else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Sends `line` + "\n" and reads one reply line; with `hangUpAfter`,
    /// closes after that many seconds instead.
    static func roundTrip(path: String, line: Data?, hangUpAfter: TimeInterval?) -> Data? {
        guard let line, let fd = connect(path: path) else { return nil }
        defer { close(fd) }
        let payload = line + Data([UInt8(ascii: "\n")])
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, payload.count) }
        if let hangUpAfter {
            Thread.sleep(forTimeInterval: hangUpAfter)
            return nil
        }
        return readLine(fd)
    }

    /// Connects, sends nothing, and reports whether the server closed the
    /// connection within `within` seconds.
    static func closedWithoutAnswer(path: String, within: TimeInterval) -> Bool {
        guard let fd = connect(path: path) else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(within), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        return read(fd, &byte, 1) == 0
    }

    private static func readLine(_ fd: Int32) -> Data? {
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
