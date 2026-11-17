import ChatWire
import Foundation
import Observation

/// One entry of the routing pill's menu.
public struct ChatRoutingMenuItem: Equatable, Sendable, Identifiable {
    public enum Pick: Equatable, Sendable {
        /// Preferred + reserve, the provider's automatic model.
        case automatic
        /// Only this provider (its model goes back to Auto).
        case provider(String)
        /// This model of the current provider ("" = Auto).
        case model(String)
    }

    public let label: String
    public let pick: Pick
    public var id: String { label }

    public init(label: String, pick: Pick) {
        self.label = label
        self.pick = pick
    }
}

/// One section of the routing pill's menu; nil title: no section header.
public struct ChatRoutingMenuSection: Equatable, Sendable, Identifiable {
    public let title: String?
    public let items: [ChatRoutingMenuItem]
    public var id: String { title ?? "" }

    public init(title: String?, items: [ChatRoutingMenuItem]) {
        self.title = title
        self.items = items
    }
}

/// The main chat's routing pill on the Mac and the phone (#1822 T17, ask #1411): which provider and model the next turn
/// asks for, the lines and fallback card under it (`ChatRoutingPresentation`), and **Use preferred**. A pick only sets
/// the next turn's routing (`ChatComposerModel.routing`); nothing is written until a turn starts. A saved chat shows its
/// own routing until a pick; a new chat shows the landing's pick. The one write is `chat_manage use_preferred`.
@MainActor
@Observable
public final class ChatRoutingModel {
    public static let automaticLabel = ProviderFallbackPreview.chatPolicyAutomatic + " · Auto"
    public static let usePreferredFailed = "Couldn't change provider choice: "
    public static let autoModel = "Auto"

    /// The pick of a routing: automatic, or one provider with a model ("" = Auto).
    struct Pick: Equatable {
        var automatic: Bool
        var provider: String
        var model: String

        static let automatic = Self(automatic: true, provider: "", model: "")

        init(automatic: Bool, provider: String, model: String) {
            self.automatic = automatic
            self.provider = provider
            self.model = model
        }

        init(_ routing: ChatRouting) {
            self.init(automatic: routing.mode != "pinned", provider: routing.provider ?? "", model: routing.model ?? "")
        }

        var routing: ChatRouting {
            automatic ? ChatRouting(mode: "auto")
                : ChatRouting(mode: "pinned", provider: provider, model: model.isEmpty ? nil : model)
        }
    }

    @ObservationIgnored private let client: any ChatClient
    @ObservationIgnored private let composerSource: () -> ChatComposerModel
    @ObservationIgnored private let onRefresh: (() async -> Void)?

    /// What the pill offers; nil: no pill (no list yet on the phone).
    public var catalog: ChatRoutingCatalog?
    /// The preferred provider before the status names one (the Mac's `ai.provider`).
    public var configuredPreferred: String?
    /// Why the last **Use preferred** did not apply.
    public private(set) var notice: String?

    public init(client: any ChatClient, composer: @escaping () -> ChatComposerModel, onRefresh: (() async -> Void)? = nil) {
        self.client = client
        self.composerSource = composer
        self.onRefresh = onRefresh
    }

    var composer: ChatComposerModel { composerSource() }

    // MARK: - State

    /// The provider automatic routing heads: the status's, else the configured one, else the catalog's first.
    public var preferredProvider: String {
        if let named = catalog?.status?.preferredProvider, !named.isEmpty { return named }
        if let configuredPreferred, !configuredPreferred.isEmpty { return configuredPreferred }
        return catalog?.providers.first?.id ?? ""
    }

    private var savedConversation: ChatFeed.Conversation? {
        let conversation = composer.conversation
        guard let id = conversation.conversationID, let saved = conversation.feed?.conversation, saved.id == id else { return nil }
        return saved
    }

    /// The pick the composer carries for its next turn (a pick lives as long as the composer that shows its chat),
    /// else the saved chat's own routing, else automatic.
    private var current: Pick {
        if let routing = composer.routing { return resolved(Pick(routing)) }
        if let saved = savedConversation { return resolved(Pick(saved.routing)) }
        return resolved(.automatic)
    }

    /// An automatic pick names the preferred provider.
    private func resolved(_ pick: Pick) -> Pick {
        pick.automatic ? Pick(automatic: true, provider: preferredProvider, model: "") : pick
    }

    public var automatic: Bool { current.automatic }
    public var provider: String { current.provider }
    /// The pinned model; "" = Auto.
    public var model: String { current.model }

    /// The routing the next turn asks for.
    public var request: ChatRouting { current.routing }

    /// A turn runs or a send is on its way: the pill and the card's action are off.
    public var isBusy: Bool { composer.conversation.isTurnRunning || composer.isSending }
    /// The engine can be reached: **Use preferred** needs it; a pick does not (it goes with the queued send).
    public var isReachable: Bool { composer.conversation.reachability == .connected }

    /// Whether the pill shows (a catalog to offer).
    public var showsPill: Bool { catalog != nil }

    public func displayName(_ id: String) -> String { catalog?.provider(id)?.displayName ?? id }

