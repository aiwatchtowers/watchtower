import Darwin
import Foundation

// MARK: - Request handling

/// Answers the bridge protocol's requests (internal/hub/transport/cloudkit/bridge.proto) over a `BridgeCloud`
/// and the share operations; the reference behaviour is the Go side's bridgefake. It checks what the bridge
/// must: Hello first and one hub per process, the hub's two CloudKit zones only, assets read only from
/// `<hub dir>/assets` and downloads written only under `<hub dir>/downloads`, and the generation of every cursor
/// and tag (another generation's is `token_expired`, never compared). It sees sealed envelopes only and opens
/// none.
public actor BridgeService {
    public struct Backends: Sendable {
        public let cloud: any BridgeCloud
        public let shares: any BridgeShareProviding

        public init(cloud: any BridgeCloud, shares: any BridgeShareProviding) {
            self.cloud = cloud
            self.shares = shares
        }
    }

    /// The envelope bytes one Batch carries at most (a frame holds 4 MiB; names and numbers fit the rest).
    public static let batchBudget = 3 << 20

    private let tags: BridgeTagMap
    private let hubDir: URL
    private let makeBackends: @Sendable (String) -> Backends
    private let onHello: @Sendable (String) -> Void
    private var hubID: String?
    private var backends: Backends?

    /// What is left of a CloudKit page that did not fit one Batch, by the cursor handed out for it.
    private struct Remainder {
        let zone: String
        var changed: [BridgeRecord]
        let token: Data?
        let more: Bool
        /// The token the page was read from.
        let resume: Data?
    }

    private var remainders: [UInt64: Remainder] = [:]

    /// `hubDir` is the directory the socket lives in; `makeBackends` builds the CloudKit side for the hub the
    /// first Hello names, `onHello` hears that hub id once (push subscriptions).
    public init(
        tags: BridgeTagMap,
        hubDir: URL,
        makeBackends: @escaping @Sendable (String) -> Backends,
        onHello: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.tags = tags
        self.hubDir = hubDir
        self.makeBackends = makeBackends
        self.onHello = onHello
    }

    public var generation: String { tags.generation }

    /// A connection's answer to one request. `helloed` says whether this connection already said Hello.
    public func handle(_ request: BridgeRequest, helloed: Bool) async -> BridgeResponse {
        BridgeResponse(id: request.id, result: await result(request.op, helloed: helloed))
    }

    private func result(_ op: BridgeOp?, helloed: Bool) async -> BridgeResult {
        if case let .hello(_, hub) = op { return hello(hub) }
        guard helloed, let hubID, let backends else { return .failure(class: "bad_request") }
        do {
            switch op {
            case .save(let items):
                return try await save(items, hubID: hubID, cloud: backends.cloud)
            case let .delete(zone, items):
                return try await delete(zone: zone, items, hubID: hubID, cloud: backends.cloud)
            case let .changes(zone, since, generation):
                return try await changes(zone: zone, since: since, generation: generation, hubID: hubID, cloud: backends.cloud)
            case let .download(zone, assetID, dst):
                try ownZone(zone, hubID: hubID)
                let target = try Self.downloadTarget(dst, hubDir: hubDir)
                try await backends.cloud.downloadAsset(zone: zone, name: assetID, to: target)
                return .done
            case .accountStatus:
                return .account(status: await backends.shares.accountStatus().wireStatus)
            case .ensureShares:
                let urls = try await backends.shares.ensureShares()
                return .shares(dataURL: urls.data, relayURL: urls.relay)
            case .setPublicLink(let open):
                try await backends.shares.setPublicLink(open: open)
                return .done
            case .participants(let zone):
                try ownZone(zone, hubID: hubID)
                let list = try await backends.shares.participants(inZoneNamed: zone)
                return .participants(list.compactMap { p in
                    p.userRecordName.map { BridgeParticipant(userRecordName: $0, accepted: p.accepted) }
                })
            case .ownerUser:
                return .ownerUser(userRecordName: try await backends.cloud.ownerUser())
            case let .removeParticipants(zone, names):
                try ownZone(zone, hubID: hubID)
                try await backends.shares.removeParticipants(inZoneNamed: zone, userRecordNames: names)
                return .done
            case .hello, nil:
                return .failure(class: "bad_request")
            }
        } catch {
            return .failure(class: bridgeFailureClass(error))
        }
    }

    private func hello(_ hub: String) -> BridgeResult {
        guard !hub.isEmpty, hubID == nil || hubID == hub else { return .failure(class: "bad_request") }
        if hubID == nil {
            hubID = hub
            backends = makeBackends(hub)
            onHello(hub)
        }
        return .hello(version: bridgeProtocolVersion, generation: tags.generation)
    }

    // MARK: Zones and paths

    private func ownZone(_ zone: String, hubID: String) throws {
        guard zone == "DataZone-\(hubID)" || zone == "RelayZone-\(hubID)" else { throw BridgeCloudFailure.unsupportedZone }
    }

    /// `path` resolved (symlinks included) when it lies inside `<hubDir>/<sub>`; nil otherwise.
    static func resolved(_ path: String, under sub: String, hubDir: URL) -> URL? {
        guard path.hasPrefix("/"), let root = realPath(hubDir.appendingPathComponent(sub).path) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let parent = realPath(url.deletingLastPathComponent().path) else { return nil }
        guard parent == root || parent.hasPrefix(root + "/") else { return nil }
        return URL(fileURLWithPath: parent).appendingPathComponent(url.lastPathComponent)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// An asset the hub asks to upload: a regular file (not a link) under `<hubDir>/assets`.
    static func assetSource(_ path: String, hubDir: URL) throws -> URL {
        guard let url = resolved(path, under: "assets", hubDir: hubDir) else { throw BridgeCloudFailure.forbidden }
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw BridgeCloudFailure.forbidden }
        return url
    }

    /// A download's destination: a new file under `<hubDir>/downloads`.
    static func downloadTarget(_ path: String, hubDir: URL) throws -> URL {
        guard let url = resolved(path, under: "downloads", hubDir: hubDir) else { throw BridgeCloudFailure.forbidden }
        return url
    }

    // MARK: Writes

    private func record(_ item: CloudItem, zone: String) throws -> BridgeRecord {
        let seq = try tags.record(zone: zone, name: item.name, changeTag: item.changeTag, systemFields: item.systemFields)
        return BridgeRecord(
            name: item.name, envelope: item.envelope, tagSeq: seq,
            serverAtMs: item.serverAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded(.down)) } ?? 0,
            assetID: item.hasAsset ? item.name : "", creator: item.creator ?? "")
    }

    /// The CloudKit precondition for an `Expect`, or the outcome when it cannot hold: a tag of another
    /// generation is refused, a tag that is not the record's current one is a conflict with the current copy.
    private enum Planned {
        case send(CloudPrecondition)
        case refused(String)
        case conflict
    }

    private func plan(_ expect: BridgeExpect?, zone: String, name: String) throws -> Planned {
        guard let expect else { return .send(.none) }
        switch expect.mode {
        case .none:
            return .send(.none)
        case .absent:
            return .send(.absent)
        case .seq:
            guard expect.generation == tags.generation else { return .refused("token_expired") }
            guard let entry = try tags.entry(zone: zone, name: name), entry.tagSeq == expect.tagSeq else { return .conflict }
            return .send(.unchanged(changeTag: entry.changeTag, systemFields: entry.systemFields))
        }
    }

    private func outcome(_ result: CloudWriteResult, zone: String, name: String, deleting: Bool) throws -> BridgeOutcome {
        switch result {
        case .done(let item):
            if deleting {
                try tags.forget(zone: zone, name: name)
                return BridgeOutcome(saved: true)
            }
            guard let item else { return BridgeOutcome(refusedClass: "unavailable") }
            return BridgeOutcome(saved: true, tagSeq: try record(item, zone: zone).tagSeq)
        case .conflict(let item):
            if item == nil { try tags.forget(zone: zone, name: name) }
            return BridgeOutcome(conflict: try item.map { try record($0, zone: zone) })
        case .refused(let failureClass):
            return BridgeOutcome(refusedClass: failureClass)
        }
    }

    private func save(_ items: [BridgeSaveItem], hubID: String, cloud: any BridgeCloud) async throws -> BridgeResult {
        var assets: [URL?] = []
        for item in items {
            try ownZone(item.zone, hubID: hubID)
            assets.append(item.assetPath.isEmpty ? nil : try Self.assetSource(item.assetPath, hubDir: hubDir))
        }
        var outcomes = [BridgeOutcome?](repeating: nil, count: items.count)
        var byZone: [String: [(index: Int, write: CloudWrite)]] = [:]
        var zoneOrder: [String] = []
        for (i, item) in items.enumerated() {
            switch try plan(item.expect, zone: item.zone, name: item.name) {
            case .refused(let failureClass):
                outcomes[i] = BridgeOutcome(refusedClass: failureClass)
            case .conflict:
                let current = try await cloud.fetch(zone: item.zone, name: item.name)
                outcomes[i] = try outcome(.conflict(current), zone: item.zone, name: item.name, deleting: false)
            case .send(let precondition):
                if byZone[item.zone] == nil { zoneOrder.append(item.zone) }
                byZone[item.zone, default: []].append(
                    (i, CloudWrite(name: item.name, envelope: item.envelope, assetURL: assets[i], precondition: precondition)))
            }
        }
        for zone in zoneOrder {
            let group = byZone[zone] ?? []
            let results = try await cloud.save(zone: zone, group.map(\.write))
            guard results.count == group.count else { throw BridgeCloudFailure.unavailable }
            for (entry, result) in zip(group, results) {
                outcomes[entry.index] = try outcome(result, zone: zone, name: entry.write.name, deleting: false)
            }
        }
        return .outcomes(outcomes.map { $0 ?? BridgeOutcome(refusedClass: "unavailable") })
    }

    private func delete(zone: String, _ items: [BridgeDeleteItem], hubID: String, cloud: any BridgeCloud) async throws -> BridgeResult {
        try ownZone(zone, hubID: hubID)
        var outcomes = [BridgeOutcome?](repeating: nil, count: items.count)
        var sendable: [(index: Int, deletion: CloudDeletion)] = []
        for (i, item) in items.enumerated() {
            switch try plan(item.expect, zone: zone, name: item.name) {
            case .refused(let failureClass):
                outcomes[i] = BridgeOutcome(refusedClass: failureClass)
            case .conflict:
                let current = try await cloud.fetch(zone: zone, name: item.name)
                outcomes[i] = try outcome(.conflict(current), zone: zone, name: item.name, deleting: true)
            case .send(let precondition):
                sendable.append((i, CloudDeletion(name: item.name, precondition: precondition)))
            }
        }
        if !sendable.isEmpty {
            let results = try await cloud.delete(zone: zone, sendable.map(\.deletion))
            guard results.count == sendable.count else { throw BridgeCloudFailure.unavailable }
            for (entry, result) in zip(sendable, results) {
                outcomes[entry.index] = try outcome(result, zone: zone, name: entry.deletion.name, deleting: true)
            }
        }
        return .outcomes(outcomes.map { $0 ?? BridgeOutcome(refusedClass: "unavailable") })
    }

    // MARK: Changes

    private func changes(zone: String, since: UInt64, generation: String, hubID: String, cloud: any BridgeCloud) async throws -> BridgeResult {
        try ownZone(zone, hubID: hubID)
        if since != 0 && generation != tags.generation { throw BridgeCloudFailure.tokenExpired }
        if let rest = remainders.removeValue(forKey: since), rest.zone == zone {
            return .batch(try pack(zone: zone, changed: rest.changed, deleted: [], token: rest.token, more: rest.more, resume: rest.resume))
        }
        let token: Data?
        do {
            token = try tags.token(zone: zone, cursor: since)
        } catch BridgeTagMap.MapError.unknownCursor {
            throw BridgeCloudFailure.tokenExpired
        }
        let page = try await cloud.changes(zone: zone, since: token)
        let changed = try page.changed.map { try record($0, zone: zone) }
        for name in page.deleted { try tags.forget(zone: zone, name: name) }
        return .batch(try pack(zone: zone, changed: changed, deleted: page.deleted, token: page.token, more: page.more, resume: token))
    }

    /// One Batch of at most `batchBudget` envelope bytes (at least one record). What does not fit waits in
    /// memory under a fresh cursor that names `resume` (the token the page was read from), so a bridge that
    /// restarts reads that page again rather than skipping it.
    private func pack(zone: String, changed: [BridgeRecord], deleted: [String], token: Data?, more: Bool, resume: Data?) throws -> BridgeBatch {
        var size = 0, count = 0
        while count < changed.count {
            size += changed[count].envelope.count + changed[count].name.utf8.count + 64
            if count > 0 && size > Self.batchBudget { break }
            count += 1
        }
        if count < changed.count {
            let cursor = try tags.cursor(zone: zone, token: resume, fresh: true)
            remainders[cursor] = Remainder(zone: zone, changed: Array(changed[count...]), token: token, more: more, resume: resume)
            return BridgeBatch(changed: Array(changed[..<count]), deleted: deleted, newSeq: cursor, more: true, generation: tags.generation)
        }
        let cursor = try tags.cursor(zone: zone, token: token)
        return BridgeBatch(changed: changed, deleted: deleted, newSeq: cursor, more: more, generation: tags.generation)
    }
}

