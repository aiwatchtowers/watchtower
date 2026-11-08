import Foundation

/// The editor panel's footer: which save or confirm buttons it offers and the
/// hint under them. Every button is an owner's press on a screen showing every
/// hashed field, so it confirms exactly those bytes (AUTO-06).
package struct AutomationDraftFooter: Equatable, Sendable {
    package enum Action: Equatable, Sendable {
        case saveAndTurnOn, saveTurnedOff, saveAndConfirm, confirmAndTurnOn, confirmTurnedOff, confirm
        /// A built-in's save: confirms the shown bytes, leaves on/off alone.
        case save

        package var title: String {
            switch self {
            case .saveAndTurnOn: "Save and Turn On"
            case .saveTurnedOff: "Save Turned Off"
            case .saveAndConfirm: "Save and Confirm"
            case .confirmAndTurnOn: "Confirm and Turn On"
            case .confirmTurnedOff: "Confirm Turned Off"
            case .confirm: "Confirm"
            case .save: "Save"
            }
        }

        /// The press writes the recipe (not only a confirm of its bytes).
        package var saves: Bool {
            switch self {
            case .saveAndTurnOn, .saveTurnedOff, .saveAndConfirm, .save: true
            case .confirmAndTurnOn, .confirmTurnedOff, .confirm: false
            }
        }
    }

    /// The primary save's title on the Look step (spec "The Look step").
    nonisolated package static let saveLookTitle = "Save Look"
    /// The AI-step line (spec "The AI-step warning").
    nonisolated package static let aiStepLine = "This change adds an AI step: every run will use the model."

    nonisolated package static let turnsOnHint = "Saving confirms exactly what's listed above and turns it on"
    nonisolated package static let saveHint = "Saving confirms exactly what's listed above"
    nonisolated package static let confirmHint = "Confirming approves exactly what's listed above"
    nonisolated package static let noChangesHint = "No changes to save"
    /// The column cannot show every hashed field of these bytes (a parse
    /// error, or a CLI without `fields`): nothing may be saved or confirmed.
    nonisolated package static let cantShowAllHint = "Can't show everything this would confirm, so it can't be saved"
    /// The draft does not validate: its errors are listed above.
    nonisolated package static let hasErrorsHint = "The recipe has errors, so it can't be saved"

    /// The header's compact "Save…" shows while the draft column is hidden and
    /// there is something to save; it opens the column, where the press is made.
    package static func showsCompactSave(hidden: Bool, canSave: Bool) -> Bool {
        hidden && canSave
    }

    /// The footer's line above Save when the change adds an `llm()` step,
    /// on every step: `aiStepLine`, plus the tokens of a dry run of these
    /// bytes when one exists. nil when the change adds none.
    package static func aiStepWarning(addsLLM: Bool, dryRunTokens: Int?) -> String? {
        guard addsLLM else { return nil }
        guard let dryRunTokens else { return aiStepLine }
        return aiStepLine + " This dry run used "
            + AutomationCardPresentation.tokensText(Int64(dryRunTokens), estimated: false) + "."
    }

    /// The editor footer's warnings, the same on every step (spec "Where it
    /// sits"): the shell warning (#560), the #559 `llm()` warning and the
    /// AI-step line, from the column of the bytes on screen.
    package struct Warnings: Equatable, Sendable {
        package let shell: String?
        package let llm: String?
        package let aiStep: String?

        package init(column: AutomationDraftColumnModel, dryRunTokens: Int?) {
            shell = column.shellWarning
            llm = column.llmWarning
            aiStep = AutomationDraftFooter.aiStepWarning(addsLLM: column.addsLLM, dryRunTokens: dryRunTokens)
        }
    }

    package let primary: Action
    package let primaryEnabled: Bool
    package let secondary: Action?
    package let hint: String

    /// The footer's press writes the recipe (a save, not a confirm of
    /// unchanged bytes, and not the "No changes to save" state): only then
    /// does the Changed row show the Inbox folder line, which the save sets.
    package var pressSaves: Bool {
        primary.saves && hint != Self.noChangesHint
    }

    /// The primary button's title on `step`: **Save Look** for a save on
    /// the Look step; a confirm keeps its own title.
    package func primaryTitle(on step: AutomationEditorStep) -> String {
        step == .look && primary.saves ? Self.saveLookTitle : primary.title
    }

    /// `bytesChanged`: the draft differs from the saved file;
    /// `needsConfirmation`: the saved file's hash is not confirmed;
    /// `showsAllFields`: the draft column shows every hashed field
    /// (`AutomationDraftColumnModel.showsAllFields`) — false turns every
    /// button off (AUTO-06); `hasErrors`: off because the recipe does not
    /// validate, which the hint then says. `isBuiltin`: a built-in, whose
    /// on/off is its feature keys (the card's Turn On/Off), so the footer
    /// never saves it turned off: **Save**, and **Save and Turn On** while
    /// it is off.
    package static func make(
        isNew: Bool,
        bytesChanged: Bool,
        enabled: Bool,
        needsConfirmation: Bool,
        showsAllFields: Bool = true,
        hasErrors: Bool = false,
        isBuiltin: Bool = false
    ) -> Self {
        if isBuiltin {
            return builtin(bytesChanged: bytesChanged, enabled: enabled, needsConfirmation: needsConfirmation,
                           showsAllFields: showsAllFields, hasErrors: hasErrors)
        }
        guard showsAllFields else {
            let shape = make(isNew: isNew, bytesChanged: bytesChanged, enabled: enabled,
                             needsConfirmation: needsConfirmation)
            return Self(primary: shape.primary, primaryEnabled: false, secondary: nil,
                        hint: hasErrors ? hasErrorsHint : cantShowAllHint)
        }
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

    private static func builtin(
        bytesChanged: Bool, enabled: Bool, needsConfirmation: Bool, showsAllFields: Bool, hasErrors: Bool
    ) -> Self {
        guard showsAllFields else {
            return Self(primary: .save, primaryEnabled: false, secondary: nil,
                        hint: hasErrors ? hasErrorsHint : cantShowAllHint)
        }
        if bytesChanged {
            return enabled
                ? Self(primary: .save, primaryEnabled: true, secondary: nil, hint: saveHint)
                : Self(primary: .saveAndTurnOn, primaryEnabled: true, secondary: .save, hint: turnsOnHint)
        }
        if needsConfirmation {
            return Self(primary: .confirm, primaryEnabled: true, secondary: nil, hint: confirmHint)
        }
        return Self(primary: .save, primaryEnabled: false, secondary: nil, hint: noChangesHint)
    }
}
