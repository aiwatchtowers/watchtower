import Foundation
import Observation
import WatchtowerKit
import WatchtowerSync

/// What an ask's row on Now offers under its text (#1785): the quick answers as chips, one **Answer…** chip, or,
/// once an answer exists on this phone, where that answer stands in place of the options, so the owner never
/// answers twice.
enum NowAnswer: Equatable {
    /// Nothing: the row itself opens the form (a check, a review, a question without quick answers).
    case none
    /// The Mac's one-tap answers as chips, the recommended one prominent.
    case chips([InlineAskOption])
    /// Too many or too long answers for chips: one **Answer…** chip that opens the form.
    case openForm
    /// An answer is on its way: "Sending answer…", or "Answer waits for your Mac" while the Mac is away.
    case sending(String)
    /// An answer is queued behind a stopped flush (no network, a rate limit): it goes by itself once the outbox
    /// can write again, and a queued row cannot be retried (`ActionOutbox.retry` takes failed rows only).
    case waitingToSend
    /// The newest answer failed or is listed under Not delivered: **Retry** writes it again (`HubSession.retry`).
    case notDelivered(rowID: String)

    static let chipLimit = 3
    /// A label longer than this does not fit a chip.
    static let chipLabelLimit = 32
    static let answerFormTitle = "Answer…"
    static let sendingText = "Sending answer…"
    static let waitingForMacText = "Answer waits for your tower"
    static let waitingToSendText = "Answer waiting to send"
    static let notDeliveredText = "Answer not delivered"
    static let retryTitle = "Retry"

    /// The ask's newest `ask_answer` row decides (`AskFormModel.status`'s rule): a pending one is on its way, a
    /// failed one (a refusal, Not delivered, the Mac's error) offers Retry. With none, an answer being written
    /// (`writing`) reads as sending; else the quick answers, if any.
    static func of(_ ask: OwnerAsk, pending: [PendingAction], flushStopped: Bool, macOnline: Bool, writing: Bool) -> Self {
        let entity = AskAnswerer.recordName(ask.id)
        guard let row = pending.last(where: { $0.action.kind == .askAnswer && $0.entityRecordName == entity }) else {
            if writing { return .sending(sendingText) }
            return chipsOrForm(ask.quick?.options.map { InlineAskOption(id: $0.label, label: $0.label, isRecommended: $0.recommended) })
        }
        switch row.state {
        case .pending:
            if row.delivery == .queued, flushStopped { return .waitingToSend }
            return .sending(macOnline ? sendingText : waitingForMacText)
        case .failed:
            return .notDelivered(rowID: row.id)
        }
    }

    /// Up to `chipLimit` answers of up to `chipLabelLimit` characters each are chips; more or longer is one
    /// **Answer…** chip.
    static func chipsOrForm(_ options: [InlineAskOption]?) -> Self {
        guard let options, !options.isEmpty else { return .none }
        guard options.count <= chipLimit, options.allSatisfy({ $0.label.count <= chipLabelLimit }) else { return .openForm }
        return .chips(options)
    }

    /// The status line in place of the options; nil when the row shows chips or nothing.
    var statusText: String? {
        switch self {
        case let .sending(text): text
        case .waitingToSend: Self.waitingToSendText
        case .notDelivered: Self.notDeliveredText
        case .none, .chips, .openForm: nil
        }
    }

    var statusTone: PhoneTone {
        if case .notDelivered = self { return .red }
        return .secondary
    }

    func toneUses(row: String) -> [ToneUse] {
        switch self {
        case .notDelivered:
            [
                ToneUse(element: "now answer \(row) not delivered", tone: .red, role: .status),
                ToneUse(element: "now answer \(row) retry", tone: .accent, role: .info)
            ]
        case .sending, .waitingToSend:
            [ToneUse(element: "now answer \(row) status", tone: .secondary, role: .info)]
        case .none, .chips, .openForm:
            []
        }
    }
}

/// What marks an ended row seen: the session and the moment its state changed (`state_at`), so a session that ends
/// again later comes back under Ended. A session without `state_at` is keyed by its `last_active_at` instead, so it
/// comes back whenever that moves, even without ending again.
struct NowEndedKey: Hashable {
    let sessionID: Int64
    let at: Date
}

/// The ended rows marked seen, per hub, in the phone's UserDefaults: the owner's reading position on this phone
/// only, never synced (`RecordingsSeenStore`'s rule), so it survives a relaunch and another phone keeps its own. Its
/// only writers are Now's **Seen** (a row's long press or VoiceOver action) and the Ended header's **Clear**, on the
/// main actor. A mark older than `keepFor` can no longer match a row (Ended keeps 24 h) and goes on the next write.
/// Marks of a hub this phone no longer links stay until the defaults go (a few short strings).
@MainActor
@Observable
final class NowEndedSeenStore {
    static let key = "now.endedSeen"
    static let keepFor = 2 * NowModel.endedSessionWindow

    /// Hub id → its marks.
    private(set) var marks: [String: Set<NowEndedKey>]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = (defaults.dictionary(forKey: Self.key) as? [String: [String]]) ?? [:]
        marks = stored.mapValues { Set($0.compactMap(Self.decode)) }
    }

    func seen(hubID: String) -> Set<NowEndedKey> {
        marks[hubID] ?? []
    }

    func markSeen(_ key: NowEndedKey, hubID: String, now: Date = Date()) {
        markSeen([key], hubID: hubID, now: now)
    }

    /// Marks every key seen in one write (the header's **Clear**).
    func markSeen(_ keys: [NowEndedKey], hubID: String, now: Date = Date()) {
        var hub = (marks[hubID] ?? []).filter { now.timeIntervalSince($0.at) <= Self.keepFor }
        hub.formUnion(keys)
        marks[hubID] = hub
        defaults.set(marks.mapValues { $0.map(Self.encode).sorted() }, forKey: Self.key)
    }

    /// "12@783012345.5": the session id and its state time.
    private static func encode(_ key: NowEndedKey) -> String {
        "\(key.sessionID)@\(key.at.timeIntervalSinceReferenceDate)"
    }

    private static func decode(_ text: String) -> NowEndedKey? {
        let parts = text.split(separator: "@", maxSplits: 1)
        guard parts.count == 2, let id = Int64(parts[0]), let at = Double(parts[1]) else { return nil }
        return NowEndedKey(sessionID: id, at: Date(timeIntervalSinceReferenceDate: at))
    }
}
