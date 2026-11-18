import Foundation

/// Shared provider-fallback presentation copy for runtime and approved catalog
/// scenes (the Mac's Settings and the chat's fallback card on the Mac and the phone). This model performs no selection, settings writes or model calls.
/// The pair it names is the catalog's (`AIModelCatalog.fallbackPair`, the Go
/// table's `reserve_peer`), never a Swift copy of the rule (LLMTRANSPORT-01).
public struct ProviderFallbackPreview: Sendable {
    /// One side of the fallback pair: its provider id and display name.
    public struct Provider: Equatable, Sendable {
        public let id: String
        public let name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The preferred provider and the reserve it pairs with.
    public struct Pair: Equatable, Sendable {
        public let preferred: Provider
        public let reserve: Provider
        public init(preferred: Provider, reserve: Provider) {
            self.preferred = preferred
            self.reserve = reserve
        }
        /// The same pair seen from the reserve's side.
        public var reversed: Self { .init(preferred: reserve, reserve: preferred) }
    }

    public enum State: String, CaseIterable, Sendable {
        case empty, checking, notInstalled, notVerified, connectionNetworkError, connectionError, ready, applying, applyError
        case fallback, bothLimited, probing, recovered, stopped, pinned, unsupported, policy
    }

    public enum Emphasis: Sendable { case neutral, success, warning, error }
    public struct Copy: Equatable, Sendable {
        public let title: String
        public let detail: String
        public let action: String?
        public let emphasis: Emphasis
        public var busy = false

        public init(title: String, detail: String, action: String?, emphasis: Emphasis, busy: Bool = false) {
            self.title = title
            self.detail = detail
            self.action = action
            self.emphasis = emphasis
            self.busy = busy
        }
    }

    public let preferred: Provider
    public let reserve: Provider
    public let state: State
    public let nextCheck: String?
    public var chatTitle: String
    public var modelDescription: String
    public var observedProvider: String?
    public var observedModel: String?
    public init(
        pair: Pair,
        state: State,
        nextCheck: String? = nil,
        chatTitle: String = "",
        modelDescription: String = "",
        observedProvider: String? = nil,
        observedModel: String? = nil
    ) {
        preferred = pair.preferred
        reserve = pair.reserve
        self.state = state
        self.nextCheck = nextCheck
        self.chatTitle = chatTitle; self.modelDescription = modelDescription
        self.observedProvider = observedProvider; self.observedModel = observedModel
    }

    /// The copy of a state that names no provider (stopped, applying, the
    /// connection label): no pair is needed to say it.
    public init(state: State) {
        let unnamed = Provider(id: "", name: "")
        self.init(pair: .init(preferred: unnamed, reserve: unnamed), state: state)
    }

    public var isChat: Bool { [.recovered, .stopped, .pinned, .unsupported].contains(state) }
    public var pageTitle: String { isChat ? "AI Chat" : "AI providers" }
    public var pageSubtitle: String {
        isChat ? chatTitle : "Settings · System · AI"
    }
    public static let preferredLabel = "Preferred provider"
    public static let reserveLabel = "Reserve provider"
    public static let modelsLabel = "Models"
    public static let automaticLabel = "Use reserve when limits are reached"
    public static let scope = "Applies to Watchtower AI. Workbench sessions keep their own agent."
    public static let recovery = "Background tasks return after the preferred provider is available. Existing chats keep their current provider."
    public static let reviewEmpty = "No actions were recorded. Check any external tools before sending a new message."
    public static let chatPolicyLabel = "Provider choice"
    public static let chatPolicyAutomatic = "Preferred + reserve"
    public static let automaticChoice = chatPolicyAutomatic + " · Auto model"
    public static func pinnedChoice(provider: String, model: String? = nil) -> String {
        "Only " + provider + (model.map { " · " + ($0.isEmpty ? "Auto" : $0) } ?? "")
    }
    public var chatPolicyValue: String {
        state == .pinned ? "Only \(preferred.name) · explicit model" : Self.chatPolicyAutomatic
    }
    public var connectionLabel: String {
        switch state {
        case .empty: "Not connected"
        case .checking: "Checking…"
        case .notInstalled: "Not installed"
        case .notVerified: "Not verified"
        case .connectionNetworkError, .connectionError: "Needs attention"
        default: "Connected"
        }
    }
    public var enabled: Bool {
        ![.empty, .checking, .notInstalled, .notVerified, .connectionNetworkError, .connectionError].contains(state)
    }
    public var actualProvider: String {
        observedProvider ?? ([.fallback, .recovered].contains(state) ? reserve.name : preferred.name)
    }
    public var actualLabel: String { "Current provider: \(actualProvider)" + (observedModel.map { " · " + $0 } ?? "") }

