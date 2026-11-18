import Foundation

/// When the background AI consent sheet opens and closes (#1886, spec §7
/// and plan Decision 12).
package enum BackgroundAIConsentPrompt {
    package enum Opened: Equatable, Sendable {
        /// Opened on its own after an upgrade, until the owner answers.
        case upgrade
        /// Opened by the owner: Settings, Home, an empty state, Automations.
        case reEntry
    }

    /// The upgrade sheet is due: onboarding is done (its own step asks
    /// otherwise) and the answer is still due.
    package static func shouldPresent(onboardingDone: Bool, state: BackgroundAIConsent.State) -> Bool {
        onboardingDone && state.prompt
    }

    /// An open sheet closes once it was answered elsewhere: the upgrade sheet
    /// once nothing is due, a re-entry once background AI is allowed.
    package static func shouldClose(opened: Opened, state: BackgroundAIConsent.State) -> Bool {
        switch opened {
        case .upgrade: !state.prompt
        case .reEntry: state.effective == .allowed
        }
    }
}

/// The consent sheet's state, kept by `AppState`: whether it is wanted,
/// whether SwiftUI actually put it up, and the one model it shows (made
/// when it opens, so a re-entry never swaps it for a fresh one).
@MainActor
package struct BackgroundAIConsentSheet {
    package private(set) var opened: BackgroundAIConsentPrompt.Opened?
    /// The open sheet's model; nil while closed.
    package private(set) var model: BackgroundAIConsentModel?
    /// The sheet is on screen (its content appeared). A sheet that is wanted
    /// but never mounted (another sheet held the window) can be retried; a
    /// mounted one is never replaced.
    package private(set) var isMounted = false
    /// Shown instead of the sheet while config.yaml cannot be read: the
    /// answer's writer refuses a file it cannot parse.
    package private(set) var showsConfigError = false
    /// Shown instead of the sheet when the provider catalog could not be
    /// read: the agent's plan and usage-limit lines come from it, and the
    /// screen never discloses without them. Its Try again presents again.
    package var showsCatalogRetry: Bool { catalogRetry != nil }
    /// Which sheet the shown catalog retry stands in for; it goes once that
    /// sheet would have closed (answered meanwhile, Decision 12).
    private var catalogRetry: BackgroundAIConsentPrompt.Opened?
    /// The upgrade sheet opens once per launch.
    private var upgradeShown = false
    /// Its config error (`makeModel` gave nil) shows once per launch.
    private var upgradeConfigErrorShown = false

    /// What a re-entry did.
    package enum Presentation: Equatable {
        /// Opened now, or the config error is shown instead.
        case opened, configError
        /// The provider catalog is not read yet: the caller reads it, then
        /// presents again (or `showCatalogRetry(for:state:)` when the read failed).
        case needsCatalog
        /// Already on screen: only bring its window forward.
        case alreadyVisible
        /// Wanted but never mounted: the caller re-asserts it with
        /// `close()` now and `reopen(_:model:)` a turn later, with a model
        /// rebuilt from the saved config (the old one was never seen).
        case retry(BackgroundAIConsentPrompt.Opened, BackgroundAIConsentModel)

        package static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.opened, .opened), (.configError, .configError), (.alreadyVisible, .alreadyVisible),
                 (.needsCatalog, .needsCatalog): true
            case let (.retry(lk, lm), .retry(rk, rm)): lk == rk && lm === rm
            default: false
            }
        }
    }

    package init() {}

    /// The upgrade sheet, once per launch, when it is due, config.yaml is
    /// readable (`makeModel` returns nil when it is not), the provider
    /// catalog is read (`catalogLoaded`: the plan lines come from it), and no
    /// release notes window is open or still to come
    /// (`UpdateService.isWhatsNewSettled`), so the two never stack.
    package mutating func presentIfDue(
        onboardingDone: Bool,
        state: BackgroundAIConsent.State,
        configUnreadable: Bool,
        releaseNotesPending: Bool,
        catalogLoaded: Bool = true,
        makeModel: () -> BackgroundAIConsentModel?
    ) {
        guard catalogLoaded, upgradeDue(onboardingDone: onboardingDone, state: state, configUnreadable: configUnreadable,
                                        releaseNotesPending: releaseNotesPending) else { return }
        // nil: the file could not be read again, or the setup read failed
        // closed (a key set twice in different case): the config error shows
        // instead, once per launch; a later readable file still opens it.
        guard let made = makeModel() else {
            if !upgradeConfigErrorShown { showsConfigError = true }
            upgradeConfigErrorShown = true
            return
        }
        upgradeShown = true
        open(.upgrade, model: made)
    }

    /// Whether the upgrade sheet would open now, the provider catalog aside:
    /// not shown yet this launch, nothing open, config.yaml readable, no
    /// release notes pending, and the answer still due.
    package func upgradeDue(
        onboardingDone: Bool, state: BackgroundAIConsent.State, configUnreadable: Bool, releaseNotesPending: Bool
    ) -> Bool {
        !upgradeShown && opened == nil && !configUnreadable && !releaseNotesPending
            && BackgroundAIConsentPrompt.shouldPresent(onboardingDone: onboardingDone, state: state)
    }

    /// The owner's re-entry (Settings, Home, empty states, Automations).
    @discardableResult
    package mutating func present(
        configUnreadable: Bool, catalogLoaded: Bool = true, makeModel: () -> BackgroundAIConsentModel?
    ) -> Presentation {
        if let opened, model != nil {
            if isMounted { return .alreadyVisible }
            guard catalogLoaded else { return .needsCatalog }
            guard !configUnreadable, let rebuilt = makeModel() else {
                close()
                showsConfigError = true
                return .configError
            }
            return .retry(opened, rebuilt)
        }
        if !configUnreadable, !catalogLoaded { return .needsCatalog }
        guard !configUnreadable, let made = makeModel() else {
            showsConfigError = true
            return .configError
        }
        open(.reEntry, model: made)
        return .opened
    }

    /// The provider catalog could not be read for sheet `kind`, still
    /// wanted: the retry shows instead of a disclosure without the plan
    /// lines, unless `state` says it was answered meanwhile.
    package mutating func showCatalogRetry(for kind: BackgroundAIConsentPrompt.Opened, state: BackgroundAIConsent.State) {
        guard !BackgroundAIConsentPrompt.shouldClose(opened: kind, state: state) else { return }
        catalogRetry = kind
    }

    package mutating func dismissCatalogRetry() {
        catalogRetry = nil
    }

    /// The sheet's content appeared.
    package mutating func markMounted() {
        if opened != nil { isMounted = true }
    }

    /// Closes the sheet when the state says it was answered elsewhere.
    package mutating func follow(_ state: BackgroundAIConsent.State) {
        if let opened, BackgroundAIConsentPrompt.shouldClose(opened: opened, state: state) { close() }
        if let catalogRetry, BackgroundAIConsentPrompt.shouldClose(opened: catalogRetry, state: state) { self.catalogRetry = nil }
    }

    package mutating func close() {
        opened = nil
        model = nil
        isMounted = false
    }

    /// The second half of a `.retry`: the same kind and the same model.
    package mutating func reopen(_ kind: BackgroundAIConsentPrompt.Opened, model: BackgroundAIConsentModel) {
        open(kind, model: model)
    }

    package mutating func dismissConfigError() {
        showsConfigError = false
    }

    private mutating func open(_ kind: BackgroundAIConsentPrompt.Opened, model: BackgroundAIConsentModel) {
        opened = kind
        self.model = model
        isMounted = false
    }
}

/// Onboarding's consent step: its model once config.yaml was read, or the
/// config error with a re-read. A loaded model is never replaced (it may be
/// saving).
@MainActor
package enum BackgroundAIConsentStepLoad {
    case pending
    case ready(BackgroundAIConsentModel)
    case unreadable
    /// The provider catalog could not be read: the plan lines are unknown,
    /// so the step offers Try again instead of the screen.
    case catalogUnavailable

    /// Reads (or re-reads after `.unreadable` or `.catalogUnavailable`); a
    /// no-op once `.ready`. `catalogLoaded` false holds the screen back.
    package mutating func load(catalogLoaded: Bool = true, _ makeModel: () -> BackgroundAIConsentModel?) {
        if case .ready = self { return }
        guard catalogLoaded else {
            self = .catalogUnavailable
            return
        }
        self = makeModel().map(Self.ready) ?? .unreadable
    }
}
