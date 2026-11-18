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
    /// The upgrade sheet opens once per launch.
    private var upgradeShown = false

    /// What a re-entry did.
    package enum Presentation: Equatable {
        /// Opened now, or the config error is shown instead.
        case opened, configError
        /// Already on screen: only bring its window forward.
        case alreadyVisible
        /// Wanted but never mounted: the caller re-asserts it with
        /// `close()` now and `reopen(_:model:)` a turn later.
        case retry(BackgroundAIConsentPrompt.Opened, BackgroundAIConsentModel)

        package static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.opened, .opened), (.configError, .configError), (.alreadyVisible, .alreadyVisible): true
            case let (.retry(lk, lm), .retry(rk, rm)): lk == rk && lm === rm
            default: false
            }
        }
    }

    package init() {}

    /// The upgrade sheet, once per launch, when it is due, config.yaml is
    /// readable (`makeModel` returns nil when it is not), and no release
    /// notes window is open or still to come (`UpdateService.isWhatsNewSettled`),
    /// so the two never stack.
    package mutating func presentIfDue(
        onboardingDone: Bool,
        state: BackgroundAIConsent.State,
        configUnreadable: Bool,
        releaseNotesPending: Bool,
        makeModel: () -> BackgroundAIConsentModel?
    ) {
        guard !upgradeShown, opened == nil, !configUnreadable, !releaseNotesPending,
              BackgroundAIConsentPrompt.shouldPresent(onboardingDone: onboardingDone, state: state),
              let made = makeModel() else { return }
        upgradeShown = true
        open(.upgrade, model: made)
    }

    /// The owner's re-entry (Settings, Home, empty states, Automations).
    @discardableResult
    package mutating func present(
        configUnreadable: Bool, makeModel: () -> BackgroundAIConsentModel?
    ) -> Presentation {
        if let opened, let model {
            return isMounted ? .alreadyVisible : .retry(opened, model)
        }
        guard !configUnreadable, let made = makeModel() else {
            showsConfigError = true
            return .configError
        }
        open(.reEntry, model: made)
        return .opened
    }

    /// The sheet's content appeared.
    package mutating func markMounted() {
        if opened != nil { isMounted = true }
    }

    /// Closes the sheet when the state says it was answered elsewhere.
    package mutating func follow(_ state: BackgroundAIConsent.State) {
        if let opened, BackgroundAIConsentPrompt.shouldClose(opened: opened, state: state) { close() }
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
