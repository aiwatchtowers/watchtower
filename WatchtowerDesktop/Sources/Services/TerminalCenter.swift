import AppKit
import Darwin
import Observation
import SwiftTerm
import SwiftUI
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
    /// The owner's own input reached the session (a keystroke, a paste),
    /// with its bytes — never `sendInput` or the terminal's replies (focus
    /// and mouse reports). Main thread.
    var onOwnerInput: (([UInt8]) -> Void)? { get set }
    /// The owner clicked into the terminal (the click that gives it the
    /// keyboard, or any later one). Main thread.
    var onOwnerFocus: (() -> Void)? { get set }
    /// ⌘-click on `path:line(:col)` resolving inside `folder` calls `open`
    /// instead of SwiftTerm's default handler (spec 2026-10-02 §9.5).
    /// `folder` is asked at each click: the session's root may move to a
    /// worktree and back (board #565).
    func setPathLinkHandler(folder: @escaping () -> String, open: @escaping (TerminalPathLinks.Location) -> Void)
    /// `ask #N` in the output (board #500): hovering one shows a card of the
    /// ask `lookUp` finds for it in the session's workbench, and a click on
    /// it calls `open`. A number `lookUp` finds nothing for is no link.
    func setAskLinkHandler(lookUp: @escaping (Int64) async -> OwnerAsk?, open: @escaping (Int64) -> Void)
    /// Whether the session host runs the process, so it outlives the app
    /// (board #496); a local process dies when the app quits.
    var isHosted: Bool { get }
}

extension TerminalSessionProcess {
    var isHosted: Bool { false }

    var onOwnerFocus: (() -> Void)? {
        get { nil }
        set {} // swiftlint:disable:this unused_setter_value
    }

    func setPathLinkHandler(folder: @escaping () -> String, open: @escaping (TerminalPathLinks.Location) -> Void) {}
    func setAskLinkHandler(lookUp: @escaping (Int64) async -> OwnerAsk?, open: @escaping (Int64) -> Void) {}
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
    /// Sessions holding a hand-off pasted but not submitted (ruling R52):
    /// the terminal pane says to press Return until the owner dismisses it
    /// or the next delivery.
    private(set) var pasteHints: Set<Int64> = []
    /// Sessions holding an ask's answer not sent yet (board #364): typed but
    /// not submitted, copied, or held behind a permission prompt (board
    /// #379). The pane says so prominently — over `clipboardHints` — until
    /// the owner's next input in that session (a copied one's first input,
    /// the paste, turns it into "press Return"; a held one stays, the input
    /// answers the prompt; input into a permission dialog changes none),
    /// Dismiss, the next delivery or the process's exit.
    private(set) var answerHints: [Int64: AnswerHint] = [:]
    /// Sessions whose Claude Code prompt holds text not submitted (board
    /// #379): the owner typed since their last submitting Return, or
    /// `submitPrompt` left a line pasted without its Return. A Return now
    /// would submit that text with ours, so `submitPrompt` only pastes.
    /// Input while `inputAnswersDialog` holds goes to Claude Code's
    /// permission dialog, not to its prompt, and changes nothing.
    @ObservationIgnored private(set) var promptDrafts: Set<Int64> = []
    /// Sessions whose prompt holds a line `submitPrompt` left without its
    /// Return next to other text not submitted — an ask's answer left
    /// typed, the owner's draft, another hand-off, there before the paste
    /// or added during its pause (board #380). The pane's "press Return"
    /// bar says the Return sends them together. Cleared with `promptDrafts`.
    private(set) var sharedPrompts: Set<Int64> = []
    /// Process runs (`runs`) where a `submitPrompt` pasted its line and
    /// waits out the pause before its Return (board #380): that line is in
    /// the prompt not submitted yet, so another delivery meanwhile — a
    /// hand-off during an answer's pause, or the reverse — only pastes, as
    /// over a draft. Keyed by run, so a relaunch during the pause starts
    /// with an empty prompt (board #387).
    @ObservationIgnored private var pendingReturns: Set<Int> = []
    /// The `pendingReturns` runs where the owner's own submitting Return
    /// came during the pause (board #388): it sent the line, so ours would
    /// only reach an empty prompt.
    @ObservationIgnored private var ownerReturnsInPause: Set<Int> = []
    /// Sessions whose owner's last printable prompt input was `\`, with
    /// only escape sequences or paste brackets since: a Return there inserts
    /// a line break in Claude Code, it does not submit.
    @ObservationIgnored private var ownerBackslashPending: Set<Int64> = []
    /// Whether the session's agent shows a permission dialog right now (its
    /// agent status is `needsApproval`). Set by `WorkbenchesViewModel`.
    @ObservationIgnored var inputAnswersDialog: (_ sessionID: Int64) -> Bool = { _ in false }
    /// Session ids the owner focused, most recent last, without duplicates —
    /// fed to `TerminalSessionPolicy.activeSession`.
    private(set) var focusOrder: [Int64] = []
    /// The latest keyboard focus move asked into a session's terminal
    /// (`requestKeyboardFocus`); its host honours each serial once.
    private(set) var keyboardFocusRequest: KeyboardFocusRequest?
    /// Sessions whose terminal, attached before the stamp passes, leaves
    /// the keyboard where it is (`keepKeyboardOnAttach`, board #412).
    @ObservationIgnored private var keepKeyboardUntil: [Int64: Date] = [:]
    /// How long `keepKeyboardOnAttach` waits for the attach it covers: an
    /// attach it never sees (the session did not come on screen) must not
    /// keep the keyboard from a later one the owner asked for.
    static let keepKeyboardWindow: TimeInterval = 2
    /// When the current process run of each session started — the session
    /// agent state's trust rule (board #312): a hook state stamped before it
    /// belongs to an earlier run. Replaced on every relaunch.
    @ObservationIgnored private(set) var startedAt: [Int64: Date] = [:]
    /// Each session's current process run, a number never handed out twice
    /// (board #387): `start()` relaunches in the same process object, so
    /// only this tells a pause's run from a relaunch that began during it.
    /// Replaced on every relaunch, gone with the session.
    @ObservationIgnored private(set) var runs: [Int64: Int] = [:]
    @ObservationIgnored private var lastRun = 0
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var processes: [Int64: any TerminalSessionProcess] = [:]
    /// The row each process was started from, so a project's sessions can be
    /// found (and closed) after the project's rows are gone.
    @ObservationIgnored private var rows: [Int64: TerminalSession] = [:]
    /// Builds each session's process. By default a `HostedTerminalSession`
    /// while `sessionHost` is set, else `makeLocalProcess`.
    @ObservationIgnored var makeProcess: () -> any TerminalSessionProcess
    /// The local fallback process (`SwiftTermSession`). A seam for tests.
    @ObservationIgnored var makeLocalProcess: () -> any TerminalSessionProcess
    /// The session host new sessions launch in (board #496); nil while no
    /// host is available — they then run locally and stop with the app.
    @ObservationIgnored var sessionHost: SessionHostClient?
    /// The current workspace's session host scope
    /// (`SessionHostPaths.scope`): hosted launches carry it, and a reattach
    /// touches only runs of it ("" from an older host counts as it).
    @ObservationIgnored var sessionHostScope = ""
    /// The one client `connectSessionHost` made, answering or not.
    @ObservationIgnored private var sessionHostClient: SessionHostClient?
    /// Sessions whose current process runs locally, not in the session
    /// host: the pane says they stop when Watchtower quits.
    private(set) var unprotected: Set<Int64> = []
    @ObservationIgnored var shell: () -> String? = { ProcessInfo.processInfo.environment["SHELL"] }
    /// Whether Claude Code has a transcript for a session id. A seam for tests.
    @ObservationIgnored var transcriptExists: (String) -> Bool = { ClaudeTranscript.exists(sessionID: $0) }
    /// Whether Codex has a rollout for a session id (`CodexRollout`), given
    /// the path its SessionStart stored; throws when Codex's sessions folder
    /// could not be listed. A seam for tests.
    @ObservationIgnored var codexRolloutExists: (_ sessionID: String, _ storedPath: String?, _ codexHome: URL?) throws -> Bool = {
        try CodexRollout.exists(sessionID: $0, storedPath: $1, codexHome: $2)
    }
    /// `watchtower workbench launch-args` for a Codex session of a workbench
    /// (`WorkbenchCLI.launchArgs`); nil when there is no CLI to ask.
    @ObservationIgnored var codexLaunchArgs: ((_ workbenchID: Int64) async throws -> CodexLaunchArgs)?
    /// Codex launches waiting for their `launch-args`, by row; a close
    /// meanwhile drops the entry, and the launch then starts nothing.
    @ObservationIgnored private var pendingLaunches: [Int64: Int] = [:]
    /// Sessions whose last launch found no binary for their agent
    /// (`launch-args` exit 3): the typed cause behind their `.unavailable`
    /// text. Gone with the next launch attempt or the session.
    @ObservationIgnored private(set) var missingAgent: [Int64: AgentKind] = [:]
    /// Every process exit, after `states` records it (the VM's resume-failure
    /// check and placed-session cleanup): session id, exit code, and whether
    /// Watchtower caused it by closing the terminal (`close`/`closeAll`,
    /// which drop the process before signalling it). One subscriber.
    @ObservationIgnored var onSessionExit: ((_ id: Int64, _ code: Int32?, _ closedByApp: Bool) -> Void)?
    /// A ⌘-clicked `path:line` in a workbench session's terminal, resolved
    /// inside its folder (`TerminalPathLinks`): workbench id, session id,
    /// location.
    @ObservationIgnored var onPathLink: ((Int64, Int64, TerminalPathLinks.Location) -> Void)?
    /// The folder a workbench session's `path:line` links resolve in — its
    /// code root (board #565: its worktree when proven): workbench id,
    /// session id. nil, or no answer, = the session's own folder.
    @ObservationIgnored var pathLinkRoot: ((Int64, Int64) -> String?)?
    /// The ask an `ask #N` in a workbench session's terminal names, when it
    /// is that workbench's (board #500): workbench id, ask id.
    @ObservationIgnored var askLinkLookUp: ((Int64, Int64) async -> OwnerAsk?)?
    /// An `ask #N` clicked there: workbench id, ask id.
    @ObservationIgnored var onAskLink: ((Int64, Int64) -> Void)?
    @ObservationIgnored private let signaller: ProcessGroupSignaller

