import AppKit
import Darwin
import os
import WatchtowerCore

/// A terminal session whose process the session host owns (board #496), so
/// it outlives the app. The view is a `PalettedTerminalView` — SwiftTerm
/// still parses every byte here, so bracketed
/// paste, links, owner input and focus behave as before — but its input and
/// size go to the host, and the host's output is fed into it. One host
/// connection per process run; a relaunch (`start` after an exit) opens a
/// new one with a new run token. A run keeps its session alive until it
/// ends (`keepAlive`): `TerminalCenter.close` drops the session before the
/// host reports the exit, and that exit must still be forgotten in the
/// host (or a hang-up still sent, `hangUpOnBind`).
@MainActor
final class HostedTerminalSession: TerminalSessionProcess {
    private static let logger = Logger(subsystem: Constants.bundleID, category: "SessionHost")

    private let client: SessionHostClient
    /// The workspace scope a launch carries (`SessionHostPaths.scope`), read
    /// at each launch.
    private let scope: () -> String
    /// The agent a launch of a row runs (`claude`, `codex`, "" for a shell),
    /// read at each launch: the host types lines with its input profile.
    private let agent: (Int64) -> String
    /// The host's watch request for a row's launch (`TerminalCenter`'s:
    /// a rollout-watched agent and the workspace database); nil = none.
    private let watch: (Int64) -> SessionHostWatchSpec?
    private let terminal: PalettedTerminalView
    private var transport: (any SessionHostTransport)?
    /// The host's key of the current run.
    private(set) var key: SessionHostAttachRequest?
    /// The host's launch counter of the current run (Launched/Attached);
    /// 0 until the host reported it, or from a v1 host. A delivery and a
    /// stop name it.
    private(set) var launch: UInt64 = 0
    /// The host's delivery events for the current run (v2): the pane's
    /// hints. Main thread.
    var onDeliveryEvent: ((SessionHostDeliveryEvent) -> Void)?
    /// The current run's exit followed a host Stop (the owner stopped it).
    private(set) var exitRequested = false
    /// The Launch or Attach went out on `transport`: input and resizes may
    /// follow it.
    private var requested = false
    /// The host answered Launched or Attached: the connection holds the run.
    private var bound = false
    /// The current run is over (or none started): its output is ignored.
    private var exited = true
    /// `detach` came before the host reported the run's pid, so the app
    /// could not hang it up: it is hung up once the pid arrives.
    private var hangUpOnBind = false
    /// Holds this session while a run is live; released when it ends or
    /// the app lets go of it (`detachFromHost`).
    private var keepAlive: HostedTerminalSession?
    /// The host reported the current run (Launched or Attached) since the
    /// last `start` or `attach`: from then on a lost connection is a
    /// disconnect to recover from (#1086), never the run's end, until the
    /// host lists the run as exited or no longer lists it.
    private var hostHeld = false
    /// The pane's link to the host for the current run (#1086).
    enum HostLink: Equatable {
        case connected
        /// The connection was lost while the run may still be going: the
        /// session retries on its own with a growing pause.
        case reconnecting
        /// The automatic retries stopped (`reconnectGiveUp`) without the
        /// host saying the run ended: only the owner's `reconnectNow`.
        case lost
    }

    private(set) var hostLink: HostLink = .connected {
        didSet { if hostLink != oldValue { onHostLinkChange?(hostLink) } }
    }

