import SwiftUI

// MARK: - InboxFeedView

/// Tab container for the secretary Dashboard: the ranked situation feed (`.feed`,
/// rendered by `DashboardView`), the learned-rules manager, and the secretary
/// profile editor. The `.feed` tab used to render a two-tier Inbox feed directly
/// (sender-grouped action/awareness items via `InboxViewModel`/`InboxCardView`);
/// it now renders the situation-composed Dashboard feed instead — see the D9
/// dashboard task. `InboxViewModel`/`InboxCardView` remain in the codebase
/// (still unit-tested) but are no longer wired into this container.
struct InboxFeedView: View {
    @Environment(AppState.self) private var appState
    @State private var tab: Tab = .feed

    /// The dashboard VM is owned by `AppState` (survives tab switches so an
    /// in-flight "Generate" run isn't orphaned on navigation) rather than
    /// created locally here.
    private var dashboardVM: DashboardViewModel? { appState.dashboardViewModel }

    enum Tab { case feed, learned, profile }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            switch tab {
            case .feed:
                if let dashboardVM {
                    DashboardView(vm: dashboardVM)
                } else {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .learned:
                learnedContent
            case .profile:
                profileContent
            }
        }
        .onAppear {
            // Cross-process daemon writes don't fire GRDB ValueObservation, so
            // reload on every tab-appear to pick up situations composed while
            // the dashboard tab was inactive.
            dashboardVM?.refresh()
        }
    }

    // MARK: - Toolbar (Tracks-style: title + count badge + tab picker)

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Dashboard")
                    .font(.title2)
                    .fontWeight(.bold)

                if let dashboardVM, dashboardVM.openCount > 0 {
                    Text("\(dashboardVM.openCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                }

                Spacer()

                if tab == .feed, let dashboardVM {
                    Button {
                        Task { await dashboardVM.generateNow() }
                    } label: {
                        if dashboardVM.isGenerating {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Generate")
                            }
                        } else {
                            Label("Generate", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(dashboardVM.isGenerating)
                    .help("Run the inbox pipeline now")
                }
            }

            Picker("", selection: $tab) {
                Text("Dashboard").tag(Tab.feed)
                Text("Learned").tag(Tab.learned)
                Text("Profile").tag(Tab.profile)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Learned Tab

    @ViewBuilder
    private var learnedContent: some View {
        if let dbPool = appState.databaseManager?.dbPool {
            InboxLearnedRulesView(db: dbPool)
        } else {
            Text("Database unavailable")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Profile Tab

    @ViewBuilder
    private var profileContent: some View {
        if let dbPool = appState.databaseManager?.dbPool {
            SecretaryProfileView(db: dbPool)
        } else {
            Text("Database unavailable")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
