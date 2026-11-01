import Darwin
import Foundation
import os

/// The Go hub's status (`watchtower hub status --json`, pinned keys; the
/// `desktop_watch` snapshot and `status` events fill `state` and `reason`
/// only). An empty string reads as nil.
package struct HubStatus: Decodable, Equatable, Sendable {
    package let state: String
    package let reason: String?
    package let hubID: String?
    package let transport: String?
    package let host: String?
    package let mode: String?
    package let recordings: String?
    package let adoption: String?

    package init(
        state: String,
        reason: String? = nil,
        hubID: String? = nil,
        transport: String? = nil,
        host: String? = nil,
        mode: String? = nil,
        recordings: String? = nil,
        adoption: String? = nil
    ) {
        func value(_ text: String?) -> String? { text?.isEmpty == false ? text : nil }
        self.state = state
        self.reason = value(reason)
        self.hubID = value(hubID)
        self.transport = value(transport)
        self.host = value(host)
        self.mode = value(mode)
        self.recordings = value(recordings)
        self.adoption = value(adoption)
    }

    /// This status with a newer `state` and `reason` (a watch event), the
    /// other fields kept.
    package func with(state: String, reason: String?) -> Self {
        Self(
            state: state, reason: reason, hubID: hubID, transport: transport, host: host, mode: mode,
            recordings: recordings, adoption: adoption
        )
    }

    private enum CodingKeys: String, CodingKey {
        case state, reason, transport, host, mode, recordings, adoption
        case hubID = "hub_id"
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            state: try c.decode(String.self, forKey: .state),
            reason: try c.decodeIfPresent(String.self, forKey: .reason),
            hubID: try c.decodeIfPresent(String.self, forKey: .hubID),
            transport: try c.decodeIfPresent(String.self, forKey: .transport),
            host: try c.decodeIfPresent(String.self, forKey: .host),
            mode: try c.decodeIfPresent(String.self, forKey: .mode),
            recordings: try c.decodeIfPresent(String.self, forKey: .recordings),
            adoption: try c.decodeIfPresent(String.self, forKey: .adoption)
        )
    }
}

/// One shown-over count of a `desktop_view` (Go `hub.ShownOverWire`): the
/// session, the run start it was judged for (nil = the session was not
/// live) and the count's `agent_background_at` (nil = none). Both go as
/// JSON null when nil; the run in the agent-state stamp layout
/// (`2006-01-02T15:04:05.000Z`, milliseconds truncated), the precision the
/// hub compares runs at.
package struct HubShownOver: Encodable, Equatable, Sendable {
    package let id: Int64
    package let run: Date?
    package let reportedAt: String?

    package init(id: Int64, run: Date?, reportedAt: String?) {
        self.id = id
        self.run = run
        self.reportedAt = reportedAt
    }

    package init(id: Int64, _ count: ShownOverCount) {
        self.init(id: id, run: count.run, reportedAt: count.reportedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, run
        case reportedAt = "reported_at"
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if let run { try c.encode(Self.stamp(run), forKey: .run) } else { try c.encodeNil(forKey: .run) }
        if let reportedAt { try c.encode(reportedAt, forKey: .reportedAt) } else { try c.encodeNil(forKey: .reportedAt) }
    }

    /// `date` as `yyyy-MM-ddTHH:mm:ss.SSSZ` in UTC, milliseconds truncated
    /// (Go `db.AgentStateStamp`).
    package static func stamp(_ date: Date) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        let seconds = millis >= 0 ? millis / 1000 : (millis - 999) / 1000
        let fraction = millis - seconds * 1000
        var time = time_t(seconds)
        var parts = tm()
        gmtime_r(&time, &parts)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday),
            Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec), Int(fraction)
        )
    }
}

