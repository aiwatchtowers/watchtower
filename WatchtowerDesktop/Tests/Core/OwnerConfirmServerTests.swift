import Foundation
import XCTest
@testable import WatchtowerCore

/// AGENT-07 (board #568, ask #357): the Desktop's side of the owner's confirmation.
@MainActor
final class OwnerConfirmServerTests: XCTestCase {
    private var dir: String = ""
    private var server: OwnerConfirmServer?
    private var prompts: [OwnerConfirmPrompt] = [] {
        didSet {
            let due = promptWaiters.filter { $0.count <= prompts.count }
            promptWaiters.removeAll { $0.count <= prompts.count }
            due.forEach { $0.continuation.resume() }
        }
    }
    private var promptWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    /// Counts the connections the server admitted.
    private let admitted = AdmitCount()
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
        cooldown: Duration = .zero,
        lineTimeout: TimeInterval = OwnerConfirmServer.readTimeout,
        sleep: @escaping (Duration) async -> Void = { _ in await parkUntilCancelled() }
    ) throws {
        let admitted = admitted
        let onAdmit: @Sendable (Int) -> Void = { admitted.reached($0) }
        let server = OwnerConfirmServer(path: socketPath, grants: grants, cooldown: cooldown,
                                        lineTimeout: lineTimeout, sleep: sleep,
                                        onAdmit: onAdmit) { [weak self] in
            self?.prompts.append($0)
        }
        try server.start()
        self.server = server
    }

    /// One CLI round trip on a background thread; the reply, or nil when the
    /// connection closed without one.
    /// With `hangUp`, the client closes once it is signalled instead of
    /// reading the reply.
    private func ask(_ request: OwnerConfirmRequest, hangUp: DispatchSemaphore? = nil) -> Task<OwnerConfirmReply?, Never> {
        let path = socketPath
        let line = try? JSONEncoder().encode(request)
        return Task.detached {
            UnixLineClient.roundTrip(path: path, line: line, hangUp: hangUp)
                .flatMap { try? JSONDecoder().decode(OwnerConfirmReply.self, from: $0) }
        }
    }

    /// Returns once `count` windows were presented — no clock.
    private func waitForPrompt(count: Int = 1) async throws {
        if prompts.count < count {
            await withCheckedContinuation { promptWaiters.append((count, $0)) }
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

    /// A Confluence page edit's detail is the whole page: a request far over
    /// the old 64 KB line is read whole and its window shows it all (the
    /// 2026-11-02 `broken pipe` on Approve).
    func testALargeRequestIsReadWhole() async throws {
        try start()
        let detail = "Args: " + String(repeating: "<p>страница &amp; текст</p>", count: 40_000)
        let pending = ask(OwnerConfirmRequest(verb: "approve an action", detail: detail,
                                              args: ["actions", "approve", "5"]))
        try await waitForPrompt()
        XCTAssertEqual(prompts[0].request.detail, detail)
        prompts[0].answer(true)
        let reply = await pending.value
        XCTAssertEqual(reply?.decision, OwnerConfirmReply.confirmed)
    }

    /// Past the limit the request is refused with a reason the CLI reads,
    /// never a silent close; no window opens.
    func testARequestOverTheLimitIsDeniedWithAReason() async throws {
        try start()
        let detail = String(repeating: "a", count: OwnerConfirmServer.maxRequestBytes)
        let reply = await ask(OwnerConfirmRequest(verb: "approve an action", detail: detail,
                                                  args: ["actions", "approve", "5"])).value
        XCTAssertEqual(reply?.decision, OwnerConfirmReply.denied)
        XCTAssertEqual(reply?.reason, OwnerConfirmServer.tooLargeReason)
        XCTAssertTrue(prompts.isEmpty)
    }

    /// Dual path: Go `ownerconfirm.MaxRequestBytes` is the same 8 MiB.
    func testTheRequestLimitMatchesGo() {
        XCTAssertEqual(OwnerConfirmServer.maxRequestBytes, 8 << 20)
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
        let hangUp = DispatchSemaphore(value: 0)
        let gone = ask(OwnerConfirmRequest(verb: "a", args: ["actions", "approve", "1"]), hangUp: hangUp)
        try await waitForPrompt()
        let prompt = prompts[0]
        await withCheckedContinuation { (withdrawn: CheckedContinuation<Void, Never>) in
            prompt.onWithdraw = { withdrawn.resume() }
            hangUp.signal()
        }
        _ = await gone.value
        // The slot is free again.
        let next = ask(OwnerConfirmRequest(verb: "b", args: ["actions", "approve", "2"]))
        try await waitForPrompt(count: 2)
        prompts[1].answer(false)
        _ = await next.value
    }

    func testTheWaitRunsOut() async throws {
        let wait = OpenOnce()
        try start { _ in await wait.wait() }
        let pending = ask(OwnerConfirmRequest(verb: "a", args: ["actions", "approve", "1"]))
        try await waitForPrompt()
        wait.open()
        let reply = await pending.value
        XCTAssertEqual(reply?.decision, OwnerConfirmReply.denied)
    }

    /// F11: a connection that sends no line is closed after the read timeout
    /// (none here, so it runs out at once).
    func testASilentConnectionIsClosed() async throws {
        try start(lineTimeout: 0)
        let path = socketPath
        let closed = await Task.detached { UnixLineClient.closedWithoutAnswer(path: path) }.value
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
        await admitted.until(OwnerConfirmServer.maxConnections)
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
        await admitted.until(OwnerConfirmServer.maxConnections)
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

    /// Sends `line` + "\n" and reads one reply line; with `hangUp`, closes
    /// once it is signalled instead.
    static func roundTrip(path: String, line: Data?, hangUp: DispatchSemaphore?) -> Data? {
        guard let line, let fd = connect(path: path) else { return nil }
        defer { close(fd) }
        let payload = line + Data([UInt8(ascii: "\n")])
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, payload.count) }
        if let hangUp {
            hangUp.wait()
            return nil
        }
        return readLine(fd)
    }

    /// Connects, sends nothing, and reports whether the server closed the
    /// connection unanswered (the read blocks until it does).
    static func closedWithoutAnswer(path: String) -> Bool {
        guard let fd = connect(path: path) else { return false }
        defer { close(fd) }
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

/// Counts the connections the server admitted; `until` returns once the
/// count reached `n`.
private final class AdmitCount: @unchecked Sendable {
    private let lock = NSLock()
    private var open = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func reached(_ count: Int) {
        let due: [CheckedContinuation<Void, Never>] = lock.withLock {
            open = max(open, count)
            let due = waiters.filter { $0.count <= open }.map(\.continuation)
            waiters.removeAll { $0.count <= open }
            return due
        }
        due.forEach { $0.resume() }
    }

    func until(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if open >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }
}

/// A wait the test ends by hand, once.
@MainActor
private final class OpenOnce {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let woken = waiting
        waiting = []
        woken.forEach { $0.resume() }
    }
}

/// A sleep that never returns on its own: it parks until its task is cancelled.
private func parkUntilCancelled() async {
    let (stream, continuation) = AsyncStream<Never>.makeStream()
    for await _ in stream {}
    withExtendedLifetime(continuation) {}
}
