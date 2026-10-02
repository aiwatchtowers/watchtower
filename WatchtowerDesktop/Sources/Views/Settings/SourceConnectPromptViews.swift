import SwiftUI
import WatchtowerCore

/// The Settings window's sheets, one at a time (`AppState.settingsSheet`).
enum SettingsSheet: String, Identifiable {
    case aboutYou, featureSuggestion

    var id: String { rawValue }
}

extension View {
    /// An Add account sheet in Settings: while it is up, the late About you
    /// sheet and the feature suggestion wait.
    func marksAccountSheet(_ appState: AppState) -> some View {
        onAppear { appState.isAddingAccount = true }
            .onDisappear { appState.isAddingAccount = false }
    }
}

/// The sidebar's quiet "+ Connect Slack, Mail, Jira…" row: what is still
/// missing, opening Settings → Connections; × hides it for good.
struct SidebarConnectRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SourceConnectPrompt.dismissedKey) private var dismissed = false

    var body: some View {
        if let title = SourceConnectPrompt.rowTitle(
            connected: appState.featureVisibility.connectedSources, dismissed: dismissed
        ) {
            HStack(spacing: 4) {
                Button {
                    appState.settingsTab = .connections
                    openSettings()
                } label: {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Hide")
                .accessibilityLabel("Hide the connect suggestion")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }
}

/// Settings' "Turn on related features?" offer after a source is connected
/// there (`AppState.featureSuggestion`). Nothing is enabled without Turn on.
struct FeatureSuggestionSheet: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Turn on related features?").font(.headline)
            Text("The source you just connected can feed these. They are off now.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(appState.featureSuggestion) { feature in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(feature.title).fontWeight(.medium)
                        Text(feature.tagline).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = appState.featureSuggestionError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Not now") { appState.declineFeatureSuggestion() }
                    .keyboardShortcut(.cancelAction)
                Button("Turn on") { Task { await appState.acceptFeatureSuggestion() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .disabled(appState.isApplyingFeatureSuggestion)
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}