/// One request on the hub's control socket (Go `hub.ControlRequest`): the
/// Desktop's ops only.
package struct HubControlRequest: Encodable, Equatable, Sendable {
    package static let desktopHeartbeat = "desktop_heartbeat"
    package static let desktopView = "desktop_view"
    package static let desktopWatch = "desktop_watch"
    /// Each list of a `desktop_view` holds at most this many entries (Go
    /// `hub.MaxViewIDs`; more is refused `too_many_ids`).
    package static let maxViewIDs = 10_000

    package let op: String
    package let hidden: [Int64]?
    package let displayOver: [HubShownOver]?

    package init(op: String, hidden: [Int64]? = nil, displayOver: [HubShownOver]? = nil) {
        self.op = op
        self.hidden = hidden
        self.displayOver = displayOver
    }

    package static var heartbeat: Self { Self(op: desktopHeartbeat) }
    package static var watch: Self { Self(op: desktopWatch) }

    /// The whole view: ids sorted, so an unchanged view is the same line.
    /// Each list keeps at most `maxViewIDs` entries, the highest session
    /// ids (the newest sessions, the ones on screen); `capped` says whether
    /// any was left out.
    package static func view(hidden: Set<Int64>, displayOver: [HubShownOver]) -> (request: Self, capped: Bool) {
        let ids = hidden.sorted()
        let over = displayOver.sorted { $0.id < $1.id }
        let capped = ids.count > maxViewIDs || over.count > maxViewIDs
        return (Self(op: desktopView, hidden: Array(ids.suffix(maxViewIDs)), displayOver: Array(over.suffix(maxViewIDs))), capped)
    }

    private enum CodingKeys: String, CodingKey {
        case op, hidden
        case displayOver = "display_over"
    }
}

/// One line from the hub (Go `hub.ControlAnswer`), the keys Desktop reads.
package struct HubControlAnswer: Decodable, Equatable, Sendable {
    package let op: String?
    package let event: String?
    package let ok: Bool
    package let error: String?
    package let state: String?
    package let reason: String?
    package let viewNeeded: Bool
    package let uploadID: String?
    package let pair: String?
    package let deviceID: String?

    package init(
        op: String? = nil,
        event: String? = nil,
        ok: Bool = false,
        error: String? = nil,
        state: String? = nil,
        reason: String? = nil,
        viewNeeded: Bool = false,
        uploadID: String? = nil,
        pair: String? = nil,
        deviceID: String? = nil
    ) {
        self.op = op
        self.event = event
        self.ok = ok
        self.error = error
        self.state = state
        self.reason = reason
        self.viewNeeded = viewNeeded
        self.uploadID = uploadID
        self.pair = pair
        self.deviceID = deviceID
    }

    private enum CodingKeys: String, CodingKey {
        case op, event, ok, error, state, reason, pair
        case viewNeeded = "view_needed"
        case uploadID = "upload_id"
        case deviceID = "device_id"
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            op: try c.decodeIfPresent(String.self, forKey: .op),
            event: try c.decodeIfPresent(String.self, forKey: .event),
            ok: try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false,
            error: try c.decodeIfPresent(String.self, forKey: .error),
            state: try c.decodeIfPresent(String.self, forKey: .state),
            reason: try c.decodeIfPresent(String.self, forKey: .reason),
            viewNeeded: try c.decodeIfPresent(Bool.self, forKey: .viewNeeded) ?? false,
            uploadID: try c.decodeIfPresent(String.self, forKey: .uploadID),
            pair: try c.decodeIfPresent(String.self, forKey: .pair),
            deviceID: try c.decodeIfPresent(String.self, forKey: .deviceID)
        )
    }
}

