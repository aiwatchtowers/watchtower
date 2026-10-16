import SwiftUI
import WatchtowerCore

/// Home's Today zone: the cards in snapshot order, or one line — the
/// all-clear, or the read error when an allowed read failed (a failed read
/// is never "nothing needs you").
struct TodayZoneView: View {
    let cards: [TodayCard]
    let nothingNeedsYou: Bool
    let readFailed: Bool
    let onLink: (HomeLink) -> Void

    init(cards: [TodayCard], nothingNeedsYou: Bool, readFailed: Bool, onLink: @escaping (HomeLink) -> Void) {
        self.cards = cards
        self.nothingNeedsYou = nothingNeedsYou
        self.readFailed = readFailed
        self.onLink = onLink
    }

    var body: some View {
        if !cards.isEmpty || readFailed || nothingNeedsYou {
            VStack(alignment: .leading, spacing: 12) {
                HomeZoneHeader(title: "Today")
                if !cards.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                        ForEach(cards, id: \.kind) { card in
                            TodayCardView(card: card, onLink: onLink)
                        }
                    }
                } else if readFailed {
                    TodayStatusLine(
                        icon: "exclamationmark.triangle", tint: .orange,
                        text: "Couldn't read today's items — see the log.")
                } else {
                    TodayStatusLine(icon: "checkmark.circle", tint: .green, text: "Nothing needs you right now.")
                }
            }
        }
    }
}

/// The one line Today shows instead of cards.
private struct TodayStatusLine: View {
    let icon: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
    }
}
