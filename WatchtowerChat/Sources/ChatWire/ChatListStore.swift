import Foundation
import Observation

/// The conversation list as the updates leave it; a resync clears it until the next snapshot.
@MainActor
@Observable
public final class ChatListStore {
    public private(set) var list: ChatList?

    public init(list: ChatList? = nil) {
        self.list = list
    }

    public func apply(_ update: ChatListUpdate) {
        switch update {
        case .snapshot(let snapshot):
            list = snapshot
        case .resync:
            list = nil
        }
    }
}
