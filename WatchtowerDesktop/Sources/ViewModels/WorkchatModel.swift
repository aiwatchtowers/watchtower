import Foundation
import Observation
import UniformTypeIdentifiers
import WatchtowerCore

/// What the Workchat asks of `SessionControl`: its gates and the permission
/// row. A protocol so the model's tests can make a read or an answer fail or
/// wait.
@MainActor
protocol WorkchatControl: AnyObject {
    func lineCheck(_ sessionID: Int64) -> SessionControl.LineCheck
    func workchatLineCheck(_ sessionID: Int64) -> SessionControl.LineCheck
    func isWorking(_ sessionID: Int64) -> Bool
    func interrupt(_ sessionID: Int64) async throws -> SessionControl.InterruptResult
    func pendingPermission(_ sessionID: Int64) async throws -> SessionControl.PermissionPrompt?
    func answerPermission(requestID: Int64, sessionID: Int64, allow: Bool, decidedBy: String) async throws
        -> SessionControl.PermissionAnswer
}

extension SessionControl: WorkchatControl {}

/// One session's Workchat composer (#711, spec §4): the draft, the lines sent
/// from it and Stop. Lines go through `SessionLineDelivery` with key
/// `.workchat(id)` behind `SessionControl.lineCheck` — PROJ-16's gate, with
/// no device grant at the Mac. Held by `WorkbenchesViewModel` per session, so
/// the draft and the queued lines survive pane switches; nothing is stored.
@MainActor
@Observable
final class WorkchatModel {
    typealias Delivery = SessionLineDelivery.Delivery

    let sessionID: Int64
    var draft = ""
    /// Files and pasted images waiting to go with the next line, as the
    /// composer's chips; in memory only (negative ids, `path` absolute).
    private(set) var attachments: [ChatAttachment] = []
    /// The lines sent from here and not yet shown by the feed, oldest first.
    private(set) var outgoing: [WorkchatOutgoing] = []
    /// Why the last Stop did not go (refused, or not checked); the next Stop clears it.
    private(set) var stopError: String?
    /// The session's pending permission request, as the card shows it; nil
    /// when none (always for Codex, whose hooks write no rows).
    private(set) var permission: SessionControl.PermissionPrompt?
    /// An Allow or Deny is on its way: the card's buttons wait.
    private(set) var answering = false
    /// Why the last permission read or answer failed; the next one clears it.
    private(set) var permissionError: String?

    /// Who decided a prompt answered in the Workchat (`decided_by`).
    static let decidedBy = "Mac"

    @ObservationIgnored private let control: any WorkchatControl
    @ObservationIgnored private let lineDelivery: SessionLineDelivery
    @ObservationIgnored private let now: () -> Date
    /// Where pasted bytes are saved; nil → a paste stays a text paste.
    @ObservationIgnored private let attachmentStore: WorkchatAttachmentStore?
    @ObservationIgnored private var attachmentCounter: Int64 = 0
    /// The chips of a line on its way, to bring back if it cannot go.
    @ObservationIgnored private var sentAttachments: [UUID: [ChatAttachment]] = [:]
    /// Codex has not been verified to queue a Return typed mid-turn, and an
    /// unknown kind is not trusted to: both keep the phone's busy hold.
    @ObservationIgnored private let kind: TerminalSession.Kind?
    /// Whether a line waits for the agent to stop (Codex, unknown kind).
    var holdsUntilIdle: Bool { kind == nil || kind == .codex }
    /// Feed entries that stood for a line already: one echo, one line.
    @ObservationIgnored private var claimedEntries: Set<String> = []
    /// Bumped by each permission read and answer, so a read that finishes
    /// after a newer one (or an answer) does not bring an old card back.
    @ObservationIgnored private var permissionReads = 0
    /// The feed as `reconcile` last saw it: a line settled after the read
    /// that already held its echo is matched against it.
    @ObservationIgnored private var lastEntries: [SessionFeedEntry] = []

    init(
        sessionID: Int64,
        control: any WorkchatControl,
        lineDelivery: SessionLineDelivery,
        kind: TerminalSession.Kind? = nil,
        attachmentStore: WorkchatAttachmentStore? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.sessionID = sessionID
        self.attachmentStore = attachmentStore
        self.kind = kind
        self.control = control
        self.lineDelivery = lineDelivery
        self.now = now
    }

