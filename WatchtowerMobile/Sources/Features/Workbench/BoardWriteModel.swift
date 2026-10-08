import Foundation
import WatchtowerKit
import WatchtowerSync

/// The fixed texts of the board writes (spec §6.3, §9).
enum BoardWriteText {
    static let groupCaption = "A group's status follows its sub-tasks"
    static let waitingForMac = "Waiting for your Mac"
    static let sending = "Sending…"
    /// Shown when the Mac refused a change without saying why.
    static let genericFailure = "Your Mac could not make this change"

    /// Why a write could not even be queued.
    static func sendError(_ error: Error) -> String {
        if case ActionOutboxError.notLinked? = error as? ActionOutboxError {
            return "This phone is not linked to a Mac yet."
        }
        return error.localizedDescription
    }
}

extension MacStatus {
    /// The heartbeat is fresh; a phone write is applied within a fetch or two.
    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}

extension BoardRowModel {
    static func priorityName(_ priority: WorkbenchTargetPriority) -> String {
        switch priority {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        default: priority.rawValue
        }
    }
}

/// A target's status or priority picker. `selection` is the requested
/// value while a write is pending, else the replica's.
struct BoardFieldPicker<Value: Hashable>: Equatable {
    let selection: Value
    let options: [Value]
    let isEnabled: Bool
    /// Why the picker is disabled, when that needs saying.
    let caption: String?
}

/// One board write the Mac has not applied yet: a pending action (with
/// "Waiting for your Mac" while the heartbeat is stale, else "Sending…"), a
/// refusal with the hub's message, or a conflict offering "apply anyway".
struct BoardWriteRow: Equatable, Identifiable {
    enum State: Equatable {
        case sending(String)
        case failed(String)
        case conflict(prompt: String)
    }

    var id: String { pending.id }
    /// What the write asks for: "Status → Done", a comment's body, a new
    /// target's title.
    let title: String
    let state: State
    /// A conflict's current value on the Mac, raw (`blocked`, `medium`).
    let conflictCurrent: String?
    let pending: PendingAction

    /// nil for an action that is not a board write.
    init?(_ pending: PendingAction, macOnline: Bool) {
        let params = pending.action.params
        var label: ((String) -> String)?
        switch pending.action.kind {
        case .boardTargetStatus:
            guard let request = try? BoardTargetStatusParams(wireParams: params) else { return nil }
            title = "Status → \(BoardRowModel.statusLabel(request.status))"
            label = { BoardRowModel.statusLabel(WorkbenchTargetStatus(rawValue: $0)) }
        case .boardTargetPriority:
            guard let request = try? BoardTargetPriorityParams(wireParams: params) else { return nil }
            title = "Priority → \(BoardRowModel.priorityName(request.priority))"
            label = { BoardRowModel.priorityName(WorkbenchTargetPriority(rawValue: $0)) }
        case .boardCommentAdd:
            guard let request = try? BoardCommentAddParams(wireParams: params) else { return nil }
            title = request.body
        case .boardCommentReply:
            guard let request = try? BoardCommentReplyParams(wireParams: params) else { return nil }
            title = request.body
        case .boardTargetCreate:
            guard let request = try? BoardTargetCreateParams(wireParams: params) else { return nil }
            title = request.text
        default:
            return nil
        }
        self.pending = pending
        switch pending.state {
        case .pending:
            state = .sending(macOnline ? BoardWriteText.sending : BoardWriteText.waitingForMac)
            conflictCurrent = nil
        case .failed:
            if pending.reason == .conflict, let label, case let .string(current)? = pending.result?["current"] {
                state = .conflict(prompt: "Changed on the Mac to \(label(current)) — apply anyway?")
                conflictCurrent = current
            } else {
                let message = pending.errorMessage.flatMap { $0.isEmpty || $0 == ActionOutbox.noMessageFallback ? nil : $0 }
                state = .failed(message ?? BoardWriteText.genericFailure)
                conflictCurrent = nil
            }
        }
    }

    var isPending: Bool {
        if case .sending = state { return true }
        return false
    }

    /// The board writes in `snapshot`'s overlay that match, oldest first.
    static func rows(
        in snapshot: WorkbenchReplicaSnapshot, now: Date, where include: (PendingAction) -> Bool
    ) -> [Self] {
        let online = MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline
        return snapshot.pending.filter(include).compactMap { Self($0, macOnline: online) }
    }
}

/// The comment composer's text: at most 4000 characters (the hub's cap),
/// and never sent when it is only whitespace.
struct CommentDraft: Equatable {
    static let limit = 4_000

    var text = "" {
        didSet {
            if text.count > Self.limit { text = String(text.prefix(Self.limit)) }
        }
    }

    var canSend: Bool { Self.trimmed(text) != nil }

    /// The text to send, trimmed; nil when nothing is left.
    static func trimmed(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The New target sheet's fields. The title is capped at 200 Unicode
/// scalars, as the hub counts it (Go runes), dropping whole graphemes; the
/// intent at 4000 characters.
struct NewBoardTargetDraft: Equatable {
    struct ParentOption: Equatable, Identifiable {
        let id: Int64
        let label: String
    }

    static let titleLimit = 200
    static let intentLimit = 4_000

    let workbenchID: Int64
    var parentID: Int64?
    var title = "" {
        didSet {
            if title.unicodeScalars.count > Self.titleLimit { title = Self.capTitle(title) }
        }
    }
    var intent = "" {
        didSet {
            if intent.count > Self.intentLimit { intent = String(intent.prefix(Self.intentLimit)) }
        }
    }
    var priority = WorkbenchTargetPriority.medium

    init(workbenchID: Int64, parentID: Int64? = nil) {
        self.workbenchID = workbenchID
        self.parentID = parentID
    }

    var canCreate: Bool { CommentDraft.trimmed(title) != nil }

    /// The `board_target_create` params; nil while the title is empty.
    func params() throws -> [String: JSONValue]? {
        guard let text = CommentDraft.trimmed(title) else { return nil }
        let intent = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        return try BoardTargetCreateParams(
            workbenchID: workbenchID, parentID: parentID, text: text, intent: intent, priority: priority
        ).wireParams()
    }

    /// The longest prefix of whole graphemes within 200 scalars.
    static func capTitle(_ text: String) -> String {
        var scalars = 0
        var end = text.startIndex
        for index in text.indices {
            scalars += text[index].unicodeScalars.count
            guard scalars <= titleLimit else { break }
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    /// The parents a new target may go under: this workbench's targets
    /// that are not archived, in board order, each followed by its
    /// sub-targets.
    static func parentOptions(workbenchID: Int64, snapshot: WorkbenchReplicaSnapshot) -> [ParentOption] {
        let live = snapshot.targets.filter { $0.workbenchID == workbenchID && !$0.archived }
        let ids = Set(live.map(\.id))
        let children = Dictionary(grouping: live.filter { $0.parentID.map(ids.contains) == true }) { $0.parentID ?? 0 }
        var options: [ParentOption] = []
        var seen = Set<Int64>()
        func visit(_ target: WorkbenchTarget) {
            guard seen.insert(target.id).inserted else { return }
            options.append(ParentOption(id: target.id, label: "#\(target.id) \(target.text)"))
            (children[target.id] ?? []).sorted(by: BoardModel.boardOrder).forEach(visit)
        }
        live.filter { $0.parentID.map(ids.contains) != true }.sorted(by: BoardModel.boardOrder).forEach(visit)
        return options
    }
}
