import SwiftUI
import WatchtowerCore

/// Settings → AI → Background AI (#1886, spec §6.1). The switch follows the
/// stored answer: turning it on opens the consent sheet (D9), turning it off
/// writes `ai background pause` at once, with no confirmation. The caption
/// names the provider as saved in config.yaml, never an unsaved edit.
/// Renders nothing without an `AppState` in the environment (design shots of
/// the provider form).
struct BackgroundAISettingsSection: View {
    @Environment(AppState.self) private var appState: AppState?
    let config: ConfigService
    let catalog: AIModelCatalog
    @State private var settings = BackgroundAISettingsModel()

    var body: some View {
        if let appState {
            BackgroundAISettingsForm(presentation: presentation(appState), isSaving: settings.isSaving) { on in
                if on {
                    appState.presentBackgroundAIConsent()
                } else {
                    Task {
                        await settings.pause(
                            make: { appState.makeBackgroundAIConsentModel() },
                            reload: { appState.reloadBackgroundAI() }
                        )
                    }
                }
            }
            .onChange(of: storedKey(appState)) { _, _ in settings.storedStateChanged() }
        }
    }

    /// What a shown pause error is about: the stored answer and whether the
    /// file can be read.
    private func storedKey(_ appState: AppState) -> String {
        "\(appState.backgroundAI.effective)-\(appState.backgroundAI.reason)-\(appState.backgroundAIConfigUnreadable)"
    }

    private func presentation(_ appState: AppState) -> BackgroundAISettingsPresentation {
        let provider = config.savedAIProvider.flatMap { $0.isEmpty ? nil : $0 } ?? "claude"
        return .make(
            state: appState.backgroundAI,
            agent: BackgroundAIConsentCopy.Agent(provider: provider, displayName: catalog.displayName(provider)),
            isSaving: settings.isSaving,
            error: settings.errorLine,
            configUnreadable: appState.backgroundAIConfigUnreadable
        )
    }
}

/// The section's layout over its presentation: one switch row whose caption
/// turns `Tone.error` for a failure, a spinner beside the title while a call
/// is in flight. The live design shots render it directly.
struct BackgroundAISettingsForm: View {
    typealias Copy = BackgroundAIConsentCopy

    let presentation: BackgroundAISettingsPresentation
    let isSaving: Bool
    let setOn: (Bool) -> Void

    var body: some View {
        SettingsSection(title: Copy.sectionTitle, footer: Copy.settingsFooter, isBusy: isSaving) {
            SettingRow(
                title: Copy.switchTitle,
                caption: presentation.caption,
                captionTone: presentation.captionIsError ? Tone.error : nil
            ) {
                Toggle("", isOn: Binding(get: { presentation.isOn }, set: setOn))
                    .labelsHidden()
                    .disabled(isSaving)
                    .managedByOrganization(presentation.locked)
            }
        }
    }
}
