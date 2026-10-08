import Foundation
import WatchtowerKit

/// The Now tab (spec §13 B2): the Mac chip, Waiting for you across every
/// workbench (newest first, 20 shown) and the session summary chips. The
/// next meeting card comes with sub-project C.
struct NowModel {
    static let waitingLimit = 20

    let macStatus: MacStatus
    let waiting: [WaitingCardModel]
    /// Open asks past the first 20.
    let waitingMore: Int
    /// "Nothing is waiting for you" when no ask is open.
    let emptyText: String?
    let sessionChips: [SessionStateCount]

    init(snapshot: WorkbenchReplicaSnapshot, now: Date) {
        macStatus = MacStatus(heartbeat: snapshot.heartbeat, now: now)
        let open = snapshot.openAsks()
        waiting = open.prefix(Self.waitingLimit).map { WaitingCardModel($0, snapshot: snapshot, now: now, showWorkbench: true) }
        waitingMore = max(0, open.count - Self.waitingLimit)
        emptyText = open.isEmpty ? "Nothing is waiting for you" : nil
        sessionChips = SessionStateCount.list(SessionStateCount.sum(snapshot.workbenches.map(\.sessionCounts)))
    }

    var macChip: String {
        switch macStatus {
        case .notConnected: "Mac not connected"
        case .online: "Mac online"
        case .offline: "Mac offline"
        }
    }

    var macChipTone: PhoneTone {
        if case .online = macStatus { return .green }
        return .secondary
    }

    var toneUses: [ToneUse] {
        [ToneUse(element: "mac chip", tone: macChipTone, isWaitingOrAsk: false)]
            + waiting.map(\.toneUse)
            + sessionChips.map(\.toneUse)
    }
}
