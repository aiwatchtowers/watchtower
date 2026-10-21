import Foundation

/// The editor panel's footer: which save or confirm buttons it offers and the
/// hint under them. Every button is an owner's press on a screen showing every
/// hashed field, so it confirms exactly those bytes (AUTO-06).
package struct AutomationDraftFooter: Equatable, Sendable {
    package enum Action: Equatable, Sendable {
        case saveAndTurnOn, saveTurnedOff, saveAndConfirm, confirmAndTurnOn, confirmTurnedOff, confirm

        package var title: String {
            switch self {
            case .saveAndTurnOn: "Save and Turn On"
            case .saveTurnedOff: "Save Turned Off"
            case .saveAndConfirm: "Save and Confirm"
            case .confirmAndTurnOn: "Confirm and Turn On"
            case .confirmTurnedOff: "Confirm Turned Off"
            case .confirm: "Confirm"
            }
        }
    }

    nonisolated package static let turnsOnHint = "Saving confirms exactly what's listed above and turns it on"
    nonisolated package static let saveHint = "Saving confirms exactly what's listed above"
    nonisolated package static let confirmHint = "Confirming approves exactly what's listed above"
    nonisolated package static let noChangesHint = "No changes to save"

    package let primary: Action
    package let primaryEnabled: Bool
    package let secondary: Action?
    package let hint: String

    /// `bytesChanged`: the draft differs from the saved file;
    /// `needsConfirmation`: the saved file's hash is not confirmed.
    package static func make(isNew: Bool, bytesChanged: Bool, enabled: Bool, needsConfirmation: Bool) -> Self {
        if isNew || (bytesChanged && !enabled) {
            return Self(primary: .saveAndTurnOn, primaryEnabled: true, secondary: .saveTurnedOff, hint: turnsOnHint)
        }
        if bytesChanged {
            return Self(primary: .saveAndConfirm, primaryEnabled: true, secondary: .saveTurnedOff, hint: saveHint)
        }
        if needsConfirmation {
            return enabled
                ? Self(primary: .confirm, primaryEnabled: true, secondary: nil, hint: confirmHint)
                : Self(primary: .confirmAndTurnOn, primaryEnabled: true, secondary: .confirmTurnedOff,
                       hint: confirmHint)
        }
        return Self(primary: .saveAndConfirm, primaryEnabled: false, secondary: nil, hint: noChangesHint)
    }
}