    // A closure literal used as a default *argument* value does not inherit
    // this class's @MainActor isolation the way one written in a method body
    // would, so `{ SwiftTermSession() }` as a default value fails to compile
    // ("main actor-isolated initializer in a synchronous nonisolated
    // context"). Defaulting to nil and building the closure inside the
    // (MainActor) init body sidesteps that.
    init(
        makeProcess: (() -> any TerminalSessionProcess)? = nil,
        makeLocalProcess: (() -> any TerminalSessionProcess)? = nil,
        signaller: ProcessGroupSignaller = .live
    ) {
        self.makeLocalProcess = makeLocalProcess ?? { SwiftTermSession() }
        // A placeholder: the default factory below captures `self`, which
        // needs every stored property initialised first.
        self.makeProcess = { SwiftTermSession() }
        self.signaller = signaller
        self.makeProcess = makeProcess ?? { [weak self] in
            guard let self else { return SwiftTermSession() }
            return sessionHost.map { self.makeHosted($0) } ?? self.makeLocalProcess()
        }
    }

    /// The connection `startSessionHost` began; a reattach waits for it.
    @ObservationIgnored private(set) var sessionHostConnection: Task<Void, Never>?

    /// Begins `connectSessionHost` once per app run, so a caller that comes
    /// after it can wait for the connection (`sessionHostConnection`).
    func startSessionHost(_ makeClient: @escaping () -> SessionHostClient) {
        guard sessionHostConnection == nil else { return }
        sessionHostConnection = Task { await self.connectSessionHost(makeClient) }
    }

    private func makeHosted(_ client: SessionHostClient) -> HostedTerminalSession {
        HostedTerminalSession(client: client) { [weak self] in self?.sessionHostScope ?? "" }
    }

    /// Connects to the session host once per app run: a second call (the
    /// database wired again) reuses the first client and its connection.
    func connectSessionHost(_ makeClient: () -> SessionHostClient) async {
        guard sessionHostClient == nil else { return }
        let client = makeClient()
        sessionHostClient = client
        sessionHost = await client.ensureRunning() ? client : nil
    }

    var liveIDs: Set<Int64> {
        Set(states.compactMap { $0.value == .running ? $0.key : nil })
    }

    /// The live agent sessions (`claude` or `codex`) — the ones whose
    /// workbench hooks report a state.
    var liveAgentIDs: Set<Int64> {
        let live = liveIDs
        return Set(rows.values.filter { $0.kind.isAgent && live.contains($0.id) }.map(\.id))
    }

    /// The live agent rows of `projectID`, as they were started.
    func liveAgentRows(ofWorkbench projectID: Int64) -> [TerminalSession] {
        let live = liveAgentIDs
        return rows.values.filter { $0.projectID == projectID && live.contains($0.id) }
    }

    func process(for sessionID: Int64) -> (any TerminalSessionProcess)? {
        processes[sessionID]
    }

    /// Sessions of `projectID` this center holds a process for (running or not).
    func sessionIDs(ofWorkbench projectID: Int64) -> Set<Int64> {
        Set(rows.values.filter { $0.projectID == projectID }.map(\.id))
    }

    /// The project's active session — the one the Terminal toggle shows
    /// first: its most recently focused live agent session.
    func activeSession(projectID: Int64) -> TerminalSession? {
        TerminalSessionPolicy.activeSession(
            rows.values.filter { $0.projectID == projectID }, live: liveIDs, lastFocused: focusOrder
        )
    }

    /// Whether an agent session (Claude Code or Codex) this app runs works in
    /// the files a branch switch swaps: a live agent row of the workbench, or one (a
    /// standalone terminal, another workbench) whose folder is the
    /// repository's work tree or inside it — a workbench in a subfolder
    /// shares one checkout with the repository root and every sibling
    /// package. Symlinks are resolved on both sides (`/tmp` is
    /// `/private/tmp`). The branch switch's agent guard (#233); a `claude`
    /// in the owner's own terminal app is not seen (v1 limit).
    ///
    /// Since board #565 a row of the workbench counts by `place` (its
    /// session's place, spec §5.3): in the work tree when its folder (the
    /// main folder, or its worktree) is that work tree; anywhere — maybe
    /// here — when its place is unknown or removed, so the confirmation is
    /// skipped only for a session proven to work elsewhere. The default
    /// knows no place: every row of the workbench counts, as before.
    func hasLiveAgentSession(
        workbenchID: Int64,
        workTree: String,
        place: (Int64) -> SessionPlace = { _ in .unknown }
    ) -> Bool {
        let root = Self.resolvedPath(workTree)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let inWorkTree = { (path: String) -> Bool in
            let resolved = Self.resolvedPath(path)
            return resolved == root || resolved.hasPrefix(prefix)
        }
        let live = liveIDs
        return rows.values.contains { row in
            guard row.kind.isAgent, live.contains(row.id) else { return false }
            guard row.projectID == workbenchID else { return inWorkTree(row.folderPath) }
            return Self.placeMayBeIn(place(row.id), mainFolder: row.folderPath, root: root, inWorkTree: inWorkTree)
        }
    }

    /// Whether a workbench row whose agent works at `place` may work in the
    /// work tree `root`. A worktree is that work tree when its top level is
    /// (a worktree nested in the main folder, `.claude/worktrees/<name>`, is
    /// not the main folder's); without a known top level, when its root is
    /// inside it. The main folder is the row's folder.
    private static func placeMayBeIn(
        _ place: SessionPlace, mainFolder: String, root: String, inWorkTree: (String) -> Bool
    ) -> Bool {
        switch place {
        case .unknown, .removed:
            return true
        case .main:
            return inWorkTree(mainFolder)
        case let .worktree(_, folder, status):
            guard !status.topLevel.isEmpty else { return inWorkTree(folder.path) }
            return resolvedPath(status.topLevel) == root
        }
    }

