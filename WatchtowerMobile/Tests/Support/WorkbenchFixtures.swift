import Foundation
import WatchtowerKit
import WatchtowerSync
@testable import WatchtowerMobile

/// Decodes a hub-shaped JSON payload into a Kit mirror, the way the replica
/// read does (the mirrors have no public inits).
func mirror<T: SliceMirror>(_ type: T.Type, _ json: [String: Any]) throws -> T {
    try T.decode(payload: JSONSerialization.data(withJSONObject: json))
}

/// The demo seed's Workbench slices decoded into one snapshot, as the
/// screens see it after a hydrate.
func demoSnapshot(now: Date) throws -> WorkbenchReplicaSnapshot {
    var snapshot = WorkbenchReplicaSnapshot()
    for (kind, json) in DemoSeed.workbenchSlices(now: now) {
        switch kind {
        case .workbench: snapshot.workbenches.append(try mirror(Workbench.self, json))
        case .workbenchTarget: snapshot.targets.append(try mirror(WorkbenchTarget.self, json))
        case .terminalSession: snapshot.sessions.append(try mirror(TerminalSessionState.self, json))
        case .ownerAsk: snapshot.asks.append(try mirror(OwnerAsk.self, json))
        case .workbenchComment: snapshot.comments.append(try mirror(WorkbenchComment.self, json))
        default: break
        }
    }
    return snapshot
}
