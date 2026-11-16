import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Mac side of the iPhone chat (spec 2026-11-15 §5, mockups
/// `docs/design/mockups/iphone-chat/index.html` 4a and 4b), from the real
/// views: a turn the hub runs for the phone, seen in the open chat with the
/// composer's line and Stop (`chat-phone-turn`), and the Chat toggle in
/// Settings → Mobile (`settings-mobile-phone-chat`). Synthetic data only.
@MainActor
enum IPhoneChatShotFixtures {
    private static var database: (pool: DatabasePool, path: String)?
    private static var sessions: ChatSessionPool?

    static func cleanUp() {
        if let sessions { Task { await sessions.closeAll() } }
        sessions = nil
        if let database { TestDatabase.cleanup(path: database.path) }
        database = nil
    }

    static var shots: [DesignShot] {
        [
            DesignShot(name: "chat-phone-turn", size: NSSize(width: 640, height: 300)) { phoneTurn() },
            DesignShot(name: "settings-mobile-phone-chat", size: NSSize(width: 640, height: 640)) { settingsChat() }
        ]
    }

    /// 4a: the hub holds the open chat's lease; its partial answer is read
    /// from the database, the composer says where it runs and offers Stop.
    static func phoneTurn() -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            database = (pool, path)
            let nowMS = ChatLease.milliseconds(Date())
            let conv = try pool.write { db -> Int64 in
                let conv = try TestDatabase.insertChatConversation(db, title: "Q3 roadmap summary")
                let user = try TestDatabase.insertChatMessage(db, conversationID: conv, role: "user",
                                                              text: "Summarise the Q3 roadmap threads", turnID: "hub-turn")
                _ = try TestDatabase.insertChatMessage(db, conversationID: conv, role: "assistant",
                                                       text: "The roadmap has three threads", parentID: user,
                                                       status: "partial", turnID: "hub-turn")
                _ = try ChatLeaseQueries.claim(db, ChatLease(conversationID: conv, owner: .hub, ownerID: "hub-acme",
                                                             turnID: "hub-turn", startedAtMS: nowMS, heartbeatAtMS: nowMS),
                                               nowMS: nowMS)
                return conv
            }
            let sessionPool = ChatSessionPool(dbPool: pool) { FakeChatSessionProcess(arguments: $0) }
            sessions = sessionPool
            let defaults = UserDefaults(suiteName: DesignShotFixtures.defaultsSuite) ?? .standard
            let chatVM = ChatViewModel(dbManager: DatabaseManager(pool: pool), pool: sessionPool, defaults: defaults,
                                       attachmentsRoot: nil)
            chatVM.select(conversationID: conv)
            var read = false
            Task { @MainActor in
                await chatVM.refreshForeignTurn()
                read = true
            }
            let deadline = Date().addingTimeInterval(5)
            while !read, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertEqual(chatVM.foreignTurn.line, ChatForeignTurnModel.answeringFromPhone)
            let items = chatVM.thread
            return AnyView(VStack(alignment: .leading, spacing: Spacing.medium) {
                Text(chatVM.currentConversation?.title ?? "").font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    ChatMessageRow(item: item, isLast: index == items.count - 1, isEditing: false, actions: ChatRowActions(),
                                   answeringElsewhere: item.message.turnID == chatVM.foreignTurn.turnID)
                }
                Spacer(minLength: 0)
                ChatComposerView(chatVM: chatVM, modelSuggestions: [], maxHeight: 120)
            }
            .padding(Spacing.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// 4b: one phone on a Relay hub, its grants on, Chat among them.
    static func settingsChat() -> AnyView {
        let now = MobileSettingsShotFixtures.now
        let defaults = UserDefaults(suiteName: "WatchtowerDesktopShots.iphoneChat") ?? .standard
        let clock: () -> Date = { now }
        let model = MobileSettingsModel(cli: ParkedCLI(), defaults: defaults, now: clock)
        let phone = MobileHubCLI.Phone(
            deviceID: "AAAA0001", name: "Phone A", scope: "shared", linkedAt: now.addingTimeInterval(-21 * 86_400),
            typingAllowed: true, typingRequested: false, permissionsAllowed: true, permissionsRequested: false,
            startSessionsAllowed: true, startSessionsGranted: true, transport: "relay", chatAllowed: true
        )
        model.present(status: MobileSettingsShotFixtures.running(), phones: [phone], jobs: nil)
        return AnyView(MobileSettingsView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
    }
}

/// A CLI whose every call waits until it is cancelled: the shot keeps the
/// read it was shown.
private struct ParkedCLI: CLIRunnerProtocol {
    func run(args: [String]) async throws -> Data {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}
