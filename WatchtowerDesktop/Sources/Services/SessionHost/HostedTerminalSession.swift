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
    /// Reattaches left after a bound connection drops while the run may
    /// still be going: one per `start` or `attach`, not restored by the
    /// reattach itself, so two windows taking one run from each other
    /// cannot loop.
    private var reattachesLeft = 1
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
    /// The current run has not reached the host yet: no Launched or
    /// Attached since the last `start` or `attach`. An exit while it holds
    /// (the host could not be reached or started) means the run never ran.
    private(set) var neverStarted = false
    /// The pane's reason when the host cannot be reached or started.
    static let hostNotRunningReason = "the session host is not running"

    init(client: SessionHostClient, scope: @escaping () -> String = { "" }, agent: @escaping (Int64) -> String = { _ in "" }) {
        self.client = client
        self.scope = scope
        self.agent = agent
        terminal = PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.hostInput = { [weak self] bytes in self?.sendToHost(bytes) }
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
        reattachesLeft = 1
        neverStarted = true
        terminal.dropsTerminalReplies = false
        let scope = scope()
        let agent = agent(row)
        connect(key) { [terminal] in
            .json(.launch, SessionHostLaunchRequest(
                row: key.row, run: key.run, executable: launch.executable, args: launch.args,
                env: launch.processEnvironment, cwd: launch.currentDirectory,
                cols: terminal.getTerminal().cols, rows: terminal.getTerminal().rows, scope: scope, agent: agent
            ))
        }
    }

    /// Attaches to a run the host already holds: the view is reset, the
    /// host replays the run's recent output, then streams it live; the
    /// pane's size goes to the host once it answers. The terminal's own
    /// replies are dropped until `replayQuietPeriod` after Attached.
    func attach(_ info: SessionHostSessionInfo) {
        reattachesLeft = 1
        neverStarted = true
        reattach(info)
    }

    /// `attach` without restoring the reattach budget (`runLost`).
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
            bound = true
            neverStarted = false
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
    /// it is gone. A bound run may still be going (the host dropped a slow
    /// reader), so the host is asked once:
    /// a running run is reattached, an exited one reports its code, and an
    /// unknown one — or a second drop of the same binding — is gone, with
    /// `reason` shown in the pane.
    private func runLost(_ transport: any SessionHostTransport, reason: String) {
        guard self.transport === transport, !exited else { return }
        Self.logger.error("hosted session lost: \(reason, privacy: .public)")
        let wasBound = bound
        closeTransport()
        guard wasBound, reattachesLeft > 0, let key else {
            terminal.feed(text: "\r\n[Watchtower] \(reason)\r\n")
            finishRun(code: nil, forget: false)
            return
        }
        reattachesLeft -= 1
        recovering = Task { [weak self, client] in
            let sessions = try? await client.list()
            guard let self, !exited, self.transport == nil, self.key == key else { return }
            guard let info = sessions?.first(where: { $0.row == key.row && $0.run == key.run }) else {
                terminal.feed(text: "\r\n[Watchtower] \(reason)\r\n")
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

    /// Ends the run; the session may be released by the last line.
    private func finishRun(code: Int32?, forget: Bool) {
        exited = true
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

    /// Owner input and the terminal's replies, split into frames the host
    /// accepts.
    private func sendToHost(_ bytes: [UInt8]) {
        guard let transport, requested, !exited else { return }
        var start = 0
        while start < bytes.count {
            let end = min(start + SessionHostFrame.maxPayload, bytes.count)
            transport.send(SessionHostFrame(type: .input, payload: Array(bytes[start..<end])))
            start = end
        }
    }

    private func resizeHost(cols: Int, rows: Int) {
        guard let transport, requested, !exited else { return }
        transport.send(.json(.resize, SessionHostResize(cols: cols, rows: rows)))
    }
}
