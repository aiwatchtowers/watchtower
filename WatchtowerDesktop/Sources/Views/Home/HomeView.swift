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
                calendar: .current,
                feedErrors: appState.homeCenter.feedErrors,
                digestsTurnOn: appState.digestsTurnOnState,
                onLink: { appState.openHomeLink($0) },
                onDecideSuggestion: { await appState.decideInstructionSuggestion(id: $0, add: $1) },
                onHideGettingReady: { appState.homeCenter.hideGettingReady() },
                onAsk: { appState.toggleHelpChat() },
                onAct: { await appState.homeCenter.act($0, on: $1) },
                onExpand: { appState.homeCenter.setFeedExpanded($0) }
            )
        }
    }
}

/// Home's page: header, Getting ready, then two columns — the feed on the
/// left, the remaining cards on the right — or one column below
/// `twoColumnWidth`. No `@Environment(AppState.self)`: values and closures
/// only, so ViewInspector can drive it.
struct HomeContent: View {
    /// nil until the first read.
    let snapshot: HomeSnapshot?
    let today: Date
    /// The calendar the feed was built with; its zone formats the feed's times.
    let calendar: Calendar
    /// A feed Done / Hide that failed, by row.
    let feedErrors: [FeedRef: String]
    let digestsTurnOn: DigestsTurnOnState
    let onLink: (HomeLink) -> Void
    let onDecideSuggestion: (Int64, Bool) async -> String?
    let onHideGettingReady: () -> Void
    let onAsk: () -> Void
    let onAct: (FeedAction, FeedRef) async -> Void
    let onExpand: (Bool) -> Void

    init(
        snapshot: HomeSnapshot?,
        today: Date,
        calendar: Calendar = .current,
        feedErrors: [FeedRef: String] = [:],
        digestsTurnOn: DigestsTurnOnState = .idle,
        onLink: @escaping (HomeLink) -> Void,
        onDecideSuggestion: @escaping (Int64, Bool) async -> String? = { _, _ in nil },
        onHideGettingReady: @escaping () -> Void,
        onAsk: @escaping () -> Void = {},
        onAct: @escaping (FeedAction, FeedRef) async -> Void = { _, _ in },
        onExpand: @escaping (Bool) -> Void = { _ in }
    ) {
        self.calendar = calendar
        self.feedErrors = feedErrors
        self.onAct = onAct
        self.onExpand = onExpand
        self.onDecideSuggestion = onDecideSuggestion
        self.snapshot = snapshot
        self.today = today
        self.digestsTurnOn = digestsTurnOn
        self.onLink = onLink
        self.onHideGettingReady = onHideGettingReady
        self.onAsk = onAsk
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                if let snapshot {
                    GettingReadyZoneView(
                        zone: snapshot.gettingReady, firstSync: snapshot.firstSync,
                        digestsTurnOn: digestsTurnOn, onLink: onLink, onHide: onHideGettingReady)
                    columns(snapshot)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
                helpLine
            }
            .frame(maxWidth: 1180, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Home")
    }

    /// The feed and the right column side by side when the content is at
    /// least `twoColumnWidth` wide, else one column: feed first. The columns
    /// themselves need 880 pt (feed 520 + 20 spacing + column 340); the row's
    /// minimum width holds the switch at the spec's 900.
    private func columns(_ snapshot: HomeSnapshot) -> some View {
        let feed = FeedZoneView(
            feed: snapshot.feed, errors: feedErrors, onLink: onLink, onAct: onAct, onExpand: onExpand, now: today,
            calendar: calendar)
        let right = TodayZoneView(
            cards: snapshot.today, readFailed: snapshot.showsReadError, onLink: onLink,
            onDecideSuggestion: onDecideSuggestion)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                feed.frame(minWidth: 520, idealWidth: 520, maxWidth: .infinity)
                right.frame(width: 340)
            }
            .frame(minWidth: Self.twoColumnWidth)
            VStack(alignment: .leading, spacing: 20) {
                feed
                right
            }
        }
    }

    /// The content width two columns start at (spec §3).
    static let twoColumnWidth: CGFloat = 900

    private var helpLine: some View {
        HStack(spacing: 0) {
            Text("Stuck? Press ")
            Button("⌘/", action: onAsk).buttonStyle(.link)
            Text(" to ask, or open the ")
            Link("User Guide", destination: GuideLinks.readme)
            Text(".")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
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