    /// Sends the draft as one line that keeps its line breaks (owner ask
    /// #421, PROJ-12 amended): `\r\n` becomes `\n` and only the ends are
    /// trimmed; the echo is matched on collapsed whitespace. An empty or
    /// whitespace-only draft is not sent. The field clears at once; a line
    /// that cannot go comes back to it.
    func send() async {
        // Line breaks stay (owner ask #421); only the ends are trimmed.
        let typed = draft.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || !attachments.isEmpty else { return }
        let paths = attachments.map(\.path)
        let text = ([typed].filter { !$0.isEmpty } + paths.map(Self.quoted)).joined(separator: "\n")
        draft = ""
        let id = UUID()
        sentAttachments[id] = attachments
        attachments = []
        outgoing.append(WorkchatOutgoing(
            id: id, text: text, sentAt: now(), state: .sending, typedText: typed, attachmentPaths: paths
        ))
        let delivery = await lineDelivery.deliverLine(
            text, key: .workchat(id), sessionID: sessionID,
            gate: { [weak control, busyHold = holdsUntilIdle] in
                Self.gate(busyHold ? control?.lineCheck($0) : control?.workchatLineCheck($0))
            },
            onHeldEvent: { [weak self] event in
                guard case let .tried(delivery) = event else { return }
                self?.settle(id, delivery)
            }
        )
        settle(id, delivery)
    }

    // MARK: - Attachments

    /// Files from Finder or a drop: sent as their own paths.
    func attach(files: [URL]) {
        for url in files {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            addChip(path: url.path, name: url.lastPathComponent, size: Int64(values?.fileSize ?? 0))
        }
    }

    /// Pasted image or PDF bytes, saved under the session's folder and sent
    /// as that path. False → the paste is not taken (no store, or a write
    /// failed: logged) and ⌘V falls back to its text.
    func attach(data: Data, name: String) async -> Bool {
        guard let attachmentStore else { return false }
        do {
            let url = try attachmentStore.save(data, name: name, sessionID: sessionID)
            addChip(path: url.path, name: name, size: Int64(data.count))
            return true
        } catch {
            NSLog("WorkchatModel: saving a pasted file for session %lld failed: %@", sessionID, String(describing: error))
            return false
        }
    }

    func removeAttachment(_ id: Int64) {
        attachments.removeAll { $0.id == id }
    }

    private func addChip(path: String, name: String, size: Int64) {
        attachmentCounter -= 1
        let mime = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        attachments.append(ChatAttachment(
            id: attachmentCounter, conversationID: nil, projectID: nil, messageID: nil, name: name,
            mime: mime, size: size, path: path, sha256: "", createdAt: now().timeIntervalSince1970
        ))
    }

    /// A path with a space goes in double quotes, as a terminal reads it.
    private static func quoted(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }

    /// Drops a queued line before it goes. A line already on its way (its
    /// retry under way) is not in the queue and stays.
    func cancel(_ id: UUID) {
        guard outgoing.first(where: { $0.id == id })?.state == .queued else { return }
        let dropped = lineDelivery.dropHeld(sessionID: sessionID) { $0 == .workchat(id) }
        guard !dropped.isEmpty else { return }
        outgoing.removeAll { $0.id == id }
    }

    /// The feed changed: a line whose owner entry it now shows leaves. A
    /// submitted line whose echo is not dated within `echoWindow` of its
    /// delivery stays as a plain bubble — judged by the echo's time, so a
    /// feed read late (the pane off screen) still matches; a typed or
    /// copied line waits for the owner's Return however long.
    func reconcile(with entries: [SessionFeedEntry]) {
        lastEntries = entries
        let owners = entries.filter { $0.kind == "owner" && !claimedEntries.contains($0.id) }
        guard !owners.isEmpty else { return }
        var kept: [WorkchatOutgoing] = []
        var claimed = Set<String>()
        for line in outgoing {
            guard let echo = owners.first(where: {
                !claimed.contains($0.id) && WorkchatOutgoing.matches($0, line: line) && Self.isTimelyEcho($0, of: line)
            }) else {
                kept.append(line)
                continue
            }
            claimed.insert(echo.id)
        }
        guard !claimed.isEmpty else { return }
        claimedEntries.formUnion(claimed)
        outgoing = kept
    }

    /// One Esc into the working agent, refused while a permission prompt is
    /// pending. A refusal the owner could not see coming says why
    /// (`stopError`); the result is returned as well.
    func stop() async -> SessionControl.InterruptResult {
        stopError = nil
        let result: SessionControl.InterruptResult
        do {
            result = try await control.interrupt(sessionID)
        } catch {
            stopError = "Could not check for a permission prompt: \(error.localizedDescription)"
            return .notWorking
        }
        switch result {
        case .awaitingApproval:
            // The prompt is drawn before its card shows.
            stopError = "A permission prompt is open — answer it on the card or in the terminal"
        case .notRunning:
            stopError = "The session is not running"
        case .sent, .notWorking:
            break
        }
        return result
    }

    // MARK: - Permission

