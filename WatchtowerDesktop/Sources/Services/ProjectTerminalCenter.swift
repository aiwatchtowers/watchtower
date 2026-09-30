import AppKit
import Darwin
import Observation
import SwiftTerm
import WatchtowerCore

/// One running terminal. The center owns it; a view only hosts `view`.
@MainActor
protocol ProjectTerminalSession: AnyObject {
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

/// Embedded Claude Code terminals, one per project (spec §6.2). Owned by
/// `AppState`, so a session — process and scrollback — survives navigation
/// (house rule); closing or quitting hangs the process group up, then kills
/// it after `killGrace` if it is still alive.
@MainActor
@Observable
final class ProjectTerminalCenter {
    enum State: Equatable {
        case running
        case exited(Int32?)
        case unavailable(String)
    }

    static let killGrace: Duration = .seconds(3)
    static let pollStep: Duration = .milliseconds(100)

    private(set) var states: [Int64: State] = [:]
    /// Projects whose last prompt went to the clipboard: the Terminal pane
    /// shows the ⌘V hint until the owner dismisses it or the next delivery.
    private(set) var clipboardHints: Set<Int64> = []
    @ObservationIgnored private var sessions: [Int64: any ProjectTerminalSession] = [:]
    @ObservationIgnored var makeSession: () -> any ProjectTerminalSession
    @ObservationIgnored var shell: () -> String? = { ProcessInfo.processInfo.environment["SHELL"] }
    @ObservationIgnored private let signaller: ProcessGroupSignaller

    // A closure literal used as a default *argument* value does not inherit
    // this class's @MainActor isolation the way one written in a method body
    // would, so `{ SwiftTermSession() }` as a default value fails to compile
    // ("main actor-isolated initializer in a synchronous nonisolated
    // context"). Defaulting to nil and building the closure inside the
    // (MainActor) init body sidesteps that.
    init(
        makeSession: (() -> any ProjectTerminalSession)? = nil,
        signaller: ProcessGroupSignaller = .live
    ) {
        self.makeSession = makeSession ?? { SwiftTermSession() }
        self.signaller = signaller
    }

    func session(for projectID: Int64) -> (any ProjectTerminalSession)? {
        sessions[projectID]
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

    /// Hands one prompt line to the project's running Claude Code session,
    /// NEVER followed by Enter and never as keystrokes: a bracketed paste when
    /// the session enabled that mode, otherwise the clipboard (the owner
    /// pastes with ⌘V). Typed digits or an Enter could answer a pending Claude
    /// Code permission prompt the owner has not seen. Never starts a session.
    func sendPrompt(_ line: String, projectID: Int64) -> PromptDelivery {
        guard states[projectID] == .running, let session = sessions[projectID] else { return .noSession }
        switch ProjectCommentPrompt.terminalPayload(line, bracketedPaste: session.bracketedPasteMode) {
        case let .paste(bytes):
            clipboardHints.remove(projectID)
            session.sendInput(bytes)
            return .sent
        case let .clipboard(text):
            copyToClipboard(text)
            clipboardHints.insert(projectID)
            return .copied
        }
    }

    func dismissClipboardHint(projectID: Int64) {
        clipboardHints.remove(projectID)
    }

    /// Starts `claude` in the project folder unless it is already running.
    /// After an exit it relaunches in the same session (scrollback kept).
    func start(project: Project, firstRun: Bool = false) {
        if states[project.id] == .running { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.folderPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            states[project.id] = .unavailable("The folder \(project.folderPath) no longer exists.")
            return
        }
        let session = sessions[project.id] ?? makeSession()
        let projectID = project.id
        session.onExit = { [weak self] code in
            self?.states[projectID] = .exited(code)
        }
        sessions[projectID] = session
        states[projectID] = .running
        // Temporary: Task 6 rewrites the center around persisted sessions.
        let uuid = UUID().uuidString.lowercased()
        session.start(.make(shell: shell(), folder: project.folderPath,
                            mode: .newClaude(uuid: uuid, prompt: firstRun ? TerminalLaunch.firstRunPrompt : nil)))
    }

    func close(projectID: Int64) async {
        guard let session = sessions.removeValue(forKey: projectID) else {
            states[projectID] = nil
            return
        }
        let pid = session.pid
        if pid > 0, states[projectID] == .running {
            signaller.signal(pid, SIGHUP)
            var waited: Duration = .zero
            while waited < Self.killGrace, isRunning(projectID, pid) {
                await signaller.sleep(Self.pollStep)
                waited += Self.pollStep
            }
            if isRunning(projectID, pid) { signaller.signal(pid, SIGKILL) }
        }
        session.onExit = nil
        session.detach()
        states[projectID] = nil
        clipboardHints.remove(projectID)
    }

    /// Quit path: every terminal at once, so the wait is one grace, not N.
    func closeAll() async {
        let ids = Array(sessions.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { @MainActor in await self.close(projectID: id) }
            }
        }
    }

    private func isRunning(_ projectID: Int64, _ pid: pid_t) -> Bool {
        states[projectID] == .running && signaller.isAlive(pid)
    }
}

/// The real session: a SwiftTerm `LocalProcessTerminalView` running the
/// launch in a pty. Keystrokes, copy/paste and resize are SwiftTerm's own
/// (no Accessibility, no event monitors — no TCC prompt).
@MainActor
final class SwiftTermSession: NSObject, ProjectTerminalSession, LocalProcessTerminalViewDelegate {
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