    private var checkDetail: String { nextCheck.map { " Next recovery check: " + $0 + "." } ?? "" }
    public var copy: Copy {
        let p = preferred.name, r = reserve.name
        switch state {
        case .empty:
            return Copy(
                title: "Add a reserve provider",
                detail: "Connect \(r) to keep supported AI tasks working when \(p) reaches its limit.",
                action: "Connect \(r)",
                emphasis: .neutral
            )
        case .checking:
            return Copy(
                title: "Checking \(r)",
                detail: "Checking the installed CLI and sign-in. This does not send an AI prompt.",
                action: nil,
                emphasis: .neutral, busy: true
            )
        case .connectionError:
            return Copy(
                title: "Couldn't connect \(r)",
                detail: "Sign in to the \(r) CLI, then try again. \(p) is still your preferred provider.",
                action: "Retry",
                emphasis: .error
            )
        case .notInstalled:
            return Copy(
                title: "\(r) CLI wasn't found",
                detail: "Install the CLI or set its path in AI settings, then connect again.",
                action: "Open setup",
                emphasis: .error
            )
        case .notVerified:
            return Copy(
                title: "\(r) connection isn't verified",
                detail: "Sign-in metadata isn't available. Test connection sends a short AI request using your account.",
                action: "Test connection",
                emphasis: .warning
            )
        case .connectionNetworkError:
            return Copy(
                title: "Couldn't check \(r)",
                detail: "The connection check couldn't reach the service. Your saved sign-in has not been changed.",
                action: "Retry",
                emphasis: .error
            )
        case .ready:
            return Copy(
                title: "Reserve ready",
                detail: "\(r) can take supported requests when \(p) reaches its limit. Model access is checked on the first request.",
                action: "Save",
                emphasis: .success
            )
        case .applying:
            return Copy(
                title: "Applying provider settings",
                detail: "Waiting for the background service to confirm the saved settings. Active tasks and Workbench sessions keep running.",
                action: nil,
                emphasis: .neutral, busy: true
            )
        case .applyError:
            return Copy(
                title: "Settings saved; background update failed",
                detail: "The current background configuration is not confirmed. Retry to apply the latest saved settings.",
                action: "Retry",
                emphasis: .error
            )
        case .fallback:
            return Copy(
                title: "Using \(r)",
                detail: "\(p) reached its limit. Supported AI tasks continue with \(r)." + checkDetail,
                action: nil,
                emphasis: .warning
            )
        case .bothLimited:
            return Copy(
                title: "AI is waiting for limits to reset",
                detail: "Both providers reached their limits. Unprocessed source data is kept; syncing continues." + checkDetail,
                action: "Check again",
                emphasis: .warning
            )
        case .probing:
            return Copy(
                title: "Checking \(p)'s recovery",
                detail: "One waiting task is checking availability. Other supported tasks continue with \(r).",
                action: nil,
                emphasis: .neutral, busy: true
            )
        case .recovered:
            return Copy(
                title: "\(p) can be tried",
                detail: "No local quota block is currently recorded for \(p). This chat stays with \(r) until you switch.",
                action: "Use \(p)",
                emphasis: .success
            )
        case .stopped:
            return Copy(
                title: "Limit reached after work started",
                detail: "This turn has stopped. Review its existing actions before sending a new message. Nothing will be " +
                    "repeated automatically.",
                action: "Review actions",
                emphasis: .warning
            )
        case .pinned:
            return Copy(
                title: "This chat is pinned to \(p)",
                detail: "Its chosen model stays unchanged. To use the reserve, change this chat to Preferred + reserve and use Auto model.",
                action: "Change provider choice",
                emphasis: .neutral
            )
        case .unsupported:
            return Copy(
                title: "This request needs \(p)",
                detail: "The reserve cannot use a required attachment or tool. The message is kept for you to retry when \(p) is available.",
                action: nil,
                emphasis: .warning
            )
        case .policy:
            return Copy(
                title: "\(p) is blocked by your organization",
                detail: "No provider was started. Your saved choices are kept. Choose a provider your organization allows.",
                action: nil,
                emphasis: .error
            )
        }
    }
}
