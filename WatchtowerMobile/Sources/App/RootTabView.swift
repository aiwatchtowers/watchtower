import SwiftUI

/// The four tabs (spec §13 A4): Now, Workbench, Calendar and More. Now and
/// Workbench are filled by sub-project B and Calendar by C; until then each
/// shows its empty state. More holds Settings.
struct RootTabView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case now, workbench, calendar, more

        var id: Self { self }

        var title: String {
            switch self {
            case .now: "Now"
            case .workbench: "Workbench"
            case .calendar: "Calendar"
            case .more: "More"
            }
        }

        var systemImage: String {
            switch self {
            case .now: "clock"
            case .workbench: "hammer"
            case .calendar: "calendar"
            case .more: "ellipsis"
            }
        }

        /// Spec §3: 5 s while Now or Workbench is on screen, 30 s otherwise.
        var fetchInterval: Duration {
            switch self {
            case .now, .workbench: .seconds(5)
            case .calendar, .more: .seconds(30)
            }
        }
    }

    @Environment(AppEnvironment.self) private var env
    @State private var selection: Tab = .now

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Tab.allCases) { tab in
                content(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .onChange(of: selection, initial: true) {
            env.setFetchInterval(selection.fetchInterval)
        }
    }

    @ViewBuilder
    private func content(for tab: Tab) -> some View {
        switch tab {
        case .now:
            EmptyTabView(
                title: "Nothing needs you",
                systemImage: "checkmark.circle",
                message: "Asks and sessions from your Mac show up here."
            )
        case .workbench:
            EmptyTabView(
                title: "No workbenches yet",
                systemImage: "hammer",
                message: "Your Mac's workbenches show up here."
            )
        case .calendar:
            EmptyTabView(
                title: "No events",
                systemImage: "calendar",
                message: "Your calendar from the Mac shows up here."
            )
        case .more:
            MoreView()
        }
    }
}

/// A tab's empty state, under its own navigation title.
private struct EmptyTabView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
        }
    }
}

/// More: Settings only.
struct MoreView: View {
    enum Row: CaseIterable, Identifiable {
        case settings

        var id: Self { self }

        var title: String {
            switch self {
            case .settings: "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .settings: "gearshape"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List(Row.allCases) { row in
                NavigationLink {
                    destination(for: row)
                } label: {
                    Label(row.title, systemImage: row.systemImage)
                }
            }
            .navigationTitle("More")
        }
    }

    @ViewBuilder
    private func destination(for row: Row) -> some View {
        switch row {
        case .settings: SettingsView()
        }
    }
}
