import SwiftUI
import WatchtowerCore

/// A "needs Reaction commands on" line with **Turn on** (the reaction
/// trigger's field in the editor form): the Inbox strip's path
/// (`featureManager.enableNow` + the app-wide daemon start queue). Renders nothing unless the
/// `reaction-commands` feature is known to be off.
struct ReactionCommandsOffNote: View {
    let text: String
    @Environment(AppState.self) private var appState

    private var isOff: Bool {
        ReactionCheatSheetView.FeatureState.from(features: appState.featureManager.features, lastCheck: nil) == .off
    }

    var body: some View {
        if isOff {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(spacing: Spacing.regular) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tone.warning)
                    Text(text)
                        .font(.callout)
                    Spacer()
                    Button("Turn on") { turnOn() }
                        .buttonStyle(.kitSecondary)
                        .disabled(appState.featureManager.isApplying)
                }
                if let error = appState.featureManager.loadError {
                    Text(error).font(.caption).foregroundStyle(Tone.error)
                }
            }
            .padding(Spacing.cozy)
            .card()
        }
    }

    private func turnOn() {
        let manager = appState.featureManager
        Task {
            await manager.enableNow(ReactionCheatSheetView.reactionCommandsFeatureID) {
                try await appState.restartOnChain(appState.daemonControl)
            }
        }
    }
}
