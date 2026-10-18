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

/// A hub-shaped `permission_request` payload (#517): a pending prompt of
/// `session`.
func permissionRequestJSON(
    _ id: Int64, session: Int64, workbench: Int64 = DemoSeed.acmeID, _ overrides: [String: Any] = [:]
) -> [String: Any] {
    var json: [String: Any] = [
        "id": id, "session_id": session, "workbench_id": workbench, "tool_name": "Bash",
        "summary": "go test ./...\nRun the tests", "created_at": DemoSeed.JSON.stamp(Date())
    ]
    json.merge(overrides) { _, new in new }
    return json
}
