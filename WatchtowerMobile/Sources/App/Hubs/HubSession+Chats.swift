import Foundation
import os
import WatchtowerSync

private let chatsLogger = Logger(subsystem: "WatchtowerMobile", category: "HubSession")

// MARK: - The hub's chats (iPhone chat spec §6)

extension HubSession {
    /// This hub's chats: the outbox sender, the upload ledger (sealed files in temp) and the copy (in memory without one).
    static func makeChats(
        outbox: ActionOutbox, secure: SecureTransport, hubID: String, copyPath: String?
    ) -> (ChatsCenter, ChatUploadLedger) {
        let ledger = ChatUploadLedger(transport: secure, directory: ChatUploadLedger.directory(hubID: hubID))
        let (copy, copyUnavailable) = openChatCopy(path: copyPath)
        let uploads = ChatUploads { payload, file in try await ledger.upload(payload, file: file) }
        let staging = ChatAttachmentPrep.stagingDirectory(hubID: hubID)
        let withdraw: ChatWithdraw = { id in
            do {
                return try await outbox.withdraw(actionID: id)
            } catch {
                chatsLogger.warning("chat action not withdrawn: \(String(describing: type(of: error)), privacy: .public)")
                return .onItsWay
            }
        }
        let center = ChatsCenter(
            sender: .through(outbox), uploads: uploads, copy: copy, copyUnavailable: copyUnavailable, withdraw: withdraw, staging: staging
        )
        return (center, ledger)
    }

    /// The hub's chat copy at `path`. One that does not open leaves the tab on an in-memory copy, with
    /// `unavailable` set so the tab says chats are not kept offline; no path (the demo) is not unavailable.
    static func openChatCopy(path: String?) -> (copy: ChatOfflineCopy?, unavailable: Bool) {
        guard let path else { return (nil, false) }
        do {
            return (try ChatOfflineCopy(path: path), false)
        } catch {
            chatsLogger.error("chat copy did not open: \(String(describing: type(of: error)), privacy: .public)")
            return (nil, true)
        }
    }

    /// The hub answers chat now: its heartbeat is fresh and offers chat, and on the relay the relay answers.
    func chatsReachable(now: Date) -> Bool {
        guard let beat = workbenchReplica.snapshot.heartbeat, beat.chatOffered,
              MacStatus.isOnline(lastHeartbeat: beat.updatedAt, now: now) else { return false }
        return relayUnansweredSince == nil
    }
}
