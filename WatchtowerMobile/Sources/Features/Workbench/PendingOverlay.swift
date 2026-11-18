import Foundation
import WatchtowerKit
import WatchtowerSync

/// One write the phone shows at tap time before the replica does (live link R5): a moved or re-prioritised card, a
/// new target, a comment, an answered ask. Keyed by the action id; marked pending until the replica shows the
/// expected effect. The echo (mailbox zone) and the slice record (data zone) arrive in either order, so the echo
/// alone never clears one.
struct PendingOverlay: Equatable, Identifiable {
    enum Kind: Equatable {
        case create, comment, status, priority, askAnswer
    }

    /// What the replica shows once the write is applied.
    enum Expected: Equatable {
        case create(workbenchID: Int64, parentID: Int64?, title: String, priority: WorkbenchTargetPriority)
        /// On a target (`entityID`), or a reply under the root comment `entityID`.
        case comment(body: String, isReply: Bool)
        case status(WorkbenchTargetStatus)
        case priority(WorkbenchTargetPriority)
        /// The ask (`entityID`) is no longer open; `label` names the answer sent ("Approved", the picked options),
        /// nil when it has no option to name.
        case askAnswer(label: String?)
    }

    /// The tower's `applied` echo: when it came, the new record's id (`target_id` / `comment_id`) for a create.
    struct Echo: Equatable {
        let at: Date
        let createdID: Int64?
        /// The entity's record when the echo came (an overlay not reconciled yet learns it at its next pass): a
        /// later different record means the change was overtaken.
        var baseline: Seen?
    }

    /// An entity's record as one reconcile pass saw it; nil inside: the replica had none.
    struct Seen: Equatable {
        let record: AnyHashable?
    }

    /// After an `applied` echo whose effect never shows, the overlay goes.
    static let appliedWait: TimeInterval = 30
    /// With no echo for this long (an offline tower) the overlay goes and today's pending row takes over.
    static let expiry: TimeInterval = 600

    let actionID: String
    let hubID: String
    /// The target, ask or root comment the write changes; nil for a create.
    let entityID: Int64?
    let expected: Expected
    /// The tap.
    let createdAt: Date
    var echo: Echo?
    /// The entity's record at the last reconcile pass (change kinds).
    var seen: Seen?
    /// A create's or comment's same-content records that predate the tap, learnt at its first pass: only a newer
    /// one hides the overlay.
    var earlierMatches: Set<Int64>?
    /// A newer write to the same field whose save is still running: this overlay is no longer shown, and comes
    /// back only if that save throws.
    var supersededBy: String?

    var id: String { actionID }

    var kind: Kind {
        switch expected {
        case .create: .create
        case .comment: .comment
        case .status: .status
        case .priority: .priority
        case .askAnswer: .askAnswer
        }
    }

    /// Today's captions: "Waiting for your tower" while no echo came and the heartbeat is stale, else "Sending…"
    /// (an applied write waits only for its slice record).
    func caption(macOnline: Bool) -> BoardWriteRow.State {
        .sending(echo == nil && !macOnline ? BoardWriteText.waitingForMac : BoardWriteText.sending)
    }

    /// When a pass next drops it by time alone.
    var deadline: Date {
        let expires = createdAt.addingTimeInterval(Self.expiry)
        guard let echo else { return expires }
        return min(expires, echo.at.addingTimeInterval(Self.appliedWait))
    }
}

/// One tower's overlays (one per `HubSession`, so towers never mix). Written by the board writer and the ask
/// answerer at tap time and by the outbox's applied echoes; read by the replica model, whose every snapshot passes
/// through `reconcile` (spec R5's rules). In memory only: a relaunch starts empty and today's pending rows show.
@MainActor
final class OverlayBook {
    let hubID: String
    /// Every overlay, a hidden create or comment (its record already showing, unconfirmed) included; oldest first.
    private(set) var overlays: [PendingOverlay] = []
    /// The hidden creates and comments of the last `reconcile`, each with the record that shows for it: their
    /// pending rows do not show where that record does.
    private(set) var matched: [String: Int64] = [:]
    /// Records a confirmed create or comment took (its echo named them), kept while another write of that kind is
    /// outstanding, so a twin with the same content never takes one.
    private var confirmed = Claims(targets: [], comments: [])
    /// Called after `add` and `receiveEcho`: the replica model reconciles again.
    var onChange: (() -> Void)?

