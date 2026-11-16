import Darwin
import Foundation
import WatchtowerInterface
import XCTest
@testable import WatchtowerCore

/// A stand-in for the daemon's tower socket (Go `tower.Serve`): a unix
/// listener at `<dir>/tower.sock` in a short temp dir. Each request line is
/// recorded and `answer` turns it into the lines sent back (none: the test
/// answers later with `reply`). Same descriptor discipline as
/// `FakeHubSocket`: only the accept thread closes the listener, and a
/// connection is written to or shut down only under `lock` while listed.
final class FakeTowerSocket: @unchecked Sendable {
    let dir: String
    let path: String
    private let fd: Int32
    private let wake: (read: Int32, write: Int32)
    private let acceptDone = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var lines: [String] = []
    private var lastConnection: Int32 = -1
    private var open: [Int32] = []
    private var stopped = false
    private var closedConnections = 0
    private var waiters: [(due: (Int, Int) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
    var answer: @Sendable ([String: Any]) -> [String] = { _ in [] }

    init() throws {
        // A short name: sockaddr_un holds 104 bytes.
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("wtts-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/" + SocketTransport.socketName
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            let err = errno
            close(listener)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw POSIXError(.EMFILE) }
        fd = listener
        wake = (pipeFDs[0], pipeFDs[1])
        Thread.detachNewThread { [self] in acceptAll() }
    }

    /// The request lines received, in order.
    var received: [String] { lock.withLock { lines } }
    var closedCount: Int { lock.withLock { closedConnections } }

    func untilRequests(_ count: Int) async { await until { requests, _ in requests >= count } }
    func untilClosed(_ count: Int) async { await until { _, closed in closed >= count } }

    /// Sends `line` on the connection that sent the last request.
    func reply(_ line: String) {
        lock.withLock { Self.send(lastConnection, line) }
    }

    /// Shuts every open connection down (the daemon went away) but keeps listening.
    func dropConnections() {
        lock.withLock {
            open.forEach { Darwin.shutdown($0, SHUT_RDWR) }
            open = []
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        dropConnections()
        _ = Darwin.write(wake.write, [UInt8(1)], 1)
        acceptDone.wait()
        close(wake.write)
        unlink(path)
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func until(_ due: @escaping (Int, Int) -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if due(lines.count, closedConnections) { return true }
                waiters.append((due, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    private func dueWaiters() -> [CheckedContinuation<Void, Never>] {
        let due = waiters.filter { $0.due(lines.count, closedConnections) }
        waiters.removeAll { $0.due(lines.count, closedConnections) }
        return due.map(\.continuation)
    }

    private func acceptAll() {
        defer {
            close(fd)
            close(wake.read)
            acceptDone.signal()
        }
        while true {
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0)]
            guard poll(&fds, 2, -1) >= 0 || errno == EINTR else { return }
            if fds[1].revents != 0 || lock.withLock({ stopped }) { return }
            guard fds[0].revents != 0 else { continue }
            let c = accept(fd, nil, nil)
            guard c >= 0 else { continue }
            let kept = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                open.append(c)
                return true
            }
            guard kept else {
                close(c)
                return
            }
            Thread.detachNewThread { [self] in serve(c) }
        }
    }

    private func serve(_ c: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(c, &chunk, chunk.count)
            guard n > 0 else {
                let woken = lock.withLock {
                    closedConnections += 1
                    open.removeAll { $0 == c }
                    close(c)
                    return dueWaiters()
                }
                woken.forEach { $0.resume() }
                return
            }
            buffer.append(contentsOf: chunk[0..<n])
            while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<end])
                buffer = Data(buffer[buffer.index(after: end)...])
                let request = (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
                let out = answer(request)
                let woken = lock.withLock {
                    lines.append(String(bytes: line, encoding: .utf8) ?? "")
                    lastConnection = c
                    if open.contains(c) { out.forEach { Self.send(c, $0) } }
                    return dueWaiters()
                }
                woken.forEach { $0.resume() }
            }
        }
    }

    private static func send(_ c: Int32, _ line: String) {
        let data = Array((line + "\n").utf8)
        _ = data.withUnsafeBufferPointer { Darwin.write(c, $0.baseAddress, $0.count) }
    }
}

final class SocketTransportTests: XCTestCase {
    private var servers: [FakeTowerSocket] = []
    private var workspaces: [String] = []

    override func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        workspaces.forEach { try? FileManager.default.removeItem(atPath: $0) }
        super.tearDown()
    }