    /// The path with symlinks resolved; a path that does not exist (any
    /// more) only standardized.
    static func resolvedPath(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let resolved = realpath(standard, nil) else { return standard }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func focus(_ sessionID: Int64) {
        // Every click reports here: an unchanged order is not reassigned,
        // so it notifies no observer.
        guard focusOrder.last != sessionID else { return }
        focusOrder.removeAll { $0 == sessionID }
        focusOrder.append(sessionID)
    }

    struct KeyboardFocusRequest: Equatable {
        let sessionID: Int64
        let serial: Int
    }

    /// Moves the keyboard into the session's terminal once its host is on
    /// screen — also when that host shows it already, where attaching
    /// changes nothing and so moves no focus (an overlay such as the go-to
    /// palette took it away).
    func requestKeyboardFocus(_ sessionID: Int64) {
        keyboardFocusRequest = KeyboardFocusRequest(sessionID: sessionID, serial: (keyboardFocusRequest?.serial ?? 0) + 1)
    }

    /// An ask switched from the keyboard (J / K in the drawer, Return on a
    /// card, board #412) puts `sessionID` on screen: its next attach leaves
    /// the keyboard where it is, so keys meant for the asks never land in
    /// the agent's input as an owner draft.
    func keepKeyboardOnAttach(_ sessionID: Int64, now: Date = Date()) {
        keepKeyboardUntil[sessionID] = now.addingTimeInterval(Self.keepKeyboardWindow)
    }

    /// Taken by the host on an attach: whether that attach leaves the
    /// keyboard alone. Once only, and only within the window.
    func takeKeepKeyboard(_ sessionID: Int64, now: Date = Date()) -> Bool {
        guard let until = keepKeyboardUntil.removeValue(forKey: sessionID) else { return false }
        return now < until
    }

    /// The latest request's serial when it is for `sessionID`.
    func keyboardFocusSerial(for sessionID: Int64) -> Int? {
        keyboardFocusRequest.flatMap { $0.sessionID == sessionID ? $0.serial : nil }
    }

    enum PromptDelivery: Equatable {
        /// Pasted into Claude Code's input, no Return (`submitPrompt`
        /// decides whether one follows).
        case sent
        /// Bracketed paste was off: the line is on the clipboard instead.
        case copied
        /// Nothing running: the next session gets it from `workbench brief`.
        case noSession
    }

    /// Writes the owner's clipboard (the `.copied` delivery). A seam for tests.
    @ObservationIgnored var copyToClipboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The paste step of `submitPrompt`: one prompt text into a running
    /// Claude Code session, never followed by Enter and never as
    /// keystrokes — a bracketed paste when the session enabled that mode,
    /// otherwise the clipboard (the owner pastes with ⌘V). Typed digits or an Enter could answer a pending Claude Code
    /// permission prompt the owner has not seen. Never starts a session.
    /// `keepingLineBreaks` keeps a multi-line text (a code question's
    /// hand-off) as several lines inside the one paste.
    func sendPrompt(
        _ line: String, sessionID: Int64, keepingLineBreaks: Bool = false, keepingFormatCharacters: Bool = false
    ) -> PromptDelivery {
        guard states[sessionID] == .running, let process = processes[sessionID] else { return .noSession }
        answerHints[sessionID] = nil
        switch WorkbenchCommentPrompt.terminalPayload(line, bracketedPaste: process.bracketedPasteMode,
                                                      keepingLineBreaks: keepingLineBreaks,
                                                      keepingFormatCharacters: keepingFormatCharacters) {
        case let .paste(bytes):
            clipboardHints.remove(sessionID)
            pasteHints.remove(sessionID)
            process.sendInput(bytes)
            return .sent
        case let .clipboard(text):
            copyToClipboard(text)
            pasteHints.remove(sessionID)
            clipboardHints.insert(sessionID)
            return .copied
        }
    }

    /// The pause between a hand-off's paste and its Return in a Claude Code
    /// session (`AgentInputProfile.pasteSettle`).
    nonisolated static let submitDelay: Duration = AgentInputProfile.claude.pasteSettle
    /// The same pause for an ask's answer (`AgentInputProfile.submitSettle`).
    nonisolated static let answerSubmitDelay: Duration = AgentInputProfile.claude.submitSettle

    /// The agent a session runs, from its row; nil for a shell or a session
    /// this center never started.
    func agent(of sessionID: Int64) -> AgentKind? {
        rows[sessionID]?.kind.agent
    }

    /// Whether the agent has a transcript for the row's stored session id:
    /// Claude Code's under `~/.claude`, Codex's rollout. No id, no transcript.
    /// A Codex lookup that failed reads as none here: a relaunch from the
    /// view model decides with `codexResumes` instead and passes the answer.
    func hasTranscript(_ session: TerminalSession) -> Bool {
        guard let id = session.claudeSessionID else { return false }
        switch session.kind {
        case .claude: return transcriptExists(id)
        case .codex: return (try? codexRolloutExists(id, session.transcriptPath, CodexRollout.home())) ?? false
        case .shell: return false
        }
    }

    /// Whether relaunching the Codex row (not fresh) resumes its stored id:
    /// a valid id whose rollout exists — at its stored path, or under
    /// `codexHome` (the login shell's, resolved by the caller; nil checks the
    /// stored path alone). Throws when Codex's sessions folder could not be
    /// listed, so the caller does not drop the id on it.
    func codexResumes(_ session: TerminalSession, codexHome: URL?) throws -> Bool {
        guard session.kind == .codex, let id = session.claudeSessionID, TerminalLaunch.isValidSessionID(id) else {
            return false
        }
        return try codexRolloutExists(id, session.transcriptPath, codexHome)
    }

    /// How lines are typed into the session (spec 2026-10-12 §8): its
    /// agent's profile; Claude Code's when it runs none.
    func inputProfile(_ sessionID: Int64) -> AgentInputProfile {
        agent(of: sessionID).map(AgentInputProfile.for) ?? .claude
    }

    /// How a hand-off reached the session.
    enum HandoffDelivery: Equatable {
        /// Pasted, then Return — ours, or the owner's own during the pause.
        case submitted
        /// Pasted; the owner presses Return (`pasteHints`).
        case pasted
        /// Bracketed paste was off: on the clipboard (`clipboardHints`).
        case copied
        case noSession
    }

    /// "Hand to Claude Code" (spec 2026-10-02 §9.5) and an ask's answer line
    /// (PROJ-12, board #379): `text` pasted (`sendPrompt`; a hand-off keeps
    /// its line breaks, an answer line passes `keepingLineBreaks: false`).
    /// A Return follows only while `canSubmit` holds and the session's
    /// prompt held no text before the paste (`promptDrafts`: the owner's
    /// half-typed text, or an earlier line left without its Return or still
    /// in its pause, `pendingReturns`) — both
    /// checked before the pause and again after it, the caller re-reading
    /// the session's agent state (ruling R52: a hand-off only into a session
    /// idle at its prompt; an answer only into a session whose hooks
    /// reported this run and show no permission prompt; a Return
    /// could answer a prompt that appeared meanwhile) — and only into the
    /// same process run (`runs`), as a write of its own (the agent's
    /// `AgentInputProfile.submit`) after `delay` (nil: the profile's
    /// `pasteSettle`): a CR read
    /// in one chunk with the paste could be taken as part of it (a line
    /// break, not Enter). `refresh` runs after the pause, before the second
    /// check (the caller re-reads the agent state, which its poll may hold
    /// up to 1 s stale) and returns whether that read succeeded: after a
    /// failed one the state is not known, so no Return. An owner's
    /// submitting Return during the pause has sent the line — unless that
    /// read failed or shows a permission dialog (`inputAnswersDialog`, asked
    /// again after it): none follows, and it counts as submitted.
    /// Otherwise the paste
    /// waits for the owner's own Return, and the session holds a draft until
    /// then; a line sharing the prompt with other text says so
    /// (`sharedPrompts`).
    func submitPrompt(
        _ text: String,
        sessionID: Int64,
        keepingLineBreaks: Bool = true,
        keepingFormatCharacters: Bool = false,
        delay: Duration? = nil,
        refresh: () async -> Bool = { true },
        submitIf canSubmit: () -> Bool
    ) async -> HandoffDelivery {
        // A running session always has its run: the line never goes
        // untracked by run.
        guard states[sessionID] == .running, let run = runs[sessionID],
              let process = processes[sessionID] else { return .noSession }
        let promptWasEmpty = !promptDrafts.contains(sessionID) && !pendingReturns.contains(run)
        // Read before the paste, which clears the bars it names.
        let heldBack = promptWasEmpty ? nil : heldBackBeforePause(sessionID, run: run)
        switch sendPrompt(text, sessionID: sessionID, keepingLineBreaks: keepingLineBreaks,
                          keepingFormatCharacters: keepingFormatCharacters) {
        case .noSession: return .noSession
        case .copied: return .copied
        case .sent: break
        }
        // The pair of `promptWasEmpty`: whether the line ends up next to
        // other text not submitted.
        var besideText = !promptWasEmpty
        if let heldBack {
            logWithheld(sessionID, heldBack)
        } else if !canSubmit() {
            logWithheld(sessionID, "the session's state, before the pause")
        } else {
            let pause = delay ?? inputProfile(sessionID).pasteSettle
            if let delivery = await returnAfterPause(process, sessionID: sessionID, run: run, delay: pause,
                                                     refresh: refresh, canSubmit: canSubmit) {
                return delivery
            }
            // An owner key or another delivery landed during the pause.
            besideText = promptDrafts.contains(sessionID)
        }
        // The line sits in the prompt unsubmitted: the next line must not
        // submit it with its own Return.
        promptDrafts.insert(sessionID)
        pasteHints.insert(sessionID)
        if besideText { sharedPrompts.insert(sessionID) }
        return .pasted
    }

    /// Whether the session's prompt holds text not submitted right now: the
    /// owner's draft, a line left without its Return, or a line in its pause
    /// before its Return — what `submitPrompt` only pastes over. The phone's
    /// lines are held instead of pasted then (PROJ-16).
    func promptHoldsText(_ sessionID: Int64) -> Bool {
        if promptDrafts.contains(sessionID) { return true }
        guard let run = runs[sessionID] else { return false }
        return pendingReturns.contains(run)
    }

    /// Why the prompt held text before the paste, for the log: a bar still
    /// asking for a Return means a line of ours is what it holds.
    private func heldBackBeforePause(_ sessionID: Int64, run: Int) -> String {
        if pendingReturns.contains(run) { return "another line waits for its Return" }
        let lineLeftTyped = pasteHints.contains(sessionID) || answerHints[sessionID] == .typed
        return lineLeftTyped ? "an earlier line left typed" : "the owner's draft"
    }

    /// `submitPrompt`'s pause, the read after it and the Return: the
    /// delivery when the line went (or its run did), nil when it stays
    /// typed.
    private func returnAfterPause(
        _ process: any TerminalSessionProcess,
        sessionID: Int64,
        run: Int,
        delay: Duration,
        refresh: () async -> Bool,
        canSubmit: () -> Bool
    ) async -> HandoffDelivery? {
        pendingReturns.insert(run)
        defer {
            pendingReturns.remove(run)
            ownerReturnsInPause.remove(run)
        }
        await signaller.sleep(delay)
        let fresh = await refresh()
        // The Return goes only into the run the line was pasted into.
        guard states[sessionID] == .running, runs[sessionID] == run else {
            logWithheld(sessionID, "the run changed during the pause")
            return .noSession
        }
        switch afterPause(sessionID, run: run, fresh: fresh, canSubmit: canSubmit) {
        case .pressReturn:
            process.sendInput(inputProfile(sessionID).submit)
            return .submitted
        case .ownerSent:
            logWithheld(sessionID, "the owner pressed Return during the pause")
            return .submitted
        case let .withheld(reason):
            logWithheld(sessionID, reason)
            return nil
        }
    }

    /// What follows a line's pause in its own run.
    private enum AfterPause {
        case pressReturn
        /// The owner's own Return sent the line.
        case ownerSent
        case withheld(String)
    }

    private func afterPause(_ sessionID: Int64, run: Int, fresh: Bool, canSubmit: () -> Bool) -> AfterPause {
        guard fresh else { return .withheld("the state read after the pause failed") }
        if ownerReturnsInPause.contains(run) {
            // `inputAnswersDialog` may have been up to a second stale when
            // that Return came, so it may have gone into a dialog shown
            // during the pause: re-asked after the read, a dialog keeps the
            // line typed (the bar may be a false one, never a Return of
            // ours). The caller's other conditions do not count — the
            // owner's Return starts a turn, and its `working` may land
            // before the read.
            return inputAnswersDialog(sessionID)
                ? .withheld("a permission prompt after the owner's Return in the pause") : .ownerSent
        }
        guard canSubmit() else { return .withheld("the session's state, after the pause") }
        guard !promptDrafts.contains(sessionID) else { return .withheld("text reached the prompt during the pause") }
        return .pressReturn
    }

    /// Why `submitPrompt` sent no Return of its own (board #396); the
    /// caller's `canSubmit` logs its own reasons.
    private func logWithheld(_ sessionID: Int64, _ reason: String) {
        NSLog("TerminalCenter: session %lld: Return withheld — %@", sessionID, reason)
    }

    func dismissClipboardHint(sessionID: Int64) {
        clipboardHints.remove(sessionID)
        pasteHints.remove(sessionID)
        answerHints[sessionID] = nil
    }

    /// The prompt holds nothing not submitted any more.
    private func clearPromptDraft(_ sessionID: Int64) {
        promptDrafts.remove(sessionID)
        sharedPrompts.remove(sessionID)
    }

    /// What the hint over a session holding an ask's answer says.
    enum AnswerHint: Equatable {
        /// Pasted, not submitted (a permission prompt appeared during the
        /// pause): press Return.
        case typed
        /// On the clipboard: paste it, then press Return.
        case copied
        /// Held while the agent waits on a permission prompt; it goes once
        /// the prompt is answered.
        case held
        /// Held so long (`OwnerAsksViewModel.stillHeldAfter`) with no change
        /// that the pane says it still waits and that Dismiss leaves it for
        /// the session's brief.
        case stillHeld
        /// Held while another answer is going to the same session; it goes
        /// right after that one.
        case queued

        /// Waiting for its delivery: the owner's input keeps it, and its
        /// Dismiss cancels the delivery.
        var isHeld: Bool {
            switch self {
            case .held, .stillHeld, .queued: true
            case .typed, .copied: false
            }
        }
    }

    /// An ask's answer line is waiting in or for a running session: its pane
    /// shows `hint` in place of the clipboard one. Never types anything.
    func showAnswerHint(_ hint: AnswerHint, sessionID: Int64) {
        guard states[sessionID] == .running else { return }
        clipboardHints.remove(sessionID)
        pasteHints.remove(sessionID)
        answerHints[sessionID] = hint
    }

    /// The owner typed or pasted into the session. Input that answers a
    /// permission dialog changes nothing: the prompt still holds what it
    /// held. Otherwise a submitting Return (`isSubmit`) empties the prompt
    /// (`promptDrafts`) and any other input leaves a draft in it. A copied
    /// answer's hint turns into "press Return" (the paste was the first
    /// step); a typed one has done its job; a held one waits for its
    /// delivery.
    private func ownerInput(_ sessionID: Int64, _ bytes: [UInt8]) {
        guard !bytes.isEmpty, !inputAnswersDialog(sessionID) else { return }
        let backslashBefore = ownerBackslashPending.contains(sessionID)
        if Self.isSubmit(bytes, backslashBefore: backslashBefore, profile: inputProfile(sessionID)) {
            clearPromptDraft(sessionID)
            if let run = runs[sessionID], pendingReturns.contains(run) { ownerReturnsInPause.insert(run) }
        } else {
            promptDrafts.insert(sessionID)
        }
        if Self.endsAfterBackslash(bytes, backslashBefore: backslashBefore) {
            ownerBackslashPending.insert(sessionID)
        } else {
            ownerBackslashPending.remove(sessionID)
        }
        switch answerHints[sessionID] {
        case nil, .held?, .stillHeld?, .queued?: break
        case .copied?: answerHints[sessionID] = .typed
        case .typed?: answerHints[sessionID] = nil
        }
    }

    /// Whether the owner's input submits the agent's prompt: it ends in the
    /// profile's `submit` (a plain Return, CR) that does not follow ESC
    /// (Option+Return), does not end in the profile's `newline`, and whose
    /// last printable input before it — in this chunk or earlier ones
    /// (`backslashBefore`), escape sequences such as cursor keys and paste
    /// brackets skipped — is not `\` (`\` then Return is a line break).
    /// Anything else is a draft: Ctrl+J (LF), Shift+Return under an extended
    /// keyboard protocol (an escape sequence ending in `u` or `~`), any
    /// other key. When unsure the input counts as a draft, which costs the
    /// owner a Return of their own, never a line submitted with theirs —
    /// so the `\` rule holds for every agent, Codex too.
    static func isSubmit(_ bytes: [UInt8], backslashBefore: Bool, profile: AgentInputProfile = .claude) -> Bool {
        if let newline = profile.newline, endsIn(bytes, newline) { return false }
        guard endsIn(bytes, profile.submit) else { return false }
        let body = bytes.dropLast(profile.submit.count)
        if body.last == 0x1B { return false }
        return !endsAfterBackslash(body, backslashBefore: backslashBefore)
    }

    /// Whether `bytes` ends in the non-empty key sequence `key`.
    private static func endsIn(_ bytes: [UInt8], _ key: [UInt8]) -> Bool {
        !key.isEmpty && bytes.suffix(key.count).elementsEqual(key)
    }

    /// Whether, after `bytes`, the last printable input is `\` with only
    /// escape sequences (CSI `ESC [ … final`, SS3 `ESC O x`, `ESC x`) since —
    /// paste brackets are CSI sequences too. A CR or LF ends the line and
    /// clears it; any other byte keeps it as it was (fail safe: a draft).
    static func endsAfterBackslash<Bytes: Collection>(_ bytes: Bytes, backslashBefore: Bool) -> Bool
        where Bytes.Element == UInt8 {
        var pending = backslashBefore
        var index = bytes.startIndex
        while index != bytes.endIndex {
            let byte = bytes[index]
            index = bytes.index(after: index)
            switch byte {
            case 0x1B:
                index = escapeSequenceEnd(in: bytes, after: index)
            case 0x0D, 0x0A:
                pending = false
            case 0x20...0x7E, 0x80...:
                pending = byte == UInt8(ascii: "\\")
            default:
                break
            }
        }
        return pending
    }

    /// The index just past the escape sequence whose ESC came before
    /// `start`.
    private static func escapeSequenceEnd<Bytes: Collection>(in bytes: Bytes, after start: Bytes.Index) -> Bytes.Index
        where Bytes.Element == UInt8 {
        guard start != bytes.endIndex else { return start }
        var index = bytes.index(after: start)
        switch bytes[start] {
        case UInt8(ascii: "["):
            // Parameters and intermediates, then one final byte 0x40–0x7E.
            while index != bytes.endIndex, !(0x40...0x7E).contains(bytes[index]) {
                index = bytes.index(after: index)
            }
            return index == bytes.endIndex ? index : bytes.index(after: index)
        case UInt8(ascii: "O"):
            return index == bytes.endIndex ? index : bytes.index(after: index)
        default:
            return index
        }
    }

    /// `start`, first asking `launch-args` for a `codex` row (spec
    /// 2026-10-12 §4.2, §7); any other row starts at once. A Codex launch
    /// needs a workbench (its MCP server and hooks are the workbench's). No
    /// `codex` found, or a failed call, launches nothing and says why in
    /// the pane (`.unavailable`). A second call while one waits, or a close
    /// meanwhile, launches nothing. Returns the mode it launched.
    @discardableResult
    func launch(
        _ session: TerminalSession,
        fresh: Bool,
        prompt: String? = nil,
        codexResume: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        setup: String? = nil
    ) async -> TerminalLaunch.Mode? {
        guard session.kind == .codex else { return start(session, fresh: fresh, prompt: prompt, setup: setup) }
        let id = session.id
        guard states[id] != .running, pendingLaunches[id] == nil else { return nil }
        rows[id] = session
        missingAgent[id] = nil
        guard let workbenchID = session.projectID else {
            states[id] = .unavailable("Codex sessions run in a workbench.")
            return nil
        }
        guard let codexLaunchArgs else {
            states[id] = .unavailable("Codex cannot be launched: the watchtower CLI is not available.")
            return nil
        }
        lastRun += 1
        let token = lastRun
        pendingLaunches[id] = token
        let args: CodexLaunchArgs
        do {
            args = try await codexLaunchArgs(workbenchID)
        } catch {
            guard pendingLaunches[id] == token else { return nil }
            pendingLaunches[id] = nil
            if case let .agentNotFound(agent)? = error as? WorkbenchCLIError { missingAgent[id] = agent }
            states[id] = .unavailable(error is WorkbenchCLIError ? error.localizedDescription
                : "Could not prepare the Codex launch: \(error.localizedDescription)")
            return nil
        }
        guard pendingLaunches[id] == token else { return nil }
        pendingLaunches[id] = nil
        return start(session, fresh: fresh, prompt: prompt, codex: args, codexResume: codexResume, setup: setup)
    }

    /// Shows `session` as `.unavailable(reason)` without launching it: a
    /// refusal made before the launch (a worktree that could not return).
    func refuseLaunch(_ session: TerminalSession, reason: String) {
        if states[session.id] == .running { return }
        rows[session.id] = session
        states[session.id] = .unavailable(reason)
    }

    /// Starts the row's process unless it is running. A `claude` row resumes
    /// its stored Claude session (`--resume`) when Claude Code has a
    /// transcript for it; without one (the owner never typed, or the first
    /// start failed) `--resume` would be refused on every Restart, so it
    /// starts the same id anew (`--session-id`, no prompt). `fresh: true` —
    /// the row's first start, or Start fresh after the caller stored a new id
    /// — always uses `--session-id` with the optional fixed `prompt`; either
    /// way the process gets the row id (`TerminalLaunch.sessionRowEnv`), so
    /// the project hook can store the id `/clear` moves Claude Code to. A
    /// `codex` row runs `codex` as `launch` resolved it (`codex`): it resumes
    /// a stored id whose rollout exists, and otherwise starts a new Codex
    /// session (`newAgent` with no id; the caller drops the stored id first). A
    /// `shell` row runs the login shell alone. After an exit it relaunches in
    /// the same process view (scrollback kept). A missing folder or a stored
    /// Claude id that is not a canonical UUID (it goes into a shell command)
    /// launches nothing. Returns the mode it launched, nil when it launched
    /// nothing.
    @discardableResult
    func start(
        _ session: TerminalSession,
        fresh: Bool,
        prompt: String? = nil,
        codex: CodexLaunchArgs? = nil,
        codexResume: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        setup: String? = nil
    ) -> TerminalLaunch.Mode? {
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
        guard let mode = mode(for: session, fresh: fresh, prompt: prompt, codexResume: codexResume) else { return nil }
        if mode.agent == .codex, codex == nil {
            states[id] = .unavailable("Codex cannot be launched without its launch arguments.")
            return nil
        }
        run(session, mode: mode, codex: codex, setup: setup)
        return mode
    }

    /// The launch `start` makes for the row; nil (the row `.unavailable`)
    /// for a `claude` row without a valid id. A Codex row resumes as
    /// `codexResume` says when the caller decided it (`codexResumes`, one
    /// walk of the rollout tree); else it looks for the rollout here.
    private func mode(
        for session: TerminalSession, fresh: Bool, prompt: String?, codexResume: Bool? // swiftlint:disable:this discouraged_optional_boolean
    ) -> TerminalLaunch.Mode? {
        switch session.kind {
        case .shell:
            return .shell
        case .claude:
            guard let uuid = session.claudeSessionID, TerminalLaunch.isValidSessionID(uuid) else {
                states[session.id] = .unavailable("This session has no valid Claude Code session id.")
                return nil
            }
            if fresh { return .newClaude(uuid: uuid, prompt: prompt) }
            return hasTranscript(session) ? .resumeClaude(uuid: uuid) : .newClaude(uuid: uuid, prompt: nil)
        case .codex:
            if !fresh, let id = session.claudeSessionID, TerminalLaunch.isValidSessionID(id),
               codexResume ?? hasTranscript(session) {
                return .resumeAgent(.codex, sessionID: id)
            }
            return .newAgent(.codex, sessionID: nil, prompt: fresh ? prompt : nil)
        }
    }

    private func run(_ session: TerminalSession, mode: TerminalLaunch.Mode, codex: CodexLaunchArgs?, setup: String?) {
        let process = processes[session.id] ?? makeProcess()
        wire(process, session: session, startedAt: now())
        process.start(.make(shell: shell(), folder: session.folderPath, mode: mode, rowID: session.id, codex: codex, setup: setup))
    }

    /// Registers `process` as the row's current run, `.running` from
    /// `startedAt`: exit, owner input and focus, links, and a fresh run's
    /// prompt state. The caller then starts or attaches it.
    private func wire(_ process: any TerminalSessionProcess, session: TerminalSession, startedAt started: Date) {
        let id = session.id
        rows[id] = session
        process.onExit = { [weak self, weak process] code in
            guard let self else { return }
            let closedByApp = process.map { self.processes[id] !== $0 } ?? true
            states[id] = .exited(code)
            answerHints[id] = nil
            onSessionExit?(id, code, closedByApp)
        }
        process.onOwnerInput = { [weak self] bytes in self?.ownerInput(id, bytes) }
        // A click into one terminal of a split makes it the active session.
        process.onOwnerFocus = { [weak self] in self?.focus(id) }
        processes[id] = process
        if process.isHosted { unprotected.remove(id) } else { unprotected.insert(id) }
        if let workbenchID = session.projectID {
            // ⌘-click on `path:line` in a workbench session opens Files;
            // the path resolves in the session's code root (board #565).
            let folder = session.folderPath
            process.setPathLinkHandler(
                folder: { [weak self] in self?.pathLinkRoot?(workbenchID, id) ?? folder },
                open: { [weak self] location in self?.onPathLink?(workbenchID, id, location) }
            )
            // `ask #N` links to that ask of this workbench (board #500).
            process.setAskLinkHandler(
                lookUp: { [weak self] askID in await self?.askLinkLookUp?(workbenchID, askID) },
                open: { [weak self] askID in self?.onAskLink?(workbenchID, askID) }
            )
        }
        startedAt[id] = started
        lastRun += 1
        runs[id] = lastRun
        // A new run starts with an empty prompt: no line of the last run
        // waits for a Return there (board #389).
        clearPromptDraft(id)
        pasteHints.remove(id)
        ownerBackslashPending.remove(id)
        states[id] = .running
    }

    // MARK: Reattach at launch (board #496)

    /// Takes over a run the session host still holds for `session` — one
    /// started before the app last quit or was updated — as `.running`,
    /// without launching anything: no `TerminalLaunch`, no `--resume`, no
    /// new process. `startedAt` is the host's, so a hook state stamped
    /// during the run stays trusted. Nothing happens while the row already
    /// runs here or no host is connected.
    func adopt(_ session: TerminalSession, info: SessionHostSessionInfo) {
        guard let host = sessionHost, states[session.id] != .running else { return }
        let process: HostedTerminalSession
        if let hosted = processes[session.id] as? HostedTerminalSession {
            process = hosted
        } else {
            // A local process of an earlier, ended run: its view leaves
            // the pane for the adopted one.
            if let local = processes.removeValue(forKey: session.id) {
                local.onExit = nil
                local.onOwnerInput = nil
                local.onOwnerFocus = nil
                local.detach()
            }
            process = makeHosted(host)
        }
        wire(process, session: session, startedAt: Date(timeIntervalSince1970: Double(info.startedAtMs) / 1000))
        process.attach(info)
    }

    /// Sorts out what the host listed at launch against the rows that still
    /// exist (`rows`, by id). Only runs of this workspace's scope
    /// (`sessionHostScope`, or "" from an older host) are touched: row ids
    /// of another workspace's database mean other rows. A running run of a
    /// row this center does not run yet is adopted (the newest, when the
    /// host holds several); an exited run of a row nothing runs for is
    /// reported once through `onSessionExit` as a natural exit, and every
    /// exited run is forgotten. A running run whose row is gone — or that
    /// is not the one the row runs — is stopped (hang-up, then kill after
    /// `killGrace`) and forgotten in `strayStops`, which the caller need
    /// not wait for. Runs this center already holds are left to their
    /// session. Safe to call again: a second call finds its own runs held.
    func reattach(_ listed: [SessionHostSessionInfo], rows existing: [Int64: TerminalSession]) async {
        guard let host = sessionHost else { return }
        let scope = sessionHostScope
        let unheld = listed.filter { info in
            (info.scope.isEmpty || info.scope == scope)
                && (processes[info.row] as? HostedTerminalSession)?.key != SessionHostAttachRequest(row: info.row, run: info.run)
        }
        var strays: [SessionHostSessionInfo] = []
        let running = Dictionary(grouping: unheld.filter { !$0.exited }, by: \.row)
        for (row, runs) in running {
            let newestFirst = runs.sorted { $0.startedAtMs > $1.startedAtMs }
            if let session = existing[row], states[row] != .running, let newest = newestFirst.first {
                adopt(session, info: newest)
                strays += newestFirst.dropFirst()
            } else {
                strays += newestFirst
            }
        }
        let exited = Dictionary(grouping: unheld.filter(\.exited), by: \.row)
        for (row, runs) in exited {
            guard let session = existing[row], running[row] == nil, processes[row] == nil,
                  let last = runs.max(by: { $0.startedAtMs < $1.startedAtMs }) else { continue }
            reportExitedWhileAway(session, code: last.code.map { Int32(clamping: $0) })
        }
        for info in unheld where info.exited {
            await host.forget(row: info.row, run: info.run)
        }
        guard !strays.isEmpty else { return }
        strayStops = Task {
            await withTaskGroup(of: Void.self) { group in
                for info in strays {
                    group.addTask { @MainActor in await self.stopStray(info, host: host) }
                }
            }
        }
    }

    /// The stops of the last `reattach`'s stray runs (tests await it).
    @ObservationIgnored private(set) var strayStops: Task<Void, Never>?

    /// After a kill, how many `pollStep`s a stray's stop waits for the host
    /// to reap the child, so the host accepts its forget.
    static let reapPolls = 10

    /// A run that ended while the app was away: the row reads as exited
    /// with its code, and the exit goes out as one the app did not cause.
    private func reportExitedWhileAway(_ session: TerminalSession, code: Int32?) {
        rows[session.id] = session
        states[session.id] = .exited(code)
        onSessionExit?(session.id, code, false)
    }

    /// Stops a hosted run nothing here shows — its row is gone, or another
    /// run of the row was adopted — the way `close` stops a session, then
    /// forgets it in the host.
    private func stopStray(_ info: SessionHostSessionInfo, host: SessionHostClient) async {
        let pid = pid_t(info.pid)
        if pid > 0 {
            signaller.signal(pid, SIGHUP)
            var waited: Duration = .zero
            while waited < Self.killGrace, signaller.isAlive(pid) {
                await signaller.sleep(Self.pollStep)
                waited += Self.pollStep
            }
            if signaller.isAlive(pid) {
                signaller.signal(pid, SIGKILL)
                for _ in 0..<Self.reapPolls where signaller.isAlive(pid) {
                    await signaller.sleep(Self.pollStep)
                }
            }
        }
        await host.forget(row: info.row, run: info.run)
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
        process.onOwnerInput = nil
        process.onOwnerFocus = nil
        process.detach()
        forget(sessionID)
    }

    /// Closes every matching session at once, so the wait is one grace, not
    /// N — the quit path (all) and project delete (that project's ids).
    func closeAll(where predicate: (Int64) -> Bool = { _ in true }) async {
        let ids = Set(processes.keys).union(states.keys).union(pendingLaunches.keys).filter(predicate)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { @MainActor in await self.close(sessionID: id) }
            }
        }
    }

    private func forget(_ sessionID: Int64) {
        pendingLaunches[sessionID] = nil
        missingAgent[sessionID] = nil
        states[sessionID] = nil
        rows[sessionID] = nil
        startedAt[sessionID] = nil
        runs[sessionID] = nil
        clearPromptDraft(sessionID)
        ownerBackslashPending.remove(sessionID)
        clipboardHints.remove(sessionID)
        pasteHints.remove(sessionID)
        answerHints[sessionID] = nil
        unprotected.remove(sessionID)
        focusOrder.removeAll { $0 == sessionID }
    }

    private func isRunning(_ sessionID: Int64, _ pid: pid_t) -> Bool {
        states[sessionID] == .running && signaller.isAlive(pid)
    }
}