// MARK: - Socket

/// The bridge's Unix socket: `<hub dir>/bridge.sock` (0600, its directory 0700), one thread per connection,
/// frames of a u32 big-endian length and a message of at most 4 MiB. A peer whose uid differs from this
/// process's is closed before anything is read or written. When no connection has been open for `idleExit`
/// (10 min) `onIdle` runs (the app exits). It is a backstop for a bridge the daemon left behind: the daemon
/// stops the bridge with the hub, and its supervisor (internal/hub/transport/cloudkit/supervisor.go) restarts
/// one that exits, so a shorter limit would only churn restarts while the hub reconnects (its healthy-run
/// mark is 60 s).
public final class BridgeSocketServer: @unchecked Sendable {
    public typealias PeerUID = @Sendable (Int32) -> uid_t?

    /// How long the bridge waits without a connection before it exits: 10 minutes.
    public static let defaultIdleExit: TimeInterval = 600

    private let socketPath: String
    private let service: BridgeService
    private let peerUID: PeerUID
    private let idleExit: TimeInterval
    private let onIdle: @Sendable () -> Void

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var connections: [ObjectIdentifier: BridgeConnection] = [:]
    private var idleTimer: DispatchSourceTimer?
    private var stopped = false

    /// The peer's uid through `getpeereid`; nil when it cannot be read.
    public static let systemPeerUID: PeerUID = { fd in
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    public init(
        socketPath: String,
        service: BridgeService,
        peerUID: @escaping PeerUID = BridgeSocketServer.systemPeerUID,
        idleExit: TimeInterval = BridgeSocketServer.defaultIdleExit,
        onIdle: @escaping @Sendable () -> Void = {}
    ) {
        self.socketPath = socketPath
        self.service = service
        self.peerUID = peerUID
        self.idleExit = idleExit
        self.onIdle = onIdle
    }

    public enum ServerError: Error, Equatable {
        case pathTooLong
        case notASocket
        case posix(String, Int32)
    }

    /// Binds and listens, then accepts on a background thread.
    public func start() throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw ServerError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        // A socket left by an earlier bridge is replaced; anything else at the path is not ours to remove.
        var st = stat()
        if lstat(socketPath, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFSOCK else { throw ServerError.notASocket }
            unlink(socketPath)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.posix("socket", errno) }
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw ServerError.posix("bind", err)
        }
        chmod(socketPath, 0o600)
        guard listen(fd, 8) == 0 else {
            let err = errno
            close(fd)
            throw ServerError.posix("listen", err)
        }
        lock.withLock { listenFD = fd }
        armIdleTimer()
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "bridge-accept"
        thread.start()
    }

    /// Closes the listener and every connection, and removes the socket file.
    public func stop() {
        let (fd, open) = lock.withLock { () -> (Int32, [BridgeConnection]) in
            stopped = true
            idleTimer?.cancel()
            idleTimer = nil
            let fd = listenFD
            listenFD = -1
            return (fd, Array(connections.values))
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(socketPath)
        }
        open.forEach { $0.close() }
    }

    /// Sends `event` to every connection that said Hello.
    public func broadcast(_ event: BridgeEvent) {
        let open = lock.withLock { Array(connections.values) }
        let frame = BridgeResponse(id: 0, result: .event(event)).encoded()
        open.filter(\.helloed).forEach { $0.send(frame) }
    }

    public var connectionCount: Int { lock.withLock { connections.count } }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            // A peer that stops reading cannot hold a write (and the connection's lock) forever.
            var sendTimeout = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            guard let uid = peerUID(client), uid == geteuid() else {
                bridgeLogger.notice("refused a bridge peer of another user")
                close(client)
                continue
            }
            let connection = BridgeConnection(fd: client, service: service)
            let accepted = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                connections[ObjectIdentifier(connection)] = connection
                idleTimer?.cancel()
                idleTimer = nil
                return true
            }
            guard accepted else {
                close(client)
                return
            }
            let thread = Thread { [weak self] in
                connection.run()
                self?.closed(connection)
            }
            thread.name = "bridge-conn"
            thread.start()
        }
    }

    private func closed(_ connection: BridgeConnection) {
        lock.withLock {
            connections[ObjectIdentifier(connection)] = nil
            if connections.isEmpty && !stopped { armIdleTimerLocked() }
        }
    }

    private func armIdleTimer() {
        lock.withLock { armIdleTimerLocked() }
    }

    private func armIdleTimerLocked() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + idleExit)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = self.lock.withLock { self.connections.isEmpty && !self.stopped }
            if idle { self.onIdle() }
        }
        idleTimer = timer
        timer.resume()
    }
}

