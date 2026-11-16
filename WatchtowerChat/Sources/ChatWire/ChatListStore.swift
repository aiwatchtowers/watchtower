import Foundation
import Observation

/// The conversation list as the updates leave it. A resync keeps the last list on screen, marked stale until the
/// next snapshot.
@MainActor
@Observable
public final class ChatListStore {
    public private(set) var list: ChatList?
    /// Events were lost since `list`: the next snapshot clears it.
    public private(set) var isStale = false

    public init(list: ChatList? = nil) {
        self.list = list
    }

    public func apply(_ update: ChatListUpdate) {
        switch update {
        case .snapshot(let snapshot):
            list = snapshot
            isStale = false
        case .resync:
            isStale = list != nil
        }
    }
}