/// The embedded terminal's colours, harmonised with the app's dark system
/// palette. Pinned to dark whatever the app appearance: Claude Code runs in
/// the terminal with its dark theme and emits truecolor text a light
/// background would make unreadable.
enum TerminalPalette {
    /// The Projects workspace's backdrop (`NSColor.detailBackground`) as the
    /// dark appearance resolves it, in concrete sRGB (SwiftTerm would capture
    /// a dynamic colour once anyway); #1e1e1e, the macOS 14+ value, only if
    /// that resolution fails. The terminal's default background: OSC 11
    /// reports it, and per-cell reverse video and the text under the block
    /// cursor draw in it.
    static let background: NSColor = {
        var resolved = srgb(0x1E1E1E)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            if let color = NSColor.detailBackground.usingColorSpace(.sRGB) { resolved = color }
        }
        return resolved
    }()

    /// Under a dark appearance the default background is fully transparent:
    /// the Projects workspace's `detailBackground()` shows through, so the
    /// terminal is one surface with the page header above it and the
    /// selected session tab beside it, whatever colour the running SDK
    /// resolves that backdrop to. Under a light appearance it is the opaque
    /// dark `background`, a dark block in the light workspace.
    ///
    /// Known SwiftTerm limits at opacity 0 (its internal code reads the raw
    /// background): whole-screen reverse video (DECSCNM, a visual bell) draws
    /// default text invisible, and IME marked text gets no backing.
    static func backgroundOpacity(for appearance: NSAppearance) -> CGFloat {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0 : 1
    }

    static let foreground = srgb(0xE5E5EA)
    static let caret = srgb(0x0A84FF)
    static let selectionBackground = srgb(0x0A84FF, alpha: 0.35)
    static let selectionForeground = srgb(0xFFFFFF)

    /// The 16 ANSI colours (black, red, green, yellow, blue, magenta, cyan,
    /// white, then the bright row): Apple's dark system colours, as hex
    /// because `NSColor.system*` resolves to different values across macOS
    /// releases. Blue is #409cff in both rows: #0a84ff misses 4.5:1 contrast
    /// on the workspace backdrop.
    static let ansi: [SwiftTerm.Color] = [
        0x1C1C1E, 0xFF453A, 0x30D158, 0xFFD60A, 0x409CFF, 0xBF5AF2, 0x64D2FF, 0xD1D1D6,
        0x8E8E93, 0xFF6961, 0x5DE07F, 0xFFE066, 0x409CFF, 0xDA8FFF, 0x8AE0FF, 0xFFFFFF
    ].map { (rgb: UInt32) in
        let (red, green, blue) = channels(rgb)
        return SwiftTerm.Color(red8: red, green8: green, blue8: blue)
    }

    private static func srgb(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        let (red, green, blue) = channels(rgb)
        return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
    }

    private static func channels(_ rgb: UInt32) -> (UInt16, UInt16, UInt16) {
        (UInt16(rgb >> 16 & 0xFF), UInt16(rgb >> 8 & 0xFF), UInt16(rgb & 0xFF))
    }
}

