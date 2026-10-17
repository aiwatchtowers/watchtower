import SwiftUI
import WatchtowerCore

/// One Today card: the header (eyebrow, title, body) opens the card's link,
/// each item row its own.
struct TodayCardView: View {
    let card: TodayCard
    let onLink: (HomeLink) -> Void
    /// Add (true) / Dismiss (false) a suggestion; the error to show, nil on success.
    let onDecideSuggestion: (Int64, Bool) async -> String?
    @State private var busy = false
    @State private var errorText: String?

    init(
        card: TodayCard,
        onLink: @escaping (HomeLink) -> Void,
        onDecideSuggestion: @escaping (Int64, Bool) async -> String? = { _, _ in nil }
    ) {
        self.card = card
        self.onLink = onLink
        self.onDecideSuggestion = onDecideSuggestion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { onLink(card.link) } label: { header }
                .buttonStyle(.plain)
            if let id = card.suggestionID {
                suggestionActions(id: id)
            }
            ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                TodayItemRow(item: item, onLink: onLink)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(HomeCardBackground())
    }

    private func suggestionActions(id: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Add") { decide(id, add: true) }
                Button("Dismiss") { decide(id, add: false) }
                Button("More\u{2026}") { onLink(card.link) }
            }
            .disabled(busy)
        }
    }

    private func decide(_ id: Int64, add: Bool) {
        busy = true
        Task {
            let failure = await onDecideSuggestion(id, add)
            errorText = failure
            // A decision stays disabled until the re-read replaces or removes the card.
            busy = failure == nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.eyebrow)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let title = card.title {
                Text(title)
                    .font(.headline)
            }
            if let body = card.body {
                Text(body)
                    .foregroundStyle(card.kind == .nextMeeting ? .secondary : .primary)
                    .lineLimit(card.kind == .briefing ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// An item: an optional chip or status dot, the title and a trailing detail.
private struct TodayItemRow: View {
    let item: TodayItem
    let onLink: (HomeLink) -> Void

    var body: some View {
        Button { onLink(item.link) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let tone = item.tone {
                    HomeStatusDot(color: Self.color(tone))
                }
                if let chip = item.chip {
                    Text(chip)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
                }
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func color(_ tone: TodayItemTone) -> Color {
        switch tone {
        case .overdue: .red
        case .dueToday: .orange
        case .inProgress: .blue
        }
    }
}
