import Foundation

/// What a screen bound to the tower shows (mobile Inbox spec §2.3).
public enum TowerScreenState: Equatable, Sendable {
    /// Nothing read yet.
    case idle
    /// The first read is on its way.
    case loading
    /// The screen's last read answered. `stale` is nil when what it shows is
    /// current, else the time of the last read that answered: the tower came
    /// back and the re-read is on its way, or a later read was refused.
    case ready(stale: Date?)
    /// The tower is down and the client is reconnecting. The line
    /// "Reconnecting to Watchtower…" shows only when `showsReconnectingLine()`.
    case reconnecting
    case failed(TowerFailure)
}

/// Why a screen or an action failed, and the sentence to show.
public struct TowerFailure: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The tower stayed down for `TowerTiming.failAfter`.
        case down
        /// The daemon speaks another interface version.
        case version
        /// The tower refused the read (the sentence is Go's).
        case refused
    }

    public let kind: Kind
    public let sentence: String

    public init(kind: Kind, sentence: String) {
        self.kind = kind
        self.sentence = sentence
    }

    /// The failure's one button: `version` draws Restart, the others Retry.
    /// Both call `TowerClient.retry()`.
    public var actionTitle: String { kind == .version ? TowerText.restart : TowerText.retry }
}

/// A pressed action's state while it has one: waiting for its answer, or
/// its final refusal or unknown outcome. No state: never pressed, or `ok`.
public enum TowerActionState: Equatable, Sendable {
    case busy
    case refused(String)
    /// The action may or may not have run; the client re-read the screen and
    /// never re-sends it (`TowerText.didntConfirmMac` / `didntConfirmPhone`).
    case unknown
}

/// How a pressed action ended.
public enum TowerActOutcome<Resp> {
    case ok(Resp)
    /// Refused, with Go's sentence.
    case refused(String)
    /// The tower cannot say whether it ran (a non-idempotent call that began).
    case unknown
    /// No answer: the tower stayed down (Retry re-sends the same request_id),
    /// another version, or an unreadable answer.
    case failed(TowerFailure)
}

extension TowerActOutcome: Sendable where Resp: Sendable {}
extension TowerActOutcome: Equatable where Resp: Equatable {}

/// A re-read the client made on its own (the tower came back, an action
/// answered `unknown`, Retry): the screen's last read and its result.
public struct TowerRefresh: Sendable {
    public let command: TowerCommand
    public let result: RawJSON?

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: result?.data ?? Data("{}".utf8))
    }
}