    /// Tap time per action, kept past its overlay (the slice may clear it before the echo) until the echo or the
    /// overlay's expiry: `confirm_ms` is tap → applied echo.
    private var taps: [String: (kind: ActionKind, at: Date)] = [:]
    private let recordConfirm: (ActionKind, Int, Date) -> Void

    /// `recordConfirm(kind, ms, at)`: a tap → `applied` echo timing, stamped when the echo arrived (spec R7).
    init(hubID: String, recordConfirm: @escaping (ActionKind, Int, Date) -> Void = { _, _, _ in }) {
        self.hubID = hubID
        self.recordConfirm = recordConfirm
    }

    /// An overlay of this tower.
    func overlay(actionID: String, entityID: Int64?, expected: PendingOverlay.Expected, createdAt: Date) -> PendingOverlay {
        PendingOverlay(actionID: actionID, hubID: hubID, entityID: entityID, expected: expected, createdAt: createdAt)
    }

    /// Adds a write's overlay at the tap; it shows at once. An older overlay of the same status, priority or answer
    /// is set aside (not shown) while the newer save runs: `remove` brings it back if that save throws, `supersede`
    /// deletes it once the save is queued.
    func add(_ overlay: PendingOverlay) {
        guard overlay.hubID == hubID, !overlays.contains(where: { $0.actionID == overlay.actionID }) else { return }
        for index in overlays.indices where Self.sameField(overlays[index], overlay) && overlays[index].supersededBy == nil {
            overlays[index].supersededBy = overlay.actionID
        }
        overlays.append(overlay)
        taps[overlay.actionID] = (Self.actionKind(overlay), overlay.createdAt)
        onChange?()
    }

    /// The newest write to a field wins: once `overlay`'s save is queued, the older overlays of the same status,
    /// priority or answer go (their timings still count).
    func supersede(by overlay: PendingOverlay) {
        let before = overlays.count
        overlays.removeAll { $0.supersededBy == overlay.actionID }
        if overlays.count != before { onChange?() }
    }

    /// Takes back the overlay of a write that was never queued (its save threw); an older write it set aside
    /// shows again.
    func remove(actionID: String) {
        taps[actionID] = nil
        guard overlays.contains(where: { $0.actionID == actionID }) else { return }
        overlays.removeAll { $0.actionID == actionID }
        for index in overlays.indices where overlays[index].supersededBy == actionID {
            overlays[index].supersededBy = nil
        }
        onChange?()
    }

    /// Two writes to the same status, priority or answer of one entity.
    private static func sameField(_ lhs: PendingOverlay, _ rhs: PendingOverlay) -> Bool {
        guard let entity = rhs.entityID, [.status, .priority, .askAnswer].contains(rhs.kind) else { return false }
        return lhs.entityID == entity && lhs.kind == rhs.kind && lhs.actionID != rhs.actionID
    }

    /// The outbox's echo of one of this tower's actions: `applied` keeps the new record's id and times the tap; a
    /// refusal (also seen in the replica as a failed row) drops the overlay at once. Other actions are not ours.
    func receiveEcho(_ action: ActionRequestPayload, now: Date) {
        switch action.status {
        case .applied:
            if let tap = taps.removeValue(forKey: action.id) {
                recordConfirm(tap.kind, Int((now.timeIntervalSince(tap.at) * 1000).rounded()), now)
            }
            guard let index = overlays.firstIndex(where: { $0.actionID == action.id }), overlays[index].echo == nil else { return }
            let key = overlays[index].kind == .comment ? "comment_id" : "target_id"
            var createdID: Int64?
            if case let .integer(id)? = action.result?[key] { createdID = id }
            overlays[index].echo = PendingOverlay.Echo(at: now, createdID: createdID, baseline: overlays[index].seen)
        case .failed, .expired, .cancelled:
            taps[action.id] = nil
            guard overlays.contains(where: { $0.actionID == action.id }) else { return }
            overlays.removeAll { $0.actionID == action.id }
        case .pending, .received, .held:
            return
        }
        onChange?()
    }