    private func makeServer() throws -> FakeTowerSocket {
        let server = try FakeTowerSocket()
        servers.append(server)
        return server
    }

    /// A workspace with no socket of its own (for the fallback path file).
    private func makeWorkspace() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("wtws-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        workspaces.append(dir)
        return dir
    }

    private static let apiTestdata = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .deletingLastPathComponent() // repo
        .appendingPathComponent("internal/tower/api/testdata")

    private static func golden(_ name: String) throws -> Data {
        try Data(contentsOf: apiTestdata.appendingPathComponent(name))
    }

    /// One line of JSON (a golden file is pretty-printed).
    private static func line(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(String(bytes: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8))
    }

    private static func ok(_ request: [String: Any], _ result: String) -> String {
        #"{"id":"\#(request["id"] as? String ?? "")","status":"ok","result":\#(result)}"#
    }

    private static func ping(_ id: String) throws -> Request {
        Request(v: 1, id: id, command: TowerCommand.towerPing.rawValue, params: try RawJSON(data: Data("{}".utf8)))
    }

    // MARK: - Frames

    func testFramesMatchTheGoGoldens() async throws {
        let server = try makeServer()
        let transport = SocketTransport(workspace: server.dir)

        let call = Task { try await transport.call(try Self.ping("req-1")) }
        await server.untilRequests(1)
        server.reply(try Self.line(try Self.golden("Response.json")))
        let response = try await call.value

        let sent = try XCTUnwrap(server.received.first)
        XCTAssertFalse(sent.contains("\n"), "one frame is one line")
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        let golden = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.golden("Request.json")) as? [String: Any])
        XCTAssertEqual(Set(frame.keys), Set(golden.keys), "the request frame has Request.json's members")
        XCTAssertEqual(frame["v"] as? Int, golden["v"] as? Int)
        XCTAssertEqual(frame["id"] as? String, "req-1")
        XCTAssertEqual(frame["command"] as? String, "tower.ping")
        XCTAssertEqual(try JSONDecoder().decode(Request.self, from: Data(sent.utf8)).command, "tower.ping")

        let expected = try JSONDecoder().decode(Response.self, from: Self.golden("Response.json"))
        XCTAssertEqual(response, expected, "the golden answer is matched to its call by id")
        XCTAssertEqual(response.refusal?.code, .changed)
    }

    func testInterleavedAnswersMatchByID() async throws {
        let server = try makeServer()
        let transport = SocketTransport(workspace: server.dir)

        let first = Task { try await transport.call(try Self.ping("a")) }
        let second = Task { try await transport.call(try Self.ping("b")) }
        await server.untilRequests(2)
        server.reply(#"{"id":"b","status":"ok","result":{"at":"B"}}"#)
        server.reply(#"{"id":"a","status":"ok","result":{"at":"A"}}"#)
        let a = try await first.value
        let b = try await second.value

        XCTAssertEqual(a.id, "a")
        XCTAssertEqual(b.id, "b")
        XCTAssertEqual(try JSONDecoder().decode(PingResponse.self, from: XCTUnwrap(a.result).data).at, "A")
        XCTAssertEqual(try JSONDecoder().decode(PingResponse.self, from: XCTUnwrap(b.result).data).at, "B")
        XCTAssertEqual(server.closedCount, 0, "both calls share one connection")
    }

    func testServerCloseFailsPendingCallsWithDown() async throws {
        let server = try makeServer()
        let transport = SocketTransport(workspace: server.dir)

        let pending = Task { try await transport.call(try Self.ping("a")) }
        await server.untilRequests(1)
        server.dropConnections()
        do {
            _ = try await pending.value
            XCTFail("a call whose connection closed must fail")
        } catch {
            XCTAssertEqual(error as? TowerTransportError, .down)
        }

        server.answer = { [Self.ok($0, #"{"at":"later"}"#)] }
        let later = try await transport.call(try Self.ping("b"))
        XCTAssertEqual(later.status, .ok, "the next call opens a new connection")
    }

    func testCancellingACallDropsItsConnection() async throws {
        let server = try makeServer()
        let transport = SocketTransport(workspace: server.dir)

        let hung = Task { try await transport.call(try Self.ping("a")) }
        await server.untilRequests(1)
        hung.cancel() // the client's answer limit ran out
        do {
            _ = try await hung.value
            XCTFail("a cancelled call must fail")
        } catch {
            XCTAssertEqual(error as? TowerTransportError, .down)
        }
        await server.untilClosed(1)

        server.answer = { [Self.ok($0, #"{"at":"later"}"#)] }
        let later = try await transport.call(try Self.ping("b"))
        XCTAssertEqual(later.status, .ok, "the next call opens a new connection")
    }

    func testNoSocketIsDown() async throws {
        let transport = SocketTransport(workspace: try makeWorkspace())
        do {
            _ = try await transport.call(try Self.ping("a"))
            XCTFail("no daemon: down")
        } catch {
            XCTAssertEqual(error as? TowerTransportError, .down)
        }
    }

    func testReadsTheFallbackPathFile() async throws {
        let workspace = try makeWorkspace()
        let first = try makeServer()
        let second = try makeServer()
        second.answer = { [Self.ok($0, #"{"at":"second"}"#)] }
        let pathFile = (workspace as NSString).appendingPathComponent(SocketTransport.pathFileName)
        try first.path.write(toFile: pathFile, atomically: true, encoding: .utf8)
        let transport = SocketTransport(workspace: workspace)

        let viaFirst = Task { try await transport.call(try Self.ping("a")) }
        await first.untilRequests(1)
        XCTAssertEqual(first.received.count, 1, "tower.sock.path names the socket")

        // The daemon moved: its old connection closes, and the next
        // connection reads the file again.
        try second.path.write(toFile: pathFile, atomically: true, encoding: .utf8)
        first.dropConnections()
        do {
            _ = try await viaFirst.value
            XCTFail("the moved daemon's connection closed")
        } catch {
            XCTAssertEqual(error as? TowerTransportError, .down)
        }
        let viaSecond = try await transport.call(try Self.ping("b"))

        XCTAssertEqual(viaSecond.status, .ok)
        XCTAssertEqual(second.received.count, 1, "a reconnect reads tower.sock.path again")
    }

    func testUnreadablePathFileIsDown() async throws {
        let workspace = try makeWorkspace()
        let pathFile = (workspace as NSString).appendingPathComponent(SocketTransport.pathFileName)
        try "".write(toFile: pathFile, atomically: true, encoding: .utf8)
        XCTAssertNil(SocketTransport.socketPath(workspace: workspace), "a present but empty file is neither a path nor absent")
        XCTAssertEqual(
            SocketTransport.socketPath(workspace: "/tmp/acme"), "/tmp/acme/tower.sock", "no file: the socket in the workspace"
        )
    }

    // MARK: - Watch

    func testWatchYieldsChangedFrames() async throws {
        let server = try makeServer()
        server.answer = { request in
            let id = request["id"] as? String ?? ""
            return [
                #"{"id":"\#(id)","status":"ok","result":{}}"#,
                #"{"id":"\#(id)","event":"changed","tables":["inbox_items"]}"#,
                #"{"id":"\#(id)","event":"changed"}"#
            ]
        }
        let transport = SocketTransport(workspace: server.dir)

        var events: [ChangedEvent] = []
        for try await event in transport.watch(try Self.ping("w")) {
            events.append(event)
            if events.count == 2 { break }
        }

        XCTAssertEqual(events, [
            ChangedEvent(id: "w", event: "changed", tables: ["inbox_items"]),
            ChangedEvent(id: "w", event: "changed")
        ])
        await server.untilClosed(1) // stopping the stream closes the watch's connection
    }

    func testRefusedWatchEndsRefused() async throws {
        let server = try makeServer()
        server.answer = { request in
            [#"{"id":"\#(request["id"] as? String ?? "")","status":"refused","refusal":{"code":"unsupported","sentence":"No watch."}}"#]
        }
        let transport = SocketTransport(workspace: server.dir)

        do {
            for try await _ in transport.watch(try Self.ping("w")) {}
            XCTFail("a refused watch must end throwing")
        } catch {
            XCTAssertEqual(error as? TowerTransportError, .refused(Refusal(code: .unsupported, sentence: "No watch.")))
        }
    }

    func testWatchEndsDownWhenTheDaemonGoes() async throws {
        let server = try makeServer()
        server.answer = { [#"{"id":"\#($0["id"] as? String ?? "")","status":"ok","result":{}}"#] }
        let transport = SocketTransport(workspace: server.dir)

        let watch = Task {
            for try await _ in transport.watch(try Self.ping("w")) {}
        }
        await server.untilRequests(1)
        server.dropConnections()
        do {
            try await watch.value
            XCTFail("a watch whose connection closed must end throwing")
        } catch {
            XCTAssertEqual(error as? TowerTransportError, .down)
        }
    }
}
