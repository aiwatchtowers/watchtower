import AppKit
import SwiftTerm
import SwiftUI

/// The Goals step's embedded sign-in (or update) terminal: one command in a
/// PTY, in the onboarding window. Not a Workbench session — no session
/// host, nothing stored.
///
/// The process group: SwiftTerm starts the shell with `forkpty`, whose
/// child runs `login_tty` → `setsid`, so the shell leads a new session and
/// a new process group whose id is its pid. A non-interactive `zsh -c`
/// runs without job control, so everything the command spawns (an update's
/// `npm`/`brew` children, a background job) stays in that group, and
/// `stop()` reaches all of it with one `killpg`.
@MainActor
final class OnboardingSignInSession {
    private let environment: [String: String]
    private let onExit: (Int32) -> Void
    private let shell: String
    private let terminal: PalettedTerminalView
    /// The delegate SwiftTerm holds weakly.
    private var delegateBox: ProcessDelegate?
    /// The running shell's pid (= its process group id), 0 when none.
    /// `nonisolated(unsafe)`: touched on the main actor and by deinit,
    /// which runs when nothing else holds the session.
    nonisolated(unsafe) private var pid: pid_t = 0
    /// Bumped by every start and stop: an exit that belongs to an older
    /// run (or to a stopped one) is dropped, so `onExit` fires once per start.
    private var generation = 0

    /// `shell` is a test seam; the app always runs the login zsh.
    init(environment: [String: String], onExit: @escaping (Int32) -> Void, shell: String = "/bin/zsh") {
        self.environment = environment
        self.onExit = onExit
        self.shell = shell
        terminal = PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 200))
        let box = ProcessDelegate(session: self)
        delegateBox = box
        terminal.processDelegate = box
    }

    deinit {
        Self.killGroup(pid)
    }

    var view: LocalProcessTerminalView { terminal }

    var isRunning: Bool { pid != 0 }

    /// Runs `<shell> -lc <command>` in the terminal. A run already going is
    /// stopped first (its `onExit` is not called). A start that cannot fork
    /// reports `onExit(127)`, as a shell that cannot exec does.
    func start(command: String) {
        if isRunning { stop() }
        generation += 1
        let run = generation
        var env = environment
        if env["TERM"] == nil { env["TERM"] = "xterm-256color" }
        terminal.startProcess(
            executable: shell,
            args: ["-lc", command],
            environment: env.map { "\($0.key)=\($0.value)" }
        )
        guard terminal.process.running, terminal.process.shellPid > 0 else {
            Task { @MainActor [weak self] in self?.finish(run: run, code: 127) }
            return
        }
        pid = terminal.process.shellPid
    }

    /// SIGTERM to the whole group, SIGKILL to what is left a second later;
    /// the shell is reaped off the main actor. `onExit` is not called.
    func stop() {
        guard isRunning else { return }
        generation += 1
        let group = pid
        pid = 0
        // Cancels SwiftTerm's exit monitor and closes the PTY; its own
        // SIGTERM reaches the shell only, ours reaches the group.
        terminal.terminate()
        Self.killGroup(group)
    }

    nonisolated private static func killGroup(_ group: pid_t) {
        guard group > 0 else { return }
        _ = killpg(group, SIGTERM)
        DispatchQueue.global().async {
            var status: Int32 = 0
            _ = waitpid(group, &status, 0)
        }
        // A group id is not reused while the group has members, and pids do
        // not wrap within a second: this reaches stragglers or no one.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            _ = killpg(group, SIGKILL)
        }
    }

    /// SwiftTerm's exit event. Its own `waitpid(WNOHANG)` can run before the
    /// child is reapable and then hands over a 0; a second look tells.
    fileprivate func processTerminated(rawStatus: Int32?) {
        guard isRunning else { return }
        let run = generation
        let shellPid = pid
        pid = 0
        var status: Int32 = 0
        switch waitpid(shellPid, &status, WNOHANG) {
        case shellPid:
            finish(run: run, code: Self.exitCode(status))
        case 0:
            DispatchQueue.global().async {
                var late: Int32 = 0
                let reaped = waitpid(shellPid, &late, 0) == shellPid
                Task { @MainActor [weak self] in
                    self?.finish(run: run, code: reaped ? Self.exitCode(late) : 1)
                }
            }
        default:
            // SwiftTerm reaped it; nil = an I/O error, not an exit.
            finish(run: run, code: rawStatus.map(Self.exitCode) ?? 1)
        }
    }

    private func finish(run: Int, code: Int32) {
        guard run == generation else { return }
        generation += 1
        onExit(code)
    }

    /// A wait status as the shell reports it: the exit code, or 128 + the
    /// signal for a killed process.
    nonisolated static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}

/// SwiftTerm's process delegate (held weakly by the view).
private final class ProcessDelegate: LocalProcessTerminalViewDelegate {
    private weak var session: OnboardingSignInSession?

    init(session: OnboardingSignInSession) {
        self.session = session
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    // SwiftTerm's local process reports on the main queue.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated { session?.processTerminated(rawStatus: exitCode) }
    }
}

/// The session's terminal view in SwiftUI.
struct OnboardingSignInTerminal: NSViewRepresentable {
    let session: OnboardingSignInSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
