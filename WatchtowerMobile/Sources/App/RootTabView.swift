import SwiftUI
import UIKit

/// The three tabs (design pass spec §5, amending mobile POC spec §13 A4):
/// Now, Workbench and Calendar. Settings is pushed from Now's gear; a voice
/// note is the Calendar's mic button.
struct RootTabView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case now, workbench, calendar

        var id: Self { self }

        var title: String {
            switch self {
            case .now: "Now"
            case .workbench: "Workbench"
            case .calendar: "Calendar"
            }
        }

        var systemImage: String {
            switch self {
            case .now: "clock"
            case .workbench: "hammer"
            case .calendar: "calendar"
            }
        }

        /// The Workbench tab's badge is the open-ask count (orange, set in
        /// `init`); 0 hides it. Other tabs carry none.
        func badge(openAskCount: Int) -> Int {
            self == .workbench ? openAskCount : 0
        }
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    /// Whether the environment's safety poll runs in `phase`: only while
    /// active. Inactive (Control Center, the app switcher, a call banner)
    /// pauses it like the background; the return fetches at once unless
    /// the last fetch is only seconds old (`AppEnvironment.setActive`).
    static func isActive(in phase: ScenePhase) -> Bool {
        phase == .active
    }

    init() {
        Self.configureTabBarAppearance()
    }

    /// The only tab badge is the open-ask count: a waiting-for-you element,
    /// orange. `UITabBarItem.appearance().badgeColor` alone did not reach
    /// the iOS 26 tab bar in the review captures (it drew red), so every
    /// item layout of the tab bar's appearance carries the colour too.
    static func configureTabBarAppearance() {
        UITabBarItem.appearance().badgeColor = PhoneTone.waitingBadgeColor
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            layout.normal.badgeBackgroundColor = PhoneTone.waitingBadgeColor
            layout.selected.badgeBackgroundColor = PhoneTone.waitingBadgeColor
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        @Bindable var navigation = env.navigation
        TabView(selection: $navigation.tab) {
            ForEach(Tab.allCases) { tab in
                content(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .badge(tab.badge(openAskCount: env.workbenchReplica.openAskCount))
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
        // The safety poll pauses while the app is not active (a
        // recording's audio background mode must not keep it running) and
        // resumes on return. Read at launch too: a launch straight into the
        // background (a silent push) never starts the poll.
        .onChange(of: scenePhase, initial: true) {
            env.setActive(Self.isActive(in: scenePhase))
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
        }
    }
}
