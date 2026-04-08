import SwiftUI

struct BoardsView: View {
    @Environment(AppState.self) private var appState
    @State private var jiraConnected = JiraQueries.isConnected()

    var body: some View {
        if jiraConnected {
            connectedContent
        } else {
            notConnectedPlaceholder
        }
    }

    // MARK: - Connected

    private var connectedContent: some View {
        NavigationStack {
            Form {
                JiraBoardsSettingsView()
                    .environment(appState)
                JiraFeaturesSettingsView()
                JiraUserMappingSettingsView()
                    .environment(appState)
                JiraSyncInfoView()
                    .environment(appState)
            }
            .formStyle(.grouped)
            .navigationTitle("Boards")
        }
    }

    // MARK: - Not Connected

    private var notConnectedPlaceholder: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No board sources connected")
                .font(.title3)
                .fontWeight(.medium)

            Text("Connect Jira in Settings to start tracking boards.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Open Settings") {
                NSApp.sendAction(
                    Selector(("showSettingsWindow:")),
                    to: nil, from: nil
                )
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
