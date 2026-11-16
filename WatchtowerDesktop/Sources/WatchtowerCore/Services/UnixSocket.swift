import Darwin
import Foundation
import os

/// The POSIX pieces the Desktop's unix-socket clients share (the hub's
/// control socket, `HubControlClient`; the daemon's tower socket,
/// `SocketTransport`). Each client maps `UnixSocket.Failure` to its own error.
enum UnixSocket {
    enum Failure: Error, Equatable {
        /// Nothing serves the path (no file there, or nobody listening).
        case absent
        /// The path does not fit `sockaddr_un`.
        case pathTooLong
        /// The write did not finish before its deadline.
        case timedOut
        /// The peer closed the connection.
        case closed
        /// A socket call failed with this errno.
        case io(Int32)
    }

    /// A connected stream socket at `path`, with `SO_NOSIGPIPE` set.
    static func connect(_ path: String) throws -> Int32 {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.pathTooLong }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.io(errno) }
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
            case ENOENT, ECONNREFUSED, ENOTDIR: throw Failure.absent
            default: throw Failure.io(err)
            }
        }
        return fd
    }

    /// Writes all of `data` before `deadline`.
    static func sendAll(_ fd: Int32, _ data: Data, deadline: Date) throws {
        var sent = 0
        while sent < data.count {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw Failure.timedOut }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(max(1, left * 1000)))
            if ready < 0 {
                if errno == EINTR { continue }
                throw Failure.io(errno)
            }
            guard ready > 0 else { continue }
            let n = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base + sent, raw.count - sent)
            }
            guard n > 0 else {
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                throw Failure.closed
            }
            sent += n
        }
    }

    /// A watch's socket: `stop` shuts it down (waking a blocked read) as
    /// long as it is open; only the watch thread closes it, under the same
    /// lock, so a shutdown never reaches a reused descriptor.
    final class WatchSocket: Sendable {
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
}
