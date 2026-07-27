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
    private let google = GoogleConnectFlow.shared
    @State private var showConnectOptions = false

    /// The dashboard VM is owned by `AppState` (survives tab switches so an
    /// in-flight "Generate" run isn't orphaned on navigation) rather than
    /// created locally here.
    private var dashboardVM: DashboardViewModel? { appState.dashboardViewModel }
    private var feedVM: FeedViewModel? { appState.feedViewModel }

    enum Tab { case feed, learned, profile }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            switch tab {
            case .feed:
                if let dashboardVM, let feedVM {
                    VStack(spacing: 0) {
                        if !sourcesFullyConnected || google.isRunning {
                            connectSourcesBanner
                            Divider()
                        }
                        DashboardView(vm: dashboardVM, feedVM: feedVM)
                    }
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
            feedVM?.refresh()
            google.refresh()
            appState.emailAccountsViewModel?.refresh()
        }
    }

    // MARK: - Connect Sources Banner

    /// True once an email source is connected — Gmail OR at least one HEALTHY
    /// IMAP/Outlook mailbox, so connecting only an IMAP account (without ever
    /// touching Gmail) satisfies the email leg of the connect check too. An
    /// account stuck in "error"/"revoked" must not count — otherwise its mere
    /// presence in the list would hide the banner even though nothing syncs.
    private var hasEmailSource: Bool {
        google.gmail.isConnected || (appState.emailAccountsViewModel?.accounts.contains { $0.isOK } ?? false)
    }

    /// Whether both the calendar and email legs are connected.
    private var sourcesFullyConnected: Bool {
        google.calendar.isConnected && hasEmailSource
    }

    /// Names of the disconnected sources, for the banner text.
    private var missingSources: [String] {
        var missing: [String] = []
        if !google.calendar.isConnected { missing.append("Google Calendar") }
        if !hasEmailSource { missing.append("Email") }
        return missing
    }

    private var connectSourcesBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(google.isRunning
                ? "Connecting Google... approve access in the browser."
                : "\(missingSources.joined(separator: " and ")) not connected — "
                    + "meeting and email signals are missing from this feed.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            if google.isRunning {
                ProgressView().controlSize(.small)
                Button("Cancel") { google.cancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else {
                Button("Connect") { showConnectOptions = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .popover(isPresented: $showConnectOptions) {
                        connectOptionsPopover
                    }
            }

            if let err = google.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }

    private var connectOptionsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect Google")
                .font(.headline)

            GoogleConnectOptionsView(flow: google)

            Text("Google will show a single approval screen listing exactly the selected access.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Connect") {
                showConnectOptions = false
                google.connect()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!google.hasSelection)
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Toolbar (Tracks-style: title + count badge + tab picker)

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Inbox")
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
                Text("Feed").tag(Tab.feed)
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
        if let vm = appState.secretaryProfileViewModel {
            SecretaryProfileView(vm: vm)
        } else {
            Text("Database unavailable")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
