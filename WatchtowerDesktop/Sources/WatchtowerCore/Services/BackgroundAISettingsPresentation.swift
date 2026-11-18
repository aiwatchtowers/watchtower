import Foundation

/// Settings → System → AI → Background AI (#1886, spec §6.1): the switch and its
/// caption for one consent state. The switch always shows the stored value;
/// turning it on only opens the consent sheet, and a failed pause leaves it
/// where it was with the error as its caption.
package struct BackgroundAISettingsPresentation: Equatable, Sendable {
    package let isOn: Bool
    /// The organization decided (`AllowBackgroundAI` false): the switch is
    /// locked with the organization badge.
    package let locked: Bool
    package let caption: String
    /// The caption is a failure line, drawn in `Tone.error`.
    package let captionIsError: Bool

    package init(isOn: Bool, locked: Bool, caption: String, captionIsError: Bool) {
        self.isOn = isOn
        self.locked = locked
        self.caption = caption
        self.captionIsError = captionIsError
    }

    /// `error` is the last failed write's line
    /// (`BackgroundAIConsentCopy.saveFailed`); while a call is in flight the
    /// stored caption shows instead. `configUnreadable`: config.yaml is there
    /// but cannot be read, so no answer can be saved.
    package static func make(
        state: BackgroundAIConsent.State,
        agent: BackgroundAIConsentCopy.Agent,
        isSaving: Bool,
        error: String?,
        configUnreadable: Bool
    ) -> Self {
        typealias Copy = BackgroundAIConsentCopy
        if !isSaving, let error {
            return Self(isOn: state.isAllowed, locked: state.locked, caption: error, captionIsError: true)
        }
        if state.locked {
            return Self(isOn: false, locked: true, caption: Copy.captionOrgOff, captionIsError: false)
        }
        if configUnreadable {
            return Self(
                isOn: state.isAllowed, locked: false,
                caption: "\(Copy.configUnreadableTitle). \(Copy.configUnreadable)", captionIsError: true
            )
        }
        let caption = switch (state.effective, state.reason) {
        case (.allowed, .organization): Copy.captionOrgAllowed
        case (.allowed, _): Copy.captionAllowed(agent)
        case (.paused, _): Copy.captionPaused
        }
        return Self(isOn: state.isAllowed, locked: false, caption: caption, captionIsError: false)
    }
}