    /// R1: "Preferred + reserve · Auto", "Only <Provider> · <model>" or "Only <Provider> · Auto".
    public var label: String {
        Self.label(automatic: automatic, providerName: displayName(provider), model: model)
    }

    /// R2: the automatic choice, a Provider section and a Model section.
    public var menu: [ChatRoutingMenuSection] {
        var ids = catalog?.providers.map(\.id) ?? []
        if !provider.isEmpty, !ids.contains(provider) { ids.append(provider) }
        return Self.menu(automatic: true, providers: ids.map { ($0, displayName($0)) },
                         models: catalog?.provider(provider)?.models ?? [])
    }

    /// The capability row of the provider the chat runs (or would run) on; nil when the catalog's rows are not the
    /// transport table's.
    public var capabilities: ChatProviderCaps? {
        guard let catalog, catalog.capabilitiesKnown else { return nil }
        let actual = savedConversation?.actualProvider ?? ""
        return catalog.provider(actual.isEmpty ? provider : actual)?.caps
    }

    /// R5–R8: the actual line, what the provider lacks, the fallback card and the claude.ai-tools notice.
    public var presentation: ChatRoutingPresentation? {
        guard let catalog else { return nil }
        let saved = savedConversation
        let actual = saved?.actualProvider ?? ""
        let actualModel = saved?.actualModel ?? ""
        let pick = current
        return ChatRoutingPresentation(
            pair: catalog.pair(preferred: pick.automatic ? preferredProvider : pick.provider),
            automatic: pick.automatic,
            actualProvider: actual.isEmpty ? nil : actual,
            actualModel: actualModel.isEmpty ? nil : actualModel,
            reason: saved?.routingReason,
            health: catalog.status,
            busy: isBusy || !isReachable,
            actualDisplayName: actual.isEmpty ? nil : catalog.provider(actual)?.displayName,
            capabilities: capabilities
        )
    }

    // MARK: - Picks

    public func pick(_ item: ChatRoutingMenuItem) {
        switch item.pick {
        case .automatic: selectAutomatic()
        case .provider(let id): selectProvider(id)
        case .model(let model): selectModel(model)
        }
    }

    public func selectAutomatic() {
        guard !isBusy else { return }
        set(.automatic)
    }

    public func selectProvider(_ id: String) {
        guard !isBusy else { return }
        let now = current
        set(Pick(automatic: false, provider: id, model: id == now.provider ? now.model : ""))
    }

    public func selectModel(_ model: String) {
        guard !isBusy else { return }
        set(Pick(automatic: false, provider: current.provider, model: model))
    }

    private func set(_ pick: Pick) {
        notice = nil
        composer.routing = pick.routing
    }

    /// The fallback card's **Use preferred**: a saved chat asks the engine to route preferred + reserve again (its
    /// sticky reserve cleared, its idle session retired); the landing only turns its pick automatic.
    public func usePreferred() async {
        guard !isBusy, isReachable else { return }
        let composer = composer
        guard let id = composer.conversation.conversationID else {
            selectAutomatic()
            return
        }
        do {
            switch try await client.send(.manage(conversationID: id, op: .usePreferred, title: nil, projectID: nil)) {
            case .applied:
                if composer.conversation.conversationID == id { set(.automatic) }
            case let .refused(code, message):
                notice = Self.usePreferredFailed + message
                if code == Self.goneCode { composer.conversation.store.apply(.gone) }
            }
        } catch {
            notice = Self.usePreferredFailed + error.localizedDescription
        }
    }

    /// The refusal of a conversation that no longer exists (chat.sock and the relay alike).
    static let goneCode = "not_found"

    // MARK: - Refresh (R10)

    /// Another chat is on screen.
    public func conversationChanged() async { await onRefresh?() }
    /// The turn ended (busy went to idle).
    public func turnEnded() async { await onRefresh?() }
    /// The app became active.
    public func activated() async { await onRefresh?() }

    // MARK: - Shared builders (the code questions' pill too)

    public static func label(automatic: Bool, providerName: String, model: String) -> String {
        automatic ? automaticLabel : ProviderFallbackPreview.pinnedChoice(provider: providerName, model: model)
    }

    /// The menu: the automatic choice (when offered), "Only <Provider>" for each provider, and Auto plus the current
    /// provider's models.
    public static func menu(automatic: Bool, providers: [(id: String, name: String)], models: [String]) -> [ChatRoutingMenuSection] {
        var sections: [ChatRoutingMenuSection] = []
        if automatic {
            sections.append(ChatRoutingMenuSection(title: nil, items: [
                ChatRoutingMenuItem(label: ProviderFallbackPreview.automaticChoice, pick: .automatic)
            ]))
        }
        sections.append(ChatRoutingMenuSection(title: "Provider", items: providers.map { provider in
            ChatRoutingMenuItem(label: ProviderFallbackPreview.pinnedChoice(provider: provider.name), pick: .provider(provider.id))
        }))
        sections.append(ChatRoutingMenuSection(title: "Model", items: [ChatRoutingMenuItem(label: autoModel, pick: .model(""))]
            + models.map { ChatRoutingMenuItem(label: $0, pick: .model($0)) }))
        return sections
    }
}