    /// Every change of `hostLink`. Main thread.
    var onHostLinkChange: ((HostLink) -> Void)?
    /// Failed reconnects in the current outage: the next one's pause.
    private var failedReconnects = 0
    /// The pauses taken in the current outage: past `reconnectGiveUp` the
    /// automatic retries stop.
    private var reconnectWaited: Duration = .zero
    /// Why the connection was lost, shown when the host no longer has the run.
    private var lostReason = ""
    /// The longest pause between two reconnects.
    static let maxReconnectDelay: Duration = .seconds(10)
    /// How long the automatic reconnects go on (their pauses summed); after
    /// it the pane waits for the owner's Reconnect and never reports an exit.
    static let reconnectGiveUp: Duration = .seconds(300)
    /// The connect of the current run (tests await it).
    private(set) var connecting: Task<Void, Never>?
    /// The look-up after a dropped connection (tests await it).
    private(set) var recovering: Task<Void, Never>?
    /// After Attached, how long the terminal's own replies stay unsent: the
    /// replay re-runs old queries (device attributes, cursor reports) whose
    /// answers would reach the program as stray input.
    static let replayQuietPeriod: Duration = .milliseconds(250)
    /// A seam for tests.
    var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    private(set) var pid: pid_t = 0
    var onExit: ((Int32?) -> Void)?
    var onOwnerInput: (([UInt8]) -> Void)? {
        get { terminal.onOwnerInput }
        set { terminal.onOwnerInput = newValue }
    }
    var onOwnerFocus: (() -> Void)? {
        get { terminal.onOwnerFocus }
        set { terminal.onOwnerFocus = newValue }
    }
    var isHosted: Bool { true }
    /// The host watches the current run's transcript (its Launched or
    /// Attached reply said so); false until it answered.
    private(set) var isHostWatched = false
    /// The current run has not reached the host yet: no Launched or
    /// Attached since the last `start` or `attach`. An exit while it holds
    /// (the host could not be reached or started) means the run never ran.
    private(set) var neverStarted = false
    /// The pane's reason when the host cannot be reached or started.
    static let hostNotRunningReason = "the session host is not running"

    init(
        client: SessionHostClient,
        scope: @escaping () -> String = { "" },
        agent: @escaping (Int64) -> String = { _ in "" },
        watch: @escaping (Int64) -> SessionHostWatchSpec? = { _ in nil }
    ) {
        self.client = client
        self.scope = scope
        self.agent = agent
        self.watch = watch
        terminal = PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.hostInput = { [weak self] bytes, owner in self?.sendToHost(bytes, owner: owner) }
        terminal.hostResize = { [weak self] cols, rows in self?.resizeHost(cols: cols, rows: rows) }
    }

    var view: NSView { terminal }
    var bracketedPasteMode: Bool { terminal.getTerminal().bracketedPasteMode }

    /// Launches `launch` in the host under a fresh run token, with the
    /// launch's environment (`processEnvironment`) and the
    /// view's size when the request goes out. A launch with no row has no
    /// host key: it is reported as an exit at once.
    func start(_ launch: TerminalLaunch) {
        guard let row = launch.rowID else {
            Self.logger.error("hosted launch without a session row")
            onExit?(nil)
            return
        }
        let key = SessionHostAttachRequest(row: row, run: UUID().uuidString.lowercased())
        pid = 0
        newRun()
        neverStarted = true
        terminal.dropsTerminalReplies = false
        let scope = scope()
        let agent = agent(row)
        let watch = watch(row)
        connect(key) { [terminal] in
            .json(.launch, SessionHostLaunchRequest(
                row: key.row, run: key.run, executable: launch.executable, args: launch.args,
                env: launch.processEnvironment, cwd: launch.currentDirectory,
                cols: terminal.getTerminal().cols, rows: terminal.getTerminal().rows, scope: scope, agent: agent,
                watch: watch
            ))
        }
    }

    /// Attaches to a run the host already holds: the view is reset, the
    /// host replays the run's recent output, then streams it live; the
    /// pane's size goes to the host once it answers. The terminal's own
    /// replies are dropped until `replayQuietPeriod` after Attached.
    func attach(_ info: SessionHostSessionInfo) {
        newRun()
        neverStarted = true
        reattach(info)
    }

    /// A `start` or `attach` begins with nothing to recover.
    private func newRun() {
        recovering?.cancel()
        recovering = nil
        hostHeld = false
        endOutage()
    }

