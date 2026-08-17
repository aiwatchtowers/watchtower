import SwiftUI
import WatchtowerCore

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var config = ConfigService()

    var body: some View {
        TabView {
            ConnectionsSettings(config: config)
                .environment(appState)
                .tabItem { Label("Connections", systemImage: "link") }
            FeaturesSettings(config: config)
                .environment(appState)
                .tabItem { Label("Features", systemImage: "sparkles") }
            MeetingsSettings(config: config)
                .environment(appState)
                .tabItem { Label("Meetings", systemImage: "mic") }
            SystemSettings(config: config)
                .environment(appState)
                .tabItem { Label("System", systemImage: "gearshape.2") }
            ProfileSettings()
                .environment(appState)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            MobileSettings()
                .environment(appState)
                .tabItem { Label("Mobile", systemImage: "iphone") }
        }
        .frame(width: 760, height: 580)
    }
}
