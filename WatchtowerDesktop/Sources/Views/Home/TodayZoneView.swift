import SwiftUI
import WatchtowerCore

/// Home's right column: the remaining Today cards stacked in snapshot order,
/// or the read error when an allowed read failed. No all-clear here: the
/// feed owns it, so with no card and no failed read the column is empty.
struct TodayZoneView: View {
    let cards: [TodayCard]
    let readFailed: Bool
    let onLink: (HomeLink) -> Void
    let onDecideSuggestion: (Int64, Bool) async -> String?

    init(
        cards: [TodayCard],
        readFailed: Bool,
        onLink: @escaping (HomeLink) -> Void,
        onDecideSuggestion: @escaping (Int64, Bool) async -> String? = { _, _ in nil }
    ) {
        self.onDecideSuggestion = onDecideSuggestion
        self.cards = cards
        self.readFailed = readFailed
        self.onLink = onLink
    }

    var body: some View {
        if !cards.isEmpty || readFailed {
            VStack(alignment: .leading, spacing: 20) {
                if !cards.isEmpty {
                    ForEach(cards, id: \.kind) { card in
                        TodayCardView(card: card, onLink: onLink, onDecideSuggestion: onDecideSuggestion)
                            .id(card.suggestionID)
                    }
                } else {
                    TodayReadErrorLine()
                }
            }
        }
    }
}

/// The line the right column shows instead of cards when their read failed.
private struct TodayReadErrorLine: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Couldn't read today's items — see the log.")
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
    }
}
