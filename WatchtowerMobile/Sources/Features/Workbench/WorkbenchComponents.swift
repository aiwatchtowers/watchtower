import SwiftUI

/// A small count pill in the model's tone.
struct CountPill: View {
    let text: String
    let tone: PhoneTone

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tone.color)
            .background(tone.color.opacity(0.15), in: Capsule())
    }
}

/// A session-state count with its dot: "● 2 working".
struct SessionCountLabel: View {
    let count: SessionStateCount

    var body: some View {
        HStack(spacing: 4) {
            SessionDot(tone: count.tone, isRing: count.isRing, size: 7)
            Text(count.text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// One Waiting-for-you card, tinted and bordered in the card's tone.
struct WaitingCardView: View {
    let card: WaitingCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(card.kindLabel)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(card.tone.color)
            Text(card.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Text(card.subline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(card.tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(card.tone.color.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// One SESSIONS row: dot, title, coloured state label, report line with a
/// mini progress bar, open-ask pill and "▸ N closed".
struct SessionRowView: View {
    let row: SessionRowModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SessionDot(tone: row.tone, isRing: row.isRing)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let glyph = row.glyph {
                        Image(systemName: glyph)
                    }
                    Text(row.caption)
                }
                .font(.subheadline)
                .foregroundStyle(row.tone.color)
                .lineLimit(1)
                if let report = row.reportLine {
                    HStack(spacing: 6) {
                        Text(report)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let progress = row.reportProgress {
                            ThinProgressBar(value: progress, tone: row.progressTone, height: 3)
                                .frame(width: 40)
                        }
                    }
                }
                if let closed = row.closedLabel {
                    Text(closed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if row.openAsks > 0 {
                CountPill(text: "\(row.openAsks)", tone: row.openAsksTone)
                    .accessibilityLabel(row.openAsks == 1 ? "1 open ask" : "\(row.openAsks) open asks")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One ask as a flat row (design pass spec §2.7), the Mac's "Waiting for
/// you" row: the kind icon in the waiting tone, the title, and a meta line
/// that starts with the kind word ("Question", semibold, waiting tone)
/// followed by the subline. Orange, not the Mac's accent, by the phone's
/// orange rule.
struct AskRow: View {
    let ask: WaitingCardModel
    var showsChevron = false
    var insets = RowInsets.flat

    var body: some View {
        FlatRow(icon: .symbol(ask.kindIcon, tone: ask.tone), title: ask.title, insets: insets) {
            HStack(spacing: Spacing.compact) {
                Text(ask.kindLabel).font(TypeScale.kind).foregroundStyle(ask.tone.color)
                Text("·")
                Text(ask.subline)
            }
        } trailing: {
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Waiting for you" as one waiting card of flat ask rows (design pass spec
/// N4, S2, D4): each row its own link to the ask's form, rows separated by
/// `RowDivider`s, an optional header on top. For a `ScrollView` only: one
/// `List` row cannot hold several links.
struct WaitingStack<Header: View>: View {
    let asks: [WaitingCardModel]
    @ViewBuilder var header: Header

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(asks.enumerated()), id: \.element.id) { index, ask in
                if index > 0 {
                    RowDivider()
                }
                NavigationLink(value: AskRoute(id: ask.id)) {
                    AskRow(ask: ask, showsChevron: true)
                }
                .buttonStyle(.plain)
            }
        }
        .card(.waiting, padding: EdgeInsets())
    }
}

extension WaitingStack where Header == EmptyView {
    init(asks: [WaitingCardModel]) {
        self.init(asks: asks) { EmptyView() }
    }
}
