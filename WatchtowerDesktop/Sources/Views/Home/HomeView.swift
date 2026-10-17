import SwiftUI
import WatchtowerCore

/// The Home tab: where the app opens. Binds `AppState.homeCenter`'s snapshot
/// to `HomeContent`; it never reads on its own, so coming back to Home shows
/// the snapshot the center already holds.
struct HomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TimelineView(.everyMinute) { context in
            HomeContent(
                snapshot: appState.homeCenter.snapshot,
                today: context.date,
                onLink: { appState.openHomeLink($0) },
                onDecideSuggestion: { await appState.decideInstructionSuggestion(id: $0, add: $1) },
                onHideGettingReady: { appState.homeCenter.hideGettingReady() }
            )
        }
    }
}

/// Home's page: header, Getting ready, Today. No `@Environment(AppState.self)`:
/// values and closures only, so ViewInspector can drive it.
struct HomeContent: View {
    /// nil until the first read.
    let snapshot: HomeSnapshot?
    let today: Date
    let onLink: (HomeLink) -> Void
    let onDecideSuggestion: (Int64, Bool) async -> String?
    let onHideGettingReady: () -> Void

    init(
        snapshot: HomeSnapshot?,
        today: Date,
        onLink: @escaping (HomeLink) -> Void,
        onDecideSuggestion: @escaping (Int64, Bool) async -> String? = { _, _ in nil },
        onHideGettingReady: @escaping () -> Void
    ) {
        self.onDecideSuggestion = onDecideSuggestion
        self.snapshot = snapshot
        self.today = today
        self.onLink = onLink
        self.onHideGettingReady = onHideGettingReady
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                if let snapshot {
                    GettingReadyZoneView(
                        zone: snapshot.gettingReady, firstSync: snapshot.firstSync,
                        onLink: onLink, onHide: onHideGettingReady)
                    TodayZoneView(
                        cards: snapshot.today, nothingNeedsYou: snapshot.nothingNeedsYou,
                        readFailed: snapshot.showsReadError, onLink: onLink,
                        onDecideSuggestion: onDecideSuggestion)
                    if snapshot.showsAskHint {
                        Text("Press ⌘/ to ask anything about Watchtower.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Home")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Home")
                .font(.largeTitle.bold())
            Text(Self.dateLine(today))
                .foregroundStyle(.secondary)
        }
    }

    /// "Thursday, October 15". UI text is English only.
    static func dateLine(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter
    }()
}

/// A zone's header: the title, an optional subtitle and trailing content.
struct HomeZoneHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension HomeZoneHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A Home card's surface: the system control background with a hairline,
/// or a dashed outline for a Connect row.
struct HomeCardBackground: View {
    var dashed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if dashed {
            shape.strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        } else {
            shape
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

/// An 8 pt status dot.
struct HomeStatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}
