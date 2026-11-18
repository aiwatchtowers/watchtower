import Foundation
import WatchtowerKit
import WatchtowerSync

extension AskFormModel {
    // MARK: - The answer on its way

    static func status(
        _ ask: OwnerAsk, snapshot: WorkbenchReplicaSnapshot, now: Date, applied: AppliedAnswer?
    ) -> Status {
        let entity = AskAnswerer.recordName(ask.id)
        let rows = snapshot.pending.filter { $0.action.kind == .askAnswer && $0.entityRecordName == entity }
        guard let row = rows.last else {
            if let applied { return .applied(applied.text) }
            // Live link R5: the echo removed the row and its delivery has not reached the answerer yet; while
            // the answer's overlay lives, the answer is still shown on its way, never as unanswered.
            guard snapshot.answerOverlaid(ask.id) else { return .none }
            return .sending(MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline ? BoardWriteText.sending : BoardWriteText.waitingForMac)
        }
        switch row.state {
        case .pending:
            let online = MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline
            return .sending(online ? BoardWriteText.sending : BoardWriteText.waitingForMac)
        case .failed:
            if row.reason == .askNotOpen {
                return .notOpen(AskText.notOpen(ask), rowID: row.id, successor: successor(of: ask.id, in: snapshot)?.id)
            }
            let message = row.errorMessage.flatMap { $0.isEmpty || $0 == ActionOutbox.noMessageFallback ? nil : $0 }
            return .failed(message ?? AskText.genericFailure, rowID: row.id)
        }
    }

    /// The newest round of a review chain after `askID` (`previous_ask_id`
    /// links), when it is open.
    static func successor(of askID: Int64, in snapshot: WorkbenchReplicaSnapshot) -> OwnerAsk? {
        var seen: Set<Int64> = [askID]
        var newest: OwnerAsk?
        var current = askID
        while let next = snapshot.asks.first(where: { $0.previousAskID == current }), seen.insert(next.id).inserted {
            newest = next
            current = next.id
        }
        return newest?.status == .open ? newest : nil
    }

    static func isPending(_ status: Status) -> Bool {
        if case .sending = status { return true }
        return false
    }

    static func isNotOpen(_ status: Status) -> Bool {
        if case .notOpen = status { return true }
        return false
    }
}
