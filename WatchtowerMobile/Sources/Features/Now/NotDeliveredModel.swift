import Foundation
import WatchtowerKit
import WatchtowerSync

/// One ordered outbox row as Now and the Not delivered list read it (relay client Phase 1): what the action is,
/// when it was made, its place in the queue and where it stands. Built from the replica's `PendingAction`; a
/// legacy row (no `action_seq`) is not one.
struct OutboxItem: Equatable, Identifiable {
    let id: String
    let kind: ActionKind
    let entityRecordName: String?
    let params: [String: JSONValue]
    let createdAt: Date
    let seq: UInt64
    let delivery: Delivery
    let reason: UndeliveredReason?

    init(
        id: String,
        kind: ActionKind,
        entityRecordName: String?,
        params: [String: JSONValue],
        createdAt: Date,
        seq: UInt64,
        delivery: Delivery,
        reason: UndeliveredReason?
    ) {
        self.id = id
        self.kind = kind
        self.entityRecordName = entityRecordName
        self.params = params
        self.createdAt = createdAt
        self.seq = seq
        self.delivery = delivery
        self.reason = reason
    }

    /// nil for a legacy row.
    init?(_ row: PendingAction) {
        guard let seq = row.actionSeq, let delivery = row.delivery else { return nil }
        self.init(
            id: row.id, kind: row.action.kind, entityRecordName: row.entityRecordName, params: row.action.params,
            createdAt: row.createdAt, seq: seq, delivery: delivery, reason: row.undeliveredReason)
    }

    /// The ordered rows in `delivery`, oldest (lowest seq) first.
    static func rows(_ pending: [PendingAction], _ delivery: Delivery) -> [Self] {
        pending.compactMap(Self.init).filter { $0.delivery == delivery }.sorted { $0.seq < $1.seq }
    }
}

/// The one-line summary of an action the phone made: "Move “Fix login” to Done". The entity's title comes from
/// the replica; a missing one reads as the kind's noun ("a task").
enum ActionSummary {
    static let inputLimit = 60
    static let fallback = "An action from this iPhone"

    static func text(for item: OutboxItem, snapshot: WorkbenchReplicaSnapshot) -> String {
        let entity = entityID(item.entityRecordName)
        switch item.kind {
        case .askAnswer:
            let title = quoted(entity.flatMap { id in snapshot.asks.first { $0.id == id }?.title }, or: "an ask")
            let answer = (try? AskAnswerParams(wireParams: item.params)).flatMap { verdict($0.answer) }
            return ["Answer \(title)", answer].compactMap { $0 }.joined(separator: " — ")
        case .boardTargetStatus:
            let column = (try? BoardTargetStatusParams(wireParams: item.params)).map { BoardRowModel.statusLabel($0.status) }
            return ["Move \(target(entity, snapshot))", column.map { "to \($0)" }].compactMap { $0 }.joined(separator: " ")
        case .boardCommentAdd:
            return "Comment on \(target(entity, snapshot))"
        case .boardCommentReply:
            let targetID = entity.flatMap { id in snapshot.comments.first { $0.id == id }?.targetID }
            return "Comment on \(target(targetID, snapshot))"
        case .boardTargetCreate:
            let text = (try? BoardTargetCreateParams(wireParams: item.params))?.text
            return "New task \(quoted(text.map(oneLine), or: "on the board"))"
        case .sessionStart:
            return "Start a session for \(target(entity, snapshot))"
        case .sessionInput:
            let text = (try? SessionInputParams(wireParams: item.params)).map { clipped(oneLine($0.text)) }
            return "Send \(quoted(text, or: "a message"))"
        case .sessionStop:
            return "Stop \(session(entity, snapshot))"
        case .sessionFinishRequest:
            return "Finish \(session(entity, snapshot))"
        case .sessionInterrupt:
            return "Interrupt \(session(entity, snapshot))"
        case .permissionAnswer:
            let allow = (try? PermissionAnswerParams(wireParams: item.params))?.behavior == .allow
            return "\(allow ? "Allow" : "Deny") a permission request"
        case .automationRun:
            let name = entity.flatMap { id in
                snapshot.workbenches.lazy.compactMap { $0.automations?.first { $0.id == id }?.name }.first
            }
            return "Run \(quoted(name, or: "an automation"))"
        default:
            return fallback
        }
    }

