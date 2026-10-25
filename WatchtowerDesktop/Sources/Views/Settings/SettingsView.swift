import SwiftUI
import WatchtowerCore

/// The Settings window's tabs. `AppState.settingsTab` holds the selection so
/// an in-app link can open Settings on a given tab.
enum SettingsTab: Hashable {
    case general, connections, features, meetings, system, mobile, profile
}

/// A section inside a Settings tab that an in-app link can scroll to.
enum SettingsAnchor: Hashable {
    case instructions
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        let config = appState.sharedConfig
        TabView(selection: $appState.settingsTab) {
            GeneralSettings(config: config)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ConnectionsSettings()
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
            MobileSettingsTab()
                .environment(appState)
                .tabItem { Label("Mobile", systemImage: "iphone") }
                .tag(SettingsTab.mobile)
            ProfileSettings()
                .environment(appState)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(SettingsTab.profile)
        }
        .frame(width: 760, height: 580)
        // Here where the connect happened: the related-features offer,
        // closed only through its own buttons.
        .sheet(isPresented: Binding(
            get: { appState.showsFeatureSuggestion },
            set: { _ in }
        )) {
            FeatureSuggestionSheet().environment(appState)
        }
    }
}
