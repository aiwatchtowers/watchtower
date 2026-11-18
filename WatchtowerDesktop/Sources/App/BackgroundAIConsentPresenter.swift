import SwiftUI
import WatchtowerCore

/// The main window's background AI consent sheet (#1886, spec §7): the
/// upgrade sheet once per launch while the answer is due, the owner's
/// re-entry (`AppState.presentBackgroundAIConsent()`), and the config error
/// shown instead while config.yaml cannot be read. Closed only by an answer,
/// or once the state says it was answered elsewhere (Decision 12).
struct BackgroundAIConsentPresenter: ViewModifier {
    let appState: AppState

    /// What opens or closes the sheet when it changes.
    private struct Inputs: Equatable {
        let state: BackgroundAIConsent.State
        let configUnreadable: Bool
        let releaseNotesPending: Bool
    }

    private var inputs: Inputs {
        Inputs(
            state: appState.backgroundAI,
            configUnreadable: appState.backgroundAIConfigUnreadable,
            releaseNotesPending: !appState.updateService.isWhatsNewSettled
                || appState.updateService.installedRelease != nil
        )
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { appState.isBackgroundAIConsentPresented }, set: { _ in })) {
                // The one model the sheet state holds: a re-entry never
                // swaps it while the sheet is up (it may be saving).
                if let model = appState.backgroundAIConsentSheet.model {
                    BackgroundAIConsentView(model: model, host: .sheet) { appState.backgroundAIConsentSheetAnswered() }
                        .interactiveDismissDisabled()
                        .onAppear { appState.backgroundAIConsentSheet.markMounted() }
                }
            }
            .alert(
                BackgroundAIConsentCopy.configUnreadableTitle,
                isPresented: Binding(
                    get: { appState.backgroundAIConsentSheet.showsConfigError },
                    set: { if !$0 { appState.backgroundAIConsentSheet.dismissConfigError() } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(BackgroundAIConsentCopy.configUnreadable)
            }
            .onAppear { appState.syncBackgroundAIConsentSheet() }
            .onChange(of: inputs) { _, _ in appState.syncBackgroundAIConsentSheet() }
    }
}
