import AppKit
import Darwin
import Observation
import SwiftTerm
import WatchtowerCore

/// One running terminal process. The center owns it; a view only hosts `view`.
@MainActor
protocol TerminalSessionProcess: AnyObject {
    var view: NSView { get }
    /// The shell's pid, which `exec claude` keeps; 0 before start.
    var pid: pid_t { get }
    var onExit: ((Int32?) -> Void)? { get set }
    func start(_ launch: TerminalLaunch)
    /// Drops the session's view from any host once the process is gone.
    func detach()
    /// Writes bytes to the session (the owner's "Send N comments to
    /// Claude", as a bracketed paste). Main thread only.
    func sendInput(_ bytes: [UInt8])
    /// Whether the program in the terminal enabled bracketed paste (DECSET
    /// 2004), so a paste arrives as text rather than as keystrokes.
    var bracketedPasteMode: Bool { get }
}

/// Process-group signalling seam, so tests never signal a real process.
struct ProcessGroupSignaller {
    var signal: (pid_t, Int32) -> Void
    var isAlive: (pid_t) -> Bool
    var sleep: (Duration) async -> Void

    static let live = Self(
        signal: { pid, sig in _ = killpg(pid, sig) },
        isAlive: { pid in kill(pid, 0) == 0 },
        sleep: { step in try? await Task.sleep(for: step) }
    )
}

/// Embedded terminals, one process per `terminal_sessions` row (spec §2), so
/// a project can run several sessions at once. Owned by `AppState`, so a
/// process and its scrollback survive navigation (house rule); closing or
/// quitting hangs the process group up, then kills it after `killGrace` if
/// it is still alive. Nothing here writes the row — the caller does.
@MainActor
@Observable
final class TerminalCenter {
    enum State: Equatable {
        case running
        case exited(Int32?)
        case unavailable(String)
    }

    static let killGrace: Duration = .seconds(3)
    static let pollStep: Duration = .milliseconds(100)

    /// Keyed by `terminal_sessions.id`.
    private(set) var states: [Int64: State] = [:]
    /// Sessions whose last prompt went to the clipboard: the terminal pane
    /// shows the ⌘V hint until the owner dismisses it or the next delivery.
    private(set) var clipboardHints: Set<Int64> = []
    /// Session ids the owner focused, most recent last, without duplicates —
    /// fed to `TerminalSessionPolicy.activeSession`.
    private(set) var focusOrder: [Int64] = []
    @ObservationIgnored private var processes: [Int64: any TerminalSessionProcess] = [:]
    /// The row each process was started from, so a project's sessions can be
    /// found (and closed) after the project's rows are gone.
    @ObservationIgnored private var rows: [Int64: TerminalSession] = [:]
    @ObservationIgnored var makeProcess: () -> any TerminalSessionProcess
    @ObservationIgnored var shell: () -> String? = { ProcessInfo.processInfo.environment["SHELL"] }
    /// Whether Claude Code has a transcript for a session id. A seam for tests.
    @ObservationIgnored var transcriptExists: (String) -> Bool = { ClaudeTranscript.exists(sessionID: $0) }
    /// Every process exit, after `states` records it (the VM's resume-failure
    /// check). One subscriber.
    @ObservationIgnored var onSessionExit: ((Int64, Int32?) -> Void)?
    @ObservationIgnored private let signaller: ProcessGroupSignaller

    // A closure literal used as a default *argument* value does not inherit
    // this class's @MainActor isolation the way one written in a method body
    // would, so `{ SwiftTermSession() }` as a default value fails to compile
    // ("main actor-isolated initializer in a synchronous nonisolated
    // context"). Defaulting to nil and building the closure inside the
    // (MainActor) init body sidesteps that.
    init(
        makeProcess: (() -> any TerminalSessionProcess)? = nil,
        signaller: ProcessGroupSignaller = .live
    ) {
        self.makeProcess = makeProcess ?? { SwiftTermSession() }
        self.signaller = signaller
    }

    var liveIDs: Set<Int64> {
        Set(states.compactMap { $0.value == .running ? $0.key : nil })
    }

    func process(for sessionID: Int64) -> (any TerminalSessionProcess)? {
        processes[sessionID]
    }

    /// Sessions of `projectID` this center holds a process for (running or not).
    func sessionIDs(ofProject projectID: Int64) -> Set<Int64> {
        Set(rows.values.filter { $0.projectID == projectID }.map(\.id))
    }

    /// Where the project's Send comments goes: its most recently focused live
    /// `claude` session.
    func activeSession(projectID: Int64) -> TerminalSession? {
        TerminalSessionPolicy.activeSession(
            rows.values.filter { $0.projectID == projectID }, live: liveIDs, lastFocused: focusOrder
        )
    }

    func focus(_ sessionID: Int64) {
        focusOrder.removeAll { $0 == sessionID }
        focusOrder.append(sessionID)
    }

    enum PromptDelivery: Equatable {
        /// Pasted into Claude Code's input; the owner presses Return.
        case sent
        /// Bracketed paste was off: the line is on the clipboard instead.
        case copied
        /// Nothing running: the next session gets it from `project brief`.
        case noSession
    }