/// A terminal view in `TerminalPalette`'s colours.
final class PalettedTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        installColors(TerminalPalette.ansi)
        nativeForegroundColor = TerminalPalette.foreground
        caretColor = TerminalPalette.caret
        // Explicit and opaque: by default the character under the block
        // cursor draws in the (possibly transparent) default background.
        caretTextColor = TerminalPalette.background
        selectedTextBackgroundColor = TerminalPalette.selectionBackground
        selectedTextForegroundColor = TerminalPalette.selectionForeground
        applyBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    // MARK: Owner input (board #364)

    /// `TerminalSessionProcess.onOwnerInput`.
    var onOwnerInput: (([UInt8]) -> Void)?
    /// `TerminalSessionProcess.onOwnerFocus`.
    var onOwnerFocus: (() -> Void)?
    /// Set while bytes that are not the owner's pass through `send(source:data:)`.
    private var forwardingAppInput = false

    /// The app's own bytes (`TerminalSessionProcess.sendInput`), through
    /// SwiftTerm's input path but not counted as the owner's.
    func sendAppInput(_ bytes: [UInt8]) {
        forwardingAppInput = true
        defer { forwardingAppInput = false }
        send(data: bytes[...])
    }

    /// The terminal's own replies reach the process through here, then
    /// `send(source:data:)`: focus reports, device attributes and mouse
    /// reports — so an owner's click in a mouse-reporting program is
    /// deliberately not counted as input; only keystrokes and pastes are.
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        if dropsTerminalReplies { return }
        forwardingAppInput = true
        defer { forwardingAppInput = false }
        super.send(source: source, data: data)
    }

    /// Every byte for the process: keystrokes and pastes are the owner's.
    /// A hosted session's bytes go to the session host instead.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !forwardingAppInput { onOwnerInput?(Array(data)) }
        if let hostInput {
            hostInput(Array(data))
            return
        }
        super.send(source: source, data: data)
    }

    // MARK: Session host (board #496)

    /// Set for a hosted session: the bytes for the process go here, not
    /// to the (never started) local process.
    var hostInput: (([UInt8]) -> Void)?
    /// Set for a hosted session: the terminal's new columns and rows.
    var hostResize: ((_ cols: Int, _ rows: Int) -> Void)?
    /// While set, the terminal's own replies (`send(source: Terminal, …)`)
    /// are dropped: a hosted session's replay re-runs old queries.
    var dropsTerminalReplies = false
    /// The size last reported through `hostResize`.
    private var hostSize: (cols: Int, rows: Int)?

    /// SwiftTerm's `sizeChanged(source:newCols:newRows:)` is public, not
    /// open: the grid's new size is read here, after SwiftTerm resized it.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard hostResize != nil else { return }
        let terminal = getTerminal()
        if let hostSize, hostSize.cols == terminal.cols, hostSize.rows == terminal.rows { return }
        reportHostSize()
    }

    /// Reports the current size through `hostResize`, changed or not (an
    /// attach: the host nudges the child to redraw).
    func reportHostSize() {
        let terminal = getTerminal()
        hostSize = (terminal.cols, terminal.rows)
        hostResize?(terminal.cols, terminal.rows)
    }

    // MARK: path:line links (spec 2026-10-02 §9.5)

    /// The folder `path:line` links resolve in, asked at each click (the
    /// session's code root); nil = SwiftTerm's own handling (a standalone
    /// terminal).
    private var pathLinkFolderSource: (() -> String)?
    /// The last folder asked and its path with symlinks resolved, read once
    /// per folder: `TerminalPathLinks` refuses outside paths without
    /// touching the disk (ruling R53).
    private var pathLinkFolderCache: (folder: String, realPath: String?)?
    private var openPathLink: ((TerminalPathLinks.Location) -> Void)?
    private var openedLinkThisClick = false

    func setPathLinks(folder: @escaping () -> String, open: @escaping (TerminalPathLinks.Location) -> Void) {
        pathLinkFolderSource = folder
        pathLinkFolderCache = nil
        openPathLink = open
    }

    /// The folder links resolve in now, with its real path.
    private func pathLinkFolder() -> (folder: String, realPath: String?)? {
        guard let folder = pathLinkFolderSource?() else { return nil }
        if let cache = pathLinkFolderCache, cache.folder == folder { return cache }
        let entry = (folder: folder, realPath: TerminalPathLinks.FileSystem.live.realPath(folder))
        pathLinkFolderCache = entry
        return entry
    }

    /// SwiftTerm's ⌘-click on a link it detected: a file of the folder
    /// opens in Files, a web URL keeps SwiftTerm's handler, anything else
    /// (a path or `file://` outside the folder, a missing file) is no link.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        openedLinkThisClick = true
        let folder = pathLinkFolder()
        switch Self.linkAction(for: link, folder: folder?.folder, folderRealPath: folder?.realPath) {
        case let .open(location): openPathLink?(location)
        case .systemHandler: super.requestOpenLink(source: source, link: link, params: params)
        case .none: break
        }
    }

    /// What a ⌘-clicked link does: in a workbench session a file of the
    /// folder opens in Files (`TerminalPathLinks.action`); SwiftTerm's own
    /// handler gets only a URL the app-wide allowlist permits
    /// (`AllowedURLSchemes`: no `smb://`, `x-apple.systempreferences:`, …,
    /// and in a standalone terminal no bare path either).
    static func linkAction(for link: String, folder: String?, folderRealPath: String?) -> TerminalPathLinks.LinkAction {
        if let folder {
            let action = TerminalPathLinks.action(for: link, folder: folder, folderRealPath: folderRealPath)
            guard action == .systemHandler else { return action }
        }
        guard let url = URL(string: link), AllowedURLSchemes.permits(url) else { return .none }
        return .systemHandler
    }

    /// SwiftTerm detects no quoted path with a space (`"a b.txt":1`): a
    /// ⌘-click it left alone is looked up here in the clicked line — the
    /// rows a long path wrapped over joined back. A click on an `ask #N`
    /// opens that ask (board #500) as `OwnerAskTerminalLinks.click` says.
    override func mouseUp(with event: NSEvent) {
        openedLinkThisClick = false
        super.mouseUp(with: event)
        if !openedLinkThisClick, let askID = askLinkID(at: event) {
            clickedAskLink(askID, event: event)
            return
        }
        guard !openedLinkThisClick, event.modifierFlags.contains(.command), event.clickCount == 1, !selectionActive,
              let openPathLink, let cell = cell(at: event),
              let hit = TerminalPathLinks.logicalLine(rows: screenRows(), row: cell.row, column: cell.col),
              let candidate = TerminalPathLinks.candidate(inLine: hit.line, at: hit.column),
              // Asked only for a path under the cursor: the root lookup
              // (and its realpath) is not every ⌘-click's cost.
              let folder = pathLinkFolder(),
              let location = TerminalPathLinks.resolve(candidate, folder: folder.folder, folderRealPath: folder.realPath)
        else { return }
        openPathLink(location)
    }

    // MARK: ask #N links (board #500)

    private var askLinkLookUp: ((Int64) async -> OwnerAsk?)?
    private var openAskLink: ((Int64) -> Void)?
    /// SwiftTerm's `mouseMoved` cannot be overridden from here (it is
    /// `public`, not `open`): a tracking area of our own reports the
    /// pointer to this object instead.
    private lazy var askHoverTracker = AskLinkHoverTracker(view: self)
    private var askHoverTracking: NSTrackingArea?
    /// The link under the pointer, its card shown or being looked up.
    private var askHover = OwnerAskTerminalLinks.Hover()
    private var askCard: NSPopover?
    /// A plain click's open, waiting out a double click.
    private var pendingAskOpen: Task<Void, Never>?

    func setAskLinks(lookUp: @escaping (Int64) async -> OwnerAsk?, open: @escaping (Int64) -> Void) {
        askLinkLookUp = lookUp
        openAskLink = open
        if askHoverTracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: askHoverTracker, userInfo: nil)
            addTrackingArea(area)
            askHoverTracking = area
        }
    }

    /// The `ask #N` at the event's cell, by the number alone (whether it is
    /// this workbench's ask is `askLinkLookUp`'s); nil without ask links.
    private func askLinkID(at event: NSEvent) -> Int64? {
        guard askLinkLookUp != nil, let cell = cell(at: event),
              let hit = TerminalPathLinks.logicalLine(rows: screenRows(), row: cell.row, column: cell.col)
        else { return nil }
        return OwnerAskTerminalLinks.askID(inLine: hit.line, at: hit.column)
    }

    private func clickedAskLink(_ askID: Int64, event: NSEvent) {
        let terminal = getTerminal()
        let click = OwnerAskTerminalLinks.click(
            clickCount: event.clickCount, command: event.modifierFlags.contains(.command), selectionActive: selectionActive,
            mouseReporting: allowMouseReporting && terminal.mouseMode != .off
        )
        switch click {
        case .openNow:
            closeAskCard()
            openAskLink?(askID)
        case .openAfterDoubleClick:
            pendingAskOpen = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                guard !Task.isCancelled, let self else { return }
                self.closeAskCard()
                self.openAskLink?(askID)
            }
        case .ignore:
            break
        }
    }

    /// A second click of a double or triple click cancels the first one's
    /// open; any new click does.
    /// A click also makes this the active session (`onOwnerFocus`):
    /// SwiftTerm's `becomeFirstResponder` is not open to override.
    override func mouseDown(with event: NSEvent) {
        pendingAskOpen?.cancel()
        pendingAskOpen = nil
        onOwnerFocus?()
        super.mouseDown(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        pendingAskOpen?.cancel()
        pendingAskOpen = nil
        closeAskCard()
    }

    fileprivate func askLinkHovered(_ event: NSEvent) {
        guard let askID = askLinkID(at: event) else {
            closeAskCard()
            return
        }
        guard let askLinkLookUp, let token = askHover.enter(askID) else {
            // Still over the link whose card is up: keep the hand.
            if askCard != nil { NSCursor.pointingHand.set() }
            return
        }
        closeCard()
        let anchor = cellRect(at: event)
        Task { @MainActor [weak self] in
            // A number naming no ask of this workbench shows nothing.
            guard let ask = await askLinkLookUp(askID), let self, self.askHover.isCurrent(token), self.window != nil
            else { return }
            self.showAskCard(ask, at: anchor)
        }
    }

    /// The pointer left the link (or the view its window): no card, no hand.
    fileprivate func closeAskCard() {
        askHover.leave()
        closeCard()
    }

    private func closeCard() {
        guard let askCard else { return }
        askCard.close()
        self.askCard = nil
        NSCursor.iBeam.set()
    }

    private func showAskCard(_ ask: OwnerAsk, at anchor: NSRect) {
        closeCard()
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: OwnerAskLinkCard(ask: ask))
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        askCard = popover
        NSCursor.pointingHand.set()
    }

    /// The cell under the pointer, in this view's coordinates (`cell(at:)`'s
    /// grid); a zero rect at the pointer off the grid.
    private func cellRect(at event: NSEvent) -> NSRect {
        guard let cell = cell(at: event), let size = cellSize() else {
            return NSRect(origin: convert(event.locationInWindow, from: nil), size: .zero)
        }
        return NSRect(x: CGFloat(cell.col) * size.width, y: frame.height - CGFloat(cell.row + 1) * size.height,
                      width: size.width, height: size.height)
    }

    /// The visible rows, one character per cell (an empty cell a space, the
    /// cell a wide character spills into `TerminalPathLinks.wideSpill`),
    /// with their soft-wrap marks.
    private func screenRows() -> [TerminalPathLinks.Row] {
        let terminal = getTerminal()
        return (0..<terminal.rows).map { row in
            guard let line = terminal.getLine(row: row) else { return TerminalPathLinks.Row(text: "", continuesAbove: false) }
            var text = ""
            for col in 0..<line.count {
                let cell = line[col]
                if cell.getCharacter() != "\u{0}" {
                    text.append(terminal.getCharacter(for: cell))
                } else {
                    text.append(col > 0 && line[col - 1].width == 2 ? TerminalPathLinks.wideSpill : " ")
                }
            }
            return TerminalPathLinks.Row(text: text, continuesAbove: line.isWrapped)
        }
    }

    /// The visible row and column under the pointer, by SwiftTerm's own
    /// cell size (the font's "W" advance on the pixel grid; the optimal
    /// frame's height over the rows).
    private func cell(at event: NSEvent) -> (row: Int, col: Int)? {
        let terminal = getTerminal()
        guard terminal.cols > 0, let size = cellSize() else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((frame.height - point.y) / size.height)
        let col = Int(point.x / size.width)
        guard (0..<terminal.rows).contains(row), (0..<terminal.cols).contains(col) else { return nil }
        return (row, col)
    }

    /// One cell's size; nil before the terminal has rows.
    private func cellSize() -> NSSize? {
        let terminal = getTerminal()
        guard terminal.rows > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let advance = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let cellHeight = getOptimalFrameSize().height / CGFloat(terminal.rows)
        guard cellHeight > 0 else { return nil }
        return NSSize(width: max(1, (advance * scale).rounded() / scale), height: cellHeight)
    }

    /// SwiftTerm's ⌘-hover link preview is the one text field it adds; it
    /// draws its text in the default background, invisible at opacity 0.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? NSTextField)?.textColor = TerminalPalette.background
    }

    /// Through `backgroundOpacity`, not a bare `nativeBackgroundColor`: its
    /// setter also flushes SwiftTerm's colour cache, so text already drawn
    /// does not keep the previous background. Either setter repaints the
    /// layer the host's margin mirrors — an appearance change re-applies the
    /// palette background over any OSC 11 colour the program set.
    private func applyBackground() {
        nativeBackgroundColor = TerminalPalette.background
        backgroundOpacity = TerminalPalette.backgroundOpacity(for: effectiveAppearance)
    }
}

