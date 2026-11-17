import AppKit
import ChatUI
import ChatWire
import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The main chat's routing accessory and the code questions' pill, state by state (#1822 T17): rendered before and
/// after the pill moved into `ChatUI` (`ChatRoutingAccessory`, `ChatRoutingPill`), so the two renders can be compared
/// name by name. Synthetic data only.
@MainActor
enum RoutingPillShotFixtures {
    private static var held: [Any] = []

    static func cleanUp() { held = [] }

    static var shots: [DesignShot] {
        let wide = NSSize(width: 560, height: 0)
        return [
            DesignShot(name: "routing-pill-auto", size: wide) { accessory(Scene()) },
            DesignShot(name: "routing-pill-pinned-model", size: wide) {
                accessory(Scene(automatic: false, provider: "codex", model: "gpt-5.6-sol"))
            },
            DesignShot(name: "routing-pill-pinned-auto-model", size: wide) {
                accessory(Scene(automatic: false, provider: "codex"))
            },
            DesignShot(name: "routing-pill-busy", size: wide) { accessory(Scene(busy: true)) },
            DesignShot(name: "routing-actual-line", size: wide) {
                accessory(Scene(actual: "claude", actualModel: "sample-model"))
            },
            DesignShot(name: "routing-preview-unsupported", size: wide) {
                accessory(Scene(actual: "claude", actualModel: "sample-model", reason: "required_capability_missing"))
            },
            DesignShot(name: "routing-preview-recovered-busy", size: wide) {
                accessory(Scene(actual: "codex", actualModel: "sample-model", reason: "quota_exhausted",
                                preferredState: "available", busy: true))
            },
            DesignShot(name: "routing-native-tools-notice", size: wide) {
                accessory(Scene(actual: "codex", actualModel: "sample-model", reason: "quota_exhausted",
                                preferredState: "quota_wait"))
            },
            DesignShot(name: "routing-status-error", size: wide) {
                accessory(Scene(statusError: "Couldn't read provider availability: The file couldn’t be opened."))
            },
            DesignShot(name: "routing-catalog-unread", size: wide) { accessory(Scene(catalogRead: false)) },
            DesignShot(name: "routing-accessory-narrow", size: NSSize(width: 360, height: 0)) {
                accessory(Scene(actual: "codex", actualModel: "sample-model", reason: "quota_exhausted",
                                preferredState: "available"))
            },
            DesignShot(name: "routing-pill-code-question", size: NSSize(width: 460, height: 0)) { codeQuestionHeader() },
            DesignShot(name: "routing-pill-questions-view", size: NSSize(width: 420, height: 0)) { questionsHeader() }
        ]
    }

    /// One accessory state: the chat's pick, what the feed says runs it, the availability read.
    struct Scene {
        var automatic = true
        var provider = "claude"
        var model = ""
        var actual = ""
        var actualModel = ""
        var reason = ""
        /// The preferred provider's availability ("" = no status read).
        var preferredState = ""
        var statusError: String?
        var catalogRead = true
        var busy = false
    }

    private static var catalog: AIModelCatalog { AIModelCatalog(providers: ProviderCatalogFixture.providers()) }

    private static func status(_ scene: Scene) -> ChatRoutingStatus? {
        guard !scene.preferredState.isEmpty else { return nil }
        return try? ChatRoutingStatus.parse(Data("""
            {"preferred_provider":"claude","enabled":true,"revision":"fixture",
             "providers":[{"provider":"claude","state":"\(scene.preferredState)","next_probe_at":"2026-01-02T14:30:00Z"}]}
            """.utf8))
    }

    // MARK: - The shared views

    private static func accessory(_ scene: Scene) -> AnyView {
        ProviderCatalogFixture.seedShared()
        let models = scene.catalogRead ? catalog : AIModelCatalog(providers: [])
        let client = RoutingShotClient()
        let conversation = ChatConversationModel(client: client, conversationID: scene.actual.isEmpty ? nil : 7)
        if !scene.actual.isEmpty {
            conversation.store.apply(.snapshot(ChatFeed(
                conversation: ChatFeed.Conversation(id: 7, title: "Q3 roadmap", actualProvider: scene.actual,
                                                    actualModel: scene.actualModel, routingReason: scene.reason),
                messages: []
            )))
        }
        let composer = ChatComposerModel(conversation: conversation)
        let routing = ChatRoutingModel(client: client) { composer }
        if !scene.automatic {
            composer.routing = ChatRouting(mode: "pinned", provider: scene.provider, model: scene.model.isEmpty ? nil : scene.model)
        }
        routing.configuredPreferred = "claude"
        let current = scene.automatic ? "claude" : scene.provider
        routing.catalog = ChatRoutingCatalog(
            models: models, offered: scene.catalogRead ? models.providerIDs : [current],
            status: status(scene), statusError: scene.statusError
        )
        held.append(contentsOf: [client, conversation, composer, routing] as [Any])
        return AnyView(ChatRoutingAccessory(model: routing, isBusy: scene.busy, reachable: true)
            .environment(\.chatUIStyle, DesignKitChatStyle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.vertical, Spacing.medium)
            .detailBackground())
    }

    private static func codeQuestionHeader() -> AnyView {
        ProviderCatalogFixture.seedShared()
        return AnyView(HStack(spacing: 6) {
            Image(systemName: "sparkle").foregroundStyle(.orange)
            Text("SessionStore.swift:42").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            CodeQuestionModelPill(choice: .init(provider: .claude, model: ""), suggestions: [], enabled: true) { _ in }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }

    private static func questionsHeader() -> AnyView {
        ProviderCatalogFixture.seedShared()
        return AnyView(HStack {
            Image(systemName: "chevron.left")
            Text("Code viewer · SessionStore.swift").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            CodeQuestionModelPill(choice: .init(provider: .codex, model: "gpt-5.6-sol"), suggestions: [], enabled: true) { _ in }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }
}

/// A client that never answers: the shots set the conversation's state themselves.
private final class RoutingShotClient: ChatClient, @unchecked Sendable {
    func send(_ op: ChatOperation) async throws -> ChatEcho { .applied(.none) }
    func feed(_ conversation: Int64) -> AsyncStream<ChatFeedUpdate> { AsyncStream { _ in } }
    func list() -> AsyncStream<ChatListUpdate> { AsyncStream { _ in } }
    var reachability: AsyncStream<ChatReachability> { AsyncStream { _ in } }
}