    /// `attach` within the current run (`lookUp`).
    private func reattach(_ info: SessionHostSessionInfo) {
        terminal.getTerminal().resetToInitialState()
        terminal.syncMouseReporting()
        terminal.dropsTerminalReplies = true
        // An exited run's pid may already belong to another process group.
        pid = info.exited ? 0 : pid_t(info.pid)
        let key = SessionHostAttachRequest(row: info.row, run: info.run)
        connect(key) { .json(.attach, key) }
    }

    /// Drops the view from its host. A run still going keeps its connection
    /// so its exit is still forgotten in the host; one whose pid the host
    /// has not reported yet (so `TerminalCenter.close` could not signal it)
    /// is hung up once it does.
    func detach() {
        terminal.removeFromSuperview()
        if !exited, pid == 0 { hangUpOnBind = true }
    }

    /// Lets go of the run without stopping it (an update's quit): the
    /// connection closes, the host keeps the process, and no exit is
    /// reported.
    func detachFromHost() {
        onExit = nil
        exited = true
        recovering?.cancel()
        endOutage()
        closeTransport()
        keepAlive = nil
    }

    func sendInput(_ bytes: [UInt8]) {
        terminal.sendAppInput(bytes)
    }

    func setPathLinkHandler(folder: @escaping () -> String, open: @escaping (TerminalPathLinks.Location) -> Void) {
        terminal.setPathLinks(folder: folder, open: open)
    }

    func setAskLinkHandler(lookUp: @escaping (Int64) async -> OwnerAsk?, open: @escaping (Int64) -> Void) {
        terminal.setAskLinks(lookUp: lookUp, open: open)
    }

    // MARK: Protocol v2

    /// The host types the app's lines (`deliver`) — a v2 host. A v1-only
    /// host (one an app update left running) does not: the app types them
    /// itself, as before v2 (`TerminalCenter.typeLocally`).
    var hostDelivers: Bool { client.speaksV2 }

    /// The host types `line` into the current run (`SessionHostClient.deliver`,
    /// PROJ-12): nothing here writes the PTY. No bound run, or a run whose
    /// launch the host has not reported, is no session; so is a host that
    /// could not be reached or refused the request (logged).
    func deliver(_ line: SessionDeliverLine, check: @escaping @MainActor () async -> DeliverCheckReply) async -> DeliverOutcome {
        guard let key, bound, !exited, launch > 0 else { return .noSession }
        let request = DeliverRequest(
            row: key.row, run: key.run, launch: launch, text: line.text,
            keepLineBreaks: line.keepLineBreaks, keepFormat: line.keepFormat,
            settleMs: line.settle.map(Self.milliseconds) ?? 0,
            submitIf: line.submitIf, holdIfPromptText: line.holdIfPromptText
        )
        do {
            return try await client.deliver(request, check: check)
        } catch SessionHostError.deliveryInterrupted {
            Self.logger.error("deliver row \(key.row): the connection ended before the host answered")
            return .interrupted
        } catch {
            // Refused or never reached: nothing was typed.
            Self.logger.error("deliver row \(key.row): \(String(describing: error), privacy: .public)")
            return .noSession
        }
    }

