import SwiftUI
import WatchtowerCore

/// Settings → AI → Background AI (#1886, spec §6.1). The switch follows the
/// stored answer: turning it on opens the consent sheet (D9), turning it off
/// writes `ai background pause` at once, with no confirmation. Renders
/// nothing without an `AppState` in the environment (design shots of the
/// provider form).
struct BackgroundAISettingsSection: View {
    @Environment(AppState.self) private var appState: AppState?
    let config: ConfigService
    let catalog: AIModelCatalog
    /// The pause writer and the saved agent the caption names, read from
    /// config.yaml as saved; nil while the file cannot be read.
    @State private var model: BackgroundAIConsentModel?

    var body: some View {
        if let appState {
            BackgroundAISettingsForm(
                presentation: presentation(appState),
                isSaving: model?.isSaving ?? false
            ) { on in
                if on { appState.presentBackgroundAIConsent() } else { pause(appState) }
            }
            .task(id: refreshKey(appState)) {
                guard model?.isBusy != true else { return }
                model = appState.makeBackgroundAIConsentModel()
            }
        }
    }

    /// A new answer, or a Settings save (the agent may have changed), reads
    /// the saved file again.
    private func refreshKey(_ appState: AppState) -> String {
        "\(appState.backgroundAI.effective)-\(appState.backgroundAI.reason)-\(config.hasUnsavedEdits)"
            + "-\(appState.backgroundAIConfigUnreadable)"
    }

    private func presentation(_ appState: AppState) -> BackgroundAISettingsPresentation {
        let agent = model?.agent ?? BackgroundAIConsentCopy.Agent(
            provider: config.aiProvider ?? "claude", displayName: catalog.displayName(config.aiProvider ?? "claude")
        )
        return .make(
            state: appState.backgroundAI,
            agent: agent,
            isSaving: model?.isSaving ?? false,
            error: model?.errorLine,
            configUnreadable: appState.backgroundAIConfigUnreadable
        )
    }

    private func pause(_ appState: AppState) {
        guard let model, !model.isBusy else { return }
        Task {
            if await model.notNow() { appState.reloadBackgroundAI() }
        }
    }
}

/// The section's layout over its presentation: one switch row, a spinner
/// beside the title while a call is in flight, an error caption in
/// `Tone.error`. The live design shots render it directly.
struct BackgroundAISettingsForm: View {
    typealias Copy = BackgroundAIConsentCopy

    let presentation: BackgroundAISettingsPresentation
    let isSaving: Bool
    let setOn: (Bool) -> Void

    var body: some View {
        SettingsSection(title: Copy.sectionTitle, footer: Copy.settingsFooter, isBusy: isSaving) {
            SettingRow(title: Copy.switchTitle, caption: presentation.captionIsError ? nil : presentation.caption) {
                Toggle("", isOn: Binding(get: { presentation.isOn }, set: setOn))
                    .labelsHidden()
                    .disabled(isSaving)
                    .managedByOrganization(presentation.locked)
            }
            if presentation.captionIsError {
                Text(presentation.caption)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
