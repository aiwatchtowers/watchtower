import Foundation
import Observation
import WatchtowerKit
import WatchtowerSync

/// Where the Mac's answer line went (`result.delivery`, spec §5.2). A
/// value this build does not know decodes to none (the plain saved line).
enum AskDelivery: String, Equatable {
    case submitted, typed, held, queued, copied
    case noSession = "no_session"
    /// An automation run's ask: the answer goes to the run, not a session.
    case automation

    /// The short line shown under an answered ask.
    var text: String {
        switch self {
        case .submitted: "Sent to the session"
        case .typed: "Typed into the session — press Return on the tower to send it"
        case .held: "Held until the session is free"
        case .queued: "Queued behind another answer to the session"
        case .copied: "On the tower's clipboard — paste it into the session"
        case .noSession: "No session is running — the answer is saved on the tower"
        case .automation: "Answer saved — the automation goes on with it"
        }
    }
}

/// An answer the Mac took this run (`applied`), with its delivery when the
/// echo named one. Until the asks slice closes the ask, the answer's
/// `askAnswer` overlay (live link R5) keeps it shown as sent.
struct AppliedAnswer: Equatable {
    let delivery: AskDelivery?

    var text: String { delivery?.text ?? AskText.appliedWithoutDelivery }
}

/// Sends the phone's ask answers (`ask_answer`, spec §5.2, §6.2) through
/// the outbox and keeps what the Mac's `applied` echoes said. Owned by
/// `AppEnvironment` with the drafts it clears.
///
/// One answer per ask is in flight at a time (`SendGuard`): a double tap on
/// Send never queues two. An `applied` echo removes its overlay row, so the
/// outbox's applied observer is how its delivery arrives (`receiveApplied(_:)`);
/// it then drops the ask's draft.
@MainActor
@Observable
final class AskAnswerer {
    /// Queues the answer under the given id (chosen at the tap, so its overlay shows first); returns that id.
    typealias Enqueue = (_ entity: String, _ params: [String: JSONValue], _ id: String) async throws -> String

    /// Ask id → its answer the Mac applied this run.
    private(set) var applied: [Int64: AppliedAnswer] = [:]

    @ObservationIgnored private let enqueue: Enqueue
    @ObservationIgnored private let remove: (String) throws -> Void
    /// The ids of an ask's failed `ask_answer` rows (its record name).
    @ObservationIgnored private let failedRows: (String) throws -> [String]
    @ObservationIgnored private let drafts: AskDraftStore
    @ObservationIgnored private let sendGuard = SendGuard()
    /// The hub's optimistic overlays; nil: none (tests of other parts).
    @ObservationIgnored private let overlays: OverlayBook?
    @ObservationIgnored private let now: () -> Date

    init(
        drafts: AskDraftStore,
        enqueue: @escaping Enqueue,
        remove: @escaping (String) throws -> Void,
        failedRows: @escaping (String) throws -> [String] = { _ in [] },
        overlays: OverlayBook? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.drafts = drafts
        self.enqueue = enqueue
        self.remove = remove
        self.failedRows = failedRows
        self.overlays = overlays
        self.now = now
    }

    /// The app's answerer: answers through the outbox, Dismiss on the
    /// overlay. `AppEnvironment.appliedObserver` hands it the outbox's applied echoes.
    static func sending(
        through outbox: ActionOutbox, store: ReplicaStore, drafts: AskDraftStore, overlays: OverlayBook? = nil
    ) -> AskAnswerer {
        AskAnswerer(
            drafts: drafts,
            enqueue: { entity, params, id in
                try await outbox.enqueue(kind: .askAnswer, entityRecordName: entity, params: params, id: id)
            },
            remove: { try store.dismissAction(id: $0) },
            failedRows: { entity in
                try store.pendingActions(forEntity: entity)
                    .filter { $0.state == .failed && $0.action.kind == .askAnswer }
                    .map(\.id)
            },
            overlays: overlays
        )
    }

