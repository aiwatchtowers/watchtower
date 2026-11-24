import Foundation
import Observation
import UniformTypeIdentifiers
import WatchtowerChatText
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
    /// Each change drops the paste payloads whose token left it (#2065 §6):
    /// a deleted token never comes back live, even typed again by hand.
    var draft = "" {
        didSet { prunePastes() }
    }
    /// Files and pasted images waiting to go with the next line, as the
    /// composer's chips; in memory only (negative ids, `path` absolute).
    private(set) var attachments: [ChatAttachment] = []
    /// The draft's paste tokens' payloads by token number (#2065 §6): a pasted
    /// long text, or the file a pasted image was saved to. A payload whose
    /// token left the draft is dropped as the draft changes. In memory only.
    private(set) var pastes: [Int: PastePayload] = [:]
    /// The lines sent from here and not yet shown by the feed, oldest first.
    private(set) var outgoing: [WorkchatOutgoing] = []
    /// Why the last attach did not take (a paste not saved, a path that
    /// cannot go in a line), under the field; the next attach or send clears it.
    private(set) var attachmentError: String?
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
    /// Where pasted bytes are saved; nil → a paste is not taken.
    @ObservationIgnored private let attachmentStore: WorkchatAttachmentStore?
    @ObservationIgnored private var attachmentCounter: Int64 = 0
    /// The chips of a line on its way, to bring back if it cannot go.
    @ObservationIgnored private var sentAttachments: [UUID: [ChatAttachment]] = [:]
    /// The paste payloads of a line on its way, to bring back with its tokenized draft.
    @ObservationIgnored private var sentPastes: [UUID: [Int: PastePayload]] = [:]
    /// Paste numbers given out whose token the draft has not shown yet (the
    /// field inserts it after `paste` returns): not pruned until it has, and
    /// Send waits for them; a token the field could not insert is let go
    /// (`pasteNotInserted`).
    @ObservationIgnored private var pendingPastes: Set<Int> = []
    /// The last paste number given out in this draft: a pruned number is never
    /// given out again, so an undone deletion cannot point at a new payload.
    @ObservationIgnored private var lastPasteNumber = 0
    /// The session's kind, read each time it is needed: a pane restored at
    /// launch makes its model before the sessions load.
    @ObservationIgnored private let kind: @MainActor () -> TerminalSession.Kind?
    /// Whether a line waits for the agent to stop: an agent that does not
    /// take a line while it works (`AgentSessionCaps.takesLineWhileWorking`:
    /// Codex, whose mid-turn MCP forms raise no state), a shell and a kind
    /// not known yet keep the phone's busy hold.
    var holdsUntilIdle: Bool { agent.map { !caps($0).takesLineWhileWorking } ?? true }
    /// The session capability rows (`AgentSessionCaps.of`; tests swap them).
    @ObservationIgnored private let caps: (AgentKind) -> AgentSessionCaps
    /// The session's terminal prompt line as its screen shows it (`TerminalCenter.promptPreview`):
    /// shown under a line held for the prompt's text, never read to decide anything.
    @ObservationIgnored private let promptPreview: (Int64) -> String?
    /// The session's agent; nil for a shell or a kind not known yet.
    var agent: AgentKind? { kind()?.agent }
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
        attachmentStore: WorkchatAttachmentStore? = nil,
        kind: @escaping @MainActor () -> TerminalSession.Kind?,
        now: @escaping () -> Date = Date.init,
        caps: @escaping (AgentKind) -> AgentSessionCaps = AgentSessionCaps.of,
        promptPreview: @escaping (Int64) -> String? = { _ in nil }
    ) {
        self.sessionID = sessionID
        self.caps = caps
        self.promptPreview = promptPreview
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
    /// that cannot go comes back to it. Paste tokens expand in place (#2065
    /// §6): a text token to its text, an image token to its saved path; an
    /// image whose file is gone refuses the send and keeps the draft. A paste
    /// whose token the field has not inserted yet refuses it too (a Return in
    /// that hop would clear the payload the token is about to land for).
    func send() async {
        guard pendingPastes.isEmpty else { return }
        // Line breaks stay (owner ask #421); only the ends are trimmed.
        let typed = draft.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || !attachments.isEmpty else { return }
        let live = PasteTokens.liveNumbers(in: typed, kinds: pastes.mapValues(\.kind))
        let sentPastes = pastes.filter { live.contains($0.key) }
        let imagePaths = sentPastes.sorted { $0.key < $1.key }.compactMap { number, payload -> (Int, String)? in
            guard case let .image(path) = payload else { return nil }
            return (number, path)
        }
        if let gone = imagePaths.first(where: { !FileManager.default.fileExists(atPath: $0.1) }) {
            attachmentError = Self.imageGone(gone.0)
            return
        }
        // The draft is trimmed around its tokens; a pasted text keeps its own
        // indentation and closing line breaks.
        let expanded = PasteTokens.expand(typed, payloads: sentPastes, imagePath: WorkchatOutgoing.quoted)
        let hasText = !expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Only a whitespace paste: refused like an empty draft.
        guard hasText || !attachments.isEmpty else { return }
        attachmentError = nil
        let chipPaths = attachments.map(\.path)
        let text = ((hasText ? [expanded] : []) + chipPaths.map(WorkchatOutgoing.quoted)).joined(separator: "\n")
        draft = ""
        pastes = [:]
        pendingPastes = []
        lastPasteNumber = 0
        let sent = attachments
        attachments = []
        await deliver(text, typed: typed, paths: chipPaths + imagePaths.map(\.1), attachments: sent,
                      pastes: sentPastes)
    }

    /// Why a paste's payload was dropped: its label is in the draft twice, so neither copy is the token.
    static func pasteDuplicated(_ number: Int, kind: PasteKind) -> String {
        "\(kind == .image ? "Pasted image" : "Pasted text") #\(number) appears twice — paste it again"
    }

    /// Why a send was refused: a pasted image's saved file is gone (swept or deleted).
    static func imageGone(_ number: Int) -> String {
        "Pasted image #\(number) is gone — paste it again"
    }

    /// Sends `text` as a line of its own — a question card's answers in the feed — leaving the draft and its files
    /// alone. It goes like a typed line: held, retried and shown on its way the same way.
    func sendLine(_ text: String) async {
        let typed = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        await deliver(typed, typed: typed, paths: [], attachments: [])
    }

    private func deliver(
        _ text: String,
        typed: String,
        paths: [String],
        attachments sent: [ChatAttachment],
        pastes sentPastes: [Int: PastePayload] = [:]
    ) async {
        let id = UUID()
        sentAttachments[id] = sent
        self.sentPastes[id] = sentPastes
        outgoing.append(WorkchatOutgoing(
            id: id, text: text, sentAt: now(), state: .sending, typedText: typed, attachmentPaths: paths
        ))
        await go(id, text: text, besideText: false)
    }

    /// One delivery of the line `id` through `SessionLineDelivery`, held and retried
    /// there; its check's hold reason goes on the bubble. `besideText`: the prompt's
    /// text does not hold it (Send together) — the host types it beside that text,
    /// without a Return, and the owner's one Return sends both (`sharedPrompts`).
    private func go(_ id: UUID, text: String, besideText: Bool) async {
        let delivery = await lineDelivery.deliverLine(
            text, key: .workchat(id), sessionID: sessionID,
            gate: { [weak self, weak control] in
                // Read at each try: a held line goes once the kind is known.
                Self.gate((self?.holdsUntilIdle ?? true) ? control?.lineCheck($0) : control?.workchatLineCheck($0),
                          besideText: besideText)
            },
            onHeldEvent: { [weak self] event in
                switch event {
                case .awaitingApproval: self?.setHoldReason(id, .needsApproval)
                case let .tried(delivery): self?.settle(id, delivery)
                }
            }
        )
        settle(id, delivery)
    }

    private func setHoldReason(_ id: UUID, _ reason: WorkchatOutgoing.HoldReason?) {
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        outgoing[index].holdReason = reason
    }

    /// Why a held line waits, by the session's check now (the one that held it,
    /// or the permission prompt read before it); nil when it would go (a
    /// failed state read held it).
    private func holdReason() -> WorkchatOutgoing.HoldReason? {
        switch holdsUntilIdle ? control.lineCheck(sessionID) : control.workchatLineCheck(sessionID) {
        case .hold(.needsApproval): .needsApproval
        case .hold(.agentBusy): .agentBusy
        case .hold(.promptHasText): .promptHasText
        case .go, .sessionGone: nil
        }
    }

    /// The terminal prompt's line under a line held for its text (spec §6.3); nil
    /// for any other line or when the screen shows none.
    func holdPreview(for id: UUID) -> String? {
        guard let line = outgoing.first(where: { $0.id == id }), line.state == .queued,
              line.holdReason == .promptHasText else { return nil }
        let preview = promptPreview(sessionID)?.trimmingCharacters(in: .whitespaces)
        return preview?.isEmpty == false ? preview : nil
    }

    /// Send together (spec §6.3): a line held for the prompt's text goes now,
    /// typed beside that text without a Return — the owner's Return in the
    /// terminal sends both. Every other hold (a permission prompt, a busy
    /// agent) still holds it.
    func sendTogether(_ id: UUID) async {
        guard let line = outgoing.first(where: { $0.id == id }), line.state == .queued,
              line.holdReason == .promptHasText,
              !lineDelivery.dropHeld(sessionID: sessionID, where: { $0 == .workchat(id) }).isEmpty,
              let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        outgoing[index].state = .sending
        outgoing[index].holdReason = nil
        await go(id, text: line.text, besideText: true)
    }

    // MARK: - Attachments

    /// Files from Finder or a drop: sent as their own paths. A path with a
    /// line break is refused (`attachmentError`): it would split the line.
    func attach(files: [URL]) {
        attachmentError = nil
        for url in files {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            addChip(path: url.path, name: url.lastPathComponent, size: Int64(values?.fileSize ?? 0))
        }
    }

    /// Pasted image or PDF bytes, saved under the session's folder and sent
    /// as that path. False → the paste is not taken (no store, or a write
    /// failed) and `attachmentError` says why; nothing is inserted instead.
    func attach(data: Data, name: String) async -> Bool {
        attachmentError = nil
        guard let path = save(data, name: name) else { return false }
        return addChip(path: path, name: name, size: Int64(data.count))
    }

    /// A pasted image or long text kept as an inline token (#2065 §6): returns
    /// the token for the field to insert at the paste. The image is saved now
    /// (as `attach(data:name:)`); a save that fails returns nil, keeps nothing
    /// and says why (`attachmentError`). Numbers count up per draft, past any
    /// number already in it, so a hand-typed `[Image #1]` is never taken over
    /// (a hand-typed number above `PasteTokens.maxNumber` is ignored).
    func paste(_ item: InlinePaste) async -> String? {
        attachmentError = nil
        let typed = PasteTokens.numbers(in: draft).filter { $0 <= PasteTokens.maxNumber }
        let number = max(lastPasteNumber, pastes.keys.max() ?? 0, typed.max() ?? 0) + 1
        switch item {
        case let .text(text):
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            keep(.text(normalized), as: number)
            return PasteTokens.textLabel(number, lines: PasteTokens.lineCount(normalized))
        case let .image(data, name):
            guard let path = save(data, name: name) else { return nil }
            guard !path.contains(where: \.isNewline) else {
                attachmentError = "Cannot attach “\(name)”: its path has a line break"
                return nil
            }
            keep(.image(path: path), as: number)
            return PasteTokens.imageLabel(number)
        }
    }

    /// The field could not insert `label` (it refused the edit or was gone):
    /// its paste stops waiting, so Send is not held for a token that never
    /// lands, and the payload goes with it (the draft does not hold it).
    func pasteNotInserted(_ label: String) {
        pendingPastes.subtract(PasteTokens.numbers(in: label))
        prunePastes()
    }

    private func keep(_ payload: PastePayload, as number: Int) {
        lastPasteNumber = number
        pendingPastes.insert(number)
        pastes[number] = payload
    }

    /// Drops each payload whose token (number and kind) the draft no longer
    /// holds once (a typed copy beside it makes both literal), unless its
    /// token has not been inserted yet.
    /// A payload dropped because its label is held twice says so
    /// (`pasteDuplicated`) on the attachment-error line.
    private func prunePastes() {
        guard !pastes.isEmpty else { return }
        let kinds = pastes.mapValues(\.kind)
        let held = PasteTokens.heldNumbers(in: draft, kinds: kinds)
        pendingPastes.subtract(held)
        let live = PasteTokens.liveNumbers(in: draft, kinds: kinds)
        let kept = pastes.filter { live.contains($0.key) || pendingPastes.contains($0.key) }
        guard kept.count != pastes.count else { return }
        if let twice = held.subtracting(live).min(), let kind = kinds[twice] {
            attachmentError = Self.pasteDuplicated(twice, kind: kind)
        }
        pastes = kept
    }

    /// Saves pasted bytes under the session's folder; nil → not saved, and `attachmentError` says why.
    private func save(_ data: Data, name: String) -> String? {
        guard let attachmentStore else {
            attachmentError = "Pasted files cannot be kept here"
            return nil
        }
        do {
            return try attachmentStore.save(data, name: name, sessionID: sessionID).path
        } catch {
            NSLog("WorkchatModel: saving a pasted file for session %lld failed: %@", sessionID, String(describing: error))
            attachmentError = "Could not save the pasted file: \(error.localizedDescription)"
            return nil
        }
    }

    func removeAttachment(_ id: Int64) {
        attachments.removeAll { $0.id == id }
    }

    @discardableResult
    private func addChip(path: String, name: String, size: Int64) -> Bool {
        guard !path.contains(where: \.isNewline) else {
            attachmentError = "Cannot attach “\(name)”: its path has a line break"
            return false
        }
        attachmentCounter -= 1
        let mime = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        attachments.append(ChatAttachment(
            id: attachmentCounter, conversationID: nil, projectID: nil, messageID: nil, name: name,
            mime: mime, size: size, path: path, sha256: "", createdAt: now().timeIntervalSince1970
        ))
        return true
    }

    /// Drops a queued line before it goes; its tokenized draft, paste payloads
    /// and files come back into an empty field (#2065 §6). A line already on
    /// its way (its retry under way) is not in the queue and stays.
    func cancel(_ id: UUID) {
        guard let line = outgoing.first(where: { $0.id == id }), line.state == .queued else { return }
        let dropped = lineDelivery.dropHeld(sessionID: sessionID) { $0 == .workchat(id) }
        guard !dropped.isEmpty else { return }
        outgoing.removeAll { $0.id == id }
        restore(id, typed: line.typedText)
    }

    /// Puts a line that did not go back: its typed text and paste payloads
    /// only into an empty field, its files only when no chips wait.
    private func restore(_ id: UUID, typed: String) {
        if draft.isEmpty {
            let restored = sentPastes[id] ?? [:]
            pastes.merge(restored) { _, restored in restored }
            lastPasteNumber = max(lastPasteNumber, restored.keys.max() ?? 0)
            draft = typed
        }
        if attachments.isEmpty, let chips = sentAttachments[id] { attachments = chips }
        sentAttachments[id] = nil
        sentPastes[id] = nil
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

    nonisolated private static func gate(
        _ check: SessionControl.LineCheck?, besideText: Bool
    ) -> SessionLineDelivery.GateAnswer {
        switch check {
        case .go: .go
        case .hold(.promptHasText) where besideText: .go
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
        // A line behind another (`.queued`) or on its way has no reason of its own.
        outgoing[index].holdReason = delivery == .held ? holdReason() : nil
        if state == .sent, !holdsUntilIdle { outgoing[index].sentWhileBusy = control.isWorking(sessionID) }
        switch state {
        case .sent, .typed, .copied:
            sentAttachments[id] = nil
            sentPastes[id] = nil
            outgoing[index].deliveredAt = now()
            // The feed read that holds its echo may have come while it was
            // still on its way; no later read would bring it again.
            reconcile(with: lastEntries)
        case .notSent:
            restore(id, typed: outgoing[index].typedText)
        case .sending, .queued: break
        }
    }
}