/// One line of the `desktop_watch` stream: its first line is the answer
/// with the status snapshot, then the hub's events.
package enum HubEvent: Equatable, Sendable {
    /// The watch answer: the hub's status when the stream started.
    case snapshot(HubStatus)
    case status(HubStatus)
    case recordingQueued(uploadID: String)
    /// A pairing step (`qr`, `waiting`, `sas`, `linked`, `refused`); never a URL or a code.
    case pair(kind: String, deviceID: String?)
    case switched
    /// An event this Desktop does not know (a newer hub): skipped.
    case unknown

    init(_ answer: HubControlAnswer) throws {
        if answer.op == HubControlRequest.desktopWatch {
            guard answer.ok, let state = answer.state else { throw HubControlError.refused(answer.error ?? "bad_answer") }
            self = .snapshot(HubStatus(state: state, reason: answer.reason))
            return
        }
        switch answer.event {
        case "status": self = .status(HubStatus(state: answer.state ?? "", reason: answer.reason))
        case "recording_queued": self = .recordingQueued(uploadID: answer.uploadID ?? "")
        case "pair": self = .pair(kind: answer.pair ?? "", deviceID: answer.deviceID)
        case "switched": self = .switched
        default: self = .unknown
        }
    }
}

package enum HubControlError: Error, Equatable {
    /// Nothing serves the socket (no file there, or no hub listening).
    case noHub
    /// The socket path does not fit `sockaddr_un`.
    case pathTooLong
    /// A socket call failed with this errno.
    case io(Int32)
    /// The hub closed the connection before a whole line.
    case closed
    /// A line that is not a control answer.
    case badAnswer
    /// The hub refused the request with this error class.
    case refused(String)
}

/// What `HubCenter` needs of the control socket (a seam for tests).
package protocol HubControlClienting: Sendable {
    func send(_ request: HubControlRequest) async throws -> HubControlAnswer
    func watch() -> AsyncThrowingStream<HubEvent, Error>
}

