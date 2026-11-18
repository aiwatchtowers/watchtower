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

/// The consent sheet's open state, kept by `AppState`.
package struct BackgroundAIConsentSheet: Equatable, Sendable {
    package private(set) var opened: BackgroundAIConsentPrompt.Opened?
    /// Shown instead of the sheet while config.yaml cannot be read: the
    /// answer's writer refuses a file it cannot parse.
    package private(set) var showsConfigError = false
    /// The upgrade sheet opens once per launch.
    private var upgradeShown = false

    package init() {}

    /// The upgrade sheet, once per launch, when it is due, config.yaml is
    /// readable, and the release notes window is not open (never stacked).
    package mutating func presentIfDue(
        onboardingDone: Bool,
        state: BackgroundAIConsent.State,
        configUnreadable: Bool,
        releaseNotesOpen: Bool
    ) {
        guard !upgradeShown, opened == nil, !configUnreadable, !releaseNotesOpen,
              BackgroundAIConsentPrompt.shouldPresent(onboardingDone: onboardingDone, state: state) else { return }
        upgradeShown = true
        opened = .upgrade
    }

    /// The owner's re-entry (Settings, Home, empty states, Automations).
    package mutating func present(configUnreadable: Bool) {
        if configUnreadable {
            showsConfigError = true
        } else if opened == nil {
            opened = .reEntry
        }
    }

    /// Closes the sheet when the state says it was answered elsewhere.
    package mutating func follow(_ state: BackgroundAIConsent.State) {
        if let opened, BackgroundAIConsentPrompt.shouldClose(opened: opened, state: state) { close() }
    }

    package mutating func close() {
        opened = nil
    }

    package mutating func dismissConfigError() {
        showsConfigError = false
    }
}
