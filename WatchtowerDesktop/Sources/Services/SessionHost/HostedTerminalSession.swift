import AppKit
import Darwin
import os
import WatchtowerCore

/// A terminal session whose process the session host owns (board #496), so
/// it outlives the app. The view is the same `PalettedTerminalView` as a
/// local session's — SwiftTerm still parses every byte here, so bracketed
/// paste, links, owner input and focus behave as before — but its input and
/// size go to the host, and the host's output is fed into it. One host
/// connection per process run; a relaunch (`start` after an exit) opens a
/// new one with a new run token.
@MainActor
final class HostedTerminalSession: TerminalSessionProcess {
    private static let logger = Logger(subsystem: Constants.bundleID, category: "SessionHost")

    private let client: SessionHostClient
    private let terminal: PalettedTerminalView
    private var transport: (any SessionHostTransport)?
    /// The host's key of the current run.
    private(set) var key: SessionHostAttachRequest?
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
    /// The connect of the current run (tests await it).
    private(set) var connecting: Task<Void, Never>?
    /// Signals a process group (`killpg`). A seam for tests.
    var signalGroup: (pid_t, Int32) -> Void = { _ = killpg($0, $1) }

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

    init(client: SessionHostClient) {
        self.client = client
        terminal = PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.hostInput = { [weak self] bytes in self?.sendToHost(bytes) }
        terminal.hostResize = { [weak self] cols, rows in self?.resizeHost(cols: cols, rows: rows) }
    }

    var view: NSView { terminal }
    var bracketedPasteMode: Bool { terminal.getTerminal().bracketedPasteMode }

    /// Launches `launch` in the host under a fresh run token, with the
    /// environment a local session gets (`processEnvironment`) and the
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
        connect(key) { [terminal] in
            .json(.launch, SessionHostLaunchRequest(
                row: key.row, run: key.run, executable: launch.executable, args: launch.args,
                env: launch.processEnvironment, cwd: launch.currentDirectory,
                cols: terminal.getTerminal().cols, rows: terminal.getTerminal().rows
            ))
        }
    }

    /// Attaches to a run the host already holds: the view is reset, the
    /// host replays the run's recent output, then streams it live; the
    /// pane's size goes to the host once it answers.
    func attach(_ info: SessionHostSessionInfo) {
        terminal.getTerminal().resetToInitialState()
        pid = pid_t(info.pid)
        let key = SessionHostAttachRequest(row: info.row, run: info.run)
        connect(key) { .json(.attach, key) }
    }

    /// Drops the view from its host. A run still going keeps its connection
    /// so its exit is still forgotten in the host.
    func detach() {
        terminal.removeFromSuperview()
        if !exited, !bound { hangUpOnBind = true }
    }

    /// Lets go of the run without stopping it (an update's quit): the
    /// connection closes, the host keeps the process, and no exit is
    /// reported.
    func detachFromHost() {
        onExit = nil
        exited = true
        closeTransport()
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

    // MARK: Host connection

    private func connect(_ key: SessionHostAttachRequest, request: @escaping () -> SessionHostFrame) {
        closeTransport()
        self.key = key
        exited = false
        hangUpOnBind = false
        let transport = client.makeSessionTransport()
        self.transport = transport
        connecting = Task { [weak self, client] in
            let running = await client.ensureRunning()
            guard let self, self.transport === transport else { return }
            guard running else {
                runLost(transport, reason: "the session host is not running")
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
            transport.send(.json(.hello, SessionHostHello(version: SessionHostHello.protocolVersion)))
            transport.send(request())
            requested = true
        }
    }

    private func received(_ frame: SessionHostFrame, on transport: any SessionHostTransport) {
        guard self.transport === transport, !exited else { return }
        switch frame.type {
        case .launched, .attached:
            guard let info = try? frame.decoded(SessionHostSessionInfo.self) else { return }
            pid = pid_t(info.pid)
            bound = true
            if hangUpOnBind, pid > 0 {
                hangUpOnBind = false
                signalGroup(pid, SIGHUP)
            }
            // The host nudges the child to redraw at the pane's size.
            if frame.type == .attached, !info.exited { terminal.reportHostSize() }
        case .output:
            terminal.feed(byteArray: frame.payload[...])
        case .exit:
            let code = (try? frame.decoded(SessionHostExit.self))?.code
            finishRun(code: code.map { Int32(clamping: $0) }, forget: true)
        case .error:
            let message = (try? frame.decoded(SessionHostErrorMessage.self).message) ?? "unreadable error"
            Self.logger.error("session host: \(message, privacy: .public)")
            // Before the host took the run, an error is the launch or
            // attach failing: the run is over.
            if !bound {
                terminal.feed(text: "\r\n[Watchtower] \(message)\r\n")
                finishRun(code: nil, forget: false)
            }
        default:
            break // HelloOK; unknown types are skipped by the decoder
        }
    }

    /// The connection ended without an Exit: the run is reported as gone.
    private func runLost(_ transport: any SessionHostTransport, reason: String) {
        guard self.transport === transport, !exited else { return }
        Self.logger.error("hosted session lost: \(reason, privacy: .public)")
        finishRun(code: nil, forget: false)
    }

    private func finishRun(code: Int32?, forget: Bool) {
        exited = true
        closeTransport()
        onExit?(code)
        if forget, let key {
            Task { [client] in await client.forget(row: key.row, run: key.run) }
        }
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