/// The Desktop's client of the Go hub's control socket (`<hub dir>/hub.sock`):
/// one JSON line per request and per answer. `send` opens a connection for
/// one request and its answer; `watch` keeps one open for the
/// `desktop_watch` stream. Blocking POSIX I/O on a queue of its own, never
/// the main actor. Never opens anything but the socket.
package final class HubControlClient: HubControlClienting {
    /// The socket's name in the hub dir (Go `hub.SocketName`).
    package static let socketName = "hub.sock"
    /// The hub dir's override (Go `hub.EnvHubDir`, test mode).
    package static let hubDirEnv = "WATCHTOWER_HUB_DIR"

    /// The socket in the hub dir as Go's `hub.Dir` picks it: an absolute
    /// `WATCHTOWER_HUB_DIR`, else the live hub's `<data root>/.hub`
    /// (`hub.DefaultDir`). A relative override, which Go refuses, is ignored.
    package static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let dir = environment[hubDirEnv], dir.hasPrefix("/") {
            return (dir as NSString).appendingPathComponent(socketName)
        }
        return (Constants.databasePath as NSString).appendingPathComponent(".hub/\(socketName)")
    }

    /// One request's whole exchange gives up after this.
    static let requestTimeout: TimeInterval = 5
    /// A line longer than this is not an answer.
    static let maxLineBytes = 1 << 20

    package let socketPath: String
    private let queue = DispatchQueue(label: "hub-control.client", attributes: .concurrent)

    package init(socketPath: String) {
        self.socketPath = socketPath
    }

    package func send(_ request: HubControlRequest) async throws -> HubControlAnswer {
        let path = socketPath
        let line = try Self.line(request)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try Self.exchange(path: path, line: line) })
            }
        }
    }

    /// The stream runs on a thread of its own, blocked in `read` with no
    /// timer; ending the stream (the consumer cancelled or stopped) shuts the
    /// socket down, which wakes the read, and the thread closes it.
    package func watch() -> AsyncThrowingStream<HubEvent, Error> {
        let path = socketPath
        let socket = WatchSocket()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in socket.stop() }
            let thread = Thread {
                do {
                    let fd = try Self.connect(path)
                    guard socket.adopt(fd) else {
                        close(fd)
                        continuation.finish()
                        return
                    }
                    defer { socket.close() }
                    try Self.write(fd, try Self.line(.watch), deadline: Date().addingTimeInterval(Self.requestTimeout))
                    var reader = LineReader(fd: fd)
                    while true {
                        guard let next = try reader.next(timeout: nil) else { continue }
                        continuation.yield(try HubEvent(try Self.decode(next)))
                    }
                } catch {
                    if socket.isStopped { continuation.finish() } else { continuation.finish(throwing: error) }
                }
            }
            thread.name = "hub-control.watch"
            thread.start()
        }
    }

    /// The watch's socket: `stop` shuts it down (waking a blocked read) as
    /// long as it is open; only the watch thread closes it, under the same
    /// lock, so a shutdown never reaches a reused descriptor.
    private final class WatchSocket: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (fd: Int32(-1), stopped: false))

        var isStopped: Bool { state.withLock { $0.stopped } }

        /// Keeps `fd` unless the stream already ended (then false: the caller closes it).
        func adopt(_ fd: Int32) -> Bool {
            state.withLock {
                guard !$0.stopped else { return false }
                $0.fd = fd
                return true
            }
        }

        func stop() {
            state.withLock {
                $0.stopped = true
                if $0.fd >= 0 { Darwin.shutdown($0.fd, SHUT_RDWR) }
            }
        }

        func close() {
            state.withLock {
                if $0.fd >= 0 { Darwin.close($0.fd) }
                $0.fd = -1
            }
        }
    }

    // MARK: - POSIX

    private static func line(_ request: HubControlRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    private static func decode(_ line: Data) throws -> HubControlAnswer {
        do {
            return try JSONDecoder().decode(HubControlAnswer.self, from: line)
        } catch {
            throw HubControlError.badAnswer
        }
    }

    /// One request and the answer to it; pairing events (`event` set) on
    /// the way are skipped.
    private static func exchange(path: String, line: Data) throws -> HubControlAnswer {
        let fd = try connect(path)
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(requestTimeout)
        try write(fd, line, deadline: deadline)
        var reader = LineReader(fd: fd)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw HubControlError.io(ETIMEDOUT) }
            guard let next = try reader.next(timeout: left) else { continue }
            let answer = try decode(next)
            if answer.event == nil { return answer }
        }
    }

    private static func connect(_ path: String) throws -> Int32 {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw HubControlError.pathTooLong }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HubControlError.io(errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            close(fd)
            switch err {
            case ENOENT, ECONNREFUSED, ENOTDIR: throw HubControlError.noHub
            default: throw HubControlError.io(err)
            }
        }
        return fd
    }

    private static func write(_ fd: Int32, _ data: Data, deadline: Date) throws {
        var sent = 0
        while sent < data.count {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw HubControlError.io(ETIMEDOUT) }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(max(1, left * 1000))) > 0 else { continue }
            let n = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base + sent, raw.count - sent)
            }
            guard n > 0 else {
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                throw HubControlError.closed
            }
            sent += n
        }
    }

    /// The lines of one connection, kept across reads.
    private struct LineReader {
        let fd: Int32
        var buffer = Data()

        /// The next whole line, nil when none arrived within `timeout`
        /// (nil: waits for data or the end, with no timer).
        mutating func next(timeout: TimeInterval?) throws -> Data? {
            if let line = take() { return line }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, timeout.map { Int32(max(1, $0 * 1000)) } ?? -1)
            if ready < 0, errno != EINTR { throw HubControlError.io(errno) }
            guard ready > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR || errno == EAGAIN { return nil }
            guard n > 0 else { throw HubControlError.closed }
            buffer.append(contentsOf: chunk[0..<n])
            if let line = take() { return line }
            guard buffer.count <= HubControlClient.maxLineBytes else { throw HubControlError.badAnswer }
            return nil
        }

        private mutating func take() -> Data? {
            guard let end = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            let line = Data(buffer[buffer.startIndex..<end])
            buffer = Data(buffer[buffer.index(after: end)...])
            return line
        }
    }
}
