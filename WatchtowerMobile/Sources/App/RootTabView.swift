import SwiftUI
import UIKit

/// The four tabs (spec §13 A4): Now, Workbench, Calendar and More. Now and
/// Workbench come from sub-project B, Calendar from C. More holds Settings
/// and the voice-note entry.
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

        /// The Workbench tab's badge is the open-ask count (orange, set in
        /// `init`); 0 hides it. Other tabs carry none.
        func badge(_ snapshot: WorkbenchReplicaSnapshot) -> Int {
            self == .workbench ? snapshot.openAsks().count : 0
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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The only tab badge is the open-ask count: a waiting-for-you element.
        UITabBarItem.appearance().badgeColor = PhoneTone.waitingBadgeColor
    }

    var body: some View {
        @Bindable var navigation = env.navigation
        TabView(selection: $navigation.tab) {
            ForEach(Tab.allCases) { tab in
                content(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .badge(tab.badge(env.workbenchReplica.snapshot))
                    .tag(tab)
            }
        }
        // A minimized capture keeps a red bar above everything: tap to
        // return to the recorder.
        .safeAreaInset(edge: .top, spacing: 0) {
            if env.recorder.isCapturing, !env.recorder.isPresented {
                RecordingMiniBar()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { env.recorder.isPresented },
            set: { presented in
                // A swipe-down only minimizes: the capture goes on.
                guard !presented else { return }
                if env.recorder.isCapturing {
                    env.recorder.minimize()
                } else {
                    env.recorder.close()
                }
            }
        )) {
            RecordingView()
        }
        .onChange(of: env.navigation.tab, initial: true) {
            env.setFetchInterval(env.navigation.tab.fetchInterval)
        }
        // The fetch loop pauses in the background (a recording's audio
        // background mode must not keep it running) and resumes on return.
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background: env.setActive(false)
            case .active: env.setActive(true)
            default: break
            }
        }
    }

    @ViewBuilder
    private func content(for tab: Tab) -> some View {
        switch tab {
        case .now:
            NowView()
        case .workbench:
            WorkbenchListView()
        case .calendar:
            AgendaView()
        case .more:
            MoreView()
        }
    }
}

/// More: Settings, and the free voice-note entry of the recorder.
struct MoreView: View {
    @Environment(AppEnvironment.self) private var env

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
            List {
                Section {
                    Button {
                        Task { await env.recorder.recordVoiceNote() }
                    } label: {
                        Label("Record a voice note", systemImage: "mic")
                    }
                }
                Section {
                    ForEach(Row.allCases) { row in
                        NavigationLink {
                            destination(for: row)
                        } label: {
                            Label(row.title, systemImage: row.systemImage)
                        }
                    }
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
