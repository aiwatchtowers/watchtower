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
    /// "Mac online · 12s", "Mac offline · 13m" or "Mac not connected".
    let macChip: String
    let waitingHeaderTone = PhoneTone.waitingForYou

    init(snapshot: WorkbenchReplicaSnapshot, now: Date) {
        macStatus = MacStatus(heartbeat: snapshot.heartbeat, now: now)
        let open = snapshot.openAsks()
        waiting = open.prefix(Self.waitingLimit).map { WaitingCardModel($0, snapshot: snapshot, now: now, showWorkbench: true) }
        waitingMore = max(0, open.count - Self.waitingLimit)
        emptyText = open.isEmpty ? "Nothing is waiting for you" : nil
        sessionChips = SessionStateCount.list(SessionStateCount.sum(snapshot.workbenches.map(\.sessionCounts)))
        let age = snapshot.heartbeat.map { " · \(CompactAge.string(from: $0.updatedAt, now: now))" } ?? ""
        macChip = switch macStatus {
        case .notConnected: "Mac not connected"
        case .online: "Mac online" + age
        case .offline: "Mac offline" + age
        }
    }

    var macChipTone: PhoneTone {
        if case .online = macStatus { return .green }
        return .secondary
    }

    var toneUses: [ToneUse] {
        [
            ToneUse(element: "mac chip", tone: macChipTone, role: .mac),
            ToneUse(element: "waiting header", tone: waitingHeaderTone, role: .waiting)
        ]
            + waiting.map(\.toneUse)
            + sessionChips.map(\.toneUse)
    }
}