/// The one state machine every screen bound to the tower uses, over a
/// `TowerTransport` (mobile Inbox spec §2.3, §3 "Reconnecting", §9).
///
/// - The first call says `tower.hello`; another interface version restarts
///   the daemon once through `restartDaemon` when it can, else fails with
///   `TowerText.differentVersion` (Restart).
/// - A call that finds the tower down puts the client in `reconnecting`:
///   it tries `tower.hello` again 0.2 s after the drop, doubling to 2 s; the
///   line shows after 1 s down; after 15 s down it fails with
///   `TowerText.daemonDown` (Retry, which asks `startDaemon` first). Calls
///   wait meanwhile and are re-sent unchanged (a press keeps its
///   request_id) when the tower is back.
/// - On return it re-opens every watch and re-issues the screen's last read
///   once (published on `refreshes()`).
/// - A press makes a request_id and keeps it until a final answer (`ok`,
///   refused, unknown). `unknown` is never re-sent: the client re-reads.
///
/// Time comes from the injected clock only.
public actor TowerClient {
    private enum Link {
        case idle, connecting, up
        case failed(TowerFailure)
    }

    private enum Exchange: Sendable {
        case answer(Response)
        case failed(TowerFailure)
    }

    private enum Hello {
        case match, mismatch, down
    }

    private struct WatchSlot {
        let command: TowerCommand
        let continuation: AsyncStream<ChangedEvent>.Continuation
        /// The open transport watch's pump, nil while the tower is down.
        var pump: Task<Void, Never>?
        var token: UUID?
    }

    /// `api.EnvelopeVersion`.
    static let envelopeVersion = 1
    private static let downFailure = TowerFailure(kind: .down, sentence: TowerText.daemonDown)
    private static let versionFailure = TowerFailure(kind: .version, sentence: TowerText.differentVersion)
    private static let unreadable = TowerFailure(kind: .refused, sentence: TowerText.unreadableAnswer)
    private static let unsendable = TowerFailure(kind: .refused, sentence: TowerText.couldNotSend)

    private let transport: any TowerTransport
    private let clock: any Clock<Duration>
    private let restartDaemon: (@Sendable () async -> Bool)?
    private let startDaemon: (@Sendable () async -> Void)?
    private let now: @Sendable () -> Date

    public private(set) var screenState: TowerScreenState = .idle {
        didSet { if screenState != oldValue { publishState() } }
    }

    private var link = Link.idle
    /// Bumped when a connect cycle ends, so a stale timer or attempt is ignored.
    private var generation = 0
    private var connectTask: Task<Void, Never>?
    private var downTimer: Task<Void, Never>?
    private var lineShown = false
    private var linkWaiters: [CheckedContinuation<TowerFailure?, Never>] = []

    private var lastRead: (command: TowerCommand, params: RawJSON)?
    private var lastOK: Date?
    private var pendingReads = 0

    private var requestIDs: [String: String] = [:]
    private var actionStates: [String: TowerActionState] = [:]
    private var inflight: [String: Task<Exchange, Never>] = [:]

    private var watches: [UUID: WatchSlot] = [:]
    private var stateSubscribers: [UUID: AsyncStream<TowerScreenState>.Continuation] = [:]
    private var refreshSubscribers: [UUID: AsyncStream<TowerRefresh>.Continuation] = [:]

    /// `restartDaemon` restarts the daemon from the app's own CLI and says
    /// whether it did (nil: this client cannot, e.g. the phone);
    /// `startDaemon` asks the start queue to start it (Retry after down).
    public init(
        transport: any TowerTransport,
        clock: any Clock<Duration>,
        restartDaemon: (@Sendable () async -> Bool)?,
        startDaemon: (@Sendable () async -> Void)?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.clock = clock
        self.restartDaemon = restartDaemon
        self.startDaemon = startDaemon
        self.now = now
    }

    // MARK: - Observing

    /// The current state, then every change.
    public func screenStates() -> AsyncStream<TowerScreenState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TowerScreenState>.makeStream()
        continuation.yield(screenState)
        stateSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropStateSubscriber(id) } }
        return stream
    }

    /// Every re-read the client makes on its own.
    public func refreshes() -> AsyncStream<TowerRefresh> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TowerRefresh>.makeStream()
        refreshSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropRefreshSubscriber(id) } }
        return stream
    }

    /// True once the tower has been down for `TowerTiming.reconnectingLineAfter`.
    public func showsReconnectingLine() -> Bool {
        lineShown && screenState == .reconnecting
    }

    public func actionState(key: String) -> TowerActionState? {
        actionStates[key]
    }

    // MARK: - Calls

    /// Reads `command` for the screen; it becomes the screen's last read.
    public func read<Resp: Decodable & Sendable>(
        _ command: TowerCommand,
        params: some Encodable & Sendable
    ) async -> Result<Resp, TowerFailure> {
        guard let encoded = Self.encode(params) else { return .failure(Self.unsendable) }
        lastRead = (command, encoded)
        switch screenState {
        case .idle, .failed: screenState = .loading
        case .loading, .ready, .reconnecting: break
        }
        pendingReads += 1
        let exchange = await exchange(command, params: encoded)
        pendingReads -= 1
        switch exchange {
        case .failed(let failure):
            return .failure(failure)
        case .answer(let response):
            let result: Result<Resp, TowerFailure> = Self.decode(response)
            settleRead(result.map { _ in })
            return result
        }
    }

    /// Sends the press `key` (a row's id plus its verb). A new press makes a
    /// request_id, passed to `params`; it is kept, and re-sent, until a final
    /// answer. A second press while one is on its way waits for that one.
    public func act<Resp: Decodable & Sendable, Params: Encodable & Sendable>(
        _ command: TowerCommand,
        key: String,
        params: (String) -> Params
    ) async -> TowerActOutcome<Resp> {
        if let running = inflight[key] { return Self.outcome(await running.value) }
        let requestID = requestIDs[key] ?? UUID().uuidString.lowercased()
        guard let encoded = Self.encode(params(requestID)) else { return .failed(Self.unsendable) }
        requestIDs[key] = requestID
        actionStates[key] = .busy
        let task = Task { await self.exchange(command, params: encoded) }
        inflight[key] = task
        let exchange = await task.value
        inflight[key] = nil
        if case .answer = exchange { requestIDs[key] = nil }
        let outcome: TowerActOutcome<Resp> = Self.outcome(exchange)
        switch outcome {
        case .ok, .failed: actionStates[key] = nil
        case .refused(let sentence): actionStates[key] = .refused(sentence)
        case .unknown:
            actionStates[key] = .unknown
            await refresh()
        }
        return outcome
    }

    /// Opens `command`'s change watch. It stays open across drops (re-opened
    /// when the tower is back) until the consumer stops iterating.
    public func watch(_ command: TowerCommand) -> AsyncStream<ChangedEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ChangedEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        watches[id] = WatchSlot(command: command, continuation: continuation)
        continuation.onTermination = { [weak self] _ in Task { await self?.closeWatch(id) } }
        switch link {
        case .up: startPump(id)
        case .idle: startConnecting(afterDrop: false)
        case .connecting, .failed: break
        }
        return stream
    }

    /// The failure's button. After `failed(.down)` it asks `startDaemon`
    /// first, after `failed(.version)` `restartDaemon`; then it reconnects
    /// from the 0.2 s backoff. Otherwise it re-reads the screen.
    public func retry() async {
        guard case .failed(let failure) = link else {
            await refresh()
            return
        }
        var mayRestart = true
        switch failure.kind {
        case .down:
            await startDaemon?()
        case .version:
            if let restartDaemon {
                _ = await restartDaemon()
                mayRestart = false
            }
        case .refused:
            break
        }
        guard case .failed = link else { return }
        startConnecting(afterDrop: true, mayRestart: mayRestart)
        _ = await linkReady(startingOver: false)
    }

    // MARK: - Exchange

    /// Sends until an answer: waits while the tower is down and re-sends the
    /// same params when it is back. A fresh call in `failed` starts a new
    /// connect cycle; a re-send after a drop gives up with the failure.
    private func exchange(_ command: TowerCommand, params: RawJSON?) async -> Exchange {
        var startingOver = true
        while true {
            if let failure = await linkReady(startingOver: startingOver) { return .failed(failure) }
            startingOver = false
            let request = Request(v: Self.envelopeVersion, id: Self.newID(), command: command.rawValue, params: params)
            do {
                return .answer(try await transport.call(request))
            } catch {
                linkDropped()
            }
        }
    }

    /// Nil once the link is up; the failure when it failed.
    private func linkReady(startingOver: Bool) async -> TowerFailure? {
        switch link {
        case .up:
            return nil
        case .failed(let failure):
            guard startingOver else { return failure }
            startConnecting(afterDrop: false)
        case .idle:
            startConnecting(afterDrop: false)
        case .connecting:
            break
        }
        return await withCheckedContinuation { linkWaiters.append($0) }
    }

    private func refresh() async {
        guard let last = lastRead else { return }
        pendingReads += 1
        let exchange = await exchange(last.command, params: last.params)
        pendingReads -= 1
        guard case .answer(let response) = exchange else { return }
        switch response.status {
        case .ok:
            settleRead(.success(()))
            let refresh = TowerRefresh(command: last.command, result: response.result)
            refreshSubscribers.values.forEach { $0.yield(refresh) }
        default:
            settleRead((Self.decode(response) as Result<RawJSON?, TowerFailure>).map { _ in })
        }
    }

    private func settleRead(_ result: Result<Void, TowerFailure>) {
        guard case .up = link else { return }
        switch result {
        case .success:
            lastOK = now()
            screenState = .ready(stale: nil)
        case .failure(let failure):
            screenState = lastOK.map { .ready(stale: $0) } ?? .failed(failure)
        }
    }

    // MARK: - Link

    private func startConnecting(afterDrop: Bool, mayRestart: Bool = true) {
        guard connectTask == nil else { return }
        link = .connecting
        let gen = generation
        let timeline = clock.timeline()
        if afterDrop { enterDown(gen, timeline) }
        connectTask = Task { await self.connect(gen, timeline, firstWaits: afterDrop, mayRestart: mayRestart) }
    }

    /// Says hello until it answers: at once (or after the first wait after a
    /// drop), then on the backoff schedule counted from the cycle's start.
    private func connect(_ gen: Int, _ start: Timeline, firstWaits: Bool, mayRestart: Bool) async {
        var timeline = start
        var mayRestart = mayRestart
        var at = Duration.zero
        var wait = TowerTiming.retryStart
        var waits = firstWaits
        while gen == generation {
            if waits {
                at += wait
                wait = min(wait * 2, TowerTiming.retryMax)
                do { try await timeline.sleep(at) } catch { return }
                guard gen == generation else { return }
            }
            waits = true
            let hello = await hello()
            guard gen == generation else { return }
            switch hello {
            case .match:
                linkUp()
                return
            case .down:
                enterDown(gen, timeline)
            case .mismatch:
                guard mayRestart, let restartDaemon else {
                    linkFailed(gen, Self.versionFailure)
                    return
                }
                mayRestart = false
                guard await restartDaemon() else {
                    linkFailed(gen, Self.versionFailure)
                    return
                }
                guard gen == generation else { return }
                // The daemon restarts: a new down period from now.
                timeline = clock.timeline()
                at = .zero
                wait = TowerTiming.retryStart
                stopDown()
                enterDown(gen, timeline)
            }
        }
    }

    private func hello() async -> Hello {
        let request = Request(
            v: Self.envelopeVersion, id: Self.newID(), command: TowerCommand.towerHello.rawValue, params: Self.encode(HelloRequest())
        )
        let response: Response
        do {
            response = try await transport.call(request)
        } catch {
            return .down
        }
        // A daemon without tower.hello refuses it: another version too.
        guard case .success(let hello) = Self.decode(response) as Result<HelloResponse, TowerFailure> else { return .mismatch }
        return hello.interfaceVersion == InterfaceVersion.current ? .match : .mismatch
    }

    /// The tower is down: `reconnecting`, the line after 1 s, `failed` after 15 s.
    private func enterDown(_ gen: Int, _ timeline: Timeline) {
        guard gen == generation else { return }
        if downTimer == nil {
            downTimer = Task { [weak self] in
                do {
                    try await timeline.sleep(TowerTiming.reconnectingLineAfter)
                    await self?.showLine(gen)
                    try await timeline.sleep(TowerTiming.failAfter)
                    await self?.linkFailed(gen, Self.downFailure)
                } catch {
                    // Cancelled: the tower came back or the cycle ended.
                }
            }
        }
        screenState = .reconnecting
    }

    private func showLine(_ gen: Int) {
        guard gen == generation, case .connecting = link else { return }
        lineShown = true
        publishState()
    }

    private func stopDown() {
        downTimer?.cancel()
        downTimer = nil
        lineShown = false
    }

    private func linkUp() {
        connectTask = nil
        generation += 1
        stopDown()
        link = .up
        resumeWaiters(nil)
        for id in watches.keys { startPump(id) }
        switch screenState {
        case .reconnecting, .failed:
            if lastRead == nil {
                screenState = .idle
            } else {
                screenState = lastOK.map { .ready(stale: $0) } ?? .loading
            }
        case .idle, .loading, .ready:
            break
        }
        if lastRead != nil, pendingReads == 0 {
            Task { await self.refresh() }
        }
    }

    private func linkDropped() {
        guard case .up = link else { return }
        stopPumps()
        startConnecting(afterDrop: true)
    }

    private func linkFailed(_ gen: Int, _ failure: TowerFailure) {
        guard gen == generation else { return }
        generation += 1
        connectTask?.cancel()
        connectTask = nil
        stopDown()
        stopPumps()
        link = .failed(failure)
        screenState = .failed(failure)
        resumeWaiters(failure)
    }

    private func resumeWaiters(_ failure: TowerFailure?) {
        let waiters = linkWaiters
        linkWaiters = []
        waiters.forEach { $0.resume(returning: failure) }
    }

    // MARK: - Watches

    private func startPump(_ id: UUID) {
        guard var slot = watches[id], slot.pump == nil else { return }
        let token = UUID()
        let events = transport.watch(Request(v: Self.envelopeVersion, id: Self.newID(), command: slot.command.rawValue))
        slot.token = token
        slot.pump = Task { await self.pump(id, token, events) }
        watches[id] = slot
    }

    private func pump(_ id: UUID, _ token: UUID, _ events: AsyncThrowingStream<ChangedEvent, Error>) async {
        var refused = false
        do {
            for try await event in events {
                watches[id]?.continuation.yield(event)
            }
        } catch TowerTransportError.refused {
            refused = true
        } catch {
            // Down: handled below.
        }
        guard let slot = watches[id], slot.token == token else { return } // closed or replaced
        if refused {
            watches[id] = nil
            slot.continuation.finish()
            return
        }
        watches[id]?.pump = nil
        watches[id]?.token = nil
        linkDropped()
    }

    /// The connection is gone: every transport watch ends (re-opened on return).
    private func stopPumps() {
        for id in watches.keys {
            watches[id]?.pump?.cancel()
            watches[id]?.pump = nil
            watches[id]?.token = nil
        }
    }

    private func closeWatch(_ id: UUID) {
        watches.removeValue(forKey: id)?.pump?.cancel()
    }

    // MARK: - Subscribers

    private func publishState() {
        stateSubscribers.values.forEach { $0.yield(screenState) }
    }

    private func dropStateSubscriber(_ id: UUID) {
        stateSubscribers[id] = nil
    }

    private func dropRefreshSubscriber(_ id: UUID) {
        refreshSubscribers[id] = nil
    }

    // MARK: - Coding

    private static func newID() -> String {
        UUID().uuidString.lowercased()
    }

    private static func encode(_ value: some Encodable) -> RawJSON? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? RawJSON(data: data)
    }

    private static func decode<Resp: Decodable>(_ response: Response) -> Result<Resp, TowerFailure> {
        switch response.status {
        case .ok:
            guard let value = try? JSONDecoder().decode(Resp.self, from: response.result?.data ?? Data("{}".utf8)) else {
                return .failure(unreadable)
            }
            return .success(value)
        case .refused:
            return .failure(TowerFailure(kind: .refused, sentence: response.refusal?.sentence ?? TowerText.unreadableAnswer))
        case .unknownStatus, .unknown:
            return .failure(unreadable)
        }
    }

    private static func outcome<Resp: Decodable>(_ exchange: Exchange) -> TowerActOutcome<Resp> {
        switch exchange {
        case .failed(let failure):
            return .failed(failure)
        case .answer(let response):
            switch response.status {
            case .unknownStatus, .unknown:
                return .unknown
            case .refused:
                return .refused(response.refusal?.sentence ?? TowerText.unreadableAnswer)
            case .ok:
                switch decode(response) as Result<Resp, TowerFailure> {
                case .success(let value): return .ok(value)
                case .failure(let failure): return .failed(failure)
                }
            }
        }
    }
}

/// Sleeps until an offset from the moment it was made (a down period's start).
private struct Timeline: Sendable {
    let sleep: @Sendable (Duration) async throws -> Void
}

extension Clock where Duration == Swift.Duration {
    /// A timeline starting now on this clock.
    fileprivate func timeline() -> Timeline {
        let start = now
        return Timeline { offset in try await sleep(until: start.advanced(by: offset), tolerance: nil) }
    }
}