    /// `owner_ask-109` → 109: everything after the first hyphen.
    private static func entityID(_ recordName: String?) -> Int64? {
        recordName?.split(separator: "-", maxSplits: 1).dropFirst().first.flatMap { Int64($0) }
    }

    private static func target(_ id: Int64?, _ snapshot: WorkbenchReplicaSnapshot) -> String {
        quoted(id.flatMap { id in snapshot.targets.first { $0.id == id }?.text }, or: "a task")
    }

    private static func session(_ id: Int64?, _ snapshot: WorkbenchReplicaSnapshot) -> String {
        quoted(id.flatMap(snapshot.session)?.title, or: "a session")
    }

    private static func quoted(_ title: String?, or noun: String) -> String {
        guard let title, !title.isEmpty else { return noun }
        return "“\(title)”"
    }

    /// A review's verdict, else the first question's picks (or its "Other"); nil for a checklist.
    private static func verdict(_ answer: OwnerAskAnswer) -> String? {
        if answer.verdict == .approved { return "Approved" }
        if answer.verdict == .changes { return "Changes requested" }
        guard let first = answer.answers.first else { return nil }
        let picks = first.labels + (first.other.isEmpty ? [] : [first.other])
        return picks.isEmpty ? nil : picks.joined(separator: ", ")
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private static func clipped(_ text: String) -> String {
        text.count > inputLimit ? "\(text.prefix(inputLimit))…" : text
    }
}

/// The Not delivered list (relay client Phase 1, mockup 5a): the actions that never reached the Mac, oldest first,
/// each with its summary, time and why, and a Retry; Dismiss All behind a confirmation. Retry is disabled on a row
/// while its retry runs, and a failed retry's message shows under that row only.
struct NotDeliveredModel {
    static let title = "Not delivered"
    static let retryTitle = "Retry"
    static let dismissAllTitle = "Dismiss All"
    static let lockedRetryError = "Unlock your iPhone to retry."
    static let otherRetryError = "Couldn't retry. Try again."
    static let dismissErrorText = "Couldn't dismiss. Try again."

    let footer: String
    let rows: [NotDeliveredRow]

    init(
        items: [OutboxItem],
        snapshot: WorkbenchReplicaSnapshot,
        macName: String,
        now: Date,
        calendar: Calendar,
        retrying: Set<String>,
        errors: [String: String]
    ) {
        let mac = macName.isEmpty ? "your Mac" : macName
        footer = "These actions never reached \(mac). Retry sends them again, after anything you did since."
        let format = RecordingsFormat(calendar: calendar, now: now)
        rows = items.filter { $0.delivery == .undelivered }.sorted { $0.seq < $1.seq }.map { item in
            let reason = item.reason == .noAnswer ? "No answer from \(mac) for 24 hours" : nil
            return NotDeliveredRow(
                id: item.id, summary: ActionSummary.text(for: item, snapshot: snapshot),
                detail: [format.when(item.createdAt), reason].compactMap { $0 }.joined(separator: " · "),
                isRetrying: retrying.contains(item.id), error: errors[item.id])
        }
    }

    /// The Dismiss All confirmation's title.
    var confirmTitle: String {
        rows.count == 1 ? "Dismiss 1 action? It won't be sent." : "Dismiss \(rows.count) actions? They won't be sent."
    }

    /// A failed Retry's message: the keychain locked, or anything else.
    static func retryErrorText(_ error: Error) -> String {
        if case KeyStoreError.locked? = error as? KeyStoreError {
            return lockedRetryError
        }
        return otherRetryError
    }

    var toneUses: [ToneUse] {
        rows.flatMap { row in
            [ToneUse(element: "not delivered \(row.id) retry", tone: row.isRetrying ? .secondary : .accent, role: .info)]
                + (row.error.map { _ in [ToneUse(element: "not delivered \(row.id) error", tone: .secondary, role: .info)] } ?? [])
        } + [ToneUse(element: "dismiss all", tone: .red, role: .status)]
    }
}

/// One Not delivered row: the summary, "Today 09:58" (plus " · No answer from Work Mac for 24 hours" for a
/// withdrawn one), and a failed retry's message.
struct NotDeliveredRow: Equatable, Identifiable {
    let id: String
    let summary: String
    let detail: String
    let isRetrying: Bool
    let error: String?
}
