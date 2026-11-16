import Foundation
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

// Test-only initializers in the shapes the tests used before the chat writes
// moved to Go (`ChatWritesTestShims` holds the Core ones): each wires a
// `FakeChatTower` over the test's own database.

extension ChatViewModel {
    convenience init(
        dbManager: DatabaseManager,
        pool: ChatSessionPool,
        provider: AIProvider = .claude,
        cliRunner: CLIRunnerProtocol? = nil,
        preferredProviderSource: (() -> AIProvider)? = nil,
        defaults: UserDefaults = .standard,
        attachmentsRoot: URL? = ChatAttachmentStore.defaultRootDir(),
        makeTurnID: @escaping () -> String = { UUID().uuidString },
        leaseClock: @escaping () -> Date = Date.init
    ) {
        self.init(dbManager: dbManager, pool: pool, writes: .fake(dbManager.dbPool), provider: provider,
                  cliRunner: cliRunner, preferredProviderSource: preferredProviderSource, defaults: defaults,
                  attachmentsRoot: attachmentsRoot, makeTurnID: makeTurnID, leaseClock: leaseClock)
    }
}

extension ChatHistoryViewModel {
    /// `attachmentsRoot` is ignored: Go removes a deleted chat's files.
    convenience init(dbManager: DatabaseManager, attachmentsRoot: URL? = nil, defaults: UserDefaults = .standard) {
        self.init(dbManager: dbManager, writes: .fake(dbManager.dbPool), defaults: defaults)
    }
}

extension ProjectDetailViewModel {
    convenience init(
        projectID: Int64,
        dbPool: DatabasePool,
        debounce: Duration = .milliseconds(500),
        attachmentsRoot: URL? = nil,
        importFile: @escaping (URL, Int64) async throws -> ChatAttachment,
        onPromptChanged: @escaping (Int64) -> Void = { _ in }
    ) {
        self.init(projectID: projectID, dbPool: dbPool, writes: .fake(dbPool), debounce: debounce,
                  importFile: importFile, onPromptChanged: onPromptChanged)
    }
}

extension ProjectDetailViewModel {
    static func storeImporter(dbPool: DatabasePool, rootDir: URL?) -> (URL, Int64) async throws -> ChatAttachment {
        storeImporter(dbPool: dbPool, rootDir: rootDir, writes: .fake(dbPool))
    }
}

extension TargetAssistantViewModel {
    convenience init(
        target: Target,
        viewModel: TargetsViewModel,
        dbManager: DatabaseManager,
        chatFactory: ChatFactory? = nil,
        embeddedChats: EmbeddedChatCenter? = nil
    ) {
        self.init(target: target, viewModel: viewModel, dbManager: dbManager, writes: .fake(dbManager.dbPool),
                  chatFactory: chatFactory, embeddedChats: embeddedChats)
    }
}

extension ReviewerCenter {
    convenience init(
        embeddedChats: EmbeddedChatCenter,
        dbPool: DatabasePool,
        reader: @escaping @MainActor () -> ReviewerSurface.Reader = ReviewerCenter.configuredReader
    ) {
        self.init(embeddedChats: embeddedChats, writes: .fake(dbPool), reader: reader)
    }
}

extension TuningChat {
    convenience init(
        workbenchID: Int64,
        conversationID: Int64,
        dbPool: DatabasePool,
        center: EmbeddedChatCenter,
        coach: CoachCenter?,
        decideTools: @escaping @MainActor () -> Bool = { TuningChatSurface.toolsAvailable(provider: nil) },
        period: @escaping @MainActor () -> AgentAnalyticsCenter.Period
    ) {
        self.init(workbenchID: workbenchID, conversationID: conversationID, dbPool: dbPool, writes: .fake(dbPool),
                  center: center, coach: coach, decideTools: decideTools, period: period)
    }
}

extension TuningChatSurface {
    static func latestOrNewConversation(dbPool: DatabasePool, workbenchID: Int64) async throws -> Int64 {
        try await latestOrNewConversation(dbPool: dbPool, writes: .fake(dbPool), workbenchID: workbenchID)
    }

    static func newConversation(dbPool: DatabasePool, workbenchID: Int64) async throws -> Int64 {
        try await newConversation(writes: .fake(dbPool), workbenchID: workbenchID)
    }
}

extension CodeQuestionSurface {
    static func createConversation(
        workbenchID: Int64, origin: CodeQuestionOrigin, choice: ModelChoice, dbPool: DatabasePool
    ) async throws -> Int64 {
        try await createConversation(workbenchID: workbenchID, origin: origin, choice: choice, writes: .fake(dbPool))
    }

    static func setModelChoice(_ choice: ModelChoice, conversationID: Int64, dbPool: DatabasePool) async throws {
        try await setModelChoice(choice, conversationID: conversationID, writes: .fake(dbPool))
    }
}

extension TrackChatSurface {
    static func conversationID(for track: Track, dbPool: DatabasePool) async throws -> Int64 {
        try await conversationID(for: track, dbPool: dbPool, writes: .fake(dbPool))
    }
}

extension IdeaChatSurface {
    static func conversationID(for idea: Idea, dbPool: DatabasePool) async throws -> Int64 {
        try await conversationID(for: idea, dbPool: dbPool, writes: .fake(dbPool))
    }
}

extension MeetingChatSurface {
    static func conversationID(transcriptID: Int64, title: String, dbPool: DatabasePool) async throws -> Int64 {
        try await conversationID(transcriptID: transcriptID, title: title, dbPool: dbPool, writes: .fake(dbPool))
    }
}

extension AutomationEditorChatSurface {
    static func conversationID(for automation: Automation, dbPool: DatabasePool) async throws -> Int64 {
        try await conversationID(for: automation, dbPool: dbPool, writes: .fake(dbPool))
    }

    static func newConversationID(contextID: String, dbPool: DatabasePool) async throws -> Int64 {
        try await newConversationID(contextID: contextID, dbPool: dbPool, writes: .fake(dbPool))
    }
}

extension SpecReviewThreadSurface {
    static func conversationID(
        workbenchID: Int64, rootAskID: Int64, itemKey: String, title: String, dbPool: DatabasePool
    ) async throws -> Int64 {
        try await conversationID(workbenchID: workbenchID, rootAskID: rootAskID, itemKey: itemKey, title: title,
                                 dbPool: dbPool, writes: .fake(dbPool))
    }
}

extension DatabaseDraftMirror {
    /// The database opened: reads from it, writes through a fake tower on it.
    var writer: (any DatabaseWriter)? {
        get { reader as? any DatabaseWriter }
        set {
            reader = newValue
            writes = newValue.map { .fake($0) }
        }
    }
}
