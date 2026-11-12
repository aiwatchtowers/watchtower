import SwiftUI
import WatchtowerCore

/// Track my threads' reading pane (spec "Track my threads (phase 3)", the
/// mockup's `threads` pane): the header with **All Threads**, the threads
/// with news (title, latest line, new-count chip, muted reason), "N more with
/// news" past `TrackThreadsSummary.visibleNewsLimit`, then the quiet note
/// with **Stop Tracking Quiet Ones…** when some quiet threads are old. A
/// row opens that thread's `InboxTrackPane` (behind `InboxTrackBackBar`).
/// The reading pane's `InboxCardColumn` scrolls and pads it.
struct InboxTracksNewsPane: View {
    let summary: TrackThreadsSummary
    /// Stop Tracking Quiet Ones…: built with its plan and apply by the view
    /// model (`quietTracksPress`), which keeps a run alive across navigation.
    @ObservedObject var quietPress: InboxBulkPressModel
    let onOpenThread: (Int) -> Void
    let onAllThreads: () -> Void

    @State private var showsAllNews = false

    init(
        summary: TrackThreadsSummary,
        quietPress: InboxBulkPressModel,
        onOpenThread: @escaping (Int) -> Void,
        onAllThreads: @escaping () -> Void
    ) {
        self.summary = summary
        self.quietPress = quietPress
        self.onOpenThread = onOpenThread
        self.onAllThreads = onAllThreads
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.page) {
            InboxPaneHeader(tile: InboxTile(kind: .threads), title: "Track my threads",
                            subtitle: summary.paneSubtitle) {
                Button("All Threads", action: onAllThreads)
                    .buttonStyle(.kitQuiet)
            }
            if !summary.news.isEmpty {
                newsSection
            }
            if let note = summary.quietNote {
                quietNote(note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - With news

    private var newsSection: some View {
        let hidden = summary.news.count - TrackThreadsSummary.visibleNewsLimit
        let shown = showsAllNews ? summary.news : Array(summary.news.prefix(TrackThreadsSummary.visibleNewsLimit))
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            InboxListSectionHeading(title: "With news for you · \(summary.news.count)")
            ForEach(shown, id: \.track.id) { card in
                newsRow(card)
            }
            if hidden > 0, !showsAllNews {
                Button {
                    showsAllNews = true
                } label: {
                    Label("\(hidden) more with news", systemImage: "chevron.right")
                        .font(.caption)
                }
                .buttonStyle(.kitQuiet)
                .padding(.horizontal, Spacing.regular)
            }
        }
    }

    private func newsRow(_ card: InboxTrackCard) -> some View {
        let line = TrackThreadsSummary.latestLine(card)
        return Button {
            onOpenThread(card.track.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(card.track.text)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !line.isEmpty {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: Spacing.regular)
                // The mockup's `trow`: the count is the chip, the reason muted text.
                if let count = TrackThreadsSummary.newCountText(card) {
                    Chip(text: count, color: .secondary)
                }
                if let reason = TrackThreadsSummary.reason(card) {
                    Text(reason.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .kitRow(isSelected: false)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("inbox.tracksNews.row.\(card.track.id)")
    }

    // MARK: - Quiet

    private func quietNote(_ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if summary.showsStopQuiet {
                InboxBulkPressButton(title: "Stop Tracking Quiet Ones…", confirmTitle: Self.confirmTitle,
                                     model: quietPress)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .padding(.vertical, Spacing.cozy)
        .padding(.horizontal, Spacing.medium)
        .card(fill: Fill.rest)
    }

    /// The confirmation's title and button: "Stop Tracking 1 Thread",
    /// "Stop Tracking 4 Threads".
    static func confirmTitle(_ count: Int) -> String {
        count == 1 ? "Stop Tracking 1 Thread" : "Stop Tracking \(count) Threads"
    }
}

/// Above an opened thread in Track my threads' pane: back to the news list.
struct InboxTrackBackBar: View {
    let onBack: () -> Void

    init(onBack: @escaping () -> Void) {
        self.onBack = onBack
    }

    var body: some View {
        Button(action: onBack) {
            Label("Track my threads", systemImage: "chevron.left")
        }
        .buttonStyle(.kitQuiet)
        .help("Back to Track my threads")
    }
}