/// One accepted connection: reads frames on its own thread, answers each request as it completes (answers
/// carry their request's id), writes under `lock`. The descriptor's lifetime follows one rule: only the reader
/// thread releases it, when its loop ends, under `lock`; `close()` only marks the connection closing and shuts
/// the socket down (which ends the reader's blocking read). `send` checks both marks under the same lock, so a
/// late answer — a request that finished after its connection closed — is dropped and never written to a
/// reused descriptor number.
final class BridgeConnection: @unchecked Sendable {
    private let fd: Int32
    private let service: BridgeService
    private let lock = NSLock()
    private var closing = false
    private var released = false
    private var saidHello = false

    init(fd: Int32, service: BridgeService) {
        self.fd = fd
        self.service = service
    }

    var helloed: Bool { lock.withLock { saidHello } }

    func run() {
        defer { release() }
        while true {
            let message: Data
            switch readFrame() {
            case .closed:
                return
            case .refused(let length):
                bridgeLogger.error("refused a frame of \(length, privacy: .public) bytes; closing the connection")
                send(BridgeResponse(id: 0, result: .failure(class: "bad_request")).encoded())
                return
            case .message(let bytes):
                message = bytes
            }
            guard let request = try? BridgeRequest.decode(message) else {
                bridgeLogger.error("refused an undecodable frame; closing the connection")
                send(BridgeResponse(id: 0, result: .failure(class: "bad_request")).encoded())
                return
            }
            if case .hello = request.op {
                // A Hello is answered before the next request is read, so that one is judged after it.
                let answered = DispatchSemaphore(value: 0)
                Task {
                    let response = await service.handle(request, helloed: false)
                    if case .hello = response.result { lock.withLock { saidHello = true } }
                    send(response.encoded())
                    answered.signal()
                }
                answered.wait()
                continue
            }
            let helloedNow = helloed
            Task { send(await service.handle(request, helloed: helloedNow).encoded()) }
        }
    }

