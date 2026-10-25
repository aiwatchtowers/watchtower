import SwiftUI
import WatchtowerCore

extension View {
    /// An Add account sheet (the Connections tab): while it is up, the
    /// feature suggestion waits.
    func marksAccountSheet(_ appState: AppState) -> some View {
        onAppear { appState.isAddingAccount = true }
            .onDisappear { appState.isAddingAccount = false }
    }
}

/// The main window's related-features offer (`FeatureSuggestionSheet`),
/// where the Connections tab connects: shown once no Add account sheet is
/// up, closed only through its own buttons.
struct FeatureSuggestionPresenter: ViewModifier {
    let appState: AppState

    /// The sheet is up: a suggestion waits and no Add account sheet is.
    var isPresented: Bool { appState.showsFeatureSuggestion }

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { isPresented },
            set: { _ in }
        )) {
            FeatureSuggestionSheet().environment(appState)
        }
    }
}

/// The sidebar's quiet "+ Connect Slack, Mail, Jira…" row: what is still
/// missing, opening the Connections tab; × hides it for good.
struct SidebarConnectRow: View {
    @Environment(AppState.self) private var appState
    @AppStorage(SourceConnectPrompt.dismissedKey) private var dismissed = false

    var body: some View {
        if let title = SourceConnectPrompt.rowTitle(
            connected: appState.featureVisibility.connectedSources, dismissed: dismissed,
            policy: appState.managedPolicy.policy
        ) {
            HStack(spacing: 4) {
                Button {
                    appState.openConnections()
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

/// The "Turn on related features?" offer after a source is connected
/// (`AppState.featureSuggestion`), over the main window. Nothing is enabled
/// without Turn on.
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