    /// What re-runs the pane's permission read: the state kind and the
    /// trusted hook's stamp (`agent_state_at`). Every hook write changes
    /// it, so a prompt whose hook set Needs approval again within one state
    /// poll, the kind unchanged, is still read.
    struct PermissionReadKey: Hashable {
        let kind: SessionSwitcherPresentation.State.Kind?
        let at: String?

        init(_ status: SessionAgentStatus?) {
            kind = status?.state.kind
            at = status?.at
        }
    }

    /// Reads the session's pending permission request again. Called on each
    /// hook write for the session (the pane's `.task(id:)` over
    /// `PermissionReadKey`) and after an answer; no timer of its own. A read that
    /// fails keeps the card as it was.
    func refreshPermission() async {
        permissionReads += 1
        let read = permissionReads
        do {
            let prompt = try await control.pendingPermission(sessionID)
            // A newer read or an answer started meanwhile: this one is stale.
            guard read == permissionReads else { return }
            permission = prompt
            permissionError = nil
        } catch {
            guard read == permissionReads else { return }
            NSLog("WorkchatModel: permission read for session %lld failed: %@", sessionID, String(describing: error))
            permissionError = "Could not read the permission prompt: \(error.localizedDescription)"
        }
    }

    /// Allow or Deny on the card, decided by `"Mac"` through the guarded
    /// update the phone uses. Answered elsewhere → the card leaves; an allow
    /// that may not be given here keeps the card with Deny only.
    func answer(allow: Bool) async {
        guard let prompt = permission, !answering else { return }
        answering = true
        defer { answering = false }
        permissionError = nil
        // Drops a read that started before this answer.
        permissionReads += 1
        let result: SessionControl.PermissionAnswer
        do {
            result = try await control.answerPermission(
                requestID: prompt.id, sessionID: sessionID, allow: allow, decidedBy: Self.decidedBy
            )
        } catch {
            permissionError = "Could not answer the prompt: \(error.localizedDescription)"
            return
        }
        switch result {
        case .applied, .notPending, .notFound:
            permission = nil
            await refreshPermission()
        case let .allowBlocked(block):
            permission = SessionControl.PermissionPrompt(
                id: prompt.id, toolName: prompt.toolName, summary: prompt.summary, allowBlock: block
            )
        case .notRunning:
            permission = nil
        }
    }

    /// How long before `deliveredAt` a submitted line's echo may be dated:
    /// `deliveredAt` is set after `submitPrompt` returns, so the real echo
    /// can be stamped a moment earlier.
    static let echoLead: TimeInterval = 2

    /// Whether `entry` (already a match, so dated) can be the line's echo: a
    /// submitted line's echo is dated from just before its delivery to
    /// `echoWindow` after it — the same text typed in the terminal while
    /// the line sat queued is not its echo.
    private static func isTimelyEcho(_ entry: SessionFeedEntry, of line: WorkchatOutgoing) -> Bool {
        switch line.state {
        case .sent:
            guard let delivered = line.deliveredAt else { return true }
            // `matches` already required the entry's date.
            let since = (entry.at ?? delivered).timeIntervalSince(delivered)
            // A line sent mid-turn is echoed when the agent reads it.
            return since >= -echoLead && (line.sentWhileBusy || since <= WorkchatOutgoing.echoWindow)
        case .typed, .copied: return true
        case .sending, .queued, .notSent: return false
        }
    }

    nonisolated private static func gate(_ check: SessionControl.LineCheck?) -> SessionLineDelivery.GateAnswer {
        switch check {
        case .go: .go
        case .hold: .hold
        case .sessionGone, nil: .drop
        }
    }

    /// A delivery's outcome on the line's bubble; a line that cannot go
    /// any more puts its text back in an empty field.
    private func settle(_ id: UUID, _ delivery: Delivery) {
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        let state: WorkchatOutgoing.State = switch delivery {
        case .submitted: .sent
        case .held, .queued: .queued
        case .typed: .typed
        case .copied: .copied
        case .noSession: .notSent
        }
        outgoing[index].state = state
        if state == .sent, !holdsUntilIdle { outgoing[index].sentWhileBusy = control.isWorking(sessionID) }
        switch state {
        case .sent, .typed, .copied:
            sentAttachments[id] = nil
            outgoing[index].deliveredAt = now()
            // The feed read that holds its echo may have come while it was
            // still on its way; no later read would bring it again.
            reconcile(with: lastEntries)
        case .notSent:
            if draft.isEmpty { draft = outgoing[index].typedText }
            if attachments.isEmpty, let chips = sentAttachments[id] { attachments = chips }
            sentAttachments[id] = nil
        case .sending, .queued: break
        }
    }
}
