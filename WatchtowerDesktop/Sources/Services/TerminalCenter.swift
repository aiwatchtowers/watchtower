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
    /// The owner's own input reached the session (a keystroke, a paste),
    /// with its bytes — never `sendInput` or the terminal's replies (focus
    /// and mouse reports). Main thread.
    var onOwnerInput: (([UInt8]) -> Void)? { get set }
    /// ⌘-click on `path:line(:col)` resolving inside `folder` calls `open`
    /// instead of SwiftTerm's default handler (spec 2026-10-02 §9.5).
    func setPathLinkHandler(folder: String, open: @escaping (TerminalPathLinks.Location) -> Void)
}

extension TerminalSessionProcess {
    func setPathLinkHandler(folder: String, open: @escaping (TerminalPathLinks.Location) -> Void) {}
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
    @ObservationIgnored var makeProcess: () -> any TerminalSessionProcess
    @ObservationIgnored var shell: () -> String? = { ProcessInfo.processInfo.environment["SHELL"] }
    /// Whether Claude Code has a transcript for a session id. A seam for tests.
    @ObservationIgnored var transcriptExists: (String) -> Bool = { ClaudeTranscript.exists(sessionID: $0) }
    /// Every process exit, after `states` records it (the VM's resume-failure
    /// check). One subscriber.
    @ObservationIgnored var onSessionExit: ((Int64, Int32?) -> Void)?
    /// A ⌘-clicked `path:line` in a workbench session's terminal, resolved
    /// inside its folder (`TerminalPathLinks`): workbench id, location.
    @ObservationIgnored var onPathLink: ((Int64, TerminalPathLinks.Location) -> Void)?
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

    /// The live `claude` sessions — the ones whose workbench hooks report a
    /// state.
    var liveClaudeIDs: Set<Int64> {
        let live = liveIDs
        return Set(rows.values.filter { $0.kind == .claude && live.contains($0.id) }.map(\.id))
    }

    func process(for sessionID: Int64) -> (any TerminalSessionProcess)? {
        processes[sessionID]
    }

    /// Sessions of `projectID` this center holds a process for (running or not).
    func sessionIDs(ofWorkbench projectID: Int64) -> Set<Int64> {
        Set(rows.values.filter { $0.projectID == projectID }.map(\.id))
    }

    /// The project's active session — the one the Terminal toggle shows
    /// first: its most recently focused live `claude` session.
    func activeSession(projectID: Int64) -> TerminalSession? {
        TerminalSessionPolicy.activeSession(
            rows.values.filter { $0.projectID == projectID }, live: liveIDs, lastFocused: focusOrder
        )
    }