    /// Asks the host to stop the current run (`SessionHostClient.stop`);
    /// its Exit then carries `requested`. False when there is no run the
    /// host reported, or the host could not take the request: the caller
    /// signals the process group itself.
    func requestStop() async -> Bool {
        guard client.speaksV2, let key, bound, !exited, launch > 0 else { return false }
        do {
            try await client.stop(row: key.row, run: key.run, launch: launch)
            return true
        } catch {
            Self.logger.error("stop row \(key.row): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// How often `waitForExit` looks.
    static let exitPollStep: Duration = .milliseconds(50)

    /// Waits until the current run's Exit came (or the run was let go of),
    /// at most `timeout`; true when it ended.
    func waitForExit(timeout: Duration) async -> Bool {
        var waited: Duration = .zero
        while !exited, waited < timeout {
            await sleep(Self.exitPollStep)
            waited += Self.exitPollStep
        }
        return exited
    }

    /// Tells the host whether a permission dialog is up in the run, so it
    /// counts no dialog key as a draft and withholds a Return over one.
    /// False when it was not sent (a v1 host, a run not bound yet).
    @discardableResult
    func sendPromptHint(dialog: Bool) -> Bool {
        // Only on a bound connection: before Launched an Error frame would
        // read as the launch failing.
        guard client.speaksV2, let key, let transport, bound, !exited, launch > 0 else { return false }
        transport.send(.json(.promptHint, SessionHostPromptHint(row: key.row, run: key.run, dialog: dialog)))
        return true
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    // MARK: Host connection

    private func connect(_ key: SessionHostAttachRequest, request: @escaping () -> SessionHostFrame) {
        closeTransport()
        self.key = key
        launch = 0
        exitRequested = false
        exited = false
        hangUpOnBind = false
        keepAlive = self
        let transport = client.makeSessionTransport()
        self.transport = transport
        connecting = Task { [weak self, client] in
            let running = await client.ensureRunning()
            guard let self, self.transport === transport else { return }
            guard running else {
                runLost(transport, reason: Self.hostNotRunningReason)
                return
            }
            do {
                try await transport.open(
                    onFrame: { [weak self, weak transport] frame in
                        guard let self, let transport else { return }
                        received(frame, on: transport)
                    },
                    onClose: { [weak self, weak transport] in
                        guard let self, let transport else { return }
                        runLost(transport, reason: "the session host closed the connection")
                    }
                )
            } catch {
                runLost(transport, reason: "could not reach the session host: \(error.localizedDescription)")
                return
            }
            guard self.transport === transport else { return }
            // The version the control connection settled: a v1 host refuses v2.
            transport.send(.json(.hello, SessionHostHello(version: client.hostVersion)))
            transport.send(request())
            requested = true
        }
    }

    private func received(_ frame: SessionHostFrame, on transport: any SessionHostTransport) {
        guard self.transport === transport, !exited else { return }
        switch frame.type {
        case .launched, .attached:
            guard let info = try? frame.decoded(SessionHostSessionInfo.self) else { return }
            pid = info.exited ? 0 : pid_t(info.pid)
            launch = info.launch
            isHostWatched = info.watched
            bound = true
            hostHeld = true
            neverStarted = false
            endOutage()
            if hangUpOnBind, pid > 0 {
                hangUpOnBind = false
                client.signalGroup(pid, SIGHUP)
            }
            if frame.type == .attached {
                let sizeLater = !info.exited && nudgeRedraw()
                endReplayQuiet(after: transport, thenReportSize: sizeLater)
            }
        case .output:
            terminal.feedOutput(frame.payload[...])
        case .exit:
            neverStarted = false // the host ran it
            let exit = try? frame.decoded(SessionHostExit.self)
            // A requested exit is the owner's stop: no PROJ-18 cleanup.
            exitRequested = exit?.requested == true
            finishRun(code: exit?.code.map { Int32(clamping: $0) }, forget: true)
        case .deliveryEvent:
            guard let event = try? frame.decoded(SessionHostDeliveryEvent.self),
                  event.row == key?.row, event.run == key?.run else { return }
            onDeliveryEvent?(event)
        case .error:
            let message = (try? frame.decoded(SessionHostErrorMessage.self).message) ?? "unreadable error"
            Self.logger.error("session host: \(message, privacy: .public)")
            if bound, message == SessionHostErrorMessage.takenOver {
                lostToTakeover()
            } else if !bound, hostHeld {
                // A reattach refused: the host's list says what became of the run.
                runLost(transport, reason: message)
            } else if !bound {
                // Before the host took the run, an error is the launch or
                // attach failing: the run is over.
                terminal.feed(text: "\r\n[Watchtower] \(message)\r\n")
                finishRun(code: nil, forget: false)
            }
        default:
            break // HelloOK; unknown types are skipped by the decoder
        }
    }

    /// Makes the child redraw at the pane's size after an attach. A resize
    /// to the same size does not make every program redraw (Node/Ink
    /// ignores it), and two resizes back to back are read as one (Node
    /// reads the size when its loop wakes), so the pane goes out one column
    /// narrower now and at its real size after the replay's quiet period.
    /// Returns whether the real size is still to be sent; with one column
    /// it goes at once.
    private func nudgeRedraw() -> Bool {
        let size = terminal.getTerminal()
        guard size.cols > 1 else {
            terminal.reportHostSize()
            return false
        }
        resizeHost(cols: size.cols - 1, rows: size.rows)
        return true
    }

    /// Another app instance attached this run (a dev build shares the
    /// host with the installed app): it is that window's now. The pane
    /// says so and lets go — no reattach, which would take it back and
    /// loop, and no exit, since the run goes on. The pid is dropped so
    /// closing the pane signals nothing.
    private func lostToTakeover() {
        terminal.feed(text: "\r\n[Watchtower] Another Watchtower window took this session over.\r\n")
        exited = true
        pid = 0
        endOutage()
        closeTransport()
        terminal.dropsTerminalReplies = false
        keepAlive = nil
    }

    /// Lets the terminal answer again once the replay is in.
    /// With `thenReportSize`, the pane's real size goes to the host then
    /// too (`nudgeRedraw`).
    private func endReplayQuiet(after transport: any SessionHostTransport, thenReportSize: Bool) {
        Task { [weak self, sleep] in
            await sleep(Self.replayQuietPeriod)
            guard let self, self.transport === transport else { return }
            terminal.dropsTerminalReplies = false
            if thenReportSize, !exited { terminal.reportHostSize() }
        }
    }

    /// The connection ended without an Exit. Before the host took the run
    /// it is gone. A run the host reported may still be going (the host
    /// dropped a slow reader, #1086), so the pane is disconnected and asks
    /// the host (`lookUp`) until it answers: a running run is reattached —
    /// after any number of drops —, an exited one reports its code, and one
    /// the host no longer lists is gone, with `reason` shown in the pane.
    /// No answer is never an exit.
    private func runLost(_ transport: any SessionHostTransport, reason: String) {
        guard self.transport === transport, !exited else { return }
        Self.logger.error("hosted session lost: \(reason, privacy: .public)")
        closeTransport()
        guard hostHeld, let key else {
            terminal.feed(text: "\r\n[Watchtower] \(reason)\r\n")
            finishRun(code: nil, forget: false)
            return
        }
        lostReason = reason
        if hostLink == .connected {
            hostLink = .reconnecting
        } else {
            failedReconnects += 1 // a reattach of this outage failed
        }
        lookUp(key)
    }

    /// The owner's Reconnect: a disconnected run is looked up now, and the
    /// automatic retries start over. Nothing while connected, or while a
    /// reattach is under way.
    func reconnectNow() {
        guard hostLink != .connected, !exited, transport == nil, let key else { return }
        recovering?.cancel()
        failedReconnects = 0
        reconnectWaited = .zero
        hostLink = .reconnecting
        lookUp(key)
    }

    /// The pause before reconnect number `failures + 1` of an outage: none
    /// for the first, then 0.5 s doubling up to `maxReconnectDelay`.
    static func reconnectDelay(after failures: Int) -> Duration {
        guard failures > 0 else { return .zero }
        let doubled = Duration.milliseconds(500) * (1 << min(failures - 1, 8))
        return min(doubled, maxReconnectDelay)
    }

    /// After the pause for this outage's failures, asks the host — started
    /// again when none answers — for the run. A host that cannot be reached
    /// or does not answer is retried later; past `reconnectGiveUp` the pane
    /// stays `.lost` until the owner's Reconnect.
    private func lookUp(_ key: SessionHostAttachRequest) {
        let delay = Self.reconnectDelay(after: failedReconnects)
        guard reconnectWaited + delay <= Self.reconnectGiveUp else {
            Self.logger.error("row \(key.row): the session host did not answer; waiting for Reconnect")
            hostLink = .lost
            return
        }
        reconnectWaited += delay
        recovering = Task { [weak self, client, sleep] in
            if delay > .zero { await sleep(delay) }
            guard let self, isRecovering(key) else { return }
            let sessions: [SessionHostSessionInfo]
            do {
                guard await client.ensureRunning() else { throw SessionHostError.disconnected }
                sessions = try await client.list()
            } catch {
                guard isRecovering(key) else { return }
                Self.logger.error("row \(key.row): could not ask the session host: \(String(describing: error), privacy: .public)")
                failedReconnects += 1
                lookUp(key)
                return
            }
            guard isRecovering(key) else { return }
            guard let info = sessions.first(where: { $0.row == key.row && $0.run == key.run }) else {
                terminal.feed(text: "\r\n[Watchtower] \(lostReason)\r\n")
                finishRun(code: nil, forget: false)
                return
            }
            if info.exited {
                finishRun(code: info.code.map { Int32(clamping: $0) }, forget: true)
            } else {
                reattach(info)
            }
        }
    }

    /// The current task still looks up `key`: not cancelled (a Reconnect
    /// replaced it), the run not over, no connection opened meanwhile.
    private func isRecovering(_ key: SessionHostAttachRequest) -> Bool {
        !Task.isCancelled && !exited && transport == nil && self.key == key && hostLink == .reconnecting
    }

    /// The outage, if any, is over: connected, counters reset.
    private func endOutage() {
        failedReconnects = 0
        reconnectWaited = .zero
        hostLink = .connected
    }

    /// Ends the run; the session may be released by the last line.
    private func finishRun(code: Int32?, forget: Bool) {
        exited = true
        endOutage()
        closeTransport()
        terminal.dropsTerminalReplies = false
        onExit?(code)
        if forget, let key {
            Task { [client] in await client.forget(row: key.row, run: key.run) }
        }
        keepAlive = nil
    }

    private func closeTransport() {
        transport?.close()
        transport = nil
        requested = false
        bound = false
    }

    /// The most bytes of one `inputTo` frame: base64 grows them by a third,
    /// `JSONEncoder` may write each base64 `/` as `\/` (at worst twice that),
    /// and the JSON around them stays well under the 4 KiB left over.
    static let inputToChunk = (SessionHostFrame.maxPayload - 4096) / 8 * 3

    /// The bytes for the run, split into frames the host accepts. Owner
    /// keystrokes and pastes go as `input`: the host counts them as the
    /// owner's draft in the prompt (PROJ-12). The terminal's own replies
    /// (focus reports, device attributes, mouse reports) and the app's input
    /// go as `inputTo`, which writes the PTY and leaves the prompt alone —
    /// as `input` a window's focus change read as a draft, and an ask's
    /// answer then waited for the owner's Return (#1743). Before the host
    /// reported the launch, or to a v1 host (no `inputTo`; it never
    /// delivers either), they go as `input` too: before Launched an Error
    /// frame would read as the launch failing. The one connection keeps
    /// both kinds in order.
    private func sendToHost(_ bytes: [UInt8], owner: Bool) {
        guard let transport, requested, !exited else { return }
        if !owner, client.speaksV2, let key, bound, launch > 0 {
            for chunk in Self.chunks(bytes, of: Self.inputToChunk) {
                transport.send(.json(.inputTo, SessionHostInputTo(row: key.row, run: key.run, launch: launch, data: Data(chunk))))
            }
            return
        }
        for chunk in Self.chunks(bytes, of: SessionHostFrame.maxPayload) {
            transport.send(SessionHostFrame(type: .input, payload: Array(chunk)))
        }
    }

    private static func chunks(_ bytes: [UInt8], of size: Int) -> [ArraySlice<UInt8>] {
        stride(from: 0, to: bytes.count, by: size).map { bytes[$0..<min($0 + size, bytes.count)] }
    }

    private func resizeHost(cols: Int, rows: Int) {
        guard let transport, requested, !exited else { return }
        transport.send(.json(.resize, SessionHostResize(cols: cols, rows: rows)))
    }
}
