import Foundation
import XCTest
@testable import WatchtowerCore
import WatchtowerInterface

/// The per-run connect socket (agent connect spec §5.3): admission by uid,
/// token and service; one peer at a time; requests on the main actor; the
/// run's end closes everything. Every client is an in-test POSIX socket;
/// nothing waits on the clock (reads block until a line or EOF arrives, a
/// held call ends by cancellation).
@MainActor
final class ConnectRunServerTests: XCTestCase {
    private var servers: [ConnectRunServer] = []
    private var clients: [WireClient] = []

    override func tearDown() async throws {
        servers.forEach { $0.stop() }
        clients.forEach { $0.close() }
        servers = []
        clients = []
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// What the handler saw: each call's start and its end (cancelled or not).
    @MainActor
    private final class HandlerLog {
        enum Event: Equatable {
            case started(Int64)
            case finished(Int64, cancelled: Bool)
        }

        private(set) var started: [Int64] = []
        private(set) var running = 0
        private let stream: AsyncStream<Event>
        private let continuation: AsyncStream<Event>.Continuation
        private var iterator: AsyncStream<Event>.Iterator

        init() {
            (stream, continuation) = AsyncStream.makeStream(of: Event.self)
            iterator = stream.makeAsyncIterator()
        }

        func start(_ id: Int64) {
            started.append(id)
            running += 1
            continuation.yield(.started(id))
        }

        func finish(_ id: Int64, cancelled: Bool) {
            running -= 1
            continuation.yield(.finished(id, cancelled: cancelled))
        }

        func next() async -> Event? {
            var it = iterator
            let event = await it.next()
            iterator = it
            return event
        }
    }

    /// `hold` runs until it is cancelled; `big` answers ~900 KB (more than a
    /// socket buffer, less than a wire line); any other tool answers at once
    /// with `{"tool":…}` under a wrong id (the server must put the
    /// request's). `keep` false leaves the server's lifetime to the test.
    private func makeServer(
        service: String = "slack",
        ownerUID: uid_t = getuid(),
        log: HandlerLog? = nil,
        keep: Bool = true
    ) -> ConnectRunServer {
        let log = log ?? HandlerLog()
        let server = ConnectRunServer(service: service, ownerUID: ownerUID, helloWithin: nil) { request in
            dispatchPrecondition(condition: .onQueue(.main))
            log.start(request.id)
            if request.tool == "hold" {
                try? await Task.sleep(for: .seconds(86_400))
                log.finish(request.id, cancelled: Task.isCancelled)
                return ConnectWireResponse(id: request.id, error: .failed, message: "held")
            }
            log.finish(request.id, cancelled: false)
            if request.tool == "big" {
                return .result(id: 999, json: Data(#"{"pad":"\#(String(repeating: "a", count: 900_000))"}"#.utf8))
            }
            return .result(id: 999, json: Data(#"{"tool":"\#(request.tool)"}"#.utf8))
        }
        if keep { servers.append(server) }
        return server
    }

    private func connect(_ path: String) throws -> WireClient {
        let client = try WireClient(path: path)
        clients.append(client)
        return client
    }

    /// A client that sent a good hello and read its reply.
    private func admittedClient(_ path: String, token: String, service: String = "slack") async throws -> WireClient {
        let client = try connect(path)
        client.send(#"{"v":1,"token":"\#(token)","service":"\#(service)"}"#)
        let reply = await client.readLine()
        XCTAssertEqual(reply, #"{"ok":true}"#)
        return client
    }

    /// The client's next line, read as a response.
    private func response(_ client: WireClient) async throws -> ConnectWireResponse {
        let line = await client.readLine()
        return try JSONDecoder().decode(ConnectWireResponse.self, from: Data(XCTUnwrap(line).utf8))
    }

    // MARK: - Tests

    func testDirectoryIs0700SocketIs0600() throws {
        let server = makeServer()
        let (path, token) = try server.start()
        let dir = (path as NSString).deletingLastPathComponent

        var st = stat()
        XCTAssertEqual(stat(dir, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(stat(path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(st.st_uid, getuid())

        XCTAssertEqual((path as NSString).lastPathComponent, "connect.sock")
        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(server.environment, ["WATCHTOWER_CONNECT_SOCKET": path, "WATCHTOWER_CONNECT_TOKEN": token])
        XCTAssertThrowsError(try server.start()) { XCTAssertEqual($0 as? ConnectRunServer.ServerError, .alreadyStarted) }

        // Each run gets its own directory and token.
        let (otherPath, otherToken) = try makeServer().start()
        XCTAssertNotEqual((otherPath as NSString).deletingLastPathComponent, dir)
        XCTAssertNotEqual(otherToken, token)
    }

    func testRefusesWrongToken() async throws {
        let server = makeServer()
        let (path, token) = try server.start()
        let wrongToken = String(repeating: "0", count: 64)
        let refused = [
            #"{"v":1,"token":"\#(wrongToken)","service":"slack"}"#,
            #"{"v":1,"token":"\#(token.prefix(63))","service":"slack"}"#,
            #"{"v":1,"token":"","service":"slack"}"#,
            #"{"v":1,"token":"\#(token)","service":"jira"}"#,
            #"{"v":2,"token":"\#(token)","service":"slack"}"#,
            #"{"token":"\#(token)","service":"slack"}"#,
            "not a hello"
        ]
        for hello in refused {
            let client = try connect(path)
            client.send(hello)
            // Closed without a reply.
            let reply = await client.readLine()
            XCTAssertNil(reply, hello)
        }
        // A refused peer never held the run's connection.
        let good = try await admittedClient(path, token: token)
        good.send(#"{"id":1,"tool":"connect_status","args":{}}"#)
        let answer1 = try await response(good)
        XCTAssertEqual(answer1.id, 1)
    }

    func testRefusesOtherUID() async throws {
        let server = makeServer(ownerUID: getuid() &+ 1)
        let (path, token) = try server.start()
        let client = try connect(path)
        client.send(#"{"v":1,"token":"\#(token)","service":"slack"}"#)
        let reply = await client.readLine()
        XCTAssertNil(reply)
    }

    func testRefusesSecondConcurrentPeer() async throws {
        let server = makeServer()
        let (path, token) = try server.start()
        let first = try await admittedClient(path, token: token)

        let second = try connect(path)
        second.send(#"{"v":1,"token":"\#(token)","service":"slack"}"#)
        let refusal = await second.readLine()
        XCTAssertEqual(try JSONDecoder().decode(ConnectWireHelloReply.self, from: Data(XCTUnwrap(refusal).utf8)),
                       .busy)
        let afterRefusal = await second.readLine()
        XCTAssertNil(afterRefusal)

        // The first peer keeps the run.
        first.send(#"{"id":7,"tool":"connect_status","args":{}}"#)
        let answer7 = try await response(first)
        XCTAssertEqual(answer7.id, 7)
    }

    func testAdmitsNextPeerAfterFirstCloses() async throws {
        let server = makeServer()
        let (path, token) = try server.start()

        let turn1 = try await admittedClient(path, token: token)
        turn1.send(#"{"id":1,"tool":"connect_status","args":{}}"#)
        let answer1 = try await response(turn1)
        XCTAssertEqual(answer1.id, 1)
        turn1.close()

        // The next turn's MCP server, right after the previous one exited.
        let turn2 = try await admittedClient(path, token: token)
        turn2.send(#"{"id":1,"tool":"connect_status","args":{}}"#)
        let nextAnswer = try await response(turn2)
        XCTAssertEqual(nextAnswer.id, 1)
    }

    func testRequestsAnsweredInOrderOnMainActor() async throws {
        let log = HandlerLog()
        let server = makeServer(log: log)
        let (path, token) = try server.start()
        let client = try await admittedClient(path, token: token)

        client.send([
            #"{"id":1,"tool":"connect_status","args":{}}"#,
            #"{"id":2,"tool":"choose","args":{"what":"jira_boards"}}"#,
            #"{"id":3,"tool":"connect_cancel","args":{}}"#
        ].joined(separator: "\n"))

        var answered: [ConnectWireResponse] = []
        for _ in 0..<3 { answered.append(try await response(client)) }
        XCTAssertEqual(answered.map(\.id), [1, 2, 3])
        XCTAssertEqual(answered.map(\.result), [
            try RawJSON(data: Data(#"{"tool":"connect_status"}"#.utf8)),
            try RawJSON(data: Data(#"{"tool":"choose"}"#.utf8)),
            try RawJSON(data: Data(#"{"tool":"connect_cancel"}"#.utf8))
        ])
        XCTAssertEqual(log.started, [1, 2, 3])
    }

    /// Calls overlap: a held call does not hold the next one. When the peer
    /// hangs up mid-call, the held handler is cancelled.
    func testPeerClosingMidCallCancelsItsHandler() async throws {
        let log = HandlerLog()
        let server = makeServer(log: log)
        let (path, token) = try server.start()
        let client = try await admittedClient(path, token: token)

        client.send(#"{"id":1,"tool":"hold","args":{}}"#)
        let firstEvent = await log.next()
        XCTAssertEqual(firstEvent, .started(1))
        client.send(#"{"id":2,"tool":"connect_status","args":{}}"#)
        let answer2 = try await response(client)
        XCTAssertEqual(answer2.id, 2)

        client.close()
        var events: [HandlerLog.Event] = []
        while let event = await log.next() {
            events.append(event)
            if event == .finished(1, cancelled: true) { break }
        }
        XCTAssertEqual(events.last, .finished(1, cancelled: true))
        XCTAssertEqual(log.running, 0)

        // The run's connection is free for the next turn.
        _ = try await admittedClient(path, token: token)
    }

    func testStopClosesAndUnlinks() async throws {
        let log = HandlerLog()
        let server = makeServer(log: log)
        let (path, token) = try server.start()
        let dir = (path as NSString).deletingLastPathComponent
        let client = try await admittedClient(path, token: token)
        client.send(#"{"id":1,"tool":"hold","args":{}}"#)
        let started = await log.next()
        XCTAssertEqual(started, .started(1))
        // A peer that has not sent its hello yet.
        let early = try connect(path)

        server.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
        XCTAssertEqual(server.environment, [:])
        // The open client reads EOF: no answer to its pending call.
        let pending = await client.readLine()
        XCTAssertNil(pending)
        let earlyRead = await early.readLine()
        XCTAssertNil(earlyRead)
        // The pending call's handler is cancelled and nothing keeps running.
        var finished: HandlerLog.Event?
        while let event = await log.next() {
            finished = event
            if case .finished = event { break }
        }
        XCTAssertEqual(finished, .finished(1, cancelled: true))
        XCTAssertEqual(log.running, 0)
        // Nobody can connect again.
        XCTAssertThrowsError(try WireClient(path: path))
        server.stop()
    }

    func testUnreadableRequestCloses() async throws {
        let server = makeServer()
        let (path, token) = try server.start()
        let client = try await admittedClient(path, token: token)
        client.send(#"{"id":"one","tool":"connect_status"}"#)
        let reply = await client.readLine()
        XCTAssertNil(reply)
        _ = try await admittedClient(path, token: token)
    }

    func testOverlongLineCloses() async throws {
        let server = makeServer()
        let (path, token) = try server.start()
        let client = try await admittedClient(path, token: token)
        let padding = String(repeating: "a", count: ConnectWire.maxLine)
        client.send(#"{"id":1,"tool":"connect_status","args":{"x":"\#(padding)"}}"#)
        let reply = await client.readLine()
        XCTAssertNil(reply)
    }

    /// Handlers start in arrival order through the FIFO even while earlier
    /// calls are still running; a finished call is no longer tracked.
    func testHandlersStartInArrivalOrderWhileOverlapping() async throws {
        let log = HandlerLog()
        let server = makeServer(log: log)
        let (path, token) = try server.start()
        let client = try await admittedClient(path, token: token)

        client.send([
            #"{"id":1,"tool":"hold","args":{}}"#,
            #"{"id":2,"tool":"connect_status","args":{}}"#,
            #"{"id":3,"tool":"hold","args":{}}"#,
            #"{"id":4,"tool":"connect_status","args":{}}"#
        ].joined(separator: "\n"))

        let first = try await response(client)
        let second = try await response(client)
        XCTAssertEqual([first.id, second.id], [2, 4])
        XCTAssertEqual(log.started, [1, 2, 3, 4])
        XCTAssertEqual(server.core.runningCalls, 2, "only the two held calls are tracked")
    }

    /// Requests already read when the run stops never reach the handler.
    func testQueuedRequestsNeverStartAfterStop() async throws {
        let log = HandlerLog()
        let server = makeServer(log: log)
        let queued = Self.events { server.core.hooks.onQueued = $0 }
        // The dispatcher waits at this gate before each request, so both are
        // still queued (not started) when the run stops.
        let (release, opener) = AsyncStream.makeStream(of: Void.self)
        let gate = Task { for await _ in release { break } }
        server.core.hooks.beforeDispatch = { await gate.value }
        let (path, token) = try server.start()
        let client = try await admittedClient(path, token: token)

        client.send([
            #"{"id":1,"tool":"connect_status","args":{}}"#,
            #"{"id":2,"tool":"connect_status","args":{}}"#
        ].joined(separator: "\n"))
        var queuedEvents = queued.makeAsyncIterator()
        _ = await queuedEvents.next()
        _ = await queuedEvents.next()
        server.stop()
        opener.finish()

        await server.core.dispatcher?.value
        XCTAssertEqual(log.started, [])
        let reply = await client.readLine()
        XCTAssertNil(reply)
    }

    /// A peer that stops reading in the middle of a large answer, then sends
    /// garbage: its reader ends, the stalled write is failed, and the
    /// descriptor closes. The write has no time bound here, so only the
    /// reader's end can free it.
    func testReaderEndUnblocksStuckWrite() async throws {
        let server = makeServer()
        let (closed, stalled) = Self.stuckWriteEvents(server)
        let (path, token) = try server.start()
        let client = try await admittedClient(path, token: token)

        client.send(#"{"id":1,"tool":"big","args":{}}"#)
        var stalls = stalled.makeAsyncIterator()
        _ = await stalls.next()
        client.send("garbage")

        var events = closed.makeAsyncIterator()
        _ = await events.next()
        XCTAssertEqual(server.core.openConnections, 0)
        _ = try await admittedClient(path, token: token)
    }

    /// A test clock for the write deadline (nanoseconds).
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 1_000_000_000

        func now() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func advance(milliseconds: UInt64) {
            lock.lock()
            value += milliseconds * 1_000_000
            lock.unlock()
        }
    }

    /// A finite write bound on a test clock, and the stalls of the answer.
    private static func clockedWrite(
        _ server: ConnectRunServer
    ) -> (clock: FakeClock, stalled: AsyncStream<Void>) {
        let clock = FakeClock()
        server.core.hooks.writeTimeout = 1000
        server.core.hooks.now = { clock.now() }
        let stalled = events { server.core.hooks.onWriteStalled = $0 }
        return (clock, stalled)
    }

    /// A peer that reads a little between stalls gets no fresh time per
    /// stall: the line fails at the one deadline it started with.
    func testStalledLineSharesOneDeadline() async throws {
        let server = makeServer()
        let (clock, stalled) = Self.clockedWrite(server)
        let (path, token) = try server.start()
        let client = try await admittedClient(path, token: token)
        client.send(#"{"id":1,"tool":"big","args":{}}"#)
        var stalls = stalled.makeAsyncIterator()

        _ = await stalls.next()
        clock.advance(milliseconds: 600)
        _ = await client.readChunk()
        _ = await stalls.next()
        clock.advance(milliseconds: 600)  // 1200 ms: past the line's 1000
        _ = await client.readChunk()

        // The answer never completes: the connection is cut mid-line.
        let line = await client.readLine()
        XCTAssertNil(line)
    }

    /// Past the deadline, even a peer that now reads everything gets no
    /// more of the line: each write attempt checks the deadline first.
    func testDeadlineCheckedBeforeEachWrite() async throws {
        let server = makeServer()
        let (clock, stalled) = Self.clockedWrite(server)
        let (path, token) = try server.start()
        let client = try await admittedClient(path, token: token)
        client.send(#"{"id":1,"tool":"big","args":{}}"#)
        var stalls = stalled.makeAsyncIterator()

        _ = await stalls.next()
        clock.advance(milliseconds: 2000)
        let line = await client.readLine()
        XCTAssertNil(line)
    }

    /// The same stuck peer, still connected: only stop can free it.
    func testStopCutsPeerThatStoppedReading() async throws {
        let server = makeServer()
        let (closed, stalled) = Self.stuckWriteEvents(server)
        let (path, token) = try server.start()
        let client = try await admittedClient(path, token: token)
        client.send(#"{"id":1,"tool":"big","args":{}}"#)
        var stalls = stalled.makeAsyncIterator()
        _ = await stalls.next()

        server.stop()
        var events = closed.makeAsyncIterator()
        _ = await events.next()
        XCTAssertEqual(server.core.openConnections, 0)
    }

    /// Nothing but the owner keeps the server alive: releasing it ends the
    /// run like `stop`.
    func testReleasingServerStopsRun() async throws {
        var server: ConnectRunServer? = makeServer(keep: false)
        weak let released = server
        let (path, token) = try XCTUnwrap(server).start()
        let dir = (path as NSString).deletingLastPathComponent
        let client = try await admittedClient(path, token: token)

        server = nil

        XCTAssertNil(released)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
        let reply = await client.readLine()
        XCTAssertNil(reply)
    }

    func testNoStartAfterStop() {
        let server = makeServer()
        server.stop()
        XCTAssertThrowsError(try server.start()) { XCTAssertEqual($0 as? ConnectRunServer.ServerError, .alreadyStarted) }
    }

    /// A descriptor that cannot be made non-blocking is reported, so it is
    /// never served (accept) and fails `start` (the listener).
    func testMakeNonBlocking() throws {
        XCTAssertFalse(ConnectRunServer.makeNonBlocking(-1))
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertTrue(ConnectRunServer.makeNonBlocking(fd))
        XCTAssertNotEqual(fcntl(fd, F_GETFL) & O_NONBLOCK, 0)
    }

    /// Only an empty peek (EOF) or a real error is a hang-up; nothing to read
    /// yet is a live peer.
    func testHungUpOnlyOnEOF() {
        XCTAssertTrue(ConnectRunPeer.peekMeansHungUp(0, errno: 0))
        XCTAssertFalse(ConnectRunPeer.peekMeansHungUp(1, errno: 0))
        XCTAssertFalse(ConnectRunPeer.peekMeansHungUp(-1, errno: EAGAIN))
        XCTAssertFalse(ConnectRunPeer.peekMeansHungUp(-1, errno: EWOULDBLOCK))
        XCTAssertFalse(ConnectRunPeer.peekMeansHungUp(-1, errno: EINTR))
        XCTAssertTrue(ConnectRunPeer.peekMeansHungUp(-1, errno: ECONNRESET))
    }

    /// A stream fed by the hook `install` sets.
    private static func events(_ install: (@escaping @Sendable () -> Void) -> Void) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        install { continuation.yield() }
        return stream
    }

    /// Closed descriptors and stalled writes, with no bound on a stalled
    /// write: nothing but the path under test can end it.
    private static func stuckWriteEvents(
        _ server: ConnectRunServer
    ) -> (closed: AsyncStream<Void>, stalled: AsyncStream<Void>) {
        server.core.hooks.writeTimeout = nil
        let closed = events { server.core.hooks.onClosed = $0 }
        let stalled = events { server.core.hooks.onWriteStalled = $0 }
        return (closed, stalled)
    }

    func testTokenComparison() {
        XCTAssertTrue(ConnectRunServer.sameBytes("ab12", "ab12"))
        XCTAssertFalse(ConnectRunServer.sameBytes("ab12", "ab13"))
        XCTAssertFalse(ConnectRunServer.sameBytes("ab12", "ab1"))
        XCTAssertFalse(ConnectRunServer.sameBytes("", ""))
    }
}

/// An in-test peer of the run's socket. Writes happen on a queue of their
/// own (a long line must not block the test while the server reads it);
/// reads block a background thread until a line or EOF.
private final class WireClient: @unchecked Sendable {
    struct ConnectFailed: Error {}

    private let fd: Int32
    private var buffer = Data()
    private let lock = NSLock()
    private var closed = false
    private let writeQueue = DispatchQueue(label: "wire-client.write")

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectFailed() }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = OwnerConfirmIO.address(path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw ConnectFailed()
        }
    }

    /// Sends `text` and its newline.
    func send(_ text: String) {
        let bytes = Array((text + "\n").utf8)
        writeQueue.async { [fd] in
            var offset = 0
            while offset < bytes.count {
                let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                guard n > 0 else { return }
                offset += n
            }
        }
    }

    /// The next line without its newline, nil at EOF.
    func readLine() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in continuation.resume(returning: blockingReadLine()) }
        }
    }

    /// Reads whatever is waiting (one read call) into the line buffer;
    /// false at EOF.
    func readChunk() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let n = read(fd, &chunk, chunk.count)
                if n > 0 { buffer.append(contentsOf: chunk[0..<n]) }
                continuation.resume(returning: n > 0)
            }
        }
    }

    private func blockingReadLine() -> String? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(bytes: buffer[buffer.startIndex..<end], encoding: .utf8)
                buffer = Data(buffer[(end + 1)...])
                return line
            }
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        // The write queue may still be busy with a line the server stopped
        // reading: shut first so its write fails, then close after it.
        shutdown(fd, SHUT_RDWR)
        writeQueue.sync { _ = Darwin.close(fd) }
    }
}