    /// Writes one answer; dropped once the connection is closing. An answer too large for a frame is
    /// answered `record_too_large` under its id instead.
    func send(_ message: Data) {
        let frame: Data
        do {
            frame = try BridgeFraming.frame(message)
        } catch {
            let id = (try? BridgeResponse.decode(message))?.id ?? 0
            bridgeLogger.error("an answer of \(message.count, privacy: .public) bytes does not fit a frame")
            send(BridgeResponse(id: id, result: .failure(class: "record_too_large")).encoded())
            return
        }
        lock.withLock {
            guard !closing, !released else { return }
            frame.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, base + offset, raw.count - offset)
                    if n <= 0 {
                        if n < 0 && errno == EINTR { continue }
                        return
                    }
                    offset += n
                }
            }
        }
    }

    /// Marks the connection closing and ends the reader's read; the reader releases the descriptor.
    func close() {
        lock.withLock {
            guard !closing, !released else { return }
            closing = true
            shutdown(fd, SHUT_RDWR)
        }
    }

    private func release() {
        lock.withLock {
            guard !released else { return }
            closing = true
            released = true
            Darwin.close(fd)
        }
    }

    private enum Frame {
        case message(Data)
        case refused(Int)
        case closed
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while offset < count {
                let n = Darwin.read(fd, base + offset, count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        return ok ? data : nil
    }

    private func readFrame() -> Frame {
        guard let header = readExactly(4) else { return .closed }
        let bytes = [UInt8](header)
        let announced = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard let length = try? BridgeFraming.length(ofHeader: header) else { return .refused(announced) }
        if length == 0 { return .message(Data()) }
        return readExactly(length).map(Frame.message) ?? .closed
    }
}