    nonisolated static func recordName(_ askID: Int64) -> String {
        SliceKind.ownerAsk.recordName(id: String(askID))
    }

    /// Whether an answer to the ask is waiting for the outbox right now.
    func isSending(_ askID: Int64) -> Bool {
        sendGuard.inFlight.contains(Self.recordName(askID))
    }

    /// Sends the draft's answer; nothing (false) while the draft is not one
    /// the Mac would take, or an answer to the ask is already on its way.
    @discardableResult
    func send(_ ask: OwnerAsk) async throws -> Bool {
        let draft = drafts.draft(for: ask.id)
        guard draft.isAnswerable(for: ask), let answer = draft.answer(for: ask) else { return false }
        return try await submit(answer, to: ask)
    }

    /// Closes the ask without answering it (#2114, the Mac's Dismiss): the draft's note with `dismissed`, down the
    /// same `ask_answer` path, overlay and refusal handling as an answer. Nothing (false) for an ask the Mac would
    /// not take it for, a note over its bound, or while an answer to the ask is already on its way.
    @discardableResult
    func sendDismissal(_ ask: OwnerAsk) async throws -> Bool {
        guard AskDraft.isDismissable(ask), let answer = drafts.draft(for: ask.id).dismissal() else { return false }
        return try await submit(answer, to: ask)
    }

    /// Queues `answer` under one id per tap, its overlay shown first. Once it
    /// is queued, the ask's older refused answers go (as `BoardWriter` drops
    /// a field's), so a later `applied` is never hidden behind a stale refusal.
    private func submit(_ answer: OwnerAskAnswer, to ask: OwnerAsk) async throws -> Bool {
        let params = try AskAnswerParams(workbenchID: ask.workbenchID, answer: answer).wireParams()
        let entity = Self.recordName(ask.id)
        let stale = try failedRows(entity)
        let tappedAt = now()
        let sent = try await sendGuard.run(entity) {
            // The answer shows as sent at the tap; a save that throws takes it back.
            let id = UUID().uuidString
            let overlay = overlays?.overlay(
                actionID: id, entityID: ask.id, expected: .askAnswer(label: Self.answerLabel(answer)), createdAt: tappedAt)
            if let overlay { overlays?.add(overlay) }
            do {
                _ = try await enqueue(entity, params, id)
            } catch {
                overlays?.remove(actionID: id)
                throw error
            }
        }
        guard sent else { return false }
        for id in stale {
            try remove(id)
        }
        return true
    }

    /// What an answer says in one line, for its caption while on its way (live link R5): the verdict, else the
    /// picked options (and "Other: …") as the closed ask lists them, or that it closes the ask unanswered; nil for a
    /// checklist or a note alone.
    nonisolated static func answerLabel(_ answer: OwnerAskAnswer) -> String? {
        if answer.dismissed { return AskText.dismissedLabel }
        if let verdict = answer.verdict { return AskText.verdictLabel(verdict) }
        let picked = answer.answers.flatMap { $0.labels + ($0.other.isEmpty ? [] : [AskText.otherLabel($0.other)]) }
        return picked.isEmpty ? nil : picked.joined(separator: ", ")
    }

    /// An `applied` echo: keeps its delivery and drops the ask's draft.
    /// Other kinds are not ours.
    func receiveApplied(_ action: ActionRequestPayload) {
        guard action.kind == .askAnswer, let askID = action.entityID.flatMap(Int64.init) else { return }
        var delivery: AskDelivery?
        if case let .string(value)? = action.result?["delivery"] {
            delivery = AskDelivery(rawValue: value)
        }
        applied[askID] = AppliedAnswer(delivery: delivery)
        drafts.discard(askID)
    }

    /// Dismiss on a failed answer.
    func dismiss(_ row: PendingAction) throws {
        try remove(row.id)
    }
}