    /// Applies spec R5 to `snapshot` (the replica, no overlays applied): drops each overlay the replica already
    /// shows, refused, overtaken or out of time; returns the ones to show, oldest first.
    func reconcile(with snapshot: WorkbenchReplicaSnapshot, now: Date) -> [PendingOverlay] {
        let refused = Set(snapshot.pending.filter { $0.state == .failed }.map(\.id))
        var kept: [PendingOverlay] = []
        var shown: [PendingOverlay] = []
        var hidden: [String: Int64] = [:]
        // A record an echo named belongs to that write, also after the write is done; each other record matches at
        // most one write.
        var claims = Claims(
            targets: confirmed.targets.union(overlays.filter { $0.kind == .create }.compactMap { $0.echo?.createdID }),
            comments: confirmed.comments.union(overlays.filter { $0.kind == .comment }.compactMap { $0.echo?.createdID }))
        // A write that set an older one aside stays until its own echo or slice, even when the replica already
        // shows its value (a reversal): the older value is still on its way.
        let superseding = Set(overlays.compactMap(\.supersededBy))
        for var overlay in overlays {
            guard !refused.contains(overlay.actionID), now < overlay.deadline else { continue }
            if overlay.supersededBy != nil {
                kept.append(overlay)
                continue
            }
            switch Self.state(of: &overlay, in: snapshot, claims: &claims, superseding: superseding.contains(overlay.actionID)) {
            case .done:
                if let id = overlay.echo?.createdID {
                    if overlay.kind == .create { confirmed.targets.insert(id) }
                    if overlay.kind == .comment { confirmed.comments.insert(id) }
                }
                continue
            case let .hidden(record):
                hidden[overlay.actionID] = record
                kept.append(overlay)
            case .live:
                kept.append(overlay)
                shown.append(overlay)
            }
        }
        overlays = kept
        matched = hidden
        if !kept.contains(where: { $0.kind == .create }) { confirmed.targets = [] }
        if !kept.contains(where: { $0.kind == .comment }) { confirmed.comments = [] }
        taps = taps.filter { now.timeIntervalSince($0.value.at) < PendingOverlay.expiry }
        return shown
    }

    /// The earliest time a pass drops an overlay by time alone; nil without overlays.
    var nextDeadline: Date? {
        overlays.map(\.deadline).min()
    }

    private enum State {
        /// `hidden`: the record that shows for the write.
        case live, hidden(Int64), done
    }

    /// Records already matched to a write in this pass, per kind.
    private struct Claims {
        var targets: Set<Int64>
        var comments: Set<Int64>
    }

    private static func state(
        of overlay: inout PendingOverlay, in snapshot: WorkbenchReplicaSnapshot, claims: inout Claims, superseding: Bool
    ) -> State {
        switch overlay.expected {
        case let .status(status):
            let target = snapshot.targets.first { $0.id == overlay.entityID }
            return change(&overlay, record: target, shows: !superseding && (target.map { $0.status == status } ?? true))
        case let .priority(priority):
            let target = snapshot.targets.first { $0.id == overlay.entityID }
            return change(&overlay, record: target, shows: !superseding && (target.map { $0.priority == priority } ?? true))
        case .askAnswer:
            let ask = snapshot.asks.first { $0.id == overlay.entityID }
            return change(&overlay, record: ask, shows: !superseding && (ask.map { $0.status != .open } ?? true))
        case let .create(workbenchID, parentID, title, _):
            let ids = snapshot.targets.map(\.id)
            let matches = snapshot.targets
                .filter { $0.workbenchID == workbenchID && $0.parentID == parentID && $0.text == title }
                .map(\.id)
            return created(&overlay, ids: ids, matches: matches, claimed: &claims.targets)
        case let .comment(body, isReply):
            let matches = snapshot.comments
                .filter { $0.body == body && (isReply ? $0.parentID == overlay.entityID : $0.targetID == overlay.entityID && $0.parentID == nil) }
                .map(\.id)
            return created(&overlay, ids: snapshot.comments.map(\.id), matches: matches, claimed: &claims.comments)
        }
    }

