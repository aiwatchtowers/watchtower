import ChatWire
import CryptoKit
import Foundation
import WatchtowerKit
import WatchtowerSync

// The Kit-only conformances of ChatWire's chat models (unified chat spec §14): ChatWire imports nothing of ours and
// the Kit does not depend on it, so the relay's slice kinds, record names and action kinds join the models here, in
// the one target that links both. Pinned by ChatWireKitConformancesTests.

extension ChatFeed: @retroactive SliceMirror {
    public static let sliceKind = SliceKind.chatFeed

    /// `chat_feed-<conversation id>`.
    static func recordName(conversationID: Int64) -> String {
        SliceKind.chatFeed.recordName(id: "\(conversationID)")
    }
}

extension ChatList: @retroactive SliceMirror {
    public static let sliceKind = SliceKind.chatList
    /// The one record's id.
    static let recordID = "main"

    /// `chat_list-main`.
    static var recordName: String { SliceKind.chatList.recordName(id: recordID) }
}

extension ChatPage: @retroactive SliceMirror {
    public static let sliceKind = SliceKind.chatPage

    /// `chat_page-<conversation id>-<before message id>`.
    static func recordName(conversationID: Int64, beforeMessageID: Int64) -> String {
        SliceKind.chatPage.recordName(id: "\(conversationID)-\(beforeMessageID)")
    }
}

extension ChatSearch: @retroactive SliceMirror {
    public static let sliceKind = SliceKind.chatSearch

    /// `chat_search-<the first 16 hex digits of sha256(query)>`, over the query exactly as sent (Go
    /// `sources.ChatSearchID`).
    static func recordName(query: String) -> String {
        let hex = SHA256.hash(data: Data(query.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return SliceKind.chatSearch.recordName(id: hex)
    }
}

extension ChatNewParams: @retroactive ActionParams {
    public static let actionKind = ActionKind.chatNew
}

extension ChatTurnParams: @retroactive ActionParams {
    public static let actionKind = ActionKind.chatTurn
}

extension ChatCancelParams: @retroactive ActionParams {
    public static let actionKind = ActionKind.chatCancel
}

extension ChatFeedRequestParams: @retroactive ActionParams {
    public static let actionKind = ActionKind.chatFeedRequest
}

extension ChatPageParams: @retroactive ActionParams {
    public static let actionKind = ActionKind.chatPage
}

extension ChatSearchParams: @retroactive ActionParams {
    public static let actionKind = ActionKind.chatSearch
}

extension ChatReadParams: @retroactive ActionParams {
    public static let actionKind = ActionKind.chatRead
}

extension ChatBranchSelectParams: @retroactive ActionParams {
    public static let actionKind = ActionKind.chatBranchSelect
}

extension ChatManageParams: @retroactive ActionParams {
    public static let actionKind = ActionKind.chatManage
}

extension ChatActionAnswerParams: @retroactive ActionParams {
    public static let actionKind = ActionKind.chatActionAnswer
}

extension ChatEntitySearchParams: @retroactive ActionParams {
    public static let actionKind = ActionKind.chatEntitySearch
}

extension ChatSkillsListParams: @retroactive ActionParams {
    public static let actionKind = ActionKind.chatSkillsList
}