    /// Whether a Claude Code session this app runs works in the files a
    /// branch switch swaps: a live `claude` row of the workbench, or one (a
    /// standalone terminal, another workbench) whose folder is the
    /// repository's work tree or inside it — a workbench in a subfolder
    /// shares one checkout with the repository root and every sibling
    /// package. Symlinks are resolved on both sides (`/tmp` is
    /// `/private/tmp`). The branch switch's agent guard (#233); a `claude`
    /// in the owner's own terminal app is not seen (v1 limit).
    func hasLiveClaudeSession(workbenchID: Int64, workTree: String) -> Bool {
        let root = Self.resolvedPath(workTree)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let live = liveIDs
        return rows.values.contains { row in
            guard row.kind == .claude, live.contains(row.id) else { return false }
            if row.projectID == workbenchID { return true }
            let path = Self.resolvedPath(row.folderPath)
            return path == root || path.hasPrefix(prefix)
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
    func sendPrompt(_ line: String, sessionID: Int64, keepingLineBreaks: Bool = false) -> PromptDelivery {
        guard states[sessionID] == .running, let process = processes[sessionID] else { return .noSession }
        answerHints[sessionID] = nil
        switch WorkbenchCommentPrompt.terminalPayload(line, bracketedPaste: process.bracketedPasteMode,
                                                      keepingLineBreaks: keepingLineBreaks) {
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

    /// The pause between a hand-off's paste and its Return, so the TUI has
    /// taken the paste in before the key arrives.
    static let submitDelay: Duration = .milliseconds(150)
    /// The same pause for an ask's answer (board #379): longer, since an
    /// answer is not urgent and the re-read after it then also sees a
    /// permission prompt whose async hook landed a little late.
    static let answerSubmitDelay: Duration = .milliseconds(500)

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
    /// reported a state this run that is not a permission prompt; a Return
    /// could answer a prompt that appeared meanwhile) — and only into the
    /// same process run (`runs`), as a write of its own after `delay`: a CR read
    /// in one chunk with the paste could be taken as part of it (a line
    /// break, not Enter). `refresh` runs after the pause, before the second
    /// check (the caller re-reads the agent state, which its poll may hold
    /// up to 1 s stale) and returns whether that read succeeded: after a
    /// failed one the state is not known, so no Return. An owner's
    /// submitting Return during the pause has sent the line: none follows,
    /// and it counts as submitted. Otherwise the paste
    /// waits for the owner's own Return, and the session holds a draft until
    /// then; a line sharing the prompt with other text says so
    /// (`sharedPrompts`).
    func submitPrompt(
        _ text: String,
        sessionID: Int64,
        keepingLineBreaks: Bool = true,
        delay: Duration = submitDelay,
        refresh: () async -> Bool = { true },
        submitIf canSubmit: () -> Bool
    ) async -> HandoffDelivery {
        let run = runs[sessionID]
        let promptWasEmpty = !promptDrafts.contains(sessionID) && !(run.map(pendingReturns.contains) ?? false)
        switch sendPrompt(text, sessionID: sessionID, keepingLineBreaks: keepingLineBreaks) {
        case .noSession: return .noSession
        case .copied: return .copied
        case .sent: break
        }
        guard let process = processes[sessionID], let run else { return .noSession }
        // The pair of `promptWasEmpty`: whether the line ends up next to
        // other text not submitted.
        var besideText = !promptWasEmpty
        if promptWasEmpty, canSubmit() {
            pendingReturns.insert(run)
            defer {
                pendingReturns.remove(run)
                ownerReturnsInPause.remove(run)
            }
            await signaller.sleep(delay)
            let fresh = await refresh()
            // The Return goes only into the run the line was pasted into.
            guard states[sessionID] == .running, runs[sessionID] == run else { return .noSession }
            // The owner's Return sent the line already; nothing waits for
            // ours, and no bar asks for one.
            if ownerReturnsInPause.contains(run) { return .submitted }
            if fresh, canSubmit(), !promptDrafts.contains(sessionID) {
                process.sendInput([0x0D])
                return .submitted
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
        if Self.isSubmit(bytes, backslashBefore: backslashBefore) {
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

    /// Whether the owner's input submits Claude Code's prompt: it ends in a
    /// plain Return (CR) that does not follow ESC (Option+Return) and whose
    /// last printable input before it — in this chunk or earlier ones
    /// (`backslashBefore`), escape sequences such as cursor keys and paste
    /// brackets skipped — is not `\` (`\` then Return is a line break).
    /// Anything else is a draft: Ctrl+J (LF), Shift+Return under an extended
    /// keyboard protocol (an escape sequence ending in `u` or `~`), any
    /// other key. When unsure the input counts as a draft, which costs the
    /// owner a Return of their own, never a line submitted with theirs.
    static func isSubmit(_ bytes: [UInt8], backslashBefore: Bool) -> Bool {
        guard bytes.last == 0x0D else { return false }
        let body = bytes.dropLast()
        if body.last == 0x1B { return false }
        return !endsAfterBackslash(body, backslashBefore: backslashBefore)
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

    /// Starts the row's process unless it is running. A `claude` row resumes
    /// its stored Claude session (`--resume`) when Claude Code has a
    /// transcript for it; without one (the owner never typed, or the first
    /// start failed) `--resume` would be refused on every Restart, so it
    /// starts the same id anew (`--session-id`, no prompt). `fresh: true` —
    /// the row's first start, or Start fresh after the caller stored a new id
    /// — always uses `--session-id` with the optional fixed `prompt`; either
    /// way the process gets the row id (`TerminalLaunch.sessionRowEnv`), so
    /// the project hook can store the id `/clear` moves Claude Code to. A
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
            self?.answerHints[id] = nil
            self?.onSessionExit?(id, code)
        }
        process.onOwnerInput = { [weak self] bytes in self?.ownerInput(id, bytes) }
        processes[id] = process
        if let workbenchID = session.projectID {
            // ⌘-click on `path:line` in a workbench session opens Files.
            process.setPathLinkHandler(folder: session.folderPath) { [weak self] location in
                self?.onPathLink?(workbenchID, location)
            }
        }
        startedAt[id] = now()
        lastRun += 1
        runs[id] = lastRun
        // A new run starts with an empty prompt: no line of the last run
        // waits for a Return there (board #389).
        clearPromptDraft(id)
        pasteHints.remove(id)
        ownerBackslashPending.remove(id)
        states[id] = .running
        process.start(.make(shell: shell(), folder: session.folderPath, mode: mode, rowID: id))
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
        process.onOwnerInput = nil
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
        startedAt[sessionID] = nil
        runs[sessionID] = nil
        clearPromptDraft(sessionID)
        ownerBackslashPending.remove(sessionID)
        clipboardHints.remove(sessionID)
        pasteHints.remove(sessionID)
        answerHints[sessionID] = nil
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
        forwardingAppInput = true
        defer { forwardingAppInput = false }
        super.send(source: source, data: data)
    }

    /// Every byte for the process: keystrokes and pastes are the owner's.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !forwardingAppInput { onOwnerInput?(Array(data)) }
        super.send(source: source, data: data)
    }

    // MARK: path:line links (spec 2026-10-02 §9.5)

    /// The workbench folder `path:line` links resolve in; nil = SwiftTerm's
    /// own handling (a standalone terminal).
    private(set) var pathLinkFolder: String?
    /// The folder with symlinks resolved, read once (it is inside the
    /// workbench): `TerminalPathLinks` refuses outside paths without
    /// touching the disk (ruling R53).
    private var pathLinkFolderRealPath: String?
    private var openPathLink: ((TerminalPathLinks.Location) -> Void)?
    private var openedLinkThisClick = false

    func setPathLinks(folder: String, open: @escaping (TerminalPathLinks.Location) -> Void) {
        pathLinkFolder = folder
        pathLinkFolderRealPath = TerminalPathLinks.FileSystem.live.realPath(folder)
        openPathLink = open
    }

    /// SwiftTerm's ⌘-click on a link it detected: a file of the folder
    /// opens in Files, a web URL keeps SwiftTerm's handler, anything else
    /// (a path or `file://` outside the folder, a missing file) is no link.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        openedLinkThisClick = true
        switch Self.linkAction(for: link, folder: pathLinkFolder, folderRealPath: pathLinkFolderRealPath) {
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
    /// rows a long path wrapped over joined back.
    override func mouseUp(with event: NSEvent) {
        openedLinkThisClick = false
        super.mouseUp(with: event)
        guard !openedLinkThisClick, event.modifierFlags.contains(.command), event.clickCount == 1, !selectionActive,
              let folder = pathLinkFolder, let openPathLink, let cell = cell(at: event),
              let hit = TerminalPathLinks.logicalLine(rows: screenRows(), row: cell.row, column: cell.col),
              let candidate = TerminalPathLinks.candidate(inLine: hit.line, at: hit.column),
              let location = TerminalPathLinks.resolve(candidate, folder: folder, folderRealPath: pathLinkFolderRealPath)
        else { return }
        openPathLink(location)
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
        guard terminal.rows > 0, terminal.cols > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let advance = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let cellWidth = max(1, (advance * scale).rounded() / scale)
        let cellHeight = getOptimalFrameSize().height / CGFloat(terminal.rows)
        guard cellHeight > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((frame.height - point.y) / cellHeight)
        let col = Int(point.x / cellWidth)
        guard (0..<terminal.rows).contains(row), (0..<terminal.cols).contains(col) else { return nil }
        return (row, col)
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

    override init() {
        terminal = PalettedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        terminal.processDelegate = self
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    var view: NSView { terminal }
    var pid: pid_t { terminal.process?.shellPid ?? 0 }

    func start(_ launch: TerminalLaunch) {
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("SHELL=\(launch.executable)")
        environment.append(contentsOf: launch.environment)
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
        terminal.sendAppInput(bytes)
    }

    var bracketedPasteMode: Bool { terminal.getTerminal().bracketedPasteMode }

    func setPathLinkHandler(folder: String, open: @escaping (TerminalPathLinks.Location) -> Void) {
        terminal.setPathLinks(folder: folder, open: open)
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        // LocalProcess delivers on the main queue (its default dispatch queue).
        MainActor.assumeIsolated { onExit?(exitCode) }
    }
}
