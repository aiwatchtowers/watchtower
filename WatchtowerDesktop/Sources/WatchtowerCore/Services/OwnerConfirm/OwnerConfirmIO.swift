import Foundation

/// The owner-confirm socket's POSIX side: the listener, the connection cap,
/// and the blocking per-connection reads and writes on a queue of their own
/// (never the main actor). Darwin's `LOCAL_PEERPID` names each connection's
/// process, which `OwnerConfirmGrants` matches against the Desktop's own
/// children.
final class OwnerConfirmIO: @unchecked Sendable {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var connections = 0
    private let acceptQueue = DispatchQueue(label: "owner-confirm.accept")
    private let connectionQueue = DispatchQueue(label: "owner-confirm.connection", attributes: .concurrent)

    /// `getsockopt` level and name of the peer pid (sys/un.h).
    private static let solLocal: Int32 = 0
    private static let localPeerPID: Int32 = 2

    /// `pastCap` admits a connection over the cap when it says yes for the
    /// connection's pid (the Desktop's own child: idle connections must not
    /// lock its buttons out).
    func listen(
        path: String,
        pastCap: @escaping @Sendable (Int32) -> Bool,
        serve: @escaping @Sendable (Int32) -> Void
    ) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OwnerConfirmServer.ServerError.socket(errno) }
        var addr = Self.address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw OwnerConfirmServer.ServerError.socket(err)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd, pastCap: pastCap, serve: serve) }
        source.setCancelHandler { close(fd) }
        lock.lock()
        listenFD = fd
        self.source = source
        lock.unlock()
        source.resume()
    }

    func stop() {
        lock.lock()
        let source = self.source
        self.source = nil
        listenFD = -1
        lock.unlock()
        source?.cancel()
    }

    private func acceptAll(
        _ fd: Int32,
        pastCap: @Sendable (Int32) -> Bool,
        serve: @escaping @Sendable (Int32) -> Void
    ) {
        while true {
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { return }
            // An accepted socket inherits O_NONBLOCK; its reads block in poll.
            _ = fcntl(conn, F_SETFL, fcntl(conn, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            var admitted = connections < OwnerConfirmServer.maxConnections
            lock.unlock()
            // Past the cap: a granted pid, or a child of this app that its
            // runner has not registered yet (the spawn → register gap). It
            // still needs its grant, or the window, to be confirmed.
            if !admitted, let pid = Self.peerPID(conn), pastCap(pid) || Self.parentPID(pid) == getpid() {
                admitted = true
            }
            if admitted {
                lock.lock()
                connections += 1
                lock.unlock()
            }
            guard admitted else {
                close(conn)
                continue
            }
            connectionQueue.async { [weak self] in
                serve(conn)
                close(conn)
                self?.lock.lock()
                self?.connections -= 1
                self?.lock.unlock()
            }
        }
    }

    /// The request line, or nil when none arrives in `within` seconds, the
    /// line is longer than `limit`, or the connection closes first.
    static func readLine(_ fd: Int32, limit: Int, within: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(within)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count <= limit {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(max(1, left * 1000))) > 0 else { continue }
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { return nil }
            data.append(contentsOf: buf[0..<n])
            if let end = data.firstIndex(of: UInt8(ascii: "\n")) { return data[..<end] }
        }
        return nil
    }

    /// True when the peer closed its side (the CLI ended).
    static func hungUp(_ fd: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 0) > 0 else { return false }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) <= 0
    }

    static func peerPID(_ fd: Int32) -> Int32? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, solLocal, localPeerPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    /// The parent of `pid` (sysctl KERN_PROC_PID), nil when unreadable.
    static func parentPID(_ pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func write(_ fd: Int32, _ reply: OwnerConfirmReply) {
        guard var data = try? JSONEncoder().encode(reply) else { return }
        data.append(UInt8(ascii: "\n"))
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
    }

    /// Whether something accepts connections on `path` (a live server).
    static func answers(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = address(path)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() where i < raw.count - 1 { raw[i] = b }
        }
        return addr
    }
}
