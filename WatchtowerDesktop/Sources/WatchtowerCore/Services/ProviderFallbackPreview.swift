/// Shared provider-fallback presentation copy for runtime and approved catalog
/// scenes. This model performs no selection, settings writes or model calls.
package struct ProviderFallbackPreview {
    package enum Provider: String, CaseIterable {
        case claude = "Claude", codex = "Codex"
        package var other: Self { self == .claude ? .codex : .claude }
    }

    package enum State: String, CaseIterable {
        case empty, checking, notInstalled, notVerified, connectionNetworkError, connectionError, ready, applying, applyError
        case fallback, bothLimited, probing, recovered, stopped, pinned, unsupported, policy
    }

    package enum Emphasis { case neutral, success, warning, error }
    package struct Copy {
        package let title: String
        package let detail: String
        package let action: String?
        package let emphasis: Emphasis
        package var busy = false
    }

    package let preferred: Provider
    package let state: State
    package let nextCheck: String?
    package var chatTitle: String
    package var modelDescription: String
    package var observedProvider: String?
    package var observedModel: String?
    package init(
        preferred: Provider,
        state: State,
        nextCheck: String? = nil,
        chatTitle: String = "",
        modelDescription: String = "",
        observedProvider: String? = nil,
        observedModel: String? = nil
    ) {
        self.preferred = preferred
        self.state = state
        self.nextCheck = nextCheck
        self.chatTitle = chatTitle; self.modelDescription = modelDescription
        self.observedProvider = observedProvider; self.observedModel = observedModel
    }
    package var reserve: Provider { preferred.other }
    package var isChat: Bool { [.recovered, .stopped, .pinned, .unsupported].contains(state) }
    package var pageTitle: String { isChat ? "AI Chat" : "AI providers" }
    package var pageSubtitle: String {
        isChat ? chatTitle : "Settings · System · AI"
    }
    package static let preferredLabel = "Preferred provider"
    package static let reserveLabel = "Reserve provider"
    package static let modelsLabel = "Models"
    package static let automaticLabel = "Use reserve when limits are reached"
    package static let scope = "Applies to Watchtower AI. Workbench sessions keep their own agent."
    package static let recovery = "Background tasks return after the preferred provider is available. Existing chats keep their current provider."
    package static let reviewEmpty = "No actions were recorded. Check any external tools before sending a new message."
    package static let chatPolicyLabel = "Provider choice"
    package static let chatPolicyAutomatic = "Preferred + reserve"
    package static let automaticChoice = chatPolicyAutomatic + " · Auto model"
    package static func pinnedChoice(provider: String, model: String? = nil) -> String {
        "Only " + provider + (model.map { " · " + ($0.isEmpty ? "Auto" : $0) } ?? "")
    }
    package var chatPolicyValue: String {
        state == .pinned ? "Only \(preferred.rawValue) · explicit model" : Self.chatPolicyAutomatic
    }
    package var connectionLabel: String {
        switch state {
        case .empty: "Not connected"
        case .checking: "Checking…"
        case .notInstalled: "Not installed"
        case .notVerified: "Not verified"
        case .connectionNetworkError, .connectionError: "Needs attention"
        default: "Connected"
        }
    }
    package var enabled: Bool {
        ![.empty, .checking, .notInstalled, .notVerified, .connectionNetworkError, .connectionError].contains(state)
    }
    package var actualProvider: String {
        observedProvider ?? ([.fallback, .recovered].contains(state) ? reserve.rawValue : preferred.rawValue)
    }
    package var actualLabel: String { "Current provider: \(actualProvider)" + (observedModel.map { " · " + $0 } ?? "") }

    private var checkDetail: String { nextCheck.map { " Next recovery check: " + $0 + "." } ?? "" }
    package var copy: Copy {
        let p = preferred.rawValue, r = reserve.rawValue
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
                title: "\(p) is available again",
                detail: "Background tasks have returned to \(p). This chat stays with \(r) until you switch.",
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