/// The owner of `PalettedTerminalView`'s ask-link tracking area: moves over
/// the terminal show an `ask #N`'s card, leaving it closes the card.
@MainActor
private final class AskLinkHoverTracker: NSResponder {
    private weak var view: PalettedTerminalView?

    init(view: PalettedTerminalView) {
        self.view = view
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func mouseMoved(with event: NSEvent) { view?.askLinkHovered(event) }
    override func mouseExited(with event: NSEvent) { view?.closeAskCard() }
}

/// The real session: a SwiftTerm `LocalProcessTerminalView` running the
/// launch in a pty. Keystrokes, copy/paste and resize are SwiftTerm's own
/// (no Accessibility, no event monitors — no TCC prompt).
@MainActor
final class SwiftTermSession: NSObject, TerminalSessionProcess, LocalProcessTerminalViewDelegate {
    private let terminal: PalettedTerminalView
    var onExit: ((Int32?) -> Void)?
    var onOwnerInput: (([UInt8]) -> Void)? {
        get { terminal.onOwnerInput }
        set { terminal.onOwnerInput = newValue }
    }
    var onOwnerFocus: (() -> Void)? {
        get { terminal.onOwnerFocus }
        set { terminal.onOwnerFocus = newValue }
    }

    override init() {
        terminal = PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        terminal.processDelegate = self
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    var view: NSView { terminal }
    var pid: pid_t { terminal.process?.shellPid ?? 0 }

    func start(_ launch: TerminalLaunch) {
        terminal.startProcess(
            executable: launch.executable,
            args: launch.args,
            environment: launch.processEnvironment,
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
        terminal.sendAppInput(bytes)
    }

    var bracketedPasteMode: Bool { terminal.getTerminal().bracketedPasteMode }

    func setPathLinkHandler(folder: @escaping () -> String, open: @escaping (TerminalPathLinks.Location) -> Void) {
        terminal.setPathLinks(folder: folder, open: open)
    }

    func setAskLinkHandler(lookUp: @escaping (Int64) async -> OwnerAsk?, open: @escaping (Int64) -> Void) {
        terminal.setAskLinks(lookUp: lookUp, open: open)
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        // LocalProcess delivers on the main queue (its default dispatch queue).
        MainActor.assumeIsolated { onExit?(exitCode) }
    }
}

extension TerminalLaunch {
    /// The environment the launch's process starts with, locally or in the
    /// session host: SwiftTerm's terminal basics (`TERM=xterm-256color`,
    /// the locale, the owner's `USER`/`HOME`), `SHELL`, then the launch's
    /// own entries.
    var processEnvironment: [String] {
        var processEnvironment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        processEnvironment.append("SHELL=\(executable)")
        processEnvironment.append(contentsOf: environment)
        return processEnvironment
    }
}
