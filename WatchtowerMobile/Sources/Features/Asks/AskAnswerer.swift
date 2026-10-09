import Foundation
import Observation
import WatchtowerKit
import WatchtowerSync

/// Where the Mac's answer line went (`result.delivery`, spec §5.2).
enum AskDelivery: String, Equatable {
    case submitted, typed, held, queued, copied
    case noSession = "no_session"

    /// The short line shown under an answered ask.
    var text: String {
        switch self {
        case .submitted: "Sent to the session"
        case .typed: "Typed into the session — press Return on the Mac to send it"
        case .held: "Held until the session is free"
        case .queued: "Queued behind another answer to the session"
        case .copied: "On the Mac's clipboard — paste it into the session"
        case .noSession: "No session is running — the answer is saved on the Mac"
        }
    }
}

/// An answer the Mac took this run (`applied`), with its delivery when the
/// echo named one.
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
    typealias Enqueue = (_ entity: String, _ params: [String: JSONValue]) async throws -> Void

    /// Ask id → its answer the Mac applied this run.
    private(set) var applied: [Int64: AppliedAnswer] = [:]

    @ObservationIgnored private let enqueue: Enqueue
    @ObservationIgnored private let remove: (String) throws -> Void
    /// The ids of an ask's failed `ask_answer` rows (its record name).
    @ObservationIgnored private let failedRows: (String) throws -> [String]
    @ObservationIgnored private let drafts: AskDraftStore
    @ObservationIgnored private let sendGuard = SendGuard()

    init(
        drafts: AskDraftStore,
        enqueue: @escaping Enqueue,
        remove: @escaping (String) throws -> Void,
        failedRows: @escaping (String) throws -> [String] = { _ in [] }
    ) {
        self.drafts = drafts
        self.enqueue = enqueue
        self.remove = remove
        self.failedRows = failedRows
    }

    /// The app's answerer: answers through the outbox, Dismiss on the
    /// overlay. `AppEnvironment.appliedObserver` hands it the outbox's applied echoes.
    static func sending(through outbox: ActionOutbox, store: ReplicaStore, drafts: AskDraftStore) -> AskAnswerer {
        AskAnswerer(
            drafts: drafts,
            enqueue: { entity, params in
                try await outbox.enqueue(kind: .askAnswer, entityRecordName: entity, params: params)
            },
            remove: { try store.removePendingAction(id: $0) },
            failedRows: { entity in
                try store.pendingActions(forEntity: entity)
                    .filter { $0.state == .failed && $0.action.kind == .askAnswer }
                    .map(\.id)
            }
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
    /// Once it is queued, the ask's older refused answers go (as
    /// `BoardWriter` drops a field's), so a later `applied` is never hidden
    /// behind a stale refusal.
    @discardableResult
    func send(_ ask: OwnerAsk) async throws -> Bool {
        let draft = drafts.draft(for: ask.id)
        guard draft.isAnswerable(for: ask), let answer = draft.answer(for: ask) else { return false }
        let params = try AskAnswerParams(workbenchID: ask.workbenchID, answer: answer).wireParams()
        let entity = Self.recordName(ask.id)
        let stale = try failedRows(entity)
        guard try await sendGuard.run(entity, { try await enqueue(entity, params) }) else { return false }
        for id in stale {
            try remove(id)
        }
        return true
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