    /// A change of an existing entity: done once the replica shows it, or, after the echo, at the entity's first
    /// different record (overtaken); the 30 s wait is the deadline.
    private static func change<Record: Hashable>(_ overlay: inout PendingOverlay, record: Record?, shows: Bool) -> State {
        guard !shows else { return .done }
        let seen = PendingOverlay.Seen(record: record.map(AnyHashable.init))
        overlay.seen = seen
        if overlay.echo != nil {
            guard let baseline = overlay.echo?.baseline else {
                overlay.echo?.baseline = seen
                return .live
            }
            if baseline != seen { return .done }
        }
        return .live
    }

    /// A create or a comment: done once the echo's id has a record; before the echo, the oldest same-content
    /// record newer than the tap that no other write claimed hides it (no duplicate) until the echo confirms. Two
    /// writes with the same content need two records.
    private static func created(
        _ overlay: inout PendingOverlay, ids: [Int64], matches: [Int64], claimed: inout Set<Int64>
    ) -> State {
        if let echo = overlay.echo {
            guard let id = echo.createdID else { return .live }
            return ids.contains(id) ? .done : .live
        }
        let earlier = overlay.earlierMatches ?? Set(matches)
        overlay.earlierMatches = earlier
        guard let match = matches.filter({ !earlier.contains($0) && !claimed.contains($0) }).min() else { return .live }
        claimed.insert(match)
        return .hidden(match)
    }

    private static func actionKind(_ overlay: PendingOverlay) -> ActionKind {
        switch overlay.expected {
        case .create: .boardTargetCreate
        case let .comment(_, isReply): isReply ? .boardCommentReply : .boardCommentAdd
        case .status: .boardTargetStatus
        case .priority: .boardTargetPriority
        case .askAnswer: .askAnswer
        }
    }
}

extension PendingOverlay {
    /// The answer an `askAnswer` overlay sends; nil for any other kind or an answer with no option to name.
    var answerLabel: String? {
        if case let .askAnswer(label) = expected { return label }
        return nil
    }
}

extension WorkbenchReplicaSnapshot {
    /// This replica with `overlays` (a `reconcile` result) shown: a moved or re-prioritised target carries the
    /// requested value. New targets are not records yet: the board draws them from `overlays`; so does an answered
    /// ask's line. `matched`: the writes whose records already show (`OverlayBook.matched`), whose pending rows go.
    func applying(_ overlays: [PendingOverlay], matched: [String: Int64] = [:]) -> Self {
        var shown = self
        shown.overlays = overlays
        shown.matchedRecords = matched
        guard !overlays.isEmpty else { return shown }
        shown.targets = targets.map { target in
            overlays.reduce(target) { target, overlay in
                guard overlay.entityID == target.id else { return target }
                switch overlay.expected {
                case let .status(status): return target.overlaid(status: status)
                case let .priority(priority): return target.overlaid(priority: priority)
                default: return target
                }
            }
        }
        return shown
    }

    /// The newest shown overlay of a status or priority write on the target.
    func fieldOverlay(on targetID: Int64) -> PendingOverlay? {
        overlays.last { $0.entityID == targetID && [.status, .priority].contains($0.kind) }
    }

    /// The live overlay of an answer to the ask: it is shown as sent.
    func answerOverlay(_ askID: Int64) -> PendingOverlay? {
        overlays.last { $0.kind == .askAnswer && $0.entityID == askID }
    }

    /// The ask's newest `ask_answer` row, unless a live answer overlay is newer (a resend after a refusal, before
    /// its row exists): then the overlay decides and this is nil.
    func answerRow(_ askID: Int64) -> PendingAction? {
        let entity = AskAnswerer.recordName(askID)
        guard let row = pending.last(where: { $0.action.kind == .askAnswer && $0.entityRecordName == entity }) else { return nil }
        if let overlay = answerOverlay(askID), overlay.actionID != row.id, overlay.createdAt > row.action.createdAt { return nil }
        return row
    }

    /// Today's caption of a write on its way ("Sending…" / "Waiting for your tower"), with the answer it sends
    /// after the meta separator when there is one (live link R5, mockup 6).
    static func sendingCaption(_ caption: String, answer label: String?) -> String {
        label.map { "\(caption) · \($0)" } ?? caption
    }
}
