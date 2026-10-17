import SwiftUI

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

/// One SESSIONS row (design pass S3): the session dot, the title on one
/// line, one meta line, and the open-ask count as a badge. In a `List`, pass
/// `insets: EdgeInsets()`.
struct SessionRowView: View {
    let row: SessionRowModel
    var insets = RowInsets.flat

    var body: some View {
        FlatRow(icon: .session(tone: row.tone, isRing: row.isRing), title: row.title, titleLineLimit: 1, insets: insets) {
            MetaLine(items: row.metaItems)
        } trailing: {
            if row.openAsks > 0 {
                CountBadge(count: row.openAsks, tone: row.openAsksTone)
                    .accessibilityLabel(row.openAsks == 1 ? "1 open ask" : "\(row.openAsks) open asks")
            }
        }
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
/// N4, S2, D4): each row its own link to the ask's form (a permission
/// request's to its session), rows separated by
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
                link(ask)
            }
        }
        .card(.waiting, padding: EdgeInsets())
    }

    @ViewBuilder
    private func link(_ ask: WaitingCardModel) -> some View {
        switch ask.destination {
        case let .ask(id):
            NavigationLink(value: AskRoute(id: id)) { AskRow(ask: ask, showsChevron: true) }
                .buttonStyle(.plain)
        case let .session(id):
            NavigationLink(value: SessionRoute(id: id)) { AskRow(ask: ask, showsChevron: true) }
                .buttonStyle(.plain)
        }
    }
}

extension WaitingStack where Header == EmptyView {
    init(asks: [WaitingCardModel]) {
        self.init(asks: asks) { EmptyView() }
    }
}
