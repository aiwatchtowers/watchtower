import SwiftUI
import WatchtowerCore

/// What the Learn zone and its See all sheet do; `HomeContent` stays
/// closure-driven.
struct LearnZoneActions {
    /// The card's main button (`LearnPrimary`).
    var primary: (LearnPick) -> Void
    var gotIt: (String) -> Void
    /// The card's guide section in the browser.
    var readMore: (LearnCard) -> Void
    /// The ⌘/ popup with "How do I use <title>?".
    var ask: (LearnCard) -> Void
    var showAgain: (String) -> Void

    static let none = Self(primary: { _ in }, gotIt: { _ in }, readMore: { _ in }, ask: { _ in }, showAgain: { _ in })
}

/// Home's Learn Watchtower zone (design §9.4), the last of the right column:
/// "N of M seen" with a thin bar and See all, then up to three cards; when
/// every card is seen, one line. Hidden by the caller when there is no
/// selection (the catalog failed or has no cards).
struct LearnZoneView: View {
    let selection: LearnSelection
    let actions: LearnZoneActions
    @State private var showsAll = false

    var body: some View {
        HomeZone(title: "Learn Watchtower", detail: "\(selection.seenCount) of \(selection.total) seen") {
            Button("See all →") { showsAll = true }
        } content: {
            ProgressView(value: Double(selection.seenCount), total: Double(max(selection.total, 1)))
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .homeZoneInset()
                .accessibilityLabel("\(selection.seenCount) of \(selection.total) seen")
            if selection.home.isEmpty {
                Text("You've seen everything. New cards come with each update.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Spacing.small)
                    .homeZoneInset()
            } else {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    ForEach(selection.home) { pick in
                        LearnCardView(pick: pick, actions: actions)
                    }
                }
                .padding(.top, Spacing.small)
            }
        }
        .sheet(isPresented: $showsAll) {
            LearnAllSheet(selection: selection, actions: actions) { showsAll = false }
        }
    }
}

/// One Home card: area icon, title with its badge, text, then the main
/// button, Got it, and the Read more / Ask about this links.
struct LearnCardView: View {
    let pick: LearnPick
    let actions: LearnZoneActions

    var body: some View {
        let primary = LearnPrimary(pick)
        HStack(alignment: .top, spacing: Spacing.cozy) {
            LearnAreaIcon(area: pick.card.area)
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    Text(LearnText.styled(pick.card.title))
                        .fontWeight(.semibold)
                    LearnBadge(variant: pick.variant)
                }
                Text(LearnText.styled(LearnText.text(pick)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Spacing.regular) {
                    Button(LearnText.primaryTitle(primary)) { actions.primary(pick) }
                        .buttonStyle(.kitSecondary)
                    Button("Got it") { actions.gotIt(pick.id) }
                        .buttonStyle(.kitQuiet)
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                .padding(.top, Spacing.tight)
                HStack(spacing: Spacing.medium) {
                    if primary != .readMore, pick.card.guideURL != nil {
                        Button("Read more") { actions.readMore(pick.card) }
                    }
                    Button("Ask about this") { actions.ask(pick.card) }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Spacing.cozy)
        .padding(.horizontal, Spacing.medium)
        .card(fill: Surface.detail)
    }
}

/// A card's area as an accent icon on a soft tile.
struct LearnAreaIcon: View {
    let area: LearnArea

    var body: some View {
        Image(systemName: LearnText.symbol(area))
            .font(.callout)
            .foregroundStyle(.tint)
            .frame(width: IconSize.tile, height: IconSize.tile)
            .background(Fill.selected, in: RoundedRectangle(cornerRadius: Radius.control))
            .accessibilityHidden(true)
    }
}

/// NEW IN X.Y / UPDATED IN X.Y; nothing on an ordinary card.
struct LearnBadge: View {
    let variant: LearnVariant

    var body: some View {
        switch variant {
        case .normal: EmptyView()
        case .new(let version): Chip(text: "NEW IN \(version)", color: Tone.success)
        case .updated(let version, _): Chip(text: "UPDATED IN \(version)", color: Tone.warning)
        }
    }
}

/// The Learn views' text and symbols.
enum LearnText {
    /// The button's title; a nav screen is named by its sidebar title.
    static func primaryTitle(_ primary: LearnPrimary) -> String {
        primary.title(screenTitle: screenTitle)
    }

    /// A `watchtower-nav` screen's name: the sidebar title, or the Inbox
    /// filter an old screen name opens.
    static func screenTitle(_ screen: String) -> String? {
        if let destination = SidebarDestination(rawValue: screen) { return destination.title }
        switch screen {
        case "briefings": return "Briefing"
        case "dayPlan", "day-plan": return "Day Plan"
        case "tracks": return "Tracks"
        case "ideas": return "Ideas"
        default: return nil
        }
    }

    /// A card's string with its inline markdown (`**bold**`, `` `code` ``)
    /// applied; the plain string when it does not parse.
    static func styled(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
    }

    /// An updated card shows what changed.
    static func text(_ pick: LearnPick) -> String {
        if case .updated(_, let text) = pick.variant { return text }
        return pick.card.text
    }

    static func areaTitle(_ area: LearnArea) -> String {
        switch area {
        case .communication: "Communication"
        case .meetings: "Meetings"
        case .tasks: "Tasks"
        case .development: "Development"
        case .assistant: "Assistant"
        case .planning: "Planning"
        case .automations: "Automations"
        case .iphone: "iPhone"
        case .setup: "Setup"
        }
    }

    static func symbol(_ area: LearnArea) -> String {
        switch area {
        case .communication: "bubble.left.and.bubble.right"
        case .meetings: "waveform"
        case .tasks: "checklist"
        case .development: "hammer"
        case .assistant: "sparkles"
        case .planning: "sun.max"
        case .automations: "gearshape.2"
        case .iphone: "iphone"
        case .setup: "slider.horizontal.3"
        }
    }
}
