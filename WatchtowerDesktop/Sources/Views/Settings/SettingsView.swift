import SwiftUI
import WatchtowerCore

/// The Settings window's tabs. `AppState.settingsTab` holds the selection so
/// an in-app link can open Settings on a given tab.
enum SettingsTab: Hashable {
    case general, connections, features, meetings, system, profile
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var config = ConfigService()

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: $appState.settingsTab) {
            GeneralSettings(config: config)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ConnectionsSettings(config: config)
                .environment(appState)
                .tabItem { Label("Connections", systemImage: "link") }
                .tag(SettingsTab.connections)
            FeaturesSettings(config: config)
                .environment(appState)
                .tabItem { Label("Features", systemImage: "sparkles") }
                .tag(SettingsTab.features)
            MeetingsSettings(config: config)
                .environment(appState)
                .tabItem { Label("Meetings", systemImage: "mic") }
                .tag(SettingsTab.meetings)
            SystemSettings(config: config)
                .environment(appState)
                .tabItem { Label("System", systemImage: "gearshape.2") }
                .tag(SettingsTab.system)
            ProfileSettings()
                .environment(appState)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(SettingsTab.profile)
        }
        .frame(width: 760, height: 580)
        // One sheet slot, here where the connect happened: About you after
        // the first Slack connect, then the related-features offer.
        .sheet(item: Binding(
            get: { appState.settingsSheet },
            set: { if $0 == nil, let shown = appState.settingsSheet { appState.settingsSheetDismissed(shown) } }
        )) { sheet in
            switch sheet {
            case .aboutYou: LateAboutYouSheet().environment(appState)
            case .featureSuggestion: FeatureSuggestionSheet().environment(appState)
            }
        }
        .onAppear { appState.presentLateAboutYouIfReady() }
    }
}
