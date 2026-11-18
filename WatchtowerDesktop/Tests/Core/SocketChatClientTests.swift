import ChatWire
import Darwin
import Foundation
import XCTest
@testable import WatchtowerCore

/// A stand-in for the daemon's chat.sock (Go `chatengine.Server`): it greets first, answers `hello` (or refuses it
/// `forbidden`), names each subscription and pushes its snapshot, and answers every other operation with `answer`.
/// Each connection is served on its own thread; the accept thread alone closes the listener (`FakeHubSocket`'s rule).
final class FakeChatSocket: @unchecked Sendable {
    let path: String
    let dir: String
    private var fd: Int32 = -1
    private var wake: (read: Int32, write: Int32) = (-1, -1)
    private var acceptDone = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var requests: [[String: Any]] = []
    private var open: [Int32] = []
    private var stopped = true
    private var subscriptionSerial = 0
    private var waiters: [(due: ([[String: Any]]) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
    var forbidHello = false
    /// The engine accepts but never speaks (an old build, a stuck accept loop).
    var silent = false
    /// Operations the engine never answers (a wedged engine).
    var unanswered: Set<String> = []
    /// The answer line's `result` for an operation (nil: `{}`); a string answers it refused with that code.
    var answer: @Sendable (_ op: String, _ params: [String: Any]) -> Any? = { _, _ in nil }
    var feedJSON: @Sendable (Int64) -> String = { id in
        #"{"conversation":{"id":\#(id),"title":"T"},"messages":[{"id":1,"role":"user","text":"hi","created_at":1}]}"#
    }

    init() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("wtcs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/chat.sock"
    }

    /// Starts listening on `path` (again, after `stop`).
    func listen() throws {
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(listener, 8) == 0 else { throw ChatSocketDropped() }
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw ChatSocketDropped() }
        fd = listener
        wake = (pipeFDs[0], pipeFDs[1])
        acceptDone = DispatchSemaphore(value: 0)
        lock.withLock { stopped = false }
        Thread.detachNewThread { [self] in acceptAll(listener: listener, wake: pipeFDs[0]) }
    }

    var received: [[String: Any]] { lock.withLock { requests } }

    func ops(_ name: String) -> [[String: Any]] { received.filter { $0["op"] as? String == name } }

    /// Returns once the requests so far satisfy `due`.
    func until(_ due: @escaping ([[String: Any]]) -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if due(requests) { return true }
                waiters.append((due, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    func until(op name: String, count: Int) async {
        await until { requests in requests.filter { $0["op"] as? String == name }.count >= count }
    }

    /// Pushes a line to every open connection.
    func push(_ line: String) {
        lock.withLock { open.forEach { Self.send($0, line) } }
    }

    /// The daemon went away: every connection is shut down; the listener stays.
    func dropConnections() {
        lock.withLock {
            open.forEach { Darwin.shutdown($0, SHUT_RDWR) }
            open = []
        }
    }

    /// Stops listening (the socket file goes) and drops the connections.
    func stop() {
        let wasRunning = lock.withLock { () -> Bool in
            let running = !stopped
            stopped = true
            return running
        }
        dropConnections()
        guard wasRunning else { return }
        _ = Darwin.write(wake.write, [UInt8(1)], 1)
        acceptDone.wait()
        close(wake.write)
        unlink(path)
    }

    func removeDir() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func acceptAll(listener: Int32, wake: Int32) {
        defer {
            close(listener)
            close(wake)
            acceptDone.signal()
        }
        while true {
            var fds = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
            guard poll(&fds, 2, -1) >= 0 || errno == EINTR else { return }
            if fds[1].revents != 0 || lock.withLock({ stopped }) { return }
            guard fds[0].revents != 0 else { continue }
            let c = accept(listener, nil, nil)
            guard c >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let kept = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                open.append(c)
                if !silent { Self.send(c, #"{"event":"ready","protocol":1}"#) }
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
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(c, &chunk, chunk.count)
            guard n > 0 else {
                lock.withLock {
                    open.removeAll { $0 == c }
                    close(c)
                }
                return
            }
            buffer.append(contentsOf: chunk[0..<n])
            while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<end])
                buffer = Data(buffer[buffer.index(after: end)...])
                guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                let lines = respond(request)
                let woken = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    requests.append(request)
                    if open.contains(c) { lines.forEach { Self.send(c, $0) } }
                    let due = waiters.filter { $0.due(requests) }
                    waiters.removeAll { $0.due(requests) }
                    return due.map(\.continuation)
                }
                woken.forEach { $0.resume() }
            }
        }
    }

    private func respond(_ request: [String: Any]) -> [String] {
        let id = request["id"] as? String ?? ""
        let op = request["op"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        if unanswered.contains(op) { return [] }
        switch op {
        case "hello":
            if forbidHello {
                return [#"{"id":"\#(id)","ok":false,"error":{"code":"forbidden","message":"only the app"}}"#]
            }
            return [#"{"id":"\#(id)","ok":true,"result":{"protocol":1,"ops":[]}}"#]
        case "subscribe":
            let name = lock.withLock { () -> String in
                subscriptionSerial += 1
                return "s\(subscriptionSerial)"
            }
            var lines = [#"{"id":"\#(id)","ok":true,"result":{"subscription":"\#(name)"}}"#]
            if let conversation = (params["conversation_id"] as? NSNumber)?.int64Value {
                let feed = feedJSON(conversation)
                lines.append(#"{"event":"snapshot","subscription":"\#(name)","conversation_id":\#(conversation),"snapshot":\#(feed)}"#)
            } else {
                lines.append(#"{"event":"snapshot","subscription":"\#(name)","list":{"conversations":[],"projects":[],"models":[]}}"#)
            }
            return lines
        default:
            let result = answer(op, params)
            if let code = result as? String {
                return [#"{"id":"\#(id)","ok":false,"error":{"code":"\#(code)","message":"no"}}"#]
            }
            let data = result.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            let body = data.flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
            return [#"{"id":"\#(id)","ok":true,"result":\#(body)}"#]
        }
    }

    private static func send(_ c: Int32, _ line: String) {
        let data = Array((line + "\n").utf8)
        _ = data.withUnsafeBufferPointer { Darwin.write(c, $0.baseAddress, $0.count) }
    }
}

/// A clock the test moves: every sleep is recorded and waits until the test advances past its deadline.
final class ManualChatClientClock: ChatClientClock, @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var offset: Duration = .zero
    private var sleepers: [(id: UUID, deadline: Duration, continuation: CheckedContinuation<Void, any Error>)] = []
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []
    private var durationWaiters: [(duration: Duration, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var sleeps: [Duration] = []

    var now: ContinuousClock.Instant { lock.withLock { start + offset } }

    var recordedSleeps: [Duration] { lock.withLock { sleeps } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (waiters, cancelled) = lock.withLock { () -> ([CheckedContinuation<Void, Never>], Bool) in
                    if Task.isCancelled { return ([], true) }
                    sleeps.append(duration)
                    sleepers.append((id, offset + duration, continuation))
                    let slept = durationWaiters.filter { $0.duration == duration }.map(\.continuation)
                    durationWaiters.removeAll { $0.duration == duration }
                    defer { sleepWaiters = [] }
                    return (sleepWaiters + slept, false)
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
                waiters.forEach { $0.resume() }
            }
        } onCancel: {
            let mine = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index).continuation
            }
            mine?.resume(throwing: CancellationError())
        }
    }

    /// The durations slept, the handshake and answer deadlines left out (the reconnect backoff alone).
    var backoffSleeps: [Duration] {
        recordedSleeps.filter { $0 <= ChatReachabilityPolicy.maxBackoff }
    }

    /// Returns once someone sleeps on this clock.
    func untilSleeping() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if !sleepers.isEmpty { return true }
                sleepWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Returns once someone has slept for `duration` on this clock.
    func until(slept duration: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if sleeps.contains(duration) { return true }
                durationWaiters.append((duration, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Waits for the next sleep, then moves time to its end and wakes it.
    func finishNextSleep() async {
        await untilSleeping()
        let due = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            guard let first = sleepers.min(by: { $0.deadline < $1.deadline }) else { return [] }
            offset = max(offset, first.deadline)
            let ready = sleepers.filter { $0.deadline <= offset }
            sleepers.removeAll { $0.deadline <= offset }
            return ready.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }
}

final class SocketChatClientTests: XCTestCase {
    private var server: FakeChatSocket!
    private var clock: ManualChatClientClock!
    private var clients: [SocketChatClient] = []
    private let starts = StartCounter()

    override func setUpWithError() throws {
        signal(SIGPIPE, SIG_IGN)
        server = try FakeChatSocket()
        clock = ManualChatClientClock()
    }

    override func tearDown() async throws {
        for client in clients { await client.close() }
        server.stop()
        server.removeDir()
        try await super.tearDown()
    }

    private var markerPath: String { server.dir + "/" + ChatReachabilityPolicy.stoppedMarkerName }

    private func makeClient(kinds: [String] = ["text", "steps"]) -> SocketChatClient {
        let starts = starts
        let client = SocketChatClient(
            socketPath: server.path, markerPath: markerPath,
            startDaemon: { starts.increment() }, clock: clock, partKinds: kinds
        )
        clients.append(client)
        return client
    }

    /// Reads reachability until `state` (bounded by `steps` fake-clock sleeps finished on the way).
    private func waitFor(
        _ state: ChatReachability,
        on iterator: inout AsyncStream<ChatReachability>.AsyncIterator
    ) async -> Bool {
        while let next = await iterator.next() {
            if next == state { return true }
        }
        return false
    }

    func testHelloDeclaresRegisteredPartKinds() async throws {
        try server.listen()
        let client = makeClient(kinds: ["text", "approval", "routing_note"])
        var states = client.reachability.makeAsyncIterator()
        let connected = await waitFor(.connected, on: &states)
        XCTAssertTrue(connected)
        let hello = try XCTUnwrap(server.ops("hello").first)
        let params = try XCTUnwrap(hello["params"] as? [String: Any])
        XCTAssertEqual(params["client"] as? String, "mac")
        XCTAssertEqual(params["protocol"] as? Int, 1)
        XCTAssertEqual(params["part_kinds"] as? [String], ["text", "approval", "routing_note"])
        XCTAssertEqual(server.received.first?["op"] as? String, "hello", "hello is the first request")
    }

    func testCrashedDaemonAutoStartsOnce() async throws {
        let client = makeClient()
        var states = client.reachability.makeAsyncIterator()
        let starting = await states.next()
        XCTAssertEqual(starting, .starting)
        await starts.until(1)
        // The backoff runs on: 100, 200, 400, 800, 1600, then 2000 ms; past 10 s it is unavailable.
        for _ in 0..<9 { await clock.finishNextSleep() }
        let next = await states.next()
        XCTAssertEqual(next, .unavailable)
        XCTAssertEqual(starts.value, 1, "the daemon is started once per outage")
    }

    func testStoppedOnPurposeShowsStartAndDoesNotStartDaemon() async throws {
        FileManager.default.createFile(atPath: markerPath, contents: Data(#"{"at":"2026-11-16T10:00:00Z","by":"cli"}"#.utf8))
        let client = makeClient()
        var states = client.reachability.makeAsyncIterator()
        let first = await states.next()
        XCTAssertEqual(first, .stoppedOnPurpose)
        for _ in 0..<8 { await clock.finishNextSleep() }
        XCTAssertEqual(starts.value, 0, "an owner stop is never undone silently")

        // Start: the start chain runs, and the chat waits for it as starting (the marker it removes is not read).
        client.startDaemonNow()
        let afterStart = await states.next()
        XCTAssertEqual(afterStart, .starting)
        await starts.until(1)
        await clock.finishNextSleep()
        XCTAssertEqual(starts.value, 1, "Start runs the start chain once")
    }

    func testClientReconnectsAndResubscribesAfterDrop() async throws {
        try server.listen()
        let client = makeClient()
        var states = client.reachability.makeAsyncIterator()
        var feed = client.feed(7).makeAsyncIterator()
        guard case .snapshot(let first)? = await feed.next() else { return XCTFail("no snapshot") }
        XCTAssertEqual(first.conversation.id, 7)
        let connected = await waitFor(.connected, on: &states)
        XCTAssertTrue(connected)

        server.dropConnections()
        guard case .resync? = await feed.next() else { return XCTFail("the drop marks the feed stale") }
        await clock.finishNextSleep()
        guard case .snapshot(let fresh)? = await feed.next() else { return XCTFail("no fresh snapshot") }
        XCTAssertEqual(fresh.conversation.id, 7)
        let again = await states.next()
        XCTAssertEqual(again, .connected, ".connected is reported after every reconnect")
        XCTAssertEqual(server.ops("subscribe").count, 2, "the open feed is subscribed again")
        XCTAssertEqual(clock.backoffSleeps, [.milliseconds(100)])
    }

    func testReconnectBackoffDoublesTo2s() async throws {
        _ = makeClient()
        for _ in 0..<8 { await clock.finishNextSleep() }
        let expected: [Duration] = [100, 200, 400, 800, 1600, 2000, 2000, 2000].map { .milliseconds($0) }
        XCTAssertEqual(Array(clock.backoffSleeps.prefix(8)), expected)
        XCTAssertEqual(ChatReachabilityPolicy.backoff(attempt: 40), .seconds(2))
    }

    /// Review Focus 5: a half-open socket after sleep — the next write fails fast, the client reconnects and
    /// resubscribes, and the send comes back as a lost answer (resent with the same key by the model).
    func testWriteFailureTriggersReconnectAndResubscribe() async throws {
        try server.listen()
        let client = makeClient()
        var states = client.reachability.makeAsyncIterator()
        var feed = client.feed(3).makeAsyncIterator()
        guard case .snapshot? = await feed.next() else { return XCTFail("no snapshot") }
        let connected = await waitFor(.connected, on: &states)
        XCTAssertTrue(connected)

        await client.failNextWrite()
        do {
            _ = try await client.send(.read(conversationID: 3, messageID: 1))
            XCTFail("a write to a half-open socket must fail")
        } catch {
            XCTAssertTrue(error is any ChatConnectionError, "a lost answer is a connection error, so a turn resends")
        }
        guard case .resync? = await feed.next() else { return XCTFail("the drop marks the feed stale") }
        await clock.finishNextSleep()
        guard case .snapshot? = await feed.next() else { return XCTFail("no fresh snapshot after the reconnect") }
        let again = await states.next()
        XCTAssertEqual(again, .connected)
    }

    func testForbiddenHelloSurfacesUnavailable() async throws {
        server.forbidHello = true
        try server.listen()
        let client = makeClient()
        var states = client.reachability.makeAsyncIterator()
        let unavailable = await waitFor(.unavailable, on: &states)
        XCTAssertTrue(unavailable)
        XCTAssertEqual(starts.value, 0, "a refused peer is no stopped daemon")
    }

    /// M2: an engine that accepts the connection but never greets is unreachable once the handshake bound passed
    /// (the daemon is started once), never stuck in its old state.
    func testSilentEngineIsUnreachableAfterTheHandshakeBound() async throws {
        server.silent = true
        try server.listen()
        let client = makeClient()
        var states = client.reachability.makeAsyncIterator()
        await clock.untilSleeping()
        XCTAssertEqual(clock.recordedSleeps, [ChatReachabilityPolicy.handshakeBound])
        await clock.finishNextSleep()
        let state = await states.next()
        XCTAssertEqual(state, .starting)
        await starts.until(1)
    }

    /// I2: a wedged engine never holds the quit: an unanswered `chat_shutdown` gives up after its bound (false), and
    /// any other unanswered request drops the connection after its own, answering the waiter as a lost answer.
    func testUnansweredRequestsGiveUpAfterTheirBound() async throws {
        server.unanswered = ["chat_shutdown", "chat_read"]
        try server.listen()
        let client = makeClient()
        var states = client.reachability.makeAsyncIterator()
        _ = await waitFor(.connected, on: &states)
        let quit = Task { await client.shutdown() }
        await server.until(op: "chat_shutdown", count: 1)
        await clock.finishNextSleep()
        let shut = await quit.value
        XCTAssertFalse(shut, "the quit goes on without the engine")
        XCTAssertTrue(clock.recordedSleeps.contains(ChatReachabilityPolicy.shutdownBound))

        await clock.finishNextSleep() // the reconnect backoff after the drop
        _ = await waitFor(.connected, on: &states)
        let read = Task { try await client.send(.read(conversationID: 1, messageID: 1)) }
        await server.until(op: "chat_read", count: 1)
        await clock.finishNextSleep()
        do {
            _ = try await read.value
            XCTFail("an unanswered request must give up")
        } catch {
            XCTAssertTrue(error is any ChatConnectionError)
        }
        XCTAssertTrue(clock.recordedSleeps.contains(ChatReachabilityPolicy.requestBound))
    }

    /// T10b I1: a socket that never greets holds a stop only `shutdownGreetBound`; then the stop goes to `watchtower
    /// chat shutdown`, whose socket step is short so its direct reap runs inside the app's watchdog.
    func testShutdownOfAHungSocketGivesUpAfterTheGreetBound() async throws {
        server.silent = true
        try server.listen()
        let client = makeClient()
        let stop = Task { await client.shutdown() }
        await clock.until(slept: ChatReachabilityPolicy.shutdownGreetBound)
        await clock.finishNextSleep()
        let shut = await stop.value
        XCTAssertFalse(shut, "the CLI fallback runs")
        XCTAssertTrue(server.ops("chat_shutdown").isEmpty)
        XCTAssertLessThan(ChatReachabilityPolicy.shutdownGreetBound, ChatReachabilityPolicy.handshakeBound)
        XCTAssertEqual(DaemonManager.chatShutdownArguments, ["chat", "shutdown", "--socket-timeout", "1s"])
    }

    /// T10b I1: once the engine answered `hello`, a stop waits at least the engine's own `chat_shutdown` budget, so a
    /// slow shutdown that works is never cut and repeated by the CLI.
    func testShutdownOnceGreetedWaitsTheEnginesBudget() async throws {
        server.unanswered = ["chat_shutdown"]
        try server.listen()
        let client = makeClient()
        var states = client.reachability.makeAsyncIterator()
        _ = await waitFor(.connected, on: &states)
        let stop = Task { await client.shutdown() }
        await server.until(op: "chat_shutdown", count: 1)
        await clock.until(slept: ChatReachabilityPolicy.shutdownBound)
        XCTAssertGreaterThanOrEqual(ChatReachabilityPolicy.shutdownBound, ChatReachabilityPolicy.engineShutdownBudget)
        XCTAssertEqual(ChatReachabilityPolicy.engineShutdownBudget, .seconds(10))
        XCTAssertFalse(clock.recordedSleeps.contains(ChatReachabilityPolicy.shutdownGreetBound), "connected: no wait")
        await clock.finishNextSleep()
        let shut = await stop.value
        XCTAssertFalse(shut)
    }

    /// T10b I2: a stop that ends the chat for good holds the client: a turn sent after it began is refused (never
    /// written), `chat_shutdown` still goes, and the connection lost to the daemon's `--internal` stop (no marker)
    /// starts nothing.
    func testHeldClientRefusesTurnsAndStartsNoDaemon() async throws {
        try server.listen()
        let client = makeClient()
        var states = client.reachability.makeAsyncIterator()
        _ = await waitFor(.connected, on: &states)
        await client.holdForStop(true)
        do {
            _ = try await client.send(.turn(ChatTurnRequest(conversationID: 1, mode: .send, text: "x", clientKey: "k")))
            XCTFail("a turn after the stop began must be refused")
        } catch {
            XCTAssertTrue(error is ChatClientStopping)
        }
        XCTAssertTrue(server.ops("chat_turn").isEmpty)
        let shut = await client.shutdown()
        XCTAssertTrue(shut)

        server.stop()
        for _ in 0..<8 { await clock.finishNextSleep() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
        XCTAssertEqual(starts.value, 0, "no daemon start behind the stop")
    }

    func testOperationAnswersEchoTheirResult() async throws {
        server.answer = { op, _ in
            switch op {
            case "chat_new": ["conversation_id": 42]
            case "chat_turn": "busy"
            default: nil
            }
        }
        try server.listen()
        let client = makeClient()
        var states = client.reachability.makeAsyncIterator()
        _ = await waitFor(.connected, on: &states)
        let created = try await client.send(.new(projectID: nil, routing: ChatRouting(mode: "auto")))
        XCTAssertEqual(created, .applied(.conversation(id: 42)))
        let refused = try await client.send(.turn(ChatTurnRequest(conversationID: 42, mode: .send, text: "x", clientKey: "k")))
        XCTAssertEqual(refused, .refused(code: "busy", message: "no"))
        let turn = try XCTUnwrap(server.ops("chat_turn").first?["params"] as? [String: Any])
        XCTAssertEqual(turn["client_key"] as? String, "k")
        XCTAssertEqual(turn["conversation_id"] as? Int, 42)
    }

    /// Anti-goal "not slower": 1 000 `message_upsert` lines through the client's path (line split, event routing,
    /// the subscription's stream) into a `ChatFeedStore`, against decoding the same lines and applying them
    /// directly. A ratio of two measured batches (no wait, no timeout): the socket path stays within 2× + 50 ms.
    @MainActor
    func testDecodePathWithinTwiceOfDirectStore() async throws {
        try server.listen()
        let client = makeClient()
        var states = client.reachability.makeAsyncIterator()
        _ = await waitFor(.connected, on: &states)
        let lines = (1...1_000).map { i in
            let text = String(repeating: "word ", count: 40) + String(i)
            return #"{"event":"message_upsert","subscription":"s1","conversation_id":9,"#
                + #""message":{"id":\#(i % 50 + 2),"role":"assistant","status":"pending","text":"\#(text)","created_at":2}}"#
        }
        let clock = ContinuousClock()
        let decoder = ChatWireCoder.makeDecoder()
        let snapshot = try decoder.decode(ChatFeed.self, from: Data(server.feedJSON(9).utf8))

        // The lowest of five rounds of each path: a busy machine slows a round, never speeds one up.
        var directTime = Duration.seconds(3600)
        var direct = ChatFeedStore()
        for _ in 0..<5 {
            let store = ChatFeedStore()
            let elapsed = try clock.measure {
                store.apply(.snapshot(snapshot))
                for line in lines {
                    let event = try decoder.decode(ChatSocketEvent.self, from: Data(line.utf8))
                    if let update = event.feedUpdate { store.apply(update) }
                }
            }
            directTime = min(directTime, elapsed)
            direct = store
        }

        var feed = client.feed(9).makeAsyncIterator()
        guard case .snapshot? = await feed.next() else { return XCTFail("no snapshot") }
        var socketTime = Duration.seconds(3600)
        var viaSocket = ChatFeedStore()
        var applied = 0
        for _ in 0..<5 {
            let store = ChatFeedStore()
            let start = clock.now
            store.apply(.snapshot(snapshot))
            server.push(lines.joined(separator: "\n"))
            applied = 0
            while applied < lines.count, let update = await feed.next() {
                store.apply(update)
                applied += 1
            }
            socketTime = min(socketTime, clock.now - start)
            viaSocket = store
        }

        XCTAssertEqual(applied, lines.count)
        XCTAssertEqual(viaSocket.feed?.messages.map(\.text), direct.feed?.messages.map(\.text))
        XCTAssertLessThanOrEqual(socketTime, directTime * 2 + .milliseconds(50),
                                 "socket \(socketTime) vs direct \(directTime)")
    }
}

/// A thread-safe count (the start chain's calls) that a test can wait on.
final class StartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var value: Int { lock.withLock { count } }

    func increment() {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            count += 1
            let ready = waiters.filter { $0.0 <= count }.map(\.1)
            waiters.removeAll { $0.0 <= count }
            return ready
        }
        due.forEach { $0.resume() }
    }

    func until(_ n: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if count >= n { return true }
                waiters.append((n, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }
}
