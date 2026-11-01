import Darwin
import Foundation
import XCTest
@testable import WatchtowerCore

/// A stand-in for the Go hub's control socket: a unix listener in a temp
/// dir whose `answer` turns each request line into the lines sent back. A
/// connection whose request is `desktop_watch` stays open and gets every
/// line passed to `push` afterwards.
final class FakeHubSocket: @unchecked Sendable {
    let path: String
    private let dir: String
    private let fd: Int32
    private let lock = NSLock()
    private var requests: [[String: Any]] = []
    private var watchers: [Int32] = []
    private var open: [Int32] = []
    private var stopped = false
    private var closedConnections = 0
    var answer: @Sendable ([String: Any]) -> [String] = { _ in [#"{"ok":true}"#] }

    init() throws {
        // A short name: sockaddr_un holds 104 bytes.
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("wthc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/hub.sock"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw HubControlError.io(errno) }
        Thread.detachNewThread { [self] in acceptAll() }
    }

    var received: [[String: Any]] { lock.withLock { requests } }
    var watcherCount: Int { lock.withLock { watchers.count } }
    /// Connections the client closed (its side hung up).
    var closedCount: Int { lock.withLock { closedConnections } }

    func push(_ line: String) {
        for w in lock.withLock({ watchers }) { Self.send(w, line) }
    }

    /// Closes every open connection (the hub went away) but keeps listening.
    func dropConnections() {
        let all = lock.withLock { () -> [Int32] in
            let all = open
            open = []
            watchers = []
            return all
        }
        all.forEach { Darwin.shutdown($0, SHUT_RDWR) }
    }

    func stop() {
        lock.withLock { stopped = true }
        dropConnections()
        Darwin.shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func acceptAll() {
        while true {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            if lock.withLock({ stopped }) { close(c); return }
            lock.withLock { open.append(c) }
            Thread.detachNewThread { [self] in serve(c) }
        }
    }

    private func serve(_ c: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(c, &chunk, chunk.count)
            guard n > 0 else {
                lock.withLock {
                    closedConnections += 1
                    open.removeAll { $0 == c }
                    watchers.removeAll { $0 == c }
                }
                close(c)
                return
            }
            buffer.append(contentsOf: chunk[0..<n])
            while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<end])
                buffer = Data(buffer[buffer.index(after: end)...])
                guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                lock.withLock { requests.append(request) }
                for out in answer(request) { Self.send(c, out) }
                if request["op"] as? String == "desktop_watch" { lock.withLock { watchers.append(c) } }
            }
        }
    }

    private static func send(_ c: Int32, _ line: String) {
        let data = Array((line + "\n").utf8)
        _ = data.withUnsafeBufferPointer { Darwin.write(c, $0.baseAddress, $0.count) }
    }
}

/// Polls `condition` up to 5 s (the fake server answers on its own threads).
func waitUntil(_ what: String, _ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), what)
}

final class HubControlClientTests: XCTestCase {
    private var server: FakeHubSocket!

    override func setUpWithError() throws {
        signal(SIGPIPE, SIG_IGN)
        server = try FakeHubSocket()
    }

    override func tearDown() {
        server.stop()
        super.tearDown()
    }

