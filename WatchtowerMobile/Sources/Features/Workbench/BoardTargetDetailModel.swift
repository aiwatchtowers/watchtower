import Foundation
import WatchtowerKit
import WatchtowerSync

/// A board target's detail: breadcrumb, status and priority pickers,
/// progress, intent, branch and PR, sub-targets, linked sessions, open asks,
/// the comment threads and the phone's own writes not yet applied. An
/// archived target is read-only on the phone (a POC choice: Archive stays a
/// read view, though the hub would accept the writes).
struct BoardTargetDetailModel {
    struct Crumb: Equatable, Identifiable {
        let id: Int64
        let title: String
    }

    let id: Int64
    let target: WorkbenchTarget
    let title: String
    let statusLabel: String
    let row: BoardRowModel
    /// Ancestors, root first, as far as the replica has them.
    let breadcrumb: [Crumb]
    let isReadOnly: Bool
    let status: BoardFieldPicker<WorkbenchTargetStatus>
    let priority: BoardFieldPicker<WorkbenchTargetPriority>
    /// The phone's status and priority writes on this target.
    let writes: [BoardWriteRow]
    let intent: String
    let branch: String
    let pr: String
    let children: [BoardRowModel]
    /// "Sub-targets · 1 / 3".
    let childrenHeader: String
    let sessions: [SessionRowModel]
    let asks: [WaitingCardModel]
    let asksHeaderTone = PhoneTone.waitingForYou
    let comments: [CommentRow]
    let thread: [ThreadItem]
    /// `BoardWriter.inFlight` when the model was built.
    private let inFlight: Set<String>

    /// `inFlight` is `BoardWriter.inFlight`: a field or composer whose send
    /// is still on its way to the outbox is locked like a pending one.
    init?(targetID: Int64, snapshot: WorkbenchReplicaSnapshot, now: Date, inFlight: Set<String> = []) {
        guard let target = snapshot.targets.first(where: { $0.id == targetID }) else { return nil }
        id = target.id
        self.target = target
        title = target.text
        statusLabel = BoardRowModel.statusLabel(target.status)
        row = BoardRowModel(target, snapshot: snapshot)
        breadcrumb = Self.breadcrumb(of: target, in: snapshot)
        isReadOnly = target.archived
        intent = target.intent
        branch = target.branch
        pr = target.pr

        let entity = SliceKind.workbenchTarget.recordName(id: String(target.id))
        self.inFlight = inFlight
        let statusSending = inFlight.contains(BoardWriter.key(.boardTargetStatus, entity))
        let prioritySending = inFlight.contains(BoardWriter.key(.boardTargetPriority, entity))
        let fieldWrites = BoardWriteRow.rows(in: snapshot, now: now) {
            $0.entityRecordName == entity && [.boardTargetStatus, .boardTargetPriority].contains($0.action.kind)
        }
        writes = fieldWrites
        func pendingRequest(_ kind: ActionKind) -> [String: JSONValue]? {
            fieldWrites.last { $0.isPending && $0.pending.action.kind == kind }?.pending.action.params
        }
        let pendingStatus = pendingRequest(.boardTargetStatus).flatMap { try? BoardTargetStatusParams(wireParams: $0).status }
        let pendingPriority = pendingRequest(.boardTargetPriority).flatMap { try? BoardTargetPriorityParams(wireParams: $0).priority }
        let isGroup = target.childrenCount > 0
        status = BoardFieldPicker(
            selection: pendingStatus ?? target.status,
            options: Self.options(WorkbenchTargetStatus.editable, keeping: pendingStatus ?? target.status),
            isEnabled: !target.archived && !isGroup && pendingStatus == nil && !statusSending,
            caption: isGroup ? BoardWriteText.groupCaption : nil
        )
        priority = BoardFieldPicker(
            selection: pendingPriority ?? target.priority,
            options: Self.options(WorkbenchTargetPriority.knownValues, keeping: pendingPriority ?? target.priority),
            isEnabled: !target.archived && pendingPriority == nil && !prioritySending,
            caption: nil
        )

        // A live target's archived children stay under Archive.
        let childTargets = snapshot.targets
            .filter { $0.parentID == target.id && $0.archived == target.archived }
            .sorted(by: BoardModel.boardOrder)
        children = childTargets.map { BoardRowModel($0, snapshot: snapshot) }
        childrenHeader = "Sub-targets · \(childTargets.filter { $0.status == .done }.count) / \(childTargets.count)"
        sessions = target.sessionIDs.compactMap(snapshot.session).map { SessionRowModel($0, now: now) }
        asks = snapshot.openAsks(in: target.workbenchID)
            .filter { $0.targetID == target.id }
            .map { WaitingCardModel($0, snapshot: snapshot, now: now) }

        let commentThread = Self.commentThread(of: target, entity: entity, in: snapshot, now: now)
        comments = commentThread.comments
        thread = commentThread.thread
    }

    /// Whether the composer's send is still on its way to the outbox: a
    /// comment on this target, or a reply under `replyRoot`.
    func composerSending(replyRoot: Int64?) -> Bool {
        let key = if let replyRoot {
            BoardWriter.key(.boardCommentReply, SliceKind.workbenchComment.recordName(id: String(replyRoot)))
        } else {
            BoardWriter.key(.boardCommentAdd, SliceKind.workbenchTarget.recordName(id: String(id)))
        }
        return inFlight.contains(key)
    }

    /// The editable values, plus the shown one when it is not among them
    /// (a snoozed target), so the picker always has its selection.
    private static func options<Value: Hashable>(_ editable: [Value], keeping shown: Value) -> [Value] {
        editable.contains(shown) ? editable : editable + [shown]
    }

    private static func breadcrumb(of target: WorkbenchTarget, in snapshot: WorkbenchReplicaSnapshot) -> [Crumb] {
        let board = snapshot.targets.filter { $0.workbenchID == target.workbenchID }
        let byID = Dictionary(board.map { ($0.id, $0) }) { first, _ in first }
        var crumbs: [Crumb] = []
        var seen: Set<Int64> = [target.id]
        var cursor = target.parentID.flatMap { byID[$0] }
        while let parent = cursor, seen.insert(parent.id).inserted {
            crumbs.insert(Crumb(id: parent.id, title: parent.text), at: 0)
            cursor = parent.parentID.flatMap { byID[$0] }
        }
        return crumbs
    }

    var toneUses: [ToneUse] {
        row.toneUses + children.flatMap(\.toneUses) + sessions.flatMap(\.toneUses) + asks.map(\.toneUse)
            + (asks.isEmpty ? [] : [ToneUse(element: "target \(id) waiting header", tone: asksHeaderTone, role: .waiting)])
    }
}
