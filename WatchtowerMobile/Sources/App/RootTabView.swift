import SwiftUI
import UIKit

/// The five tabs (design pass spec §5, amending mobile POC spec §13 A4; iPhone chat spec §6.1; mobile Inbox
/// spec §7, ask #1349): Now, Inbox, Workbench, Chats and Calendar. Settings is pushed from Now's gear; a voice
/// note is the Calendar's mic button.
struct RootTabView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case now, inbox, workbench, chats, calendar

        var id: Self { self }

        var title: String {
            switch self {
            case .now: "Now"
            case .inbox: InboxPhoneText.tabTitle
            case .workbench: "Workbench"
            case .chats: "Chats"
            case .calendar: "Calendar"
            }
        }

        var systemImage: String {
            switch self {
            case .now: "clock"
            case .inbox: "tray"
            case .workbench: "hammer"
            case .chats: "bubble.left.and.bubble.right"
            case .calendar: "calendar"
            }
        }

        /// The Now tab's badge (#1788): what Now's Waiting for you lists for
        /// the hub on screen, open asks, pending permission requests and
        /// failed sessions to continue (`WorkbenchReplicaModel.waitingCount`;
        /// orange, set in `init`);
        /// 0 hides it. The Inbox's is the sum of its folders' `waiting` (open
        /// approvals and rows that wait on the owner, `InboxCenter.badge`;
        /// ask #1349), orange too. The other tabs carry none.
        /// The app icon's badge counts Now's things summed over every hub
        /// that can still answer them (`AppEnvironment.openAskTotal`), so with
        /// one Mac the two agree.
        func badge(waitingCount: Int, inboxWaiting: Int = 0) -> Int {
            switch self {
            case .now: waitingCount
            case .inbox: inboxWaiting
            case .workbench, .chats, .calendar: 0
            }
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

    /// The Chats tab's frame in the screenshot tour; nil reads the hub on screen.
    private let chatsShot: ChatsShot?
    /// The Inbox tab's frame in the screenshot tour; nil reads the hub on screen.
    private let inboxShot: InboxShot?

    init(chatsShot: ChatsShot? = nil, inboxShot: InboxShot? = nil) {
        self.chatsShot = chatsShot
        self.inboxShot = inboxShot
        Self.configureTabBarAppearance()
    }

    /// The tab badges (Now's waiting count, the Inbox's waiting rows) are
    /// waiting-for-you elements, orange. `UITabBarItem.appearance().badgeColor` alone did not reach
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
                    .badge(tab.badge(waitingCount: env.workbenchReplica.waitingCount, inboxWaiting: inboxBadge))
                    .tag(tab)
            }
        }
        // A hub switch rebuilds the tabs, so every tab's stack starts at
        // its root (multi-hub spec §5.6). Only the tabs: the recorder's
        // cover and the REC bar below stay outside it, so the recorder
        // that owns the microphone or the screen (`env.recorder`, maybe
        // another hub's) stays on screen across the switch.
        .id(env.activeHubID)
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

    /// The Inbox's waiting count while the hub on screen publishes the Inbox.
    private var inboxBadge: Int {
        if let inboxShot { return inboxShot.center.badge(capability: inboxShot.inputs.capability) }
        let heartbeat = env.workbenchReplica.snapshot.heartbeat
        return env.inbox.badge(capability: heartbeat == nil ? InboxCapability.on : heartbeat?.capabilities?.inbox)
    }

    @ViewBuilder
    private func content(for tab: Tab) -> some View {
        switch tab {
        case .now:
            NowView()
        case .inbox:
            InboxTabView(shot: inboxShot)
        case .workbench:
            WorkbenchListView()
        case .chats:
            ChatsTabView(shot: chatsShot)
        case .calendar:
            AgendaView()
        }
    }
}