    func testDecodesPinnedStatusKeys() throws {
        let json = """
            {"state":"running","reason":"","hub_id":"hub-acme","relay_device_id":"r1","transport":"cloudkit",
             "impl":"go","dir":"/x","phones":2,"host":"desktop","mode":"live","recordings":"on","adoption":"done"}
            """
        let status = try JSONDecoder().decode(HubStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, HubStatus(
            state: "running", reason: nil, hubID: "hub-acme", transport: "cloudkit", host: "desktop", mode: "live",
            recordings: "on", adoption: "done"
        ))
        // A desktop host's CLI answer before the Go hub runs there.
        let off = try JSONDecoder().decode(HubStatus.self, from: Data(#"{"state":"off","reason":"desktop_host"}"#.utf8))
        XCTAssertEqual(off.reason, "desktop_host")
        XCTAssertNil(off.hubID)
    }

    func testHeartbeatAnswerCarriesViewNeeded() async throws {
        server.answer = { _ in [#"{"op":"desktop_heartbeat","ok":true,"at":"2026-11-01T10:00:00Z","view_needed":true}"#] }
        let answer = try await HubControlClient(socketPath: server.path).send(.heartbeat)
        XCTAssertTrue(answer.ok)
        XCTAssertTrue(answer.viewNeeded)
        XCTAssertEqual(server.received.first?["op"] as? String, "desktop_heartbeat")
    }

    func testPairEventsBeforeTheAnswerAreSkipped() async throws {
        server.answer = { _ in [#"{"event":"pair","ok":false,"pair":"waiting"}"#, #"{"op":"desktop_view","ok":true}"#] }
        let answer = try await HubControlClient(socketPath: server.path).send(.view(hidden: [], displayOver: []).request)
        XCTAssertEqual(answer.op, "desktop_view")
        XCTAssertTrue(answer.ok)
    }

    /// The Go `hub.ShownOverWire` shape: `{id, run, reported_at}`, nulls
    /// spelled out, the run in the agent-state stamp layout.
    func testViewWireShape() async throws {
        let run = Date(timeIntervalSince1970: 1_799_999_000.123_9)
        let (request, capped) = HubControlRequest.view(hidden: [9, 4], displayOver: [
            HubShownOver(id: 6, run: nil, reportedAt: nil),
            HubShownOver(id: 5, ShownOverCount(run: run, reportedAt: "2027-01-15T07:43:21.000Z"))
        ])
        XCTAssertFalse(capped)
        _ = try await HubControlClient(socketPath: server.path).send(request)
        let sent = try XCTUnwrap(server.received.first)
        XCTAssertEqual(sent["op"] as? String, "desktop_view")
        XCTAssertEqual(sent["hidden"] as? [Int64], [4, 9])
        let over = try XCTUnwrap(sent["display_over"] as? [[String: Any]])
        XCTAssertEqual(over.count, 2)
        XCTAssertEqual(over[0]["id"] as? Int64, 5)
        XCTAssertEqual(over[0]["run"] as? String, "2027-01-15T07:43:20.123Z")
        XCTAssertEqual(over[0]["reported_at"] as? String, "2027-01-15T07:43:21.000Z")
        XCTAssertEqual(over[1]["id"] as? Int64, 6)
        XCTAssertTrue(over[1]["run"] is NSNull)
        XCTAssertTrue(over[1]["reported_at"] is NSNull)
    }

    func testWatchYieldsTheSnapshotThenEvents() async throws {
        server.answer = { request in
            request["op"] as? String == "desktop_watch"
                ? [#"{"op":"desktop_watch","ok":true,"state":"off","reason":"disabled"}"#] : []
        }
        var events = HubControlClient(socketPath: server.path).watch().makeAsyncIterator()
        let first = try await events.next()
        XCTAssertEqual(first, .snapshot(HubStatus(state: "off", reason: "disabled")))
        await waitUntil("the watch is registered") { server.watcherCount == 1 }
        server.push(#"{"event":"status","ok":false,"state":"running"}"#)
        server.push(#"{"event":"recording_queued","ok":false,"upload_id":"u-1"}"#)
        server.push(#"{"event":"pair","ok":false,"pair":"linked","device_id":"d-1"}"#)
        server.push(#"{"event":"later","ok":false}"#)
        let rest = [try await events.next(), try await events.next(), try await events.next(), try await events.next()]
        XCTAssertEqual(rest, [
            .status(HubStatus(state: "running")), .recordingQueued(uploadID: "u-1"),
            .pair(kind: "linked", deviceID: "d-1"), .unknown
        ])
        server.dropConnections()
        do {
            _ = try await events.next()
            XCTFail("a closed connection ends the stream with an error")
        } catch {
            XCTAssertEqual(error as? HubControlError, .closed)
        }
    }

    /// Cancelling the consumer shuts the socket down at once (no timer):
    /// the hub sees the connection closed and the stream's thread ends.
    func testCancellingTheWatchClosesItsSocket() async throws {
        server.answer = { _ in [#"{"op":"desktop_watch","ok":true,"state":"running"}"#] }
        let stream = HubControlClient(socketPath: server.path).watch()
        let consumer = Task {
            var count = 0
            for try await _ in stream { count += 1 }
            return count
        }
        await waitUntil("the watch is registered") { server.watcherCount == 1 }
        consumer.cancel()
        await waitUntil("the client closed its side") { server.closedCount == 1 }
        let count = try await consumer.value
        XCTAssertEqual(count, 1, "the snapshot, then a clean end")
    }

    func testViewListsAreCappedToTheNewestIDs() {
        let ids = Set((1...Int64(HubControlRequest.maxViewIDs + 5)))
        let (request, capped) = HubControlRequest.view(hidden: ids, displayOver: [HubShownOver(id: 1, run: nil, reportedAt: nil)])
        XCTAssertTrue(capped)
        XCTAssertEqual(request.hidden?.count, HubControlRequest.maxViewIDs)
        XCTAssertEqual(request.hidden?.first, 6, "the lowest ids go")
        XCTAssertEqual(request.displayOver?.map(\.id), [1])
    }

    func testSocketPathHonoursTheHubDirOverride() {
        XCTAssertEqual(HubControlClient.defaultSocketPath(environment: ["WATCHTOWER_HUB_DIR": "/tmp/hubtest-acme"]),
                       "/tmp/hubtest-acme/hub.sock")
        let live = (Constants.databasePath as NSString).appendingPathComponent(".hub/hub.sock")
        XCTAssertEqual(HubControlClient.defaultSocketPath(environment: [:]), live)
        XCTAssertEqual(HubControlClient.defaultSocketPath(environment: ["WATCHTOWER_HUB_DIR": "relative"]), live,
                       "a relative dir, refused by Go, is ignored")
    }

    func testNoSocketIsNoHub() async {
        let client = HubControlClient(socketPath: "/tmp/wt-hc-missing-\(UUID().uuidString.prefix(8))/hub.sock")
        do {
            _ = try await client.send(.heartbeat)
            XCTFail("no socket, no answer")
        } catch {
            XCTAssertEqual(error as? HubControlError, .noHub)
        }
        var events = client.watch().makeAsyncIterator()
        do {
            _ = try await events.next()
            XCTFail("no socket, no watch")
        } catch {
            XCTAssertEqual(error as? HubControlError, .noHub)
        }
    }

    func testStampTruncatesToMilliseconds() {
        XCTAssertEqual(HubShownOver.stamp(Date(timeIntervalSince1970: 0.9999)), "1970-01-01T00:00:00.999Z")
        XCTAssertEqual(HubShownOver.stamp(Date(timeIntervalSince1970: 1_799_999_000)), "2027-01-15T07:43:20.000Z")
    }
}
