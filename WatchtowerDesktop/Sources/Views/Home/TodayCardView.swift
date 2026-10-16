import SwiftUI
import WatchtowerCore

/// One Today card: the header (eyebrow, title, body) opens the card's link,
/// each item row its own.
struct TodayCardView: View {
    let card: TodayCard
    let onLink: (HomeLink) -> Void

    init(card: TodayCard, onLink: @escaping (HomeLink) -> Void) {
        self.card = card
        self.onLink = onLink
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { onLink(card.link) } label: { header }
                .buttonStyle(.plain)
            ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                TodayItemRow(item: item, onLink: onLink)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(HomeCardBackground())
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
