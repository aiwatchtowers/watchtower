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
                onExpand: { appState.homeCenter.setFeedExpanded($0) },
                onReconnect: { appState.openAccountConnection(source: $0) },
                purges: appState.accountPurgeCenter?.openRows ?? []
            )
        }
    }
}

/// Home's page: header, Getting ready, then two columns — the feed on the
/// left, Workbench, links and numbers on the right — or one column below
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
    /// Open account purges (board #601): the red banner above Getting ready.
    let purges: [AccountPurge]
    let onReconnect: (String) -> Void

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
        onExpand: @escaping (Bool) -> Void = { _ in },
        onReconnect: @escaping (String) -> Void = { _ in },
        purges: [AccountPurge] = []
    ) {
        self.purges = purges
        self.onReconnect = onReconnect
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
            VStack(alignment: .leading, spacing: Spacing.wide) {
                header
                if !purges.isEmpty {
                    AccountPurgeBanner(rows: purges, zone: calendar.timeZone, onReconnect: onReconnect)
                }
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
            .padding(.horizontal, Spacing.hero)
            .padding(.top, Spacing.wide)
            .padding(.bottom, Spacing.hero)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .detailBackground()
        .navigationTitle("Home")
    }

    /// The feed and the right column side by side across the whole width
    /// when the content is at least `twoColumnWidth` wide, else one column:
    /// feed first.
    private func columns(_ snapshot: HomeSnapshot) -> some View {
        let feed = FeedZoneView(
            feed: snapshot.feed, errors: feedErrors, onLink: onLink, onAct: onAct, onExpand: onExpand, now: today,
            calendar: calendar)
        let right = HomeSideColumn(snapshot: snapshot, onLink: onLink, onDecideSuggestion: onDecideSuggestion)
        return ViewThatFits(in: .horizontal) {
            HomeColumnsLayout(spacing: Spacing.page) {
                feed
                right
            }
            VStack(alignment: .leading, spacing: Spacing.page) {
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
        VStack(alignment: .leading, spacing: Spacing.tight) {
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

/// Home's right column: the Workbench zone, the links zone and today in
/// numbers, in that order; a zone with nothing to show is left out (numbers
/// show once their first read lands).
struct HomeSideColumn: View {
    let snapshot: HomeSnapshot
    let onLink: (HomeLink) -> Void
    let onDecideSuggestion: (Int64, Bool) async -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.page) {
            if snapshot.showsWorkbench {
                WorkbenchZoneView(
                    blocks: snapshot.workbench, suggestion: snapshot.suggestion, failed: snapshot.workbenchFailed,
                    onLink: onLink, onDecideSuggestion: onDecideSuggestion)
            }
            if !snapshot.links.isEmpty {
                LinksZoneView(links: snapshot.links, failed: snapshot.linksFailed, onLink: onLink)
            }
            if let numbers = snapshot.numbers {
                NumbersZoneView(numbers: numbers)
            }
        }
    }
}

/// The feed and the right column side by side, split about 60/40 (the
/// mockup's 1.55 : 1) across the whole proposed width; each column is as
/// tall as its own content. Its ideal width is `HomeContent.twoColumnWidth`,
/// so `ViewThatFits` falls back to one column below it.
struct HomeColumnsLayout: Layout {
    static let feedShare: CGFloat = 1.55 / 2.55
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = Self.resolvedWidth(proposal.width)
        let heights = zip(subviews, columnWidths(width)).map { subview, columnWidth in
            subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
        }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x = bounds.minX
        for (subview, columnWidth) in zip(subviews, columnWidths(bounds.width)) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: columnWidth, height: nil))
            x += columnWidth + spacing
        }
    }

    /// Never narrower than the breakpoint, whatever is proposed (the old
    /// row's `minWidth`), so the two columns never fit below it; nil or an
    /// infinite proposal is the breakpoint itself (the ideal width).
    static func resolvedWidth(_ proposed: CGFloat?) -> CGFloat {
        max(proposed.flatMap { $0.isFinite ? $0 : nil } ?? 0, HomeContent.twoColumnWidth)
    }

    /// The feed's and the right column's widths.
    func columnWidths(_ width: CGFloat) -> [CGFloat] {
        let feed = ((width - spacing) * Self.feedShare).rounded()
        return [feed, width - spacing - feed]
    }
}

/// A Home zone, as the mockup draws it: a small uppercase title with a
/// dimmer detail (a count, a progress) and an optional trailing control over
/// the content, on a kit card. Rows inside use `.kitRow`, whose plate insets
/// the text by `Spacing.regular`; other content takes `homeZoneInset()` to
/// line up.
struct HomeZone<Trailing: View, Content: View>: View {
    let title: String
    /// After the title: "49", "6 of 11 ready"; nil shows the title alone.
    var detail: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(alignment: .center, spacing: Spacing.regular) {
                HomeZoneTitle(title: title, detail: detail)
                Spacer(minLength: Spacing.regular)
                trailing
                    .buttonStyle(.kitQuiet)
                    .controlSize(.small)
            }
            .homeZoneInset()
            VStack(alignment: .leading, spacing: Spacing.tight) {
                content
            }
        }
        .padding(.vertical, Spacing.medium)
        .padding(.horizontal, Spacing.small)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}

extension HomeZone where Trailing == EmptyView {
    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, detail: detail, trailing: { EmptyView() }, content: content)
    }
}

/// "WAITING ON YOU · 49": the zone's title in small caps, then its detail.
struct HomeZoneTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Text(title)
                .textCase(.uppercase)
                .tracking(Tracking.caps)
                .foregroundStyle(.secondary)
            if let detail {
                Text("· \(detail)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption.weight(.bold))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Lines non-row content of a zone up with the text of its `.kitRow` rows.
    func homeZoneInset() -> some View {
        padding(.horizontal, Spacing.regular)
    }
}

/// "Couldn't read <zone> — see the log.": a zone whose read failed says so
/// and never reads as empty.
struct HomeZoneErrorLine: View {
    let zone: String

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Tone.warning)
                .accessibilityHidden(true)
            Text("Couldn't read \(zone) — see the log.")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Spacing.small)
        .homeZoneInset()
    }
}

/// A Connect row's dashed outline.
struct HomeDashedOutline: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
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