    /// Writes the owner's clipboard (the `.copied` delivery). A seam for tests.
    @ObservationIgnored var copyToClipboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Hands one prompt line to a running Claude Code session, NEVER
    /// followed by Enter and never as keystrokes: a bracketed paste when the
    /// session enabled that mode, otherwise the clipboard (the owner pastes
    /// with ⌘V). Typed digits or an Enter could answer a pending Claude Code
    /// permission prompt the owner has not seen. Never starts a session.
    func sendPrompt(_ line: String, sessionID: Int64) -> PromptDelivery {
        guard states[sessionID] == .running, let process = processes[sessionID] else { return .noSession }
        switch ProjectCommentPrompt.terminalPayload(line, bracketedPaste: process.bracketedPasteMode) {
        case let .paste(bytes):
            clipboardHints.remove(sessionID)
            process.sendInput(bytes)
            return .sent
        case let .clipboard(text):
            copyToClipboard(text)
            clipboardHints.insert(sessionID)
            return .copied
        }
    }

    func dismissClipboardHint(sessionID: Int64) {
        clipboardHints.remove(sessionID)
    }

    /// Starts the row's process unless it is running. A `claude` row resumes
    /// its stored Claude session (`--resume`) when Claude Code has a
    /// transcript for it; without one (the owner never typed, or the first
    /// start failed) `--resume` would be refused on every Restart, so it
    /// starts the same id anew (`--session-id`, no prompt). `fresh: true` —
    /// the row's first start, or Start fresh after the caller stored a new id
    /// — always uses `--session-id` with the optional fixed `prompt`. A
    /// `shell` row runs the login shell alone. After an exit it relaunches in
    /// the same process view (scrollback kept). A missing folder or a stored
    /// id that is not a canonical UUID (it goes into a shell command)
    /// launches nothing. Returns the mode it launched, nil when it launched
    /// nothing.
    @discardableResult
    func start(_ session: TerminalSession, fresh: Bool, prompt: String? = nil) -> TerminalLaunch.Mode? {
        let id = session.id
        if states[id] == .running { return nil }
        // Recorded before the guards, so an unavailable session is still
        // found — and cleaned up — by its project.
        rows[id] = session
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.folderPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            states[id] = .unavailable("The folder \(session.folderPath) no longer exists.")
            return nil
        }
        let mode: TerminalLaunch.Mode
        switch session.kind {
        case .shell:
            mode = .shell
        case .claude:
            guard let uuid = session.claudeSessionID, TerminalLaunch.isValidSessionID(uuid) else {
                states[id] = .unavailable("This session has no valid Claude Code session id.")
                return nil
            }
            if fresh {
                mode = .newClaude(uuid: uuid, prompt: prompt)
            } else {
                mode = transcriptExists(uuid) ? .resumeClaude(uuid: uuid) : .newClaude(uuid: uuid, prompt: nil)
            }
        }
        let process = processes[id] ?? makeProcess()
        process.onExit = { [weak self] code in
            self?.states[id] = .exited(code)
            self?.onSessionExit?(id, code)
        }
        processes[id] = process
        states[id] = .running
        process.start(.make(shell: shell(), folder: session.folderPath, mode: mode))
        return mode
    }

    func close(sessionID: Int64) async {
        guard let process = processes.removeValue(forKey: sessionID) else {
            forget(sessionID)
            return
        }
        let pid = process.pid
        if pid > 0, states[sessionID] == .running {
            signaller.signal(pid, SIGHUP)
            var waited: Duration = .zero
            while waited < Self.killGrace, isRunning(sessionID, pid) {
                await signaller.sleep(Self.pollStep)
                waited += Self.pollStep
            }
            if isRunning(sessionID, pid) { signaller.signal(pid, SIGKILL) }
        }
        process.onExit = nil
        process.detach()
        forget(sessionID)
    }

    /// Closes every matching session at once, so the wait is one grace, not
    /// N — the quit path (all) and project delete (that project's ids).
    func closeAll(where predicate: (Int64) -> Bool = { _ in true }) async {
        let ids = Set(processes.keys).union(states.keys).filter(predicate)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { @MainActor in await self.close(sessionID: id) }
            }
        }
    }

    private func forget(_ sessionID: Int64) {
        states[sessionID] = nil
        rows[sessionID] = nil
        clipboardHints.remove(sessionID)
        focusOrder.removeAll { $0 == sessionID }
    }

    private func isRunning(_ sessionID: Int64, _ pid: pid_t) -> Bool {
        states[sessionID] == .running && signaller.isAlive(pid)
    }
}

/// The real session: a SwiftTerm `LocalProcessTerminalView` running the
/// launch in a pty. Keystrokes, copy/paste and resize are SwiftTerm's own
/// (no Accessibility, no event monitors — no TCC prompt).
@MainActor
final class SwiftTermSession: NSObject, TerminalSessionProcess, LocalProcessTerminalViewDelegate {
    private let terminal: LocalProcessTerminalView
    var onExit: ((Int32?) -> Void)?

    override init() {
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        terminal.processDelegate = self
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    var view: NSView { terminal }
    var pid: pid_t { terminal.process?.shellPid ?? 0 }

    func start(_ launch: TerminalLaunch) {
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("SHELL=\(launch.executable)")
        terminal.startProcess(
            executable: launch.executable,
            args: launch.args,
            environment: environment,
            execName: nil,
            currentDirectory: launch.currentDirectory
        )
    }

    func detach() {
        terminal.removeFromSuperview()
    }

    /// SwiftTerm's own input path (`TerminalView.send(data:)` →
    /// `LocalProcess.send`), on the main actor as it requires.
    func sendInput(_ bytes: [UInt8]) {
        terminal.send(data: bytes[...])
    }

    var bracketedPasteMode: Bool { terminal.getTerminal().bracketedPasteMode }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        // LocalProcess delivers on the main queue (its default dispatch queue).
        MainActor.assumeIsolated { onExit?(exitCode) }
    }
}
