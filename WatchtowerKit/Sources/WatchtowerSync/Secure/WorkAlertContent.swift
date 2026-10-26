import Foundation

/// What the notification extension sets on a notification for an opened `WorkAlertPayload`: the fields the extension
/// copies onto its mutable content. Pure, so it is tested outside the extension.
public struct WorkAlertContent: Equatable, Sendable {
    public let title: String
    public let body: String
    /// Notifications of one session group together; an alert with no session groups by its workbench.
    public let threadID: String
    /// String-only, for the app to route a tap: hub, event, key, and the ids the event has.
    public let userInfo: [String: String]

    public init(payload: WorkAlertPayload, hubID: String) {
        title = payload.title
        body = payload.body
        threadID = payload.sessionID.map { "session-\($0)" } ?? "workbench-\(payload.workbenchID)"
        var info = ["wt_hub": hubID, "wt_event": payload.event.rawValue, "wt_key": payload.key]
        if let session = payload.sessionID { info["wt_session"] = String(session) }
        if let ask = payload.askID { info["wt_ask"] = String(ask) }
        userInfo = info
    }
}
